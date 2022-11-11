#!/usr/bin/env sh
set -e -u

# This script optimizes png and jpeg images on the site

# Install missing packages
sudo apt -y install optipng advancecomp jpegoptim

echo "Optimising PNGs..."
find web/prod -type f -iname "*.png" -exec optipng -o7 -preserve {} \;
find web/prod -type f -iname "*.png" -exec advpng -z4 {} \;

echo "Optimising JPEGs..."
find web/prod -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec jpegoptim --strip-none {} \;

echo "Images optimisation complete"
