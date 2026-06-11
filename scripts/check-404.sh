#!/usr/bin/env sh
set -u

# Print 404s from the nginx access log for redirects troubleshooting.
# Usage: check-404.sh [log-file]
# The log file defaults to logs/nginx/prod.access.log or can be set via CHECK_404_LOG.

LOG_FILE="${1:-${CHECK_404_LOG:-logs/nginx/prod.access.log}}"

if [ ! -f "${LOG_FILE}" ]; then
  echo "ERROR: log file not found: ${LOG_FILE}" >&2
  echo "Usage: $0 [log-file]  or set CHECK_404_LOG env var" >&2
  exit 1
fi

grep -F '" 404 ' "${LOG_FILE}" | grep -E 'YandexBot/|Googlebot/' | cut -d '"' -f 2 | cut -d ' ' -f 2 | grep -Ev '^(/bitrix/cache/|/upload/)' | sort | uniq -c | sort -rn | less
