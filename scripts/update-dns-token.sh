#!/usr/bin/env sh
set -e -u

# write down new token using file rewrite to avoid sed escaping issues
env_file="./private/environment/dnsrobocert.env"
token=$("$HOME/yandex-cloud/bin/yc" iam create-token)
# rewrite file: keep all lines except AUTH_KEY, then append new AUTH_KEY
grep -v '^AUTH_KEY=' "$env_file" >"${env_file}.tmp" || true
printf 'AUTH_KEY=%s\n' "$token" >>"${env_file}.tmp"
mv "${env_file}.tmp" "$env_file"
# recreate services that use the AUTH_KEY only if they are running
if docker compose ps -q certbot | grep -q .; then
  echo "Recreating certbot to pick up new AUTH_KEY..."
  docker compose --profile certs up -d certbot
fi

if docker compose ps -q zabbix-agent | grep -q .; then
  echo "Recreating zabbix-agent to pick up new AUTH_KEY..."
  docker compose --profile monitoring up -d zabbix-agent
fi
