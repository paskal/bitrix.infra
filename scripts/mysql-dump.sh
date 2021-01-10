#!/usr/bin/env bash

set -e -u -o pipefail

PROD_DB=admin_favorgroup
SHORTHOSTNAME="${HOSTNAME/.*/}"
DATE="$(date +%Y-%m-%d)"
TIME="$(date +%H-%M-%S)"
DIRECTORY="/backup/$SHORTHOSTNAME/$DATE"
FILE="$DATE-$TIME-$SHORTHOSTNAME-$PROD_DB-mysqldump.sql.gz"

if [ ! -d "$DIRECTORY" ]; then
  echo "Creating backup directory: $DIRECTORY"
  mkdir -p "$DIRECTORY"
fi

PROC_NUM=$(echo "$(nproc)/2" | bc)

if [ -z "$PROC_NUM" ]; then
  PROC_NUM=1
elif [ "$PROC_NUM" -lt 1 ]; then
  PROC_NUM=1
fi

# read MYSQL_ROOT_PASSWORD
. ./private/environment/mysql.env

# create temp file to store mysql login and password for the time of the script
# location for it should be the directory which is passed inside the container
mysql_config_file=$(
  echo 'mkstemp(template)' |
    m4 -D template="./private/mysql-data/deleteme_XXXXXX"
) || exit

mysql_binary_path="docker exec -u0 mysql /bin"
mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"

# bash echo required -e to write \n as a newline
echo -e "[client]\nuser = root\npassword = ${MYSQL_ROOT_PASSWORD}" >${mysql_config_file}

echo "Backing up MySQL to $DIRECTORY"

${mysql_binary_path}/mysqldump --defaults-extra-file=${mysql_config_inside_container} --routines --single-transaction --flush-logs --no-tablespaces --no-data ${PROD_DB} | pigz -p $PROC_NUM -c >"$DIRECTORY/$FILE"
${mysql_binary_path}/mysqldump --defaults-extra-file=${mysql_config_inside_container} --routines --single-transaction --flush-logs --no-tablespaces --ignore-table=${PROD_DB}.b_user_session ${PROD_DB} | pigz -p $PROC_NUM -c >>"$DIRECTORY/$FILE"
chmod 0640 "$DIRECTORY/$FILE"

# clean up tmp file with credentials
rm -f -- "${mysql_config_file}"

echo "Backup is complete"
