#!/usr/bin/env sh
set -e -u

# This script blocks Google via robots.txt for regions other than
# Moscow, Tula and SPB, so that they are indexed only in Yandex

echo "Getting list of robots.txt files..."
robots_files=$(ls -1 web/*/aspro_regions/robots/*.txt)

for f in $robots_files; do
  filename=$(basename "${f}")
  case $filename in
  robots_favor-group.ru.txt)
    echo "Ignoring ${f}"
    ;;
  *)
    echo "Processing ${f}"
    # add text in the file only if it's not already there
    # \n doesn't work here for god knows why, so replaced it with \s
    perl -0777 -pi -e 's/^(Disallow: \/bitrix\/\*)\s+Allow/\1\nDisallow: \/info\/blog\/\nAllow/gm' "${f}"
    ;;
  esac
done

echo "robots.txt files other than Moscow, have /info/blog/ disallow entry now"

