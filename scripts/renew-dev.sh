#!/usr/bin/env sh
set -e -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo, 'sudo $0'"
  exit 1
fi

# This script recreates dev site from current prod one with deleting old dev in the process

dump_file=''
mysql_config_file=''
dev_config_tmp=''

cleanup() {
  if [ -n "${dump_file}" ]; then
    rm -f -- "${dump_file}" || :
  fi
  if [ -n "${mysql_config_file}" ]; then
    rm -f -- "${mysql_config_file}" || :
  fi
  if [ -n "${dev_config_tmp}" ]; then
    rm -rf -- "${dev_config_tmp}" || :
  fi
}

handle_signal() {
  exit_code=$1
  trap - EXIT HUP INT TERM
  cleanup
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# Abort unless the dev copy of a DB connection file is safe to publish: every
# expected dev line is present, and no line that assigns a database, login or
# password is left without a dev value. sed reports success even when a pattern
# matched nothing, so a layout the substitution does not cover (other quoting, a
# second connection) would otherwise be published to dev with production
# credentials.
check_dev_db_config() {
  file=$1
  shift
  for needle in "$@"; do
    grep -q -F -- "${needle}" "${file}" && continue
    echo "${file}: expected line not found, DB connection file layout is not supported" >&2
    exit 1
  done
  if grep -iE "(database|login|password)['\"]?[[:space:]]*=>|\\\$DB(Name|Login|Password)[[:space:]]*=" "${file}" |
    grep -v -F -e "'${DEV_DB}'" -e "'${DEV_USER}'" -e "'${DEV_PASSWORD}'" | grep -q .; then
    echo "${file}: a connection setting was not rewritten, DB connection file layout is not supported" >&2
    exit 1
  fi
}

# Validate identifier for use in SQL (alphanumeric, underscore, hyphen only)
validate_sql_identifier() {
  case "$1" in
  *[!a-zA-Z0-9_-]*)
    echo "Invalid characters in SQL identifier: $1" >&2
    exit 1
    ;;
  '')
    echo "Empty SQL identifier not allowed" >&2
    exit 1
    ;;
  esac
}

# Parse command line arguments
USE_EXISTING_BACKUP=0
if [ $# -eq 1 ] && [ "$1" = "--date" ]; then
  USE_EXISTING_BACKUP=1
fi

# Site-specific values. Each one is read from the environment when non-empty,
# so another site runs the script by setting what differs, e.g.
#   sudo DOMAIN=example.com DEV_ADMIN_USER_IDS="1 7" ./scripts/renew-dev.sh
DOMAIN="${DOMAIN:-favor-group.ru}"                 # production domain
DEV_SUBDOMAIN="${DEV_SUBDOMAIN:-dev}"              # dev host is ${DEV_SUBDOMAIN}.${DOMAIN}
DEV_DOMAIN="${DEV_SUBDOMAIN}.${DOMAIN}"
PROD_LOCATION="${PROD_LOCATION:-./web/prod}"       # production tree on the host
DEV_LOCATION="${DEV_LOCATION:-./web/${DEV_SUBDOMAIN}}" # dev tree on the host, recreated by this script
BACKUP_LOCATION="${BACKUP_LOCATION:-./backup}"     # holds <date>/ directories with mysqldump.sql.gz
CONTAINER_WEB_ROOT="${CONTAINER_WEB_ROOT:-/web}"   # where the php container mounts the trees
DEV_DOCROOT="${DEV_DOCROOT:-${CONTAINER_WEB_ROOT}/${DEV_SUBDOMAIN}}" # DEV_LOCATION as the php container sees it
PHP_CONTAINER="${PHP_CONTAINER:-php}"              # container names from docker-compose.yml
MYSQL_CONTAINER="${MYSQL_CONTAINER:-mysql}"
MYSQL_ENV_FILE="${MYSQL_ENV_FILE:-./private/environment/mysql.env}" # provides MYSQL_ROOT_PASSWORD
MYSQL_DATA_DIR="${MYSQL_DATA_DIR:-./private/mysql-data}" # host path of the container's /var/lib/mysql
WEB_UID="${WEB_UID:-1000}"                         # owner of the web trees (www-data in the php image)
WEB_GID="${WEB_GID:-1000}"
DEV_ADMIN_USER_IDS="${DEV_ADMIN_USER_IDS-6 92 1560 1561}" # user ids put into the administrators group on dev; unset means these, empty adds none
DEV_ADMIN_IP_MASK="${DEV_ADMIN_IP_MASK:-255.255.0.0}"      # session/store IP mask of that group on dev
POST_RENEW_HOOK="${POST_RENEW_HOOK:-./private/scripts/renew-dev-post.sh}"

# MySQL variables: production domain as-is as DB name and username, dots and dashes as underscores
PROD_DB="${PROD_DB:-$(echo "${DOMAIN}" | tr '.' '_' | tr '-' '_')}"
DEV_DB="${DEV_DB:-$(echo "${DEV_DOMAIN}" | tr '.' '_' | tr '-' '_')}"
DEV_USER="${DEV_USER:-$(echo "${DEV_DOMAIN}" | tr '.' '_' | tr '-' '_')}"
DEV_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 32 | head -n 1)

