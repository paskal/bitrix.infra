#!/usr/bin/env sh
set -e

# This script sets proper owner and group for files in the repo

# cron tasks should be owned by root, otherwise they won't run
# and will be silently ignored
echo "Fixing cron permissions..."
chown -R 0:0 ./config/cron
chmod 0644 ./config/cron/*

# mysql container files
echo "Fixing mysql permissions..."
chown -R 1001:1001 ./config/mysql
chown -R 1001:1001 ./logs/mysql
chown -R 1001:1001 ./private/mysql-data
chown -R 1001:1001 ./private/mysqld

# php and nginx containers files
echo "Fixing php and nginx permissions..."
chown -R 0:0 ./config/nginx
chown -R 0:0 ./config/php
chown -R 1000:1000 ./logs/nginx
chown -R 1000:1000 ./logs/php
chown -R 1000:1000 ./private/letsencrypt
chown -R 1000:1000 ./private/msmtprc
echo "web folder will be processed now, hold on..."
chown -R 1000:1000 ./web

echo "Access rights fix is complete"
