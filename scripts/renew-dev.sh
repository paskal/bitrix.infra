#!/usr/bin/env sh
set -e

# This script recreates dev site from current prod one with deleting old dev in the process

# Domain names
DOMAIN=favor-group.ru
DEV_SUBDOMAIN=dev
DEV_DOMAIN="${DEV_SUBDOMAIN}.${DOMAIN}"

# MySQL variables
PROD_DB=admin_favorgroup
# use production domain as-is as DB name and username, but replace dots and dashes with underscores
DEV_DB=$(echo ${DEV_DOMAIN} | tr '.' '_' | tr '-' '_')
DEV_USER=$(echo ${DEV_DOMAIN} | tr '.' '_' | tr '-' '_')
DEV_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)

# File path variables
PROD_LOCATION="./web/${DOMAIN}"
DEV_LOCATION="./web/${DEV_DOMAIN}"

# Sanity checks before the run
[ -d "${PROD_LOCATION}" ] || (echo "${PROD_LOCATION} (prod location) directory is absent" && exit 45)

# read MYSQL_ROOT_PASSWORD
[ -f "./private/environment/mysql.env" ] || (echo "./private/environment/mysql.env file is absent, couldn't read MYSQL_ROOT_PASSWORD variable" && exit 46)
. ./private/environment/mysql.env

echo "Creating dev copy of the site in $DEV_LOCATION"

# create temp file to store mysql login and password for the time of the script
# location for it should be the directory which is passed inside the container
mysql_config_file=$(
  echo 'mkstemp(template)' |
    m4 -D template="./private/mysql-data/deleteme_XXXXXX"
) || exit

mysql_binary_path="docker exec -u0 mysql /bin"
mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"

echo "[client]\nuser = root\npassword = ${MYSQL_ROOT_PASSWORD}" >${mysql_config_file}

echo "Recreating DB base and user"
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "drop database if exists ${DEV_DB};"
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "drop user if exists '${DEV_USER}'@'%';"

# prepare new dev database and user
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "create database ${DEV_DB};"
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "create user '${DEV_USER}'@'%' identified by '${DEV_PASSWORD}';"
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "grant all on ${DEV_DB}.* to '${DEV_USER}'@'%';"
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e 'flush privileges;'

# create and load database dump
# --no-tablespaces allows running not from root (not used currently)
# --single-transaction will start a transaction before running
# first --no-data run just dumps the schema for all tables,
# second --ignore-table run ignores data from user sessions as we don't need to transfer it
echo "Creating mysql dump"
${mysql_binary_path}/mysqldump --defaults-extra-file=${mysql_config_inside_container} --single-transaction --no-tablespaces --no-data ${PROD_DB} >prod-dump.sql
${mysql_binary_path}/mysqldump --defaults-extra-file=${mysql_config_inside_container} --single-transaction --no-tablespaces --ignore-table=${PROD_DB}.b_user_session ${PROD_DB} >>prod-dump.sql
echo "[client]\nuser = ${DEV_USER}\npassword = ${DEV_PASSWORD}" >${mysql_config_file}
echo "Restoring mysql dump for dev"
cat prod-dump.sql | docker exec -u0 -i mysql /bin/mysql --defaults-extra-file=${mysql_config_inside_container} ${DEV_DB}

echo "Changing settings on dev site after DB restore"
# change aspro and main site URL to reflect dev site value
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_iblock_element_property set VALUE = '${DEV_DOMAIN}' where VALUE = '${DOMAIN}';" ${DEV_DB}
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_lang set SERVER_NAME = '${DEV_DOMAIN}' where SERVER_NAME = '${DOMAIN}';" ${DEV_DB}
# change security filter settings to use new domain
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = '${DEV_DOMAIN}' where VALUE = '${DOMAIN}';" ${DEV_DB}
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = '${DEV_DOMAIN}' where MODULE_ID = 'security' and NAME = 'restriction_hosts_hosts';" ${DEV_DB}
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'a:1:{s:4:\"host\";s:26:\"https://${DEV_DOMAIN}\";}' where MODULE_ID = 'security' AND name = 'restriction_hosts_action_options';" ${DEV_DB}
# mark site as development one
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'Y' where MODULE_ID = 'main' and NAME = 'update_devsrv';" ${DEV_DB}
# disable external access to the site
${mysql_binary_path}/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'Y' where MODULE_ID = 'main' and NAME = 'site_stopped';" ${DEV_DB}

echo "Copying files"
# install -d is the same as mkdir -p, but it allows setting owner user and group for created folder
install -d -o 1000 -g 1000 ${DEV_LOCATION}
# copy files
# --archive preserves file permissions and so on
# --delete deletes files from destination if they are not present in the source
# --no-inc-recursive calculates file size for progress bar at the beginning
# --exclude excludes cache folders from the sync
# / in the end of src location avoid creating additional directory level at destination
rsync --archive --no-inc-recursive --delete --exclude '**/cache/' --exclude '**/managed_cache/' --info=progress2 ${PROD_LOCATION}/ ${DEV_LOCATION}

echo "Changing DB and memcached connection settings"
# change settings in files to reflect dev site
sed -i "s/.*\$DBName.*/\$DBName = '${DEV_DB}';/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*\$DBLogin.*/\$DBLogin = '${DEV_USER}';/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*\$DBPassword.*/\$DBPassword = '${DEV_PASSWORD}';/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*BX_CACHE_SID.*/define('BX_CACHE_SID', '${DEV_SUBDOMAIN}');/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*BX_TEMPORARY_FILES_DIRECTORY.*/define('BX_TEMPORARY_FILES_DIRECTORY', '\/tmp\/${DEV_DOMAIN}');/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*'sid'.*/'sid' => '${DEV_SUBDOMAIN}'/" ${DEV_LOCATION}/bitrix/.settings_extra.php
sed -i "s/.*'database' =>.*/'database' => '${DEV_DB}',/" ${DEV_LOCATION}/bitrix/.settings.php
sed -i "s/.*'login' =>.*/'login' => '${DEV_USER}',/" ${DEV_LOCATION}/bitrix/.settings.php
sed -i "s/.*'password' =>.*/'password' => '${DEV_PASSWORD}',/" ${DEV_LOCATION}/bitrix/.settings.php

echo "Cleaning up"

# remove mysql dump
rm -f prod-dump.sql

# clean up tmp files with credentials (even from other runs)
rm -f ./private/mysql-data/deleteme_*

echo "Dev renewal from production is complete, available at https://${DEV_DOMAIN}"