# --- validators ---
# Canonical absolute path; GNU realpath -m normalises components that do not
# exist yet (the dev tree before its first run) and resolves symlinks.
canonical_path() {
  realpath -m -- "$1"
}

# True when $1 equals $2 or lies below it; both canonical absolute paths.
is_within() {
  case "$2" in
  /) parent_prefix=/ ;;
  *) parent_prefix="$2/" ;;
  esac
  [ "$1" = "$2" ] && return 0
  case "$1" in
  "${parent_prefix}"*) return 0 ;;
  esac
  return 1
}

# The dev tree is emptied and rewritten (rsync --delete, connection files
# replaced), so it must be neither the production tree nor inside it, nor
# contain it or the backups.
check_tree_separation() {
  prod=$(canonical_path "${PROD_LOCATION}") || exit 1
  dev=$(canonical_path "${DEV_LOCATION}") || exit 1
  backup=$(canonical_path "${BACKUP_LOCATION}") || exit 1
  if is_within "${dev}" "${prod}" || is_within "${prod}" "${dev}"; then
    echo "DEV_LOCATION ${dev} and the production tree ${prod} overlap" >&2
    exit 1
  fi
  if is_within "${backup}" "${dev}"; then
    echo "BACKUP_LOCATION ${backup} is inside DEV_LOCATION ${dev}" >&2
    exit 1
  fi
}

# Login and database name from the production connection file, so the dev
# credentials can never name the production account that the script drops.
# Fails closed: the variable must be assigned exactly once, as one complete
# quoted literal ended by a semicolon (an optional // comment may follow);
# concatenations, duplicates and other layouts are reported as unsupported.
prod_connection_value() {
  file="${PROD_LOCATION}/bitrix/php_interface/dbconn.php"
  assignments=$(grep -c "^[[:space:]]*\\\$DB${1}[[:space:]]*=" "${file}") || :
  if [ "${assignments}" -ne 1 ]; then
    echo "${file}: \$DB${1} is assigned ${assignments} times, layout is not supported" >&2
    return 1
  fi
  sed -n \
    -e "s|^[[:space:]]*\\\$DB${1}[[:space:]]*=[[:space:]]*'\([^'\\\\]*\)'[[:space:]]*;[[:space:]]*\(//.*\)\{0,1\}\$|\1|p" \
    -e "s|^[[:space:]]*\\\$DB${1}[[:space:]]*=[[:space:]]*\"\([^\"\\\\\$]*\)\"[[:space:]]*;[[:space:]]*\(//.*\)\{0,1\}\$|\1|p" \
    "${file}"
}

