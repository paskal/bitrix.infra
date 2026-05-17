#!/usr/bin/env bash
# Weekly PHPStan scan against the prod Bitrix codebase.
#
# Two scopes:
#   - owned       (default): code we wrote (local/, php_interface/init.php, php_interface/include).
#                 Target = 0 findings. Zabbix watches the count file.
#   - diagnostic  (--diagnostic flag): broader sweep including Bitrix-injected scaffold.
#                 Manual use only — not alerted on.
#
# The PHAR is fetched fresh on each run via curl conditional GET; no version pin.
# Because the alerting metric is "owned errors = 0", a PHPStan upgrade that adds
# a new rule simply produces fixable findings on the next run, not a false alarm.
#
# Outputs (host paths under <repo>/logs/phpstan/):
#   <scope>-latest.json            raw PHPStan JSON
#   <scope>_errors_count.txt       single integer Zabbix reads
#   stderr.log                     open_basedir + any other PHP warnings
#   tmp-<scope>/                   PHPStan result cache
#
# Cron: 30 4 * * 1  (Mon 04:30 UTC, weekly)

set -euo pipefail

LOCK_FILE="/var/lock/phpstan-scan.lock"

# Re-exec ourselves under flock so concurrent invocations exit immediately.
# The FLOCKED env var prevents an infinite re-exec loop.
if [ -z "${FLOCKED:-}" ]; then
  export FLOCKED=1
  exec flock -n -E 99 "$LOCK_FILE" "$0" "$@"
fi

SCOPE="owned"
if [ "${1:-}" = "--diagnostic" ]; then
  SCOPE="diagnostic"
fi

# Repo root is the script's parent dir; resolve so the script works from any cwd.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(dirname "$SCRIPT_DIR")

PHAR_HOST_DIR="$REPO_DIR/private/phpstan"
LOG_HOST_DIR="$REPO_DIR/logs/phpstan"
PHAR_HOST="$PHAR_HOST_DIR/phpstan.phar"

# Container-side paths (mounted via docker-compose). Each *_CT has a sibling
# *_HOST below for use by the host shell (-s tests, mv) — same physical file.
PHAR_CT="/phpstan/phpstan.phar"
NEON_CT="/phpstan/phpstan-${SCOPE}.neon"
LOG_CT="/var/log/phpstan"
JSON_CT="$LOG_CT/${SCOPE}-latest.json"
JSON_CT_HOST="$LOG_HOST_DIR/${SCOPE}-latest.json"

ts() { date -u +%FT%TZ; }

mkdir -p "$PHAR_HOST_DIR" "$LOG_HOST_DIR"

# Catch-all sentinel: any uncaught error, SIGINT, SIGTERM, or unexpected exit
# leaves a failure sentinel so Zabbix sees the failure within one polling cycle.
# Cleared on the success path via `trap - ERR INT TERM` just before the final
# `rm -f ${SCOPE}_last_failure.txt`. Without this, a mid-run kill (OOM, host
# reboot, `docker compose down`, manual Ctrl-C, failed `mv` after XML write)
# leaves no sentinel and the 8-day freshness trigger is the only backstop.
trap 'echo "$(ts) trapped signal/exit before completion (rc=$?)" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true' ERR INT TERM

# Self-update PHAR via conditional GET (-z compares against local mtime).
# Idempotent: if the upstream is unchanged we get a 304 and the file stays.
# Download to a tmp file first so an interrupted download cannot leave a
# zero-byte PHAR that breaks the next run.
echo "$(ts) self-update: fetching latest phpstan.phar"
if [ -f "$PHAR_HOST" ]; then
  curl_args=(-sSLz "$PHAR_HOST")
else
  curl_args=(-sSL)
fi
if curl --fail --max-time 120 "${curl_args[@]}" \
  https://github.com/phpstan/phpstan/releases/latest/download/phpstan.phar \
  -o "$PHAR_HOST.tmp"; then
  # curl -z writes nothing when the file is unchanged, so the tmp file may be
  # zero bytes — keep the existing PHAR in that case.
  if [ -s "$PHAR_HOST.tmp" ]; then
    mv "$PHAR_HOST.tmp" "$PHAR_HOST"
    chmod 0644 "$PHAR_HOST"
    echo "$(ts) self-update: PHAR refreshed ($(wc -c <"$PHAR_HOST") bytes)"
  else
    rm -f "$PHAR_HOST.tmp"
    echo "$(ts) self-update: PHAR up to date"
  fi
else
  rm -f "$PHAR_HOST.tmp"
  echo "$(ts) self-update: curl failed, keeping existing PHAR"
  if [ ! -s "$PHAR_HOST" ]; then
    echo "$(ts) FATAL: no PHAR available and download failed (scope=$SCOPE)"
    echo "$(ts) phpstan PHAR download failure (no cached PHAR)" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true
    exit 1
  fi
fi

