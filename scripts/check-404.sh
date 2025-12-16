#!/usr/bin/env sh
set -u

# this script prints current 404s from favor-group.ru for redirects troubleshooting
# google shows year-old pages and we need to redirect poor souls clicking on them somewhere

grep -F '" 404 ' logs/nginx/prod.access.log | grep -E 'YandexBot/|Googlebot/' | cut -d '"' -f 2 | cut -d ' ' -f 2 | grep -Ev '^(/bitrix/cache/|/upload/)' | sort | uniq -c | sort -rn | less