check_dev_credentials_differ() {
  prod_login=$(prod_connection_value Login) || exit 1
  prod_name=$(prod_connection_value Name) || exit 1
  if [ -z "${prod_login}" ] || [ -z "${prod_name}" ]; then
    echo "${PROD_LOCATION}/bitrix/php_interface/dbconn.php: \$DBLogin or \$DBName is not one quoted literal assignment, layout is not supported" >&2
    exit 1
  fi
  if [ "${DEV_USER}" = "${prod_login}" ] || [ "${DEV_DB}" = "${prod_name}" ] || [ "${DEV_DB}" = "${PROD_DB}" ]; then
    echo "dev database '${DEV_DB}' or user '${DEV_USER}' would be the production one (${prod_name}, ${prod_login}); set DEV_DB and DEV_USER" >&2
    exit 1
  fi
}

# Digits and blanks only, so the list can be split without globbing.
validate_admin_ids() {
  case "$1" in
  *[!0-9[:blank:]]*)
    echo "DEV_ADMIN_USER_IDS must hold numeric user ids separated by spaces, got '$1'" >&2
    exit 1
    ;;
  esac
}

# A dotted IPv4 netmask: four decimal octets without leading zeros, all-ones
# octets, then at most one partial octet, then zeros (0.0.0.0 and
# 255.255.255.255 included). Checked per octet, no wide arithmetic.
validate_ip_mask() {
  mask=$1
  case "${mask}" in
  *[!0-9.]* | '' | *..* | .* | *.)
    echo "DEV_ADMIN_IP_MASK must be a dotted IPv4 mask, got '${mask}'" >&2
    exit 1
    ;;
  esac
  old_ifs=$IFS
  IFS=.
  # shellcheck disable=SC2086
  set -- ${mask}
  IFS=$old_ifs
  if [ $# -ne 4 ]; then
    echo "DEV_ADMIN_IP_MASK must have four octets, got '${mask}'" >&2
    exit 1
  fi
  state=ones
  for octet in "$@"; do
    case "${octet}" in
    0 | [1-9] | [1-9][0-9] | 1[0-9][0-9] | 2[0-4][0-9] | 25[0-5]) ;;
    *)
      echo "DEV_ADMIN_IP_MASK octet '${octet}' is not a decimal 0-255 in '${mask}'" >&2
      exit 1
      ;;
    esac
    case "${state}:${octet}" in
    ones:255) ;;
    ones:0 | ones:128 | ones:192 | ones:224 | ones:240 | ones:248 | ones:252 | ones:254) state=zeros ;;
    zeros:0) ;;
    *)
      echo "DEV_ADMIN_IP_MASK must be a contiguous netmask such as 255.255.0.0, got '${mask}'" >&2
      exit 1
      ;;
    esac
  done
}
# --- end validators ---

case "${DEV_SUBDOMAIN}" in
*[!a-z0-9-]* | '')
  echo "DEV_SUBDOMAIN must be a lowercase DNS label, got '${DEV_SUBDOMAIN}'" >&2
  exit 1
  ;;
esac
if ! realpath -m -- / >/dev/null 2>&1; then
  echo "GNU realpath with -m is required (coreutils)" >&2
  exit 1
fi
validate_admin_ids "${DEV_ADMIN_USER_IDS}"
validate_ip_mask "${DEV_ADMIN_IP_MASK}"

# SQL VALUES lists for the administrators group rows, one entry per user id;
# empty lists skip the inserts.
admin_access_values=''
admin_group_values=''
for id in ${DEV_ADMIN_USER_IDS}; do
  admin_access_values="${admin_access_values:+${admin_access_values}, }('${id}', 'group', 'G1')"
  admin_group_values="${admin_group_values:+${admin_group_values}, }('${id}', '1', NULL, NULL)"
done

# Validate SQL identifiers to prevent injection
validate_sql_identifier "${PROD_DB}"
validate_sql_identifier "${DEV_DB}"
validate_sql_identifier "${DEV_USER}"

# Sanity checks before the run
if [ ! -d "${PROD_LOCATION}" ]; then
  echo "${PROD_LOCATION} (prod location) directory is absent"
  exit 45
fi
check_tree_separation
check_dev_credentials_differ

