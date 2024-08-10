#!/usr/bin/env sh
set -e -u

# This script optimises png, jpeg, and webp images on the site and marks them as optimised, so that they are not processed again.
# It uses optipng and advancecomp for PNGs, jpegoptim for JPEGs, and cwebp for WebP images.
# The script is designed to be run as a cron job.
# It only processes files that have been modified since the last optimisation.
# It also cleans up orphaned .optimised files.

# Install missing packages
sudo apt -y install optipng advancecomp jpegoptim webp

# Function to optimise PNGs
optimise_png() {
    local file="$1"
    if nice -n 10 ionice -c2 -n7 optipng -fix -o7 -preserve "$file"; then
        if nice -n 10 ionice -c2 -n7 advpng -z4 "$file"; then
            touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
            chmod 600 "$file.optimised"  # Restrict permissions to owner only
        else
            echo "Error: Failed to process $file with advpng. Skipping."
        fi
    else
        echo "Error: Failed to process $file with optipng. Skipping."
    fi
}

# Function to optimise JPEGs
optimise_jpeg() {
    local file="$1"
    if nice -n 10 ionice -c2 -n7 jpegoptim --strip-none "$file"; then
        touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
        chmod 600 "$file.optimised"  # Restrict permissions to owner only
    else
        echo "Error: Failed to process $file with jpegoptim. Skipping."
    fi
}

# Function to optimise WebP images
optimise_webp() {
    local file="$1"
    local tmpfile="${file}.tmp.webp"
    if nice -n 10 ionice -c2 -n7 cwebp -q 100 "$file" -o "$tmpfile"; then
        mv "$tmpfile" "$file"
        touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
        chmod 600 "$file.optimised"  # Restrict permissions to owner only
    else
        echo "Error: Failed to process $file with cwebp. Skipping."
        rm -f "$tmpfile"  # Clean up temporary file if optimization fails
    fi
}

# Clean up orphaned .optimised files
cleanup_optimised_flags() {
    find web/prod/images web/prod/upload -type f -iname "*.optimised" | while read -r flag; do
        original_file="${flag%.optimised}"
        if [ ! -f "$original_file" ]; then
            rm -f "$flag"
        fi
    done
}

# Single find command to locate PNG, JPEG, and WebP files, case insensitive
echo "Optimising images..."
find web/prod/images web/prod/upload -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.webp" \) | while read -r file; do
    if [ ! -f "${file}.optimised" ] || [ "$file" -nt "${file}.optimised" ]; then
        # Convert file extension to lowercase
        extension=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
        case "$extension" in
            png)
                optimise_png "$file"
                ;;
            jpg|jpeg)
                optimise_jpeg "$file"
                ;;
            webp)
                optimise_webp "$file"
                ;;
        esac
    fi
done

# Cleanup orphaned .optimised files
echo "Cleaning up orphaned .optimised files..."
cleanup_optimised_flags

echo "Images optimisation and cleanup complete"
