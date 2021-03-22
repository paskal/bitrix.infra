#!/usr/bin/env sh
set -e -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo, 'sudo $0'"
  exit
fi

# This script sets up Debian-based host machine for favor-group.ru
# and recovers site files and the DB content from the backup.

# Check the current running folder
[ -d "./scripts" ] || (echo "./scripts locations is absent, please run from parent directory of this script" && exit 45)