# If --date is provided, validate backup directory exists and select backup file
if [ ${USE_EXISTING_BACKUP} -eq 1 ]; then
  if [ ! -d "${BACKUP_LOCATION}" ]; then
    echo "${BACKUP_LOCATION} (backup location) directory is absent"
    exit 47
  fi

  # List available backup directories
  echo "Available backup dates:"
  ls -1 "${BACKUP_LOCATION}/" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort -r | head -20

  # Ask user to select a date
  printf "Enter the backup date (YYYY-MM-DD): "
  read -r BACKUP_DATE

  # Check if directory exists
  if [ ! -d "${BACKUP_LOCATION}/${BACKUP_DATE}" ]; then
    echo "Error: Backup directory ${BACKUP_LOCATION}/${BACKUP_DATE} does not exist"
    exit 1
  fi

  # List files in selected directory
  echo "Available backup files for ${BACKUP_DATE}:"
  BACKUP_FILES=$(ls -1 "${BACKUP_LOCATION}/${BACKUP_DATE}/" 2>/dev/null | grep "mysqldump.sql.gz$" || true)
  if [ -z "${BACKUP_FILES}" ]; then
    echo "No backup files found"
    exit 1
  fi
  echo "${BACKUP_FILES}"

  # Ask user to select a file
  printf "Enter the backup filename: "
  read -r BACKUP_FILE

  # Prevent path traversal by using basename
  BACKUP_FILE=$(basename "${BACKUP_FILE}")
  BACKUP_PATH="${BACKUP_LOCATION}/${BACKUP_DATE}/${BACKUP_FILE}"

  # Check if file exists
  if [ ! -f "${BACKUP_PATH}" ]; then
    echo "Error: Backup file ${BACKUP_PATH} does not exist"
    exit 1
  fi

  echo "Selected backup: ${BACKUP_PATH}"
fi

# read MYSQL_ROOT_PASSWORD
if [ ! -f "${MYSQL_ENV_FILE}" ]; then
  echo "${MYSQL_ENV_FILE} file is absent, couldn't read MYSQL_ROOT_PASSWORD variable"
  exit 46
fi
# shellcheck disable=SC1090
. "${MYSQL_ENV_FILE}"

echo "Creating dev copy of the production site in $DEV_LOCATION for $DEV_DOMAIN"

# create temp file to store mysql login and password for the time of the script
# location for it should be the directory which is passed inside the container
mysql_config_file=$(
  echo 'mkstemp(template)' |
    m4 -D template="${MYSQL_DATA_DIR}/deleteme_XXXXXX"
) || exit

mysql_binary_path="docker exec -u0 ${MYSQL_CONTAINER} /bin"
mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"

# shellcheck disable=SC2028
echo "[client]\nuser = root\npassword = ${MYSQL_ROOT_PASSWORD}\ndefault-character-set = utf8mb4" >${mysql_config_file}

# The dev DB connection files are built from the production ones with the dev
# credentials substituted and checked before the dev database is dropped, so an
# unsupported production file aborts while the old dev site still works. They
# stay in a root-only temporary directory until the restore is complete: see the
# publishing step below. rsync excludes both files, so production credentials
# never reach the dev tree, and --delete leaves excluded files in place.
echo "Preparing dev DB connection settings"
dev_dbconn="${DEV_LOCATION}/bitrix/php_interface/dbconn.php"
dev_settings="${DEV_LOCATION}/bitrix/.settings.php"
dev_config_tmp=$(mktemp -d)
dev_dbconn_tmp="${dev_config_tmp}/dbconn.php"
dev_settings_tmp="${dev_config_tmp}/settings.php"
sed \
  -e "s/^\([[:space:]]*\)\$DBName[[:space:]]*=.*/\1\$DBName = '${DEV_DB}';/" \
  -e "s/^\([[:space:]]*\)\$DBLogin[[:space:]]*=.*/\1\$DBLogin = '${DEV_USER}';/" \
  -e "s/^\([[:space:]]*\)\$DBPassword[[:space:]]*=.*/\1\$DBPassword = '${DEV_PASSWORD}';/" \
  "${PROD_LOCATION}/bitrix/php_interface/dbconn.php" >"${dev_dbconn_tmp}"
