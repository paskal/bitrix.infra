#!/usr/bin/env sh
# Convert every table of a MySQL database to utf8mb4 in place.
#
# Usage: sudo ./scripts/convert-utf8mb4.sh [--dry-run] [--collation NAME] DATABASE
#
# Each table gets one ALTER TABLE that sets the table default and rewrites
# every character column with its own definition: type, NULL, DEFAULT, COMMENT.
# A plain CONVERT TO CHARACTER SET would widen TEXT to MEDIUMTEXT and turn
# binary collations into the table collation, which breaks unique keys such
# as b_search_stem.STEM. Here *_bin columns become utf8mb4_bin and every other
# column takes the target collation (default utf8mb4_unicode_ci, the same
# comparison rules as utf8mb3_unicode_ci).
#
# Before touching anything the script writes a column snapshot and a per-table
# data fingerprint (row count and folded MD5 of every row read as utf8mb4)
# under ./logs/utf8mb4/DATABASE-TIMESTAMP/, converts table by table with a
# timing log, then takes both again and fails when a definition changed beyond
# charset and collation or a fingerprint differs. Tables are rebuilt with a
# copy, so writes to a table wait while it converts: stop the site and its cron
# jobs first. A run that stops halfway can be repeated and picks the tables that
# are still not converted; each run verifies the tables it converted itself, so
# read the diff files of a failed run before repeating it.
#
# The database alone does not make an application use utf8mb4: the client
# connection has to ask for it too (for Bitrix: 'charset' => 'utf8mb4' and an
# after-connect SET NAMES with the same collation in .settings.php, plus
# default-character-set = utf8mb4 for the mysql client in my.cnf so dumps keep
# 4-byte characters).

set -e -u

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo, 'sudo $0'" >&2
  exit 1
fi

collation=utf8mb4_unicode_ci
dry_run=0
database=''
while [ $# -gt 0 ]; do
  case "$1" in
  --dry-run) dry_run=1 ;;
  --collation)
    shift
    collation=${1:-}
    ;;
  -h | --help)
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  -*)
    echo "unknown option: $1" >&2
    exit 1
    ;;
  *) database=$1 ;;
  esac
  shift
done
if [ -z "${database}" ]; then
  echo "usage: sudo $0 [--dry-run] [--collation NAME] DATABASE" >&2
  exit 1
fi
case "${database}" in
*[!a-zA-Z0-9_]*)
  echo "database name may contain only letters, digits and underscores" >&2
  exit 1
  ;;
esac
case "${collation}" in
utf8mb4_*) ;;
*)
  echo "collation must be a utf8mb4 collation, got '${collation}'" >&2
  exit 1
  ;;
esac
case "${collation}" in
*[!a-zA-Z0-9_]*)
  echo "collation name may contain only letters, digits and underscores" >&2
  exit 1
  ;;
esac

if [ ! -f ./private/environment/mysql.env ]; then
  echo "./private/environment/mysql.env is absent, cannot read MYSQL_ROOT_PASSWORD" >&2
  exit 1
fi
. ./private/environment/mysql.env

mysql_config_file=''
cleanup() {
  if [ -n "${mysql_config_file}" ]; then
    rm -f -- "${mysql_config_file}" || :
  fi
}
handle_signal() {
  trap - EXIT HUP INT TERM
  cleanup
  exit "$1"
}
trap cleanup EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

# root credentials for the mysql client inside the container, as in renew-dev.sh
mysql_config_file=$(mktemp ./private/mysql-data/deleteme_XXXXXX)
chmod 0600 "${mysql_config_file}"
printf '[client]\nuser = root\npassword = %s\ndefault-character-set = utf8mb4\n' "${MYSQL_ROOT_PASSWORD}" >"${mysql_config_file}"
mysql_config_inside_container="/var/lib/mysql/${mysql_config_file##*/}"

# run SQL from stdin against the database, tab-separated output without headers
mysql_run() {
  docker exec -u0 -i mysql /bin/mysql --defaults-extra-file="${mysql_config_inside_container}" --batch --raw --skip-column-names "$@"
}
# run a single query given as an argument
mysql_query() {
  printf '%s\n' "$1" | mysql_run
}

db_exists=$(mysql_query "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${database}'")
if [ "${db_exists}" != "1" ]; then
  echo "database ${database} does not exist" >&2
  exit 1
fi
# the generated SQL relies on backslash escapes (QUOTE, LIKE patterns)
if [ "$(mysql_query "SELECT @@global.sql_mode LIKE '%NO_BACKSLASH_ESCAPES%'")" != "0" ]; then
  echo "sql_mode NO_BACKSLASH_ESCAPES is not supported" >&2
  exit 1
