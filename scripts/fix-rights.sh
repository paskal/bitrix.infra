#!/usr/bin/env sh
set -e -u

# This script sets proper owner and group for files in the repo.
# Run with sudo before the first docker-compose up on a fresh clone.

# Create directories that docker file-mounts require to exist as files, not dirs.
# Without this, docker creates them as directories on first mount, breaking the container.
echo "Creating required directories..."
mkdir -p logs/nginx logs/php logs/mysql logs/phpstan \
  private/mysqld private/mysql-data private/nginx \
  private/letsencrypt \
  web/prod web/dev
[ -f private/msmtprc ] || touch private/msmtprc

# cron tasks should be owned by root, otherwise they won't run
# and will be silently ignored
echo "Fixing cron permissions..."
chown -R 0:0 ./config/cron
chmod 0644 ./config/cron/*

# logrotate configuration should be owned by root,
# otherwise it will be ignored
echo "Fixing logrotate permissions..."
chown -R 0:0 ./config/logrotate
chmod 0644 ./config/logrotate/*

# mysql container files
echo "Fixing mysql permissions..."
chown -R 1001:1001 ./config/mysql
[ -d ./logs/mysql ] && chown -R 1001:1001 ./logs/mysql
[ -d ./private/mysql-data ] && chown -R 1001:1001 ./private/mysql-data
[ -d ./private/mysqld ] && chown -R 1001:1001 ./private/mysqld

# php and nginx containers files
echo "Fixing php and nginx permissions..."
[ -d ./logs/nginx ] && chown -R 1000:1000 ./logs/nginx
[ -d ./logs/php ] && chown -R 1000:1000 ./logs/php
[ -d ./logs/phpstan ] && chown -R 1000:1000 ./logs/phpstan
[ -d ./private/letsencrypt ] && chown -R 1000:1000 ./private/letsencrypt
[ -d ./private/nginx ] && chown -R 1000:1000 ./private/nginx
[ -f ./private/msmtprc ] && chown 1000:1000 ./private/msmtprc
echo "web folder will be processed now, hold on..."
chown -R 1000:1000 ./web

echo "Fixing backup folder permissions..."
[ -d ./backup/ ] && chown -R 1000:1000 ./backup/

echo "Access rights fix is complete"
