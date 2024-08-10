#!/bin/bash

# Directory to search for images
SEARCH_DIR="web/prod"

# Exclude directory
EXCLUDE_DIR="web/prod/bitrix"

# Function to get the expected MIME type based on file extension
get_expected_mime_type() {
    case "$1" in
        jpg|jpeg) echo "image/jpeg" ;;
        png) echo "image/png" ;;
        webp) echo "image/webp" ;;
        gif) echo "image/gif" ;;
        bmp) echo "image/bmp" ;;
        *) echo "" ;;
    esac
}

# Find files, exclude the specified directory, and compare their MIME types with their extensions
find "$SEARCH_DIR" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.webp' -o -iname '*.gif' -o -iname '*.bmp' \) -not -path "$EXCLUDE_DIR/*" -print0 | while IFS= read -r -d '' file; do
    # Get the file extension in lowercase
    extension="${file##*.}"
    extension="${extension,,}"  # Convert to lowercase

    # Get the actual MIME type of the file
    mime_type=$(file --mime-type -b "$file")

    # Get the expected MIME type based on the file extension
    expected_mime_type=$(get_expected_mime_type "$extension")

    # Compare and print if there's a mismatch
    if [ -n "$expected_mime_type" ] && [ "$mime_type" != "$expected_mime_type" ]; then
        echo "Mismatch: $file - Extension: .$extension, MIME type: $mime_type"
    fi
done
