#!/usr/bin/env sh
set -e -u

# This script optimises png and jpeg images on the site and marks them as optimised, so that they are not processed again.
# It uses optipng and advancecomp for PNGs and jpegoptim for JPEGs.
# The script is designed to be run as a cron job.
# It only processes files that have been modified since the last optimisation.
# It also cleans up orphaned .optimised files.

# Install missing packages
sudo apt -y install optipng advancecomp jpegoptim

# Function to optimise PNGs
optimise_png() {
    local file="$1"
    nice -n 10 ionice -c2 -n7 optipng -fix -o7 -preserve "$file"
    nice -n 10 ionice -c2 -n7 advpng -z4 "$file"
    touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
    chmod 600 "$file.optimised"  # Restrict permissions to owner only
}

# Function to optimise JPEGs
optimise_jpeg() {
    local file="$1"
    nice -n 10 ionice -c2 -n7 jpegoptim --strip-none "$file"
    touch -r "$file" "$file.optimised"  # Set .optimised file's modification time to the original file's time
    chmod 600 "$file.optimised"  # Restrict permissions to owner only
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

# Optimising PNG files
echo "Optimising PNGs..."
find web/prod/images web/prod/upload -type f -iname "*.png" | while read -r png; do
    if [ ! -f "${png}.optimised" ] || [ "$png" -nt "${png}.optimised" ]; then
        optimise_png "$png"
    fi
done

# Optimising JPEG files
echo "Optimising JPEGs..."
find web/prod/images web/prod/upload -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | while read -r jpg; do
    if [ ! -f "${jpg}.optimised" ] || [ "$jpg" -nt "${jpg}.optimised" ]; then
        optimise_jpeg "$jpg"
    fi
done

# Cleanup orphaned .optimised files
echo "Cleaning up orphaned .optimised files..."
cleanup_optimised_flags

echo "Images optimisation and cleanup complete"

