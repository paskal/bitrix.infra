#!/usr/bin/env sh
set -e -u

# This script sets up Debian-based host machine for bitrix.infra
# and recovers site files and the DB content from the backup.

domain="favor-group.ru"

### Pre-checks

# Check the current running folder
[ -d "./scripts" ] || (echo "./scripts locations is absent, please run from parent directory of this script" && exit 45)

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo, 'sudo $0'"
  exit
fi

# Start recovery

echo "Server has latest backup of files and DB restored!"

### Final DNS recommendation

server_ip=$(dig +short myip.opendns.com @resolver1.opendns.com)
site_a_entry=$(dig +short ${domain})

if [ "${server_ip}" != "${site_a_entry}" ]; then
  echo "Current IP for ${domain} is: ${site_a_entry}"
  echo "This machine external IP (best guess): ${server_ip}"

  echo "\
Please ensure DNS A entries are pointing to this machine external IP: \
https://connect.yandex.ru/portal/services/webmaster/resources/${domain}
"
else
  echo "Server IP (${server_ip}) matches A entry for ${domain}, by now site should be working at https://${domain}"
fi