sed \
  -e "s/^\([[:space:]]*\)'database'[[:space:]]*=>.*/\1'database' => '${DEV_DB}',/" \
  -e "s/^\([[:space:]]*\)'login'[[:space:]]*=>.*/\1'login' => '${DEV_USER}',/" \
  -e "s/^\([[:space:]]*\)'password'[[:space:]]*=>.*/\1'password' => '${DEV_PASSWORD}',/" \
  "${PROD_LOCATION}/bitrix/.settings.php" >"${dev_settings_tmp}"
check_dev_db_config "${dev_dbconn_tmp}" \
  "\$DBName = '${DEV_DB}';" "\$DBLogin = '${DEV_USER}';" "\$DBPassword = '${DEV_PASSWORD}';"
check_dev_db_config "${dev_settings_tmp}" \
  "'database' => '${DEV_DB}'," "'login' => '${DEV_USER}'," "'password' => '${DEV_PASSWORD}',"

echo "Recreating DB base and user"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "drop database if exists ${DEV_DB};"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "drop user if exists '${DEV_USER}'@'localhost';"
# dropping the user leaves its open sessions alive (php-fpm keeps persistent
# connections), and they would keep working on the recreated database
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -N -e "select concat('kill ', ID, ';') from information_schema.PROCESSLIST where USER = '${DEV_USER}';" |
  docker exec -u0 -i "${MYSQL_CONTAINER}" /bin/mysql --defaults-extra-file="${mysql_config_inside_container}" --force >/dev/null || :

# prepare new dev database and user; the database takes the charset and
# collation of the production one, the dump carries them per table only
prod_db_charset=$(${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -N -e "select concat('character set ', DEFAULT_CHARACTER_SET_NAME, ' collate ', DEFAULT_COLLATION_NAME) from information_schema.SCHEMATA where SCHEMA_NAME = '${PROD_DB}';")
case "${prod_db_charset}" in
'character set '*' collate '*) ;;
*)
  echo "could not read the charset of ${PROD_DB}: '${prod_db_charset}'" >&2
  exit 1
  ;;
esac
validate_sql_identifier "${prod_db_charset##* }"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "create database ${DEV_DB} ${prod_db_charset};"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "create user '${DEV_USER}'@'localhost' identified by '${DEV_PASSWORD}';"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "grant all on ${DEV_DB}.* to '${DEV_USER}'@'localhost';"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "grant system_variables_admin on *.* to '${DEV_USER}'@'localhost';"
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e 'flush privileges;'

# create and load database dump
dump_file="prod-dump.sql"
if [ ${USE_EXISTING_BACKUP} -eq 1 ]; then
  echo "Using existing backup: ${BACKUP_PATH}"
  # Decompress the backup
  zcat "${BACKUP_PATH}" >"${dump_file}"
else
  # --no-tablespaces allows running not from root
  # --single-transaction will start a transaction before running
  # first --no-data run just dumps the schema for all tables,
  # second --ignore-table run ignores data from user sessions as we don't need to transfer it
  echo "Creating mysql dump"
  ${mysql_binary_path}/mysqldump --defaults-extra-file="${mysql_config_inside_container}" --single-transaction --no-tablespaces --no-data ${PROD_DB} >"${dump_file}"
  ${mysql_binary_path}/mysqldump --defaults-extra-file="${mysql_config_inside_container}" --single-transaction --no-tablespaces --ignore-table=${PROD_DB}.b_user_session ${PROD_DB} >>"${dump_file}"
fi
# shellcheck disable=SC2028
echo "[client]\nuser = ${DEV_USER}\npassword = ${DEV_PASSWORD}\ndefault-character-set = utf8mb4" >${mysql_config_file}
echo "Restoring mysql dump for dev"
cat "${dump_file}" | docker exec -u0 -i "${MYSQL_CONTAINER}" /bin/mysql --defaults-extra-file="${mysql_config_inside_container}" ${DEV_DB}

