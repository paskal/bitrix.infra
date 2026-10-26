#!/usr/bin/env bash
set -euo pipefail
# Every sort and comm below compares byte-wise. Cron runs with the system locale, in which comm
# rejects C-sorted input and the script would stop before optimising anything.
export LC_ALL=C

# This script losslessly optimises png, jpeg and gif images on the site, using SQLite to track optimised files.
# It uses optipng and advancecomp for PNGs, jpegoptim for JPEGs, and gifsicle for GIFs. WebP images are left
# alone: cwebp can only re-encode them lossily, which degrades them and often makes them larger.

IMAGE_DIRS="web/prod/images web/prod/upload"
# Bitrix thumbnails, regenerated from the originals whenever its cache is cleared
RESIZE_CACHE="web/prod/upload/resize_cache"
DB="private/image-optimisation/optimised.db"
# rows are written to the database every this many files, so an interrupted run keeps its progress
FLUSH_EVERY=500
# a run that succeeds or makes progress touches this file when the directory exists (the private
# overlay mounts it into the Zabbix agent)
HEARTBEAT="logs/heartbeat/optimise-images"

# --originals-only leaves the thumbnails out, to work through a large backlog of originals first
originals_only=0
case "${1:-}" in
"") ;;
--originals-only) originals_only=1 ;;
*)
  echo "usage: $0 [--originals-only]" >&2
  exit 2
  ;;
esac

heartbeat() {
  if [[ -d "$(dirname "$HEARTBEAT")" ]]; then
    touch "$HEARTBEAT"
  fi
}

# Install missing packages; an apt lock held by another process must not stop a run that has them all
for tool in optipng advpng jpegoptim gifsicle sqlite3; do
  if ! command -v "$tool" >/dev/null; then
    sudo apt-get -y install optipng advancecomp jpegoptim gifsicle sqlite3 >/dev/null
    break
  fi
done

mkdir -p "$(dirname "$DB")"
# The first run over a large backlog can take days; the next weekly start must not run alongside it
exec 9>"$(dirname "$DB")/optimise.lock"
if ! flock -n 9; then
  echo "another optimise-images run is still going" >&2
  exit 1
fi

# Initialize SQLite database
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS optimised (
    path TEXT PRIMARY KEY,
    mtime INTEGER NOT NULL,
    size INTEGER NOT NULL
);"

# Queue file to be marked as optimised (batched for performance); a file removed in the meantime is skipped
queue_optimised() {
  local file="$1"
  local mtime size escaped
  mtime=$(stat -c %Y "$file" 2>/dev/null) || return 0
  size=$(stat -c %s "$file" 2>/dev/null) || return 0
  escaped=$(printf '%s' "$file" | sed "s/'/''/g")
  echo "INSERT OR REPLACE INTO optimised (path, mtime, size) VALUES ('$escaped', $mtime, $size);" >>"$TMPDIR/batch_update.sql"
}

# Flush queued updates to database in a single transaction
flush_optimised() {
  if [[ -s "$TMPDIR/batch_update.sql" ]]; then
    {
      echo "BEGIN TRANSACTION;"
      cat "$TMPDIR/batch_update.sql"
      echo "COMMIT;"
    } | sqlite3 "$DB"
    : >"$TMPDIR/batch_update.sql"
    heartbeat
  fi
}

# Function to optimise PNGs
optimise_png() {
  local file="$1"
  if nice -n 10 ionice -c2 -n7 optipng -quiet -fix -o7 -preserve "$file"; then
    if nice -n 10 ionice -c2 -n7 advpng --quiet -z4 "$file"; then
      queue_optimised "$file"
    else
      echo "Error: Failed to process $file with advpng. Skipping." >&2
    fi
  else
    echo "Error: Failed to process $file with optipng. Skipping." >&2
  fi
}

# Function to optimise JPEGs
optimise_jpeg() {
  local file="$1"
  if nice -n 10 ionice -c2 -n7 jpegoptim --quiet --strip-none "$file"; then
    queue_optimised "$file"
  else
    echo "Error: Failed to process $file with jpegoptim. Skipping." >&2
  fi
}

# Function to optimise GIFs
optimise_gif() {
  local file="$1"
  if nice -n 10 ionice -c2 -n7 gifsicle --optimize=3 --batch "$file"; then
    queue_optimised "$file"
  else
    echo "Error: Failed to process $file with gifsicle. Skipping." >&2
  fi
}

# A copy to another host or the monthly hard-link deduplication changes a file's mtime but not its
# content, so a file whose path and size still match its row keeps counting as optimised
adopt_new_mtimes() {
  sqlite3 "$DB" <<EOF
CREATE TEMP TABLE fs (path TEXT PRIMARY KEY, mtime INTEGER, size INTEGER);
.separator |
.import $TMPDIR/fs_state.txt fs
UPDATE optimised SET mtime = (SELECT fs.mtime FROM fs WHERE fs.path = optimised.path)
WHERE EXISTS (SELECT 1 FROM fs WHERE fs.path = optimised.path AND fs.size = optimised.size AND fs.mtime <> optimised.mtime);
SELECT 'Adopted the new mtime of ' || changes() || ' unchanged files';
EOF
}

