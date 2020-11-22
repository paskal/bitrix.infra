#!/usr/bin/env sh

# This script recreates dev site from current prod one with deleting old dev in the process

PROD_LOCATION=/home/admin/web/favor-group.ru/public_html
DEV_LOCATION=/home/admin/web/dev.favor-group.ru/public_html

# MySQL variables
PROD_DB=admin_favorgroup
DEV_DB=dev_favor_group_ru
DEV_USER=dev_favor_group_ru
DEV_PASSWORD=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

# read MYSQL_ROOT_PASSWORD
. ./private/environment/percona.env

# create temp file to store mysql login and password for the time of the script
# location for it should be the directory which is passed inside the container
mysql_config_file=$(
  echo 'mkstemp(template)' |
    m4 -D template="./private/percona-data/deleteme_XXXXXX"
) || exit

mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"

echo "[client]\nuser = root\npassword = ${MYSQL_ROOT_PASSWORD}" > ${mysql_config_file}

docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "drop database if exists ${DEV_DB};"
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "drop user if exists '${DEV_USER}'@'%';"

# prepare new dev database and user
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "create database ${DEV_DB};"
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "create user '${DEV_USER}'@'%' identified by '${DEV_PASSWORD}';"
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "grant all on ${DEV_DB}.* to '${DEV_USER}'@'%';"
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e 'flush privileges;'

# create and load database dump
# --no-tablespaces allows running not from root
# --single-transaction will start a transaction before running
docker exec -u0 percona-server /bin/mysqldump --defaults-extra-file=${mysql_config_inside_container} --single-transaction --no-tablespaces ${PROD_DB} >prod-dump.sql
echo "[client]\nuser = ${DEV_USER}\npassword = ${DEV_PASSWORD}" > ${mysql_config_file}
cat prod-dump.sql | docker exec -u0 -i percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} ${DEV_DB}

# change aspro and main site URL to reflect dev site value
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_iblock_element_property set VALUE = 'dev.favor-group.ru' where VALUE = 'favor-group.ru';" ${DEV_DB}
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_lang set SERVER_NAME = 'dev.favor-group.ru' where SERVER_NAME = 'favor-group.ru';" ${DEV_DB}
# change security filter settings to use new domain
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'dev.favor-group.ru' where VALUE = 'favor-group.ru';" ${DEV_DB}
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'dev.favor-group.ru' where MODULE_ID = 'security' and NAME = 'restriction_hosts_hosts';" ${DEV_DB}
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'a:1:{s:4:\"host\";s:26:\"https://dev.favor-group.ru\";}' where MODULE_ID = 'security' AND name = 'restriction_hosts_action_options';" ${DEV_DB}
# mark site as development one
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'Y' where MODULE_ID = 'main' and NAME = 'update_devsrv';" ${DEV_DB}
# disable external access to the site
docker exec -u0 percona-server /bin/mysql --defaults-extra-file=${mysql_config_inside_container} -e "update b_option set VALUE = 'Y' where MODULE_ID = 'main' and NAME = 'site_stopped';" ${DEV_DB}

# copy files
# --archive preserves file permissions and so on
# --delete deletes files from destination if they are not present in the source
# --no-inc-recursive calculates file size for progress bar at the beginning
# / in the end of src location avoid creating additional directory level at destination
rsync --archive --no-inc-recursive --delete --info=progress2 ${PROD_LOCATION}/ ${DEV_LOCATION}

# change settings in files to reflect dev site
sed -i "s/.*\$DBName.*/\$DBName = '${DEV_DB}';/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*\$DBLogin.*/\$DBLogin = '${DEV_USER}';/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*\$DBPassword.*/\$DBPassword = '${DEV_PASSWORD}';/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*BX_CACHE_SID.*/define('BX_CACHE_SID', 'dev');/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*BX_TEMPORARY_FILES_DIRECTORY.*/define('BX_TEMPORARY_FILES_DIRECTORY', '\/tmp\/dev.favor-group.ru');/" ${DEV_LOCATION}/bitrix/php_interface/dbconn.php
sed -i "s/.*'sid'.*/'sid' => 'dev'/" ${DEV_LOCATION}/bitrix/.settings_extra.php
sed -i "s/.*'database' =>.*/'database' => '${DEV_DB}',/" ${DEV_LOCATION}/bitrix/.settings.php
sed -i "s/.*'login' =>.*/'login' => '${DEV_USER}',/" ${DEV_LOCATION}/bitrix/.settings.php
sed -i "s/.*'password' =>.*/'password' => '${DEV_PASSWORD}',/" ${DEV_LOCATION}/bitrix/.settings.php

# clean up bitrix file cache
rm -rf ${DEV_LOCATION}/bitrix/cache/*
rm -rf ${DEV_LOCATION}/bitrix/managed_cache/*

# remove mysql dump
rm -f prod-dump.sql

# clean up tmp file with credentials
rm -f -- "${mysql_config_file}"

# TODO:
# установка для разработки
# закрыть публичную часть
# поменять url