echo "Changing settings on dev site after DB restore"
# change aspro and main site URL to reflect dev site value
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_iblock_element_property set VALUE = '${DEV_DOMAIN}' where VALUE = '${DOMAIN}';" ${DEV_DB}
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_lang set SERVER_NAME = '${DEV_DOMAIN}' where SERVER_NAME = '${DOMAIN}';" ${DEV_DB}
# change security filter settings to use new domain
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_option set VALUE = '${DEV_DOMAIN}' where VALUE = '${DOMAIN}';" ${DEV_DB}
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_option set VALUE = '${DEV_DOMAIN}' where MODULE_ID = 'security' and NAME = 'restriction_hosts_hosts';" ${DEV_DB}
# calculate serialized string length for PHP array (byte length for PHP serialize)
DEV_URL="https://${DEV_DOMAIN}"
DEV_URL_LEN=$(printf '%s' "$DEV_URL" | LC_ALL=C wc -c | tr -d ' ')
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_option set VALUE = 'a:1:{s:4:\"host\";s:${DEV_URL_LEN}:\"${DEV_URL}\";}' where MODULE_ID = 'security' AND name = 'restriction_hosts_action_options';" ${DEV_DB}
# mark site as development one
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_option set VALUE = 'Y' where MODULE_ID = 'main' and NAME = 'update_devsrv';" ${DEV_DB}
# disable external access to the site
${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "update b_option set VALUE = 'Y' where MODULE_ID = 'main' and NAME = 'site_stopped';" ${DEV_DB}
# give admin access to users #6, #92, #1560, #1561
if [ -n "${admin_access_values}" ]; then
  ${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "INSERT IGNORE INTO b_user_access (user_id, provider_id, access_code) VALUES ${admin_access_values};" ${DEV_DB}
  ${mysql_binary_path}/mysql --defaults-extra-file="${mysql_config_inside_container}" -e "INSERT IGNORE INTO b_user_group (user_id, group_id, date_active_from, date_active_to) VALUES ${admin_group_values};" ${DEV_DB}
else
  echo "No extra administrators configured for dev (DEV_ADMIN_USER_IDS is empty)"
fi

# Published only after the restore: a dev site that can connect while its
# database is still empty caches those empty results in its cache backend, where
# managed cache entries have no expiry, and serves errors from them after the
# restore. Until this point the tree holds the previous dev credentials, invalid
# since the dev user was recreated, so dev never connects to the production
# database.
echo "Writing dev DB connection settings"
# install -d is the same as mkdir -p, but it allows setting owner user and group for created folders
install -d -o "${WEB_UID}" -g "${WEB_GID}" "${DEV_LOCATION}/bitrix/php_interface"
install -o "${WEB_UID}" -g "${WEB_GID}" -m 0640 "${dev_dbconn_tmp}" "${dev_dbconn}.new"
install -o "${WEB_UID}" -g "${WEB_GID}" -m 0640 "${dev_settings_tmp}" "${dev_settings}.new"
mv -f "${dev_dbconn}.new" "${dev_dbconn}"
mv -f "${dev_settings}.new" "${dev_settings}"
rm -rf -- "${dev_config_tmp}"
dev_config_tmp=''

echo "Copying files"
# copy files
# --archive preserves file permissions and so on
# --whole-file skips delta-transfer algorithm, faster for local copy
# --inplace writes directly to destination file, avoids temp file overhead
# --delete deletes files from destination if they are not present in the source
# --force allows deletion of non-empty directories when their contents were excluded
# --exclude excludes the DB connection files written above, backup, Bitrix caches, temp files, PDFs, and image caches from the sync
# / in the end of src location avoid creating additional directory level at destination
echo "Starting rsync at $(date '+%H:%M:%S'), estimated duration ~3 minutes, expected completion at $(date -d '+3 minutes' '+%H:%M:%S')"
rsync --archive --whole-file --inplace --delete --force --exclude '/bitrix/php_interface/dbconn.php' --exclude '/bitrix/.settings.php' --exclude '/bitrix/backup' --exclude '/bitrix/cache/' --exclude '/bitrix/managed_cache/' --exclude '*.tmp*' --exclude '*.pdf' --exclude '/upload/delight.webpconverter/' --exclude '/upload/resize_cache/' "${PROD_LOCATION}/" "${DEV_LOCATION}"
echo "Rsync completed at $(date '+%H:%M:%S')"

# Cache entries left by the previous dev copy, or written while the files were
# still syncing, describe another database and another tree. Bitrix cleans the
# cache its own settings address; with a cache backend shared between sites,
# every site needs its own sid in .settings_extra.php for this to stay local.
# The composite page cache is not touched through the API: with memcached
# storage its deleteAll() flushes the whole shared instance. Its file storage
# keeps one directory per host, and the dev host's directory is removed here.
echo "Clearing dev site caches"
docker exec -i -u www-data -e DEV_DOCROOT="${DEV_DOCROOT}" "${PHP_CONTAINER}" php <<'PHP'
<?php
declare(strict_types=1);

$docroot = (string) getenv('DEV_DOCROOT');
if ($docroot === '' || !is_dir($docroot)) {
    fwrite(STDERR, "DEV_DOCROOT is not a directory inside the php container: '{$docroot}'\n");
    exit(1);
}
$_SERVER['DOCUMENT_ROOT'] = $docroot;
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
define('NO_AGENT_CHECK', true);
require $docroot . '/bitrix/modules/main/include/prolog_before.php';

\Bitrix\Main\Application::getInstance()->getManagedCache()->cleanAll();
BXClearCache(true);
PHP
rm -rf "${DEV_LOCATION:?}/bitrix/html_pages/${DEV_DOMAIN:?}"

# keep dev admin sessions valid when Private Relay rotates an address inside the same /16
docker exec -i -u www-data -e DEV_DOCROOT="${DEV_DOCROOT}" -e DEV_ADMIN_IP_MASK="${DEV_ADMIN_IP_MASK}" "${PHP_CONTAINER}" php <<'PHP'
<?php
declare(strict_types=1);

$docroot = (string) getenv('DEV_DOCROOT');
$mask = (string) getenv('DEV_ADMIN_IP_MASK');
if ($docroot === '' || !is_dir($docroot) || $mask === '') {
    fwrite(STDERR, "DEV_DOCROOT or DEV_ADMIN_IP_MASK is missing inside the php container\n");
    exit(1);
}
$_SERVER['DOCUMENT_ROOT'] = $docroot;
define('NO_KEEP_STATISTIC', true);
define('NOT_CHECK_PERMISSIONS', true);
require $docroot . '/bitrix/modules/main/include/prolog_before.php';

use Bitrix\Main\GroupTable;

$row = GroupTable::getRow([
    'select' => ['SECURITY_POLICY'],
    'filter' => ['=ID' => 1],
]);
$policy = unserialize((string) ($row['SECURITY_POLICY'] ?? ''), ['allowed_classes' => false]);
if (!is_array($policy)) {
    fwrite(STDERR, "Administrator security policy is invalid\n");
    exit(1);
}

$policy['SESSION_IP_MASK'] = $mask;
$policy['STORE_IP_MASK'] = $mask;
$result = GroupTable::update(1, ['SECURITY_POLICY' => serialize($policy)]);
if (!$result->isSuccess()) {
    fwrite(STDERR, implode('; ', $result->getErrorMessages()) . "\n");
    exit(1);
}

$updated = GroupTable::getRow([
    'select' => ['SECURITY_POLICY'],
    'filter' => ['=ID' => 1],
]);
$verified = unserialize((string) ($updated['SECURITY_POLICY'] ?? ''), ['allowed_classes' => false]);
if (
    !is_array($verified)
    || ($verified['SESSION_IP_MASK'] ?? null) !== $mask
    || ($verified['STORE_IP_MASK'] ?? null) !== $mask
) {
    fwrite(STDERR, "Administrator security policy update was not persisted\n");
    exit(1);
}
PHP

if [ -x "${POST_RENEW_HOOK}" ]; then
  echo "Running site-specific dev post-renew hook"
  "${POST_RENEW_HOOK}"
fi

echo "Dev renewal from production is complete, available at https://${DEV_DOMAIN}"