fi

# columns that still need conversion: any character column whose collation is
# neither the target nor utf8mb4_bin
needs_work="c.CHARACTER_SET_NAME IS NOT NULL AND c.COLLATION_NAME NOT IN ('${collation}', 'utf8mb4_bin')"

echo "Checking ${database} for definitions the conversion cannot rewrite"
blockers=$(mysql_run <<SQL
SELECT CONCAT('generated or invisible column: ', TABLE_NAME, '.', COLUMN_NAME, ' (', EXTRA, ')')
  FROM information_schema.COLUMNS c
  WHERE TABLE_SCHEMA = '${database}' AND ${needs_work} AND EXTRA NOT IN ('', 'DEFAULT_GENERATED')
UNION ALL
SELECT CONCAT('foreign key on character column: ', k.TABLE_NAME, '.', k.COLUMN_NAME, ' (', k.CONSTRAINT_NAME, ')')
  FROM information_schema.KEY_COLUMN_USAGE k
  JOIN information_schema.COLUMNS c ON c.TABLE_SCHEMA = k.TABLE_SCHEMA AND c.TABLE_NAME = k.TABLE_NAME AND c.COLUMN_NAME = k.COLUMN_NAME
  WHERE k.TABLE_SCHEMA = '${database}' AND k.REFERENCED_TABLE_NAME IS NOT NULL AND c.CHARACTER_SET_NAME IS NOT NULL
UNION ALL
SELECT CONCAT('varchar longer than 16383 characters: ', TABLE_NAME, '.', COLUMN_NAME, ' (', COLUMN_TYPE, ')')
  FROM information_schema.COLUMNS c
  WHERE TABLE_SCHEMA = '${database}' AND ${needs_work} AND DATA_TYPE = 'varchar' AND CHARACTER_MAXIMUM_LENGTH > 16383
UNION ALL
SELECT CONCAT('line break in the default, type or comment: ', TABLE_NAME, '.', COLUMN_NAME)
  FROM information_schema.COLUMNS c
  WHERE TABLE_SCHEMA = '${database}' AND ${needs_work}
    AND (COLUMN_COMMENT REGEXP '[\r\n]' OR COLUMN_TYPE REGEXP '[\r\n]' OR COLUMN_DEFAULT REGEXP '[\r\n]')
UNION ALL
SELECT CONCAT('unsupported character in a name: ', TABLE_NAME, '.', COLUMN_NAME)
  FROM information_schema.COLUMNS c
  WHERE TABLE_SCHEMA = '${database}' AND (TABLE_NAME REGEXP '[\`\t\r\n]' OR COLUMN_NAME REGEXP '[\`\t\r\n]')
UNION ALL
SELECT CONCAT('view: ', TABLE_NAME)
  FROM information_schema.VIEWS
  WHERE TABLE_SCHEMA = '${database}'
UNION ALL
SELECT CONCAT('not InnoDB: ', TABLE_NAME, ' (', ENGINE, ')')
  FROM information_schema.TABLES
  WHERE TABLE_SCHEMA = '${database}' AND TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB';
SQL
)
if [ -n "${blockers}" ]; then
  echo "${blockers}" >&2
  echo "Convert these by hand first, the script does not rewrite them" >&2
  exit 1
fi

# tables to convert: a column needs work, or the table default is not the target
tables=$(mysql_run <<SQL
SELECT t.TABLE_NAME
  FROM information_schema.TABLES t
  WHERE t.TABLE_SCHEMA = '${database}' AND t.TABLE_TYPE = 'BASE TABLE'
    AND (t.TABLE_COLLATION <> '${collation}'
         OR EXISTS (SELECT 1 FROM information_schema.COLUMNS c
                    WHERE c.TABLE_SCHEMA = t.TABLE_SCHEMA AND c.TABLE_NAME = t.TABLE_NAME AND ${needs_work}))
  ORDER BY t.TABLE_NAME;
SQL
)
table_count=$(printf '%s\n' "${tables}" | grep -c . || :)
total_mb=$(mysql_query "SELECT IFNULL(ROUND(SUM(DATA_LENGTH + INDEX_LENGTH) / 1048576), 0) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '${database}'")
db_collation=$(mysql_query "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '${database}'")
echo "${database}: ${table_count} tables to convert to ${collation}, ${total_mb} MB in the database, default collation ${db_collation}"
if [ "${table_count}" -eq 0 ] && [ "${db_collation}" = "${collation}" ]; then
  echo "Nothing to do"
  exit 0
fi

out_dir="./logs/utf8mb4/${database}-$(date -u '+%Y%m%d-%H%M%S')"
mkdir -p "${out_dir}"
alter_file="${out_dir}/alter.sql"