# The container's php.ini sets open_basedir to /web/prod:/web/dev:... which
# blocks /phpstan and /var/log/phpstan. Override per-invocation via -d so we
# don't have to edit the deployed php.ini (which is hand-curated per host).
OPEN_BASEDIR="/web/prod:/web/dev:/tmp:/var/log/php:/var/lib/php/sessions:/var/run/mysqld:/usr/bin/msmtp:/etc/msmtprc:/phpstan:$LOG_CT"

XML_CT="$LOG_CT/${SCOPE}-latest.xml"

echo "$(ts) phpstan analyse: scope=$SCOPE"
# PHPStan exit code 1 means "errors found" -- expected, swallow with || true.
# stderr is captured separately (open_basedir warnings are noisy but harmless).
# -w /web/prod sets the working dir so PHPStan's composer-helper probe lands
# inside open_basedir instead of warning about '//composer.json' at the root.
#
# Why --debug + checkstyle:
# - PHPStan's JSON formatter throws on malformed UTF-8 (Bitrix scaffold under
#   php_interface/include/ has mixed encodings); checkstyle XML tolerates it.
# - --debug forces single-process mode; otherwise PHPStan's parallel worker
#   subprocesses don't inherit the wrapper's `-d open_basedir=...` flag and
#   crash with exit 255 because they can't read /phpstan/phpstan.phar.
#   TODO: bake /phpstan + /var/log/phpstan into the container image's open_basedir
#   so we can drop --debug and regain parallel-process throughput (~2x faster).
# - In --debug mode PHPStan emits the file-list to stdout before the XML;
#   we strip everything before the `<?xml` marker via awk.
#
# Atomic-write pattern: write to .tmp first, validate, then mv.
# A truncated/zero-byte/incomplete XML (PHAR corruption, docker exec failure,
# OOM kill, mid-output crash) must NOT silently overwrite the prior good XML
# or the count file with "0" -- Zabbix would happily report "all green" while
# no analysis ran. We capture the docker exec exit code separately so a
# non-zero PHPStan exit (other than 1 = errors-found) is treated as failure
# and the sentinel marker is written before we exit.
#
# PHPStan documented exit codes:
#   0   - no errors
#   1   - errors found (expected; we still want to write the count file)
#   2   - warnings only (rare; not used in our config, but accept to survive
#         future releases that emit 2 with otherwise-valid XML)
#   255 - fatal error (container can't load PHAR, neon parse error, etc.)
# The real validation is the XML-validation chain below (non-empty + closing
# tag + simplexml parse); accept 0/1/2 here and let bad XML trip those guards.
XML_TMP="$LOG_HOST_DIR/${SCOPE}-latest.xml.tmp"
set +o pipefail
set +e
docker exec -u www-data -w /web/prod php \
  php -d "open_basedir=$OPEN_BASEDIR" "$PHAR_CT" analyse --debug --no-progress --error-format=checkstyle -c "$NEON_CT" \
  2>>"$LOG_HOST_DIR/stderr.log" \
  | awk '/^<\?xml/{f=1} f' \
  >"$XML_TMP"
phpstan_rc=${PIPESTATUS[0]}
set -e
set -o pipefail

# Treat anything other than 0/1/2 as a hard failure -- write sentinel + exit.
if [ "$phpstan_rc" -ne 0 ] && [ "$phpstan_rc" -ne 1 ] && [ "$phpstan_rc" -ne 2 ]; then
  rm -f "$XML_TMP"
  echo "$(ts) FATAL: phpstan exited with code $phpstan_rc (scope=$SCOPE); prior count file untouched"
  echo "$(ts) phpstan exit code $phpstan_rc" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true
  exit 1
fi

# Refuse to proceed if the XML is empty (phpstan crashed before emitting any
# XML, awk filter found no <?xml marker, etc.). Without this guard, the
# parser below would parse a 0-byte file, fall into the @simplexml_load_file
# false branch, write "0" to the count file, and Zabbix would silently
# report success for as long as the failure persisted.
if [ ! -s "$XML_TMP" ]; then
  rm -f "$XML_TMP"
  echo "$(ts) FATAL: phpstan produced empty output (scope=$SCOPE); prior count file untouched"
  echo "$(ts) phpstan empty-output failure" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true
  exit 1
fi

# Refuse to proceed if the XML is truncated (mid-output crash after the
# <?xml header was emitted). simplexml_load_file will happily parse an
# incomplete <checkstyle>...</file>... fragment as valid XML with zero <file>
# children -- another silent-green path. Require the closing </checkstyle>
# tag to appear anywhere in the file (no end-anchor, no tail-window; any
# trailing debug text from PHPStan stays harmless).
if ! grep -q '</checkstyle>' "$XML_TMP"; then
  rm -f "$XML_TMP"
  echo "$(ts) FATAL: phpstan XML is truncated, missing </checkstyle> close (scope=$SCOPE); prior count file untouched"
  echo "$(ts) phpstan XML truncated (no </checkstyle> close)" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true
  exit 1
