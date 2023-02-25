#!/usr/bin/env sh
set -e -u

# This script blocks /info/blog/ via robots.txt for regions other than
# Moscow so that it would be indexed only there.
# Also, block /montag/ for Tula as it's not present there.

echo "Getting list of robots.txt files..."
robots_files=$(ls -1 web/*/aspro_regions/robots/*.txt)

# perl replace commands adds text in the file only if it's not already there
# \n doesn't work here for god knows why, so replaced it with \s
for f in $robots_files; do
  filename=$(basename "${f}")
  case $filename in
  robots_favor-group.ru.txt)
    echo "Ignoring ${f}"
    ;;
  robots_tula.favor-group.ru.txt)
    echo "Processing ${f}"
    # disallow blog and montag section
    perl -0777 -pi -e 's/^(Disallow: \/bitrix\/\*)\s+(Allow)/\1\nDisallow: \/info\/blog\/\n\2/gm' "${f}"
    perl -0777 -pi -e 's/^(Disallow: \/basket)\s+(Disallow: \/form\/)/\1\nDisallow: \/montag\/\n\2/gm' "${f}"
    ;;
  *)
    echo "Processing ${f}"
    # disallow only blog
    perl -0777 -pi -e 's/^(Disallow: \/bitrix\/\*)\s+(Allow)/\1\nDisallow: \/info\/blog\/\n\2/gm' "${f}"
    ;;
  esac
done

echo "robots.txt files other than Moscow, have /info/blog/ disallow entry now, and Tula disallows /montag/ also"
