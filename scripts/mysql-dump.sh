#!/usr/bin/env bash
# MySQL dump to local directory and sync to S3.
# Configuration is read from private/environment/backup.env and
# private/environment/mysql.env.
# Required variables: BACKUP_S3_BUCKET, S3_ENDPOINT_URL, DOMAIN
# Optional second destination: BACKUP2_S3_BUCKET, BACKUP2_S3_ENDPOINT_URL, BACKUP2_AWS_PROFILE

set -e -u -o pipefail

BACKUP_ENV="./private/environment/backup.env"
if [ ! -f "${BACKUP_ENV}" ]; then
  echo "ERROR: ${BACKUP_ENV} is missing. Copy backup.env.example and fill in values." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${BACKUP_ENV}"
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET must be set in ${BACKUP_ENV}}"
: "${S3_ENDPOINT_URL:?S3_ENDPOINT_URL must be set in ${BACKUP_ENV}}"
: "${DOMAIN:?DOMAIN must be set in ${BACKUP_ENV}}"

prod_db=$(echo "${DOMAIN}" | tr '.' '_' | tr '-' '_')
date="$(date +%Y-%m-%d)"
time="$(date +%H-%M-%S)"
backup_directory_path="./backup/"
backup_directory="${backup_directory_path}${date}"
backup_file="${date}-${time}-${prod_db}-mysqldump.sql.gz"
backup_path="${backup_directory}/${backup_file}"
backup_tmp=''
mysql_config_file=''

cleanup() {
  if [ -n "${backup_tmp}" ]; then
    rm -f -- "${backup_tmp}"
  fi
  if [ -n "${mysql_config_file}" ]; then
    rm -f -- "${mysql_config_file}"
  fi
}
trap cleanup EXIT

if [ ! -d "${backup_directory}" ]; then
  echo "Creating backup directory: ${backup_directory}"
  mkdir -p "${backup_directory}"
  chown 1000:1000 "${backup_directory}"
fi

# The dump is written under a temporary name owned by this run and renamed only
# after it passed the checks below, so a failed run never leaves a file that the
# S3 sync would upload.
backup_tmp=$(mktemp --suffix=.tmp "${backup_path}.XXXXXX")

# read MYSQL_ROOT_PASSWORD
# shellcheck disable=SC1091
. ./private/environment/mysql.env

# create temp file to store mysql login and password for the time of the script
# location for it should be the directory which is passed inside the container
mysql_config_file=$(
  echo 'mkstemp(template)' |
    m4 -D template="./private/mysql-data/deleteme_XXXXXX"
) || exit

mysql_binary_path="docker exec -u0 mysql /bin"
mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"

printf '[client]\nuser = root\npassword = %s\ndefault-character-set = utf8mb4\n' "${MYSQL_ROOT_PASSWORD}" >"${mysql_config_file}"

echo "Backing up MySQL to ${backup_path}"

# mysql_binary_path is an intentional multi-word command prefix ("docker exec -u0 mysql /bin");
# it MUST stay unquoted so the shell word-splits it into argv. Quoting it makes the shell look
# for a single executable literally named "docker exec -u0 mysql /bin/mysqldump" and fail with
# "not found", producing an empty (20-byte) gzip that uploads as a silently-broken backup.
# pipefail makes a mysqldump failure abort the run even though pigz exits successfully.
# shellcheck disable=SC2086
${mysql_binary_path}/mysqldump --defaults-extra-file="${mysql_config_inside_container}" --routines --single-transaction --flush-logs --no-tablespaces --ignore-table="${prod_db}.b_user_session" "${prod_db}" | pigz -c >"${backup_tmp}"
chmod 0640 "${backup_tmp}"
chown 1000:1000 "${backup_tmp}"

# Sanity guard: a real dump is ~100 MB. A mysqldump that exits 0 with next to no output
# (wrong database name, empty schema) would otherwise upload as a silently-broken backup.
backup_size=$(stat -c %s "${backup_tmp}")
if [ "${backup_size}" -lt 1000000 ]; then
  echo "ERROR: ${backup_file} is only ${backup_size} bytes (<1 MB); mysqldump likely failed. NOT syncing to S3." >&2
  exit 1
fi
mv -f -- "${backup_tmp}" "${backup_path}"

# sync with S3; ignore the duplicity caches in the backup volume (one per destination,
# .duplicity-cache and .duplicity-cache-2; aws filters let * cross "/") and any dump a crashed
# run left under its temporary name. The optional third argument is the credentials profile
# holding that destination's keys (none = the default credentials).
sync_to() {
  echo "Syncing backups to s3://$1"
  HOME=/home/admin /usr/local/bin/aws ${3:+--profile "$3"} --endpoint-url="$2" s3 sync "${backup_directory_path}" "s3://$1/mysql_$(hostname)/" --exclude '.duplicity-cache*' --exclude '*.tmp'
}
# A failed destination does not stop the other one: the second copy matters most exactly when
# the first provider is down. The run still exits non-zero if either failed.
failed=0
sync_to "${BACKUP_S3_BUCKET}" "${S3_ENDPOINT_URL}" || failed=1
if [ -n "${BACKUP2_S3_BUCKET:-}" ]; then
  sync_to "${BACKUP2_S3_BUCKET}" \
    "${BACKUP2_S3_ENDPOINT_URL:?BACKUP2_S3_ENDPOINT_URL must be set when BACKUP2_S3_BUCKET is}" \
    "${BACKUP2_AWS_PROFILE:-}" || failed=1
fi
if [ "${failed}" -ne 0 ]; then
  echo "ERROR: S3 sync failed for at least one destination" >&2
  exit 1
fi

# Monitoring status file — written ONLY on a fully successful run (guard passed + sync to every
# destination done).
# The zabbix-agent reads it read-only via ./logs/backup:/var/log/backup; a stale mtime means
# the dump has been failing, and the size value is a secondary guard. See the "Backup monitoring"
# Zabbix template (config/zabbix/templates/backup-monitoring.yaml).
mkdir -p ./logs/backup
echo "${backup_size}" >./logs/backup/mysql-last-size.txt
chown -R 1000:1000 ./logs/backup 2>/dev/null || true

echo "Backup is complete"
