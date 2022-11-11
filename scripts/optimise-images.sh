#!/usr/bin/env sh
set -e -u

# This script optimizes png and jpeg images on the site

# Install missing packages
sudo apt -y install optipng advancecomp jpegoptim

echo "Optimising PNGs..."
find web/prod/images web/prod/upload -type f -iname "*.png" -exec optipng -fix -o7 -preserve {} \;
find web/prod/images web/prod/upload -type f -iname "*.png" -exec advpng -z4 {} \;

echo "Optimising JPEGs..."
find web/prod/images web/prod/upload -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec jpegoptim --strip-none {} \;

echo "Images optimisation complete"