# one ALTER per table; every character column that is not yet in the target
# collation (or utf8mb4_bin) is rewritten with an explicit character set and
# collation and its current type, nullability, default and comment, so the only
# change is the charset; columns already there are left alone
mysql_run <<SQL >"${alter_file}"
SET SESSION group_concat_max_len = 16777216;
SELECT CONCAT('ALTER TABLE \`', c.TABLE_NAME, '\` DEFAULT CHARACTER SET utf8mb4 COLLATE ${collation}',
  IFNULL(GROUP_CONCAT(
    IF(c.CHARACTER_SET_NAME IS NULL OR c.COLLATION_NAME IN ('${collation}', 'utf8mb4_bin'), NULL, CONCAT(
      ', MODIFY \`', c.COLUMN_NAME, '\` ', c.COLUMN_TYPE,
      ' CHARACTER SET utf8mb4 COLLATE ', IF(RIGHT(c.COLLATION_NAME, 4) = '_bin', 'utf8mb4_bin', '${collation}'),
      IF(c.IS_NULLABLE = 'YES', ' NULL', ' NOT NULL'),
      CASE WHEN c.EXTRA LIKE '%DEFAULT_GENERATED%' THEN CONCAT(' DEFAULT (', c.COLUMN_DEFAULT, ')')
           WHEN c.COLUMN_DEFAULT IS NOT NULL THEN CONCAT(' DEFAULT ', QUOTE(c.COLUMN_DEFAULT))
           WHEN c.IS_NULLABLE = 'YES' AND c.DATA_TYPE NOT IN ('tinytext', 'text', 'mediumtext', 'longtext') THEN ' DEFAULT NULL'
           ELSE '' END,
      IF(c.COLUMN_COMMENT <> '', CONCAT(' COMMENT ', QUOTE(c.COLUMN_COMMENT)), '')))
    ORDER BY c.ORDINAL_POSITION SEPARATOR ''), ''),
  ';')
  FROM information_schema.COLUMNS c
  JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
  WHERE c.TABLE_SCHEMA = '${database}' AND t.TABLE_TYPE = 'BASE TABLE'
    AND (t.TABLE_COLLATION <> '${collation}'
         OR EXISTS (SELECT 1 FROM information_schema.COLUMNS c2
                    WHERE c2.TABLE_SCHEMA = c.TABLE_SCHEMA AND c2.TABLE_NAME = c.TABLE_NAME
                      AND c2.CHARACTER_SET_NAME IS NOT NULL AND c2.COLLATION_NAME NOT IN ('${collation}', 'utf8mb4_bin')))
  GROUP BY c.TABLE_NAME
  ORDER BY c.TABLE_NAME;
SQL
statement_count=$(grep -c '^ALTER TABLE ' "${alter_file}" || :)
incomplete=$(grep -c -v ';$' "${alter_file}" || :)
if [ "${statement_count}" -ne "${table_count}" ] || [ "${incomplete}" -ne 0 ]; then
  echo "generated ${statement_count} statements for ${table_count} tables, ${incomplete} incomplete, see ${alter_file}" >&2
  exit 1
fi

if [ "${dry_run}" -eq 1 ]; then
  echo "Dry run: statements written to ${alter_file}, first three:"
  head -n 3 "${alter_file}" | cut -c1-300
  exit 0
fi

