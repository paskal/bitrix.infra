#!/usr/bin/env sh
# Incremental file backup to S3 via duplicity.
# Configuration is read from private/environment/backup.env.
# Required variables: BACKUP_S3_BUCKET, S3_ENDPOINT_URL

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

src="/web"
cache_dir="${src}/backup/.duplicity-cache"
dest="boto3+s3://${BACKUP_S3_BUCKET}/duplicity_web_$(hostname)"

# HOME is required to read .aws/credentials from it
HOME="/home/admin" duplicity \
  --no-encryption \
  --full-if-older-than 60D \
  --asynchronous-upload \
  --s3-use-ia \
  --s3-endpoint-url "${S3_ENDPOINT_URL}" \
  --log-file /web/logs/duplicity.log \
  --archive-dir "${cache_dir}" \
  --exclude '**/.git' \
  --exclude '**/.synosnap_data' \
  --exclude '**/backup/' \
  --exclude '**/logs/' \
  --exclude '**/private/mysqld/' \
  --exclude '**/private/mysql-data/' \
  --exclude '**/web/dev/' \
  --exclude '**/web/prod/upload/tmp/' \
  --exclude '**/web/prod/upload/esol.importxml' \
  --exclude '**/web/prod/upload/acrit.core/.tmp' \
  --exclude '**/web/prod/bitrix/managed_cache' \
  --exclude '**/web/prod/bitrix/cache' \
  --exclude '**/.cache' \
  --exclude '**/.idea' \
  "${src}" "${dest}"
