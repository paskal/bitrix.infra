#!/usr/bin/env sh
set -e -u

# write down new token
sed -i "s/.*\AUTH_KEY.*/\AUTH_KEY=$($HOME/yandex-cloud/bin/yc iam create-token)/" "./private/environment/dnsrobocert.env"
# recreate services that use the AUTH_KEY only if they are running
if docker compose ps -q certbot | grep -q .; then
    echo "Recreating certbot to pick up new AUTH_KEY..."
    docker compose --profile certs up -d certbot
fi

if docker compose ps -q zabbix-agent | grep -q .; then
    echo "Recreating zabbix-agent to pick up new AUTH_KEY..."
    docker compose --profile monitoring up -d zabbix-agent
fi