# Clean up orphaned entries from database using pre-computed file list
cleanup_orphaned_from_list() {
  local fs_paths="$1"
  echo "Cleaning up orphaned database entries..."
  local count_before count_after
  count_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")

  # Extract just paths from db_state and compare with fs_paths
  cut -d'|' -f1 <"$TMPDIR/db_state.txt" | sort >"$TMPDIR/db_paths.txt"
  # a run without the thumbnails keeps their rows
  if ((originals_only)); then
    grep -v "^$RESIZE_CACHE/" "$TMPDIR/db_paths.txt" >"$TMPDIR/db_paths_scoped.txt" || true
    mv "$TMPDIR/db_paths_scoped.txt" "$TMPDIR/db_paths.txt"
  fi

  # Files in DB but not in filesystem are orphaned. The scan leaves out files changed in the last
  # ten minutes, so each candidate is checked on disk. The statements go through stdin, since a
  # single argument is limited to 128 KiB.
  {
    echo "BEGIN TRANSACTION;"
    comm -23 "$TMPDIR/db_paths.txt" "$fs_paths" | while IFS= read -r path; do
      if [[ ! -e "$path" ]]; then
        printf '%s\n' "$path"
      fi
    done | sed "s/'/''/g; s/.*/DELETE FROM optimised WHERE path='&';/"
    echo "COMMIT;"
  } | sqlite3 "$DB"

  count_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")
  echo "Removed $((count_before - count_after)) orphaned entries"
}

# Display stats using pre-computed counts
display_stats_from_counts() {
  local total="$1"
  local optimised="$2"
  local percent
  if [[ "$total" -eq 0 ]]; then
    percent="0.00"
  else
    percent=$(awk "BEGIN {printf \"%.2f\", ($optimised/$total)*100}")
  fi
  echo "Total images: $total, Optimised images: $optimised, Percentage optimised: $percent%"
}

# Function to determine file type and optimize accordingly
optimise_file() {
  local file="$1"
  local file_type
  file_type=$(file --mime-type -b "$file")

  case "$file_type" in
  image/png)
    optimise_png "$file"
    ;;
  image/jpeg)
    optimise_jpeg "$file"
    ;;
  image/gif)
    optimise_gif "$file"
    ;;
  *)
    echo "Warning: Unsupported file type '$file_type' for file '$file'. Skipping." >&2
    ;;
  esac
}

# Main
echo "=== $(date -u +%FT%TZ) optimise-images start ==="
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Scanning filesystem..."
# Files changed in the last ten minutes are left for the next run: Bitrix may still be writing them.
# Leftover temp files from earlier cwebp runs are listed only to be removed.
prune=()
if ((originals_only)); then
  echo "Leaving out $RESIZE_CACHE"
  prune=(-path "$RESIZE_CACHE" -prune -o)
fi
# shellcheck disable=SC2086
find $IMAGE_DIRS "${prune[@]}" -type f ! -mmin -10 \( \
  -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.gif' -o -iname '*.tmp.webp' \
  \) -printf '%p|%Ts|%s\n' 2>/dev/null | sort >"$TMPDIR/fs_all.txt"

# Split into regular images and temp files
grep -v -E '\.(tmp\.webp|tmp\.gif)\|' "$TMPDIR/fs_all.txt" >"$TMPDIR/fs_state.txt" || true
grep -E '\.(tmp\.webp|tmp\.gif)\|' "$TMPDIR/fs_all.txt" | cut -d'|' -f1 >"$TMPDIR/tmp_files.txt" || true
total_images=$(wc -l <"$TMPDIR/fs_state.txt")

adopt_new_mtimes

echo "Exporting database state..."
sqlite3 "$DB" "SELECT path || '|' || mtime || '|' || size FROM optimised;" | sort >"$TMPDIR/db_state.txt"
# rows of the files this run covers: without the thumbnails when they are left out
db_rows_in_scope() {
  if ((originals_only)); then
    grep -c -v "^$RESIZE_CACHE/" "$1" || true
  else
    wc -l <"$1"
  fi
}
db_count=$(db_rows_in_scope "$TMPDIR/db_state.txt")

# Extract just paths for cleanup comparison
cut -d'|' -f1 <"$TMPDIR/fs_state.txt" | sort >"$TMPDIR/fs_paths.txt"

display_stats_from_counts "$total_images" "$db_count"

echo "Finding files to optimize..."
comm -23 "$TMPDIR/fs_state.txt" "$TMPDIR/db_state.txt" | cut -d'|' -f1 >"$TMPDIR/to_process.txt"
total_to_process=$(wc -l <"$TMPDIR/to_process.txt")

echo "Optimising $total_to_process images..."
touch "$TMPDIR/batch_update.sql"
processed=0
while read -r file; do
  if [[ -f "$file" ]]; then
    optimise_file "$file"
  fi
  processed=$((processed + 1))
  if ((processed % FLUSH_EVERY == 0)); then
    flush_optimised
    echo "$(date -u +%FT%TZ) $processed of $total_to_process"
  fi
done <"$TMPDIR/to_process.txt"
flush_optimised

cleanup_orphaned_from_list "$TMPDIR/fs_paths.txt"

# Cleanup leftover temp files
tmp_count=$(wc -l <"$TMPDIR/tmp_files.txt")
if [[ "$tmp_count" -gt 0 ]]; then
  echo "Cleaning up $tmp_count temp files..."
  while read -r tmpfile; do
    rm -f "$tmpfile"
  done <"$TMPDIR/tmp_files.txt"
fi

sqlite3 "$DB" "SELECT path FROM optimised;" >"$TMPDIR/db_final.txt"
final_db_count=$(db_rows_in_scope "$TMPDIR/db_final.txt")
display_stats_from_counts "$total_images" "$final_db_count"

heartbeat
echo "Images optimisation complete"
