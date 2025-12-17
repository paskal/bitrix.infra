#!/usr/bin/env bash
set -eu

# Directories to search for images
IMAGE_DIRS="web/prod/images web/prod/upload"
DB="private/image-optimisation/optimised.db"

# Base find command to locate files in the directories
FIND_CMD="find $IMAGE_DIRS -type f"

# Find command specifically for locating image files
FIND_IMAGES_CMD="$FIND_CMD \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) -not -iname '*.tmp.webp'"

# This script optimises png, jpeg, webp, and gif images on the site using SQLite to track optimised files.
# It uses optipng and advancecomp for PNGs, jpegoptim for JPEGs, cwebp for WebP images, and gifsicle for GIFs.

# Install missing packages
sudo apt-get -y install optipng advancecomp jpegoptim webp gifsicle pv sqlite3 >/dev/null

# Initialize SQLite database
mkdir -p "$(dirname "$DB")"
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS optimised (
    path TEXT PRIMARY KEY,
    mtime INTEGER NOT NULL,
    size INTEGER NOT NULL
);"
sqlite3 "$DB" "CREATE INDEX IF NOT EXISTS idx_path ON optimised(path);"

# Check if file needs optimization (returns 0 if needs optimization, 1 if already done)
needs_optimise() {
    local file="$1"
    local mtime size result
    mtime=$(stat -c %Y "$file")
    size=$(stat -c %s "$file")
    result=$(sqlite3 "$DB" "SELECT 1 FROM optimised WHERE path='$file' AND mtime=$mtime AND size=$size LIMIT 1;")
    [[ -z "$result" ]]
}

# Mark file as optimised
mark_optimised() {
    local file="$1"
    local mtime size
    mtime=$(stat -c %Y "$file")
    size=$(stat -c %s "$file")
    sqlite3 "$DB" "INSERT OR REPLACE INTO optimised (path, mtime, size) VALUES ('$file', $mtime, $size);"
}

# Function to optimise PNGs
optimise_png() {
    local file="$1"
    if nice -n 10 ionice -c2 -n7 optipng -quiet -fix -o7 -preserve "$file"; then
        if nice -n 10 ionice -c2 -n7 advpng --quiet -z4 "$file"; then
            mark_optimised "$file"
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
        mark_optimised "$file"
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
        mark_optimised "$file"
    else
        echo "Error: Failed to process $file with cwebp. Skipping." >&2
        rm -f "$tmpfile"
    fi
}

# Function to optimise GIFs
optimise_gif() {
    local file="$1"
    if nice -n 10 ionice -c2 -n7 gifsicle --optimize=3 --batch "$file"; then
        mark_optimised "$file"
    else
        echo "Error: Failed to process $file with gifsicle. Skipping." >&2
    fi
}

# Clean up orphaned entries from database
cleanup_orphaned() {
    echo "Cleaning up orphaned database entries..."
    local count_before count_after
    count_before=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")

    sqlite3 "$DB" "SELECT path FROM optimised;" | while read -r path; do
        if [[ ! -f "$path" ]]; then
            sqlite3 "$DB" "DELETE FROM optimised WHERE path='$path';"
        fi
    done

    count_after=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")
    echo "Removed $((count_before - count_after)) orphaned entries"
}

# Function to calculate and display progress stats
display_stats() {
    local total optimised percent
    total=$(eval "$FIND_IMAGES_CMD" | wc -l)
    optimised=$(sqlite3 "$DB" "SELECT COUNT(*) FROM optimised;")
    percent=$(awk "BEGIN {printf \"%.2f\", ($optimised/$total)*100}")
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
echo "Calculating initial statistics..."
display_stats

echo "Optimising images..."
total_files=$(eval "$FIND_IMAGES_CMD" | wc -l)

eval "$FIND_IMAGES_CMD" | pv -l -s "$total_files" | while read -r file; do
    if needs_optimise "$file"; then
        optimise_file "$file"
    fi
done

echo "Calculating final statistics..."
display_stats

cleanup_orphaned

echo "Images optimisation complete"
