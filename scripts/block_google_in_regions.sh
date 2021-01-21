#!/usr/bin/env sh
set -e

# This script blocks Google via robots.txt for regions other than
# Moscow, Tula and SPB, so that they are indexed only in Yandex

echo "Getting list of robots.txt files..."
robots_files=$(ls -1 web/*/aspro_regions/robots/*.txt)

for f in $robots_files; do
  filename=$(basename "${f}")
  case $filename in
  robots_favor-group.ru.txt | robots_spb.favor-group.ru.txt | robots_tula.favor-group.ru.txt)
    echo "Ignoring ${f}"
    ;;
  *)
    echo "Processing ${f}"
    # add text in the beginning of the file only if it's not already there
    sed -i '1s/^\(User-agent: [^G][^o][^o][^g]\)/User-agent: Googlebot\nDisallow: \/\n\n\1/' "${f}"
    ;;
  esac
done

echo "robots.txt files other than Moscow, SPB and Tula have Google block entry now"

