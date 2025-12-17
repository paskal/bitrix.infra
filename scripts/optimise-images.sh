#!/usr/bin/env bash
set -euo pipefail

# This script optimises png, jpeg, webp, and gif images on the site using SQLite to track optimised files.
# It uses optipng and advancecomp for PNGs, jpegoptim for JPEGs, cwebp for WebP images, and gifsicle for GIFs.

IMAGE_DIRS="web/prod/images web/prod/upload"
DB="private/image-optimisation/optimised.db"

# Install missing packages
sudo apt-get -y install optipng advancecomp jpegoptim webp gifsicle pv sqlite3 >/dev/null

# Initialize SQLite database
mkdir -p "$(dirname "$DB")"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS optimised (
    path TEXT PRIMARY KEY,
    mtime INTEGER NOT NULL,
    size INTEGER NOT NULL
);"

# Queue file to be marked as optimised (batched for performance)
queue_optimised() {
    local file="$1"
    local mtime size escaped
    mtime=$(stat -c %Y "$file")
    size=$(stat -c %s "$file")
    escaped=$(printf '%s' "$file" | sed "s/'/''/g")
    echo "INSERT OR REPLACE INTO optimised (path, mtime, size) VALUES ('$escaped', $mtime, $size);" >> "$TMPDIR/batch_update.sql"
}

# Flush queued updates to database in a single transaction
flush_optimised() {
    if [[ -s "$TMPDIR/batch_update.sql" ]]; then
        {
            echo "BEGIN TRANSACTION;"
            cat "$TMPDIR/batch_update.sql"
            echo "COMMIT;"
        } | sqlite3 "$DB"
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

# Function to optimise WebP images
optimise_webp() {
    local file="$1"
    local tmpfile="${file}.tmp.webp"
    if nice -n 10 ionice -c2 -n7 cwebp -q 100 -quiet "$file" -o "$tmpfile"; then
        mv "$tmpfile" "$file"
        queue_optimised "$file"
    else
        echo "Error: Failed to process $file with cwebp. Skipping." >&2
        rm -f "$tmpfile"
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

# Clean up orphaned entries from database using pre-computed file list
cleanup_orphaned_from_list() {
    local fs_paths="$1"
    echo "Cleaning up orphaned database entries..."
    local count_before paths_to_delete=""
    count_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")

    # Extract just paths from db_state and compare with fs_paths
    cut -d'|' -f1 < "$TMPDIR/db_state.txt" > "$TMPDIR/db_paths.txt"

    # Files in DB but not in filesystem are orphaned
    while read -r path; do
        local escaped_path
        escaped_path=$(printf '%s' "$path" | sed "s/'/''/g")
        paths_to_delete+="DELETE FROM optimised WHERE path='${escaped_path}';"
    done < <(comm -23 "$TMPDIR/db_paths.txt" "$fs_paths")

    if [[ -n "$paths_to_delete" ]]; then
        sqlite3 "$DB" "BEGIN TRANSACTION; ${paths_to_delete} COMMIT;"
    fi

    local count_after
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
        image/webp)
            optimise_webp "$file"
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
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Scanning filesystem..."
# shellcheck disable=SC2086
find $IMAGE_DIRS -type f \( \
    -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \
\) -printf '%p|%Ts|%s\n' 2>/dev/null | LC_ALL=C sort > "$TMPDIR/fs_all.txt"

# Split into regular images and temp files
grep -v -E '\.(tmp\.webp|tmp\.gif)\|' "$TMPDIR/fs_all.txt" > "$TMPDIR/fs_state.txt" || true
grep -E '\.(tmp\.webp|tmp\.gif)\|' "$TMPDIR/fs_all.txt" | cut -d'|' -f1 > "$TMPDIR/tmp_files.txt" || true
total_images=$(wc -l < "$TMPDIR/fs_state.txt")

echo "Exporting database state..."
sqlite3 "$DB" "SELECT path || '|' || mtime || '|' || size FROM optimised;" | LC_ALL=C sort > "$TMPDIR/db_state.txt"
db_count=$(wc -l < "$TMPDIR/db_state.txt")

# Extract just paths for cleanup comparison
cut -d'|' -f1 < "$TMPDIR/fs_state.txt" > "$TMPDIR/fs_paths.txt"

display_stats_from_counts "$total_images" "$db_count"

echo "Finding files to optimize..."
comm -23 "$TMPDIR/fs_state.txt" "$TMPDIR/db_state.txt" | cut -d'|' -f1 > "$TMPDIR/to_process.txt"
total_to_process=$(wc -l < "$TMPDIR/to_process.txt")

echo "Optimising $total_to_process images..."
if [[ "$total_to_process" -gt 0 ]]; then
    touch "$TMPDIR/batch_update.sql"
    pv -l -s "$total_to_process" < "$TMPDIR/to_process.txt" | while read -r file; do
        if [[ -f "$file" ]]; then
            optimise_file "$file"
        fi
    done
    flush_optimised
fi

cleanup_orphaned_from_list "$TMPDIR/fs_paths.txt"

# Cleanup leftover temp files
tmp_count=$(wc -l < "$TMPDIR/tmp_files.txt")
if [[ "$tmp_count" -gt 0 ]]; then
    echo "Cleaning up $tmp_count temp files..."
    while read -r tmpfile; do
        rm -f "$tmpfile"
    done < "$TMPDIR/tmp_files.txt"
fi

final_db_count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")
display_stats_from_counts "$total_images" "$final_db_count"

echo "Images optimisation complete"