# column snapshot and data fingerprint, taken before and after; a column is
# described by everything but its charset, and a table by its row count and
# the XOR and sum of the MD5 of every row read as utf8mb4, so a conversion that
# changed a definition, or data beyond an MD5 collision, shows up as a diff
snapshot_columns() {
  mysql_run <<SQL
SELECT c.TABLE_NAME, c.COLUMN_NAME, c.COLUMN_TYPE, c.IS_NULLABLE, IFNULL(c.COLUMN_DEFAULT, '<null>'), c.EXTRA, c.COLUMN_COMMENT,
       CASE WHEN c.CHARACTER_SET_NAME IS NULL THEN '-' WHEN RIGHT(c.COLLATION_NAME, 4) = '_bin' THEN 'bin' ELSE 'ci' END
  FROM information_schema.COLUMNS c
  JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
  WHERE c.TABLE_SCHEMA = '${database}' AND t.TABLE_TYPE = 'BASE TABLE'
  ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;
SQL
}
fingerprint() {
  mysql_run <<SQL >"${out_dir}/fingerprint.sql"
SET SESSION group_concat_max_len = 16777216;
SELECT CONCAT('SELECT ', QUOTE(c.TABLE_NAME), ', COUNT(*), ',
  'IFNULL(BIT_XOR(CAST(CONV(LEFT(MD5(r.row_text), 16), 16, 10) AS UNSIGNED)), 0), ',
  'IFNULL(BIT_XOR(CAST(CONV(RIGHT(MD5(r.row_text), 16), 16, 10) AS UNSIGNED)), 0), ',
  'IFNULL(SUM(CAST(CONV(LEFT(MD5(r.row_text), 8), 16, 10) AS UNSIGNED)), 0) ',
  'FROM (SELECT CONCAT_WS(CHAR(31), ',
  GROUP_CONCAT(
    CASE WHEN c.CHARACTER_SET_NAME IS NOT NULL THEN CONCAT('IFNULL(HEX(CONVERT(\`', c.COLUMN_NAME, '\` USING utf8mb4)), ''<null>'')')
         WHEN c.DATA_TYPE IN ('tinyblob', 'blob', 'mediumblob', 'longblob', 'binary', 'varbinary', 'bit', 'json', 'geometry',
                              'point', 'linestring', 'polygon', 'multipoint', 'multilinestring', 'multipolygon', 'geomcollection')
              THEN CONCAT('IFNULL(HEX(\`', c.COLUMN_NAME, '\`), ''<null>'')')
         ELSE CONCAT('IFNULL(CAST(\`', c.COLUMN_NAME, '\` AS CHAR), ''<null>'')') END
    ORDER BY c.ORDINAL_POSITION SEPARATOR ', '),
  ') AS row_text FROM \`${database}\`.\`', c.TABLE_NAME, '\`) r;')
  FROM information_schema.COLUMNS c
  JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
  WHERE c.TABLE_SCHEMA = '${database}' AND t.TABLE_TYPE = 'BASE TABLE'
  GROUP BY c.TABLE_NAME
  ORDER BY c.TABLE_NAME;
SQL
  mysql_run <"${out_dir}/fingerprint.sql"
}

echo "Taking the column snapshot and data fingerprint before the conversion"
snapshot_columns >"${out_dir}/columns-before.tsv"
fingerprint >"${out_dir}/fingerprint-before.tsv"

log="${out_dir}/convert.log"
echo "Converting ${table_count} tables, log in ${log}"
run_started=$(date +%s)
n=0
while IFS= read -r statement; do
  case "${statement}" in
  'ALTER TABLE `'*) ;;
  *) continue ;;
  esac
  table=${statement#ALTER TABLE \`}
  table=${table%%\`*}
  n=$((n + 1))
  started=$(date +%s)
  if printf '%s\n' "${statement}" | mysql_run "${database}"; then
    printf '%s\t%s\t%ss\tok\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "${table}" "$(($(date +%s) - started))" | tee -a "${log}"
  else
    printf '%s\t%s\t%ss\tFAILED\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" "${table}" "$(($(date +%s) - started))" | tee -a "${log}"
    echo "Conversion of ${table} failed, statement:" >&2
    printf '%s\n' "${statement}" >&2
    exit 1
  fi
done <"${alter_file}"

if [ "${db_collation}" != "${collation}" ]; then
  mysql_query "ALTER DATABASE \`${database}\` CHARACTER SET utf8mb4 COLLATE ${collation}"
  echo "database default set to utf8mb4 ${collation}" | tee -a "${log}"
fi
echo "Converted ${n} tables in $(($(date +%s) - run_started)) s" | tee -a "${log}"

echo "Taking the column snapshot and data fingerprint after the conversion"
snapshot_columns >"${out_dir}/columns-after.tsv"
fingerprint >"${out_dir}/fingerprint-after.tsv"

status=0
if ! diff -u "${out_dir}/columns-before.tsv" "${out_dir}/columns-after.tsv" >"${out_dir}/columns.diff"; then
  echo "column definitions changed beyond the charset, see ${out_dir}/columns.diff" >&2
  status=1
fi
if ! diff -u "${out_dir}/fingerprint-before.tsv" "${out_dir}/fingerprint-after.tsv" >"${out_dir}/fingerprint.diff"; then
  echo "data fingerprint changed, see ${out_dir}/fingerprint.diff" >&2
  status=1
fi
leftovers=$(mysql_query "SELECT COUNT(*) FROM information_schema.COLUMNS c JOIN information_schema.TABLES t ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME WHERE c.TABLE_SCHEMA = '${database}' AND t.TABLE_TYPE = 'BASE TABLE' AND ${needs_work}")
if [ "${leftovers}" != "0" ]; then
  echo "${leftovers} columns are still not ${collation} or utf8mb4_bin" >&2
  status=1
fi
if [ "${status}" -eq 0 ]; then
  echo "Verified: every character column is utf8mb4, definitions unchanged, row digests match"
fi
exit "${status}"