fi

# Move tmp into place only after all validation passed.
mv "$XML_TMP" "$LOG_HOST_DIR/${SCOPE}-latest.xml"

# Parse checkstyle XML, emit JSON (matching the previous schema for backward
# compat: { totals: { file_errors: N, errors: 0 }, files: { path: { errors: N,
# messages: [ { line, message, identifier } ] } } }) and write the count file.
# Both JSON and count file are written via tmp + mv for the same atomic-write
# reason as the XML above.
#
# Path naming: *_CT vars are container-side paths (passed to docker exec), *_HOST
# vars are host-side paths (used for shell tests and mv). The two refer to the
# same physical file via the docker-compose bind mount.
JSON_TMP_CT="$JSON_CT.tmp"
JSON_TMP_HOST="$LOG_HOST_DIR/${SCOPE}-latest.json.tmp"
COUNT_TMP_CT="$LOG_CT/${SCOPE}_errors_count.txt.tmp"
COUNT_TMP_HOST="$LOG_HOST_DIR/${SCOPE}_errors_count.txt.tmp"
# Wrap the docker exec in `set +e` so an inline-php exit(2) on parse failure
# doesn't abort the script before we get to write the failure sentinel.
set +e
docker exec -u www-data php \
  php -d "open_basedir=$OPEN_BASEDIR" -r '
    $xml = @simplexml_load_file($argv[1]);
    if ($xml === false) { fwrite(STDERR, "FATAL: simplexml_load_file failed on " . $argv[1] . "\n"); exit(2); }
    $totalErrors = 0; $files = [];
    foreach ($xml->file as $file) {
        $path = (string)$file["name"];
        $messages = [];
        foreach ($file->error as $err) {
            $messages[] = [
                "line"       => (int)$err["line"],
                "message"    => (string)$err["message"],
                "identifier" => (string)$err["source"],
            ];
            $totalErrors++;
        }
        $files[$path] = ["errors" => count($messages), "messages" => $messages];
    }
    $out = ["totals" => ["errors" => 0, "file_errors" => $totalErrors], "files" => $files];
    file_put_contents($argv[2], json_encode($out, JSON_PRETTY_PRINT | JSON_INVALID_UTF8_SUBSTITUTE));
    file_put_contents($argv[3], (string)$totalErrors);
  ' "$XML_CT" "$JSON_TMP_CT" "$COUNT_TMP_CT"
post_rc=$?
set -e

# Treat any non-zero exit (PHP fatal, simplexml failure, container down) as
# a hard failure and write sentinel before exiting.
if [ "$post_rc" -ne 0 ]; then
  rm -f "$JSON_TMP_HOST" "$COUNT_TMP_HOST"
  echo "$(ts) FATAL: post-processing PHP exited with code $post_rc (scope=$SCOPE); prior count file untouched"
  echo "$(ts) phpstan post-processing exit code $post_rc" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true
  exit 1
fi

# Verify both tmp files were written, then atomic-move into place.
# `-s` requires size > 0 — true even for a 1-byte "0" count.
if [ ! -s "$JSON_TMP_HOST" ] || [ ! -s "$COUNT_TMP_HOST" ]; then
  rm -f "$JSON_TMP_HOST" "$COUNT_TMP_HOST"
  echo "$(ts) FATAL: post-processing failed to produce JSON/count (scope=$SCOPE); prior count file untouched"
  echo "$(ts) phpstan post-processing missing output" > "$LOG_HOST_DIR/${SCOPE}_last_failure.txt" || true
  exit 1
fi
mv "$JSON_TMP_HOST" "$JSON_CT_HOST"
mv "$COUNT_TMP_HOST" "$LOG_HOST_DIR/${SCOPE}_errors_count.txt"

# All success-path writes done. Disarm the catch-all trap before clearing the
# sentinel — otherwise an unrelated error during the final `cat` / `wc` lines
# below would re-create the sentinel and falsely fire the failure trigger.
trap - ERR INT TERM

# Clear the failure sentinel on success so a recovered scan resolves any
# freshness/failure trigger that had been firing.
# An owned-scope success also clears any stale diagnostic-scope sentinel,
# because the diagnostic scope is manual-only and could otherwise leave a
# permanent failure marker after one bad manual run. The Zabbix template only
# watches the owned sentinel, so this is belt-and-braces for operators who
# may later add a diagnostic watch.
rm -f "$LOG_HOST_DIR/${SCOPE}_last_failure.txt"
if [ "$SCOPE" = "owned" ]; then
  rm -f "$LOG_HOST_DIR/diagnostic_last_failure.txt"
fi

COUNT=$(cat "$LOG_HOST_DIR/${SCOPE}_errors_count.txt")
echo "$(ts) scope=$SCOPE errors=$COUNT json=$(wc -c <"$LOG_HOST_DIR/${SCOPE}-latest.json") bytes"
