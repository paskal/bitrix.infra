#!/usr/bin/env sh
# Incremental file backup to S3 via duplicity.
# Configuration is read from private/environment/backup.env.
# Required variables: BACKUP_S3_BUCKET, S3_ENDPOINT_URL
# Optional second destination: BACKUP2_S3_BUCKET, BACKUP2_S3_ENDPOINT_URL, BACKUP2_AWS_PROFILE

set -e -u

BACKUP_ENV="./private/environment/backup.env"
if [ ! -f "${BACKUP_ENV}" ]; then
  echo "ERROR: ${BACKUP_ENV} is missing. Copy backup.env.example and fill in values." >&2
  exit 1
fi
# shellcheck disable=SC1090
. "${BACKUP_ENV}"
# the deploy user keeps the S3 keys in its ~/.aws
# shellcheck source=scripts/deploy-user.sh
. ./scripts/deploy-user.sh
: "${BACKUP_S3_BUCKET:?BACKUP_S3_BUCKET must be set in ${BACKUP_ENV}}"
: "${S3_ENDPOINT_URL:?S3_ENDPOINT_URL must be set in ${BACKUP_ENV}}"

src="/web"
cache_dir="${src}/backup/.duplicity-cache"

# Each destination keeps its own independent chain (full every 60 days), so either one restores
# on its own. Each also gets its own archive-dir: duplicity names its cache after the target URL,
# which leaves out the endpoint, so two providers with the same bucket name would share one cache.
# HOME is required to read .aws/credentials from it; an optional fourth argument names the
# credentials profile with the destination's keys (none = the default credentials).
# NOTE: --no-encryption uploads to S3 in cleartext, including private/environment/*.env
# (MySQL root password, OAuth/AWS tokens) which is NOT excluded below. The bucket ACL is
# the only protection — keep every destination bucket private. Matches the DR restore path,
# which also runs --no-encryption (see scripts/disaster-recovery.sh).
backup_to() {
  env HOME="${deploy_home}" ${4:+"AWS_PROFILE=$4"} duplicity \
    --no-encryption \
    --full-if-older-than 60D \
    --asynchronous-upload \
    --s3-use-ia \
    --s3-endpoint-url "$2" \
    --log-file /web/logs/duplicity.log \
    --archive-dir "$3" \
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
    "${src}" "boto3+s3://$1/duplicity_web_$(hostname)"
}

# A failed destination does not stop the other one: the second copy matters most exactly when
# the first provider is down. The run still exits non-zero if either failed.
failed=0
backup_to "${BACKUP_S3_BUCKET}" "${S3_ENDPOINT_URL}" "${cache_dir}" || failed=1
if [ -n "${BACKUP2_S3_BUCKET:-}" ]; then
  backup_to "${BACKUP2_S3_BUCKET}" \
    "${BACKUP2_S3_ENDPOINT_URL:?BACKUP2_S3_ENDPOINT_URL must be set when BACKUP2_S3_BUCKET is}" \
    "${cache_dir}-2" "${BACKUP2_AWS_PROFILE:-}" || failed=1
fi
if [ "${failed}" -ne 0 ]; then
  echo "ERROR: duplicity failed for at least one destination, see /web/logs/duplicity.log" >&2
  exit 1
fi

# Monitoring status file — written only after duplicity exited 0 for every destination, so a
# failing second destination also leaves it stale.
# duplicity 3.x prints no completion summary, so this mtime is the freshness signal the
# zabbix-agent reads via ./logs/backup:/var/log/backup. See backup-monitoring Zabbix template.
mkdir -p /web/logs/backup
date +%s > /web/logs/backup/files-last.txt
chown -R 1000:1000 /web/logs/backup 2>/dev/null || true
