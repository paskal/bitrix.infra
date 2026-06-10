#!/usr/bin/env sh
# MySQL dump to local directory and sync to S3.
# Configuration is read from private/environment/backup.env and
# private/environment/mysql.env.
# Required variables: BACKUP_S3_BUCKET, S3_ENDPOINT_URL, DOMAIN

set -e -u

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

if [ ! -d "${backup_directory}" ]; then
  echo "Creating backup directory: ${backup_directory}"
  mkdir -p "${backup_directory}"
  chown 1000:1000 "${backup_directory}"
fi

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

# shellcheck disable=SC2028
# echo will expand everything properly in sh (which we are using)
# but will require -e flag in bash to work
echo "[client]\nuser = root\npassword = ${MYSQL_ROOT_PASSWORD}" >"${mysql_config_file}"

echo "Backing up MySQL to ${backup_directory}/${backup_file}"

"${mysql_binary_path}"/mysqldump --defaults-extra-file="${mysql_config_inside_container}" --routines --single-transaction --flush-logs --no-tablespaces --ignore-table="${prod_db}.b_user_session" "${prod_db}" | pigz -c >"${backup_directory}/${backup_file}"
chmod 0640 "${backup_directory}/${backup_file}"
chown 1000:1000 "${backup_directory}/${backup_file}"

# clean up tmp file with credentials
rm -f -- "${mysql_config_file}"

echo "Syncing backups to s3://${BACKUP_S3_BUCKET}"
# sync with S3; also ignore duplicity cache in the backup volume
HOME=/home/admin /usr/local/bin/aws --endpoint-url="${S3_ENDPOINT_URL}" s3 sync "${backup_directory_path}" "s3://${BACKUP_S3_BUCKET}/mysql_$(hostname)/" --exclude '.duplicity-cache/*'

echo "Backup is complete"
