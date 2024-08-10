#!/usr/bin/env sh
set -e -u

# Directories to search for images
IMAGE_DIRS="web/prod/images web/prod/upload"

# Base find command to locate files in the directories
FIND_CMD="find $IMAGE_DIRS -type f"

# Find command specifically for locating image files, now including GIF files
FIND_IMAGES_CMD="$FIND_CMD \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' \) -not -iname '*.tmp.webp'"

# This script optimises png, jpeg, webp, and gif images on the site and marks them as optimised, so that they are not processed again.
# It uses optipng and advancecomp for PNGs, jpegoptim for JPEGs, cwebp for WebP images, and gifsicle for GIFs.
# The script is designed to be run as a cron job.
# It only processes files that have been modified since the last optimisation.
# It also cleans up orphaned .optimised and leftover .tmp.webp files and shows a progress bar.

# Install missing packages
sudo apt-get -y install optipng advancecomp jpegoptim webp gifsicle pv >/dev/null

# Function to optimise PNGs
optimise_png() {
    local file="$1"
    if nice -n 10 ionice -c2 -n7 optipng -quiet -fix -o7 -preserve "$file"; then
        if nice -n 10 ionice -c2 -n7 advpng --quiet -z4 "$file"; then
            touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
            chmod 600 "$file.optimised"  # Restrict permissions to owner only
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
        touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
        chmod 600 "$file.optimised"  # Restrict permissions to owner only
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
        touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
        chmod 600 "$file.optimised"  # Restrict permissions to owner only
    else
        echo "Error: Failed to process $file with cwebp. Skipping." >&2
        rm -f "$tmpfile"  # Clean up temporary file if optimization fails
    fi
}

# Function to optimise GIFs
optimise_gif() {
    local file="$1"
    if nice -n 10 ionice -c2 -n7 gifsicle --optimize=3 --batch "$file"; then
        touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
        chmod 600 "$file.optimised"  # Restrict permissions to owner only
    else
        echo "Error: Failed to process $file with gifsicle. Skipping." >&2
    fi
}

# Clean up orphaned .optimised and leftover .tmp.webp files
cleanup_optimised_and_tmp_files() {
    $FIND_CMD \( -iname "*.optimised" -o -iname "*.tmp.webp" \) | while read -r file; do
        original_file="${file%.optimised}"
        if [ ! -f "$original_file" ]; then
            rm -f "$file"
        fi
    done
}

# Function to calculate and display progress stats
display_stats() {
    total=$(eval "$FIND_IMAGES_CMD" | wc -l)
    optimised=$($FIND_CMD -iname "*.optimised" | wc -l)
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

# Start processing images with progress bar
echo "Calculating initial statistics..."
display_stats

echo "Optimising images..."

# Count the total number of files
total_files=$(eval "$FIND_IMAGES_CMD" | wc -l)

# Process the files and update progress bar
eval "$FIND_IMAGES_CMD" | pv -l -s "$total_files" | while read -r file; do
    if [ ! -f "${file}.optimised" ] || [ "$file" -nt "${file}.optimised" ]; then
        optimise_file "$file"
    fi
done

echo "Calculating final statistics..."
display_stats

# Cleanup orphaned .optimised and leftover .tmp.webp files
echo "Cleaning up orphaned .optimised and leftover .tmp.webp files..."
cleanup_optimised_and_tmp_files

echo "Images optimisation and cleanup complete"

