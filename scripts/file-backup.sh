#!/usr/bin/env sh

set -e -u

src="/web"
cache_dir="${src}/backup/.duplicity-cache"
dest="boto3+s3://favor-group-backup/duplicity_web_$(hostname)"

# HOME is required to read .aws/credentials from it
HOME="/home/admin" duplicity \
  --no-encryption \
  --full-if-older-than 60D \
  --asynchronous-upload \
  --s3-use-ia \
  --s3-endpoint-url https://storage.yandexcloud.net \
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
