#!/usr/bin/env sh
# Replace identical files under the site's upload directory with hard links.
# Bitrix keeps many byte-identical copies there (resized images, copied
# product pictures), and hardlink from util-linux merges them in place.
#
# Usage: ./scripts/dedup-upload.sh [--dry-run] [directory]
# The directory defaults to ./web/prod/upload. Run as root, or as a user
# that owns the files: hardlink keeps owner, mode and extended attributes
# and only ignores the modification time, so copies written at different
# times still merge. The full hardlink output and its exit status go to
# ./logs/dedup-upload.log on every run; the console shows the summary.
#
# Hard links share content: a file that is later rewritten in place changes
# every linked copy with it. Bitrix media (iblock, resize_cache, medialibrary)
# is written once and replaced by a new file, never edited in place, and the
# weekly image optimiser rewrites identical bytes into identical bytes, so a
# shared inode is harmless there. Directories that modules use as scratch
# space or logs are excluded below, and a lock keeps two runs apart.

set -e -u

# hardlink prints its summary in the current locale; keep it parseable
LC_ALL=C
export LC_ALL

dry_run=''
target='./web/prod/upload'
for arg in "$@"; do
  case "$arg" in
  --dry-run) dry_run='-n' ;;
  -h | --help)
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  *) target="$arg" ;;
  esac
done

if ! command -v hardlink >/dev/null 2>&1; then
  echo "hardlink is not installed (package util-linux)" >&2
  exit 1
fi
# other programs called hardlink exist; the options below are util-linux's
if ! hardlink --help 2>&1 | grep -q -- '--respect-xattrs'; then
  echo "hardlink here is not the util-linux implementation" >&2
  exit 1
fi
if [ ! -d "$target" ]; then
  echo "$target is not a directory" >&2
  exit 1
fi

# temporary, exchange and log directories that modules rewrite while the site runs
exclude='/(tmp|\.tmp|1c_[^/]*|esol\.importxml|acrit\.core|acrit\.export|sproduction\.integration|webdebug\.antirutin|kda\.importexcel)(/|$)'

mkdir -p ./logs
log=./logs/dedup-upload.log
exec 9>./logs/dedup-upload.lock
if ! flock -n 9; then
  echo "another dedup-upload run is still going" >&2
  exit 1
fi

# -t ignores modification time, -X keeps files with different extended
# attributes apart; owner and mode still have to match
status=0
# shellcheck disable=SC2086
output=$(hardlink -t -X -x "$exclude" $dry_run "$target" 2>&1) || status=$?
{
  echo "$(date -u '+%Y-%m-%d %H:%M:%S') UTC ${dry_run:+dry run }over ${target}, exit ${status}"
  printf '%s\n' "$output"
} >>"$log"
printf '%s\n' "$output" | grep -E '^(Files|Linked|Saved|Duration):' || true
if [ "$status" -ne 0 ]; then
  printf '%s\n' "$output" >&2
  exit "$status"
fi
