#!/usr/bin/env sh

set -e -u

src="/web"
dest="boto3+s3://favor-group-backup/duplicity_web_$(hostname)"

# HOME is required to read .aws/credentials from it
HOME="/home/admin" duplicity \
  --no-encryption \
  --full-if-older-than 60D \
  --asynchronous-upload \
  --s3-use-ia \
  --s3-endpoint-url https://storage.yandexcloud.net \
  --log-file /web/logs/duplicity.log \
  --archive-dir /root/.cache/duplicity \
  --exclude '**/.git' \
  --exclude '**/backup/' \
  --exclude '**/logs/' \
  --exclude '**/web/dev' \
  "${src}" "${dest}"
