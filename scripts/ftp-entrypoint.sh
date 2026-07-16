#!/bin/sh

set -eu
umask 027

log_dir=/var/log/pure-ftpd
session_log="$log_dir/pureftpd.log"
session_history="$log_dir/session-history.log"
log_uid=${FTP_LOG_UID:-1000}
log_gid=${FTP_LOG_GID:-1000}

# The image starts rsyslog and then unlinks its already-open FTP log. Run as a
# narrow rm guard when /run.sh resolves this script through the temporary PATH.
if [ "${0##*/}" = "rm" ]; then
  if [ "$#" -eq 2 ] && [ "$1" = "-rf" ] && [ "$2" = "$session_log" ]; then
    : >"$session_log"
    exit 0
  fi
  exec /bin/rm "$@"
fi

mkdir -p "$log_dir"
chmod 0750 "$log_dir"

# The image's /run.sh removes pureftpd.log whenever verbose logging is enabled.
# Append the previous run to a persistent, rotated history first.
if [ -s "$session_log" ]; then
  printf '\nFTP container restart at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$session_history"
  cat "$session_log" >>"$session_history"
fi

: >"$session_log"
touch "$session_history"
chown "$log_uid:$log_gid" "$log_dir" "$session_log" "$session_history"
chmod 0640 "$session_log" "$session_history"

guard_dir=/tmp/ftp-command-guards
mkdir -p "$guard_dir"
ln -sf /usr/local/sbin/ftp-entrypoint.sh "$guard_dir/rm"
PATH="$guard_dir:$PATH"
export PATH

exec /run.sh "$@" -P "${PUBLICHOST:-localhost}"
