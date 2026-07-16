#!/bin/sh

set -eu
umask 027

log_dir=/var/log/pure-ftpd
session_log="$log_dir/pureftpd.log"
session_history="$log_dir/session-history.log"

mkdir -p "$log_dir"
chmod 0750 "$log_dir"

# The image's /run.sh removes pureftpd.log whenever verbose logging is enabled.
# Append the previous run to a persistent, rotated history first.
if [ -s "$session_log" ]; then
  printf '\nFTP container restart at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$session_history"
  cat "$session_log" >>"$session_history"
fi

exec /run.sh "$@" -P "${PUBLICHOST:-localhost}"
