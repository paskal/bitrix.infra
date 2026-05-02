#!/usr/bin/env bash
# Daily Yandex Webmaster recrawl batch worker.
# Reads URLs from /web/private/seo-reindex/queue.txt (top first),
# submits as many as today's quota allows, removes submitted ones from the queue,
# appends a summary block to /web/private/seo-reindex/progress_log.md.
#
# Cron: 15 21 * * *  (21:15 UTC == 00:15 Moscow time, runs as root)

set -euo pipefail

QUEUE_DIR=/web/private/seo-reindex
QUEUE="$QUEUE_DIR/queue.txt"
PROGRESS="$QUEUE_DIR/progress_log.md"
ENV_FILE=/web/private/environment/seo-reindex.env

LOG_DIR=/web/logs/seo-reindex
mkdir -p "$LOG_DIR" "$QUEUE_DIR"
LOG="$LOG_DIR/$(date -u +%Y-%m-%d).log"
exec >>"$LOG" 2>&1

ts() { date -u +%FT%TZ; }

echo "=== $(ts) seo-reindex start ==="

if [ ! -f "$ENV_FILE" ]; then
  echo "FATAL: $ENV_FILE missing"
  exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
: "${YANDEX_WEBMASTER_TOKEN:?missing YANDEX_WEBMASTER_TOKEN in $ENV_FILE}"
: "${YANDEX_WEBMASTER_USER_ID:?missing YANDEX_WEBMASTER_USER_ID in $ENV_FILE}"

if [ ! -s "$QUEUE" ]; then
  echo "queue empty -- nothing to do"
  exit 0
fi

# Quota is account-wide (shared across all verified hosts) -- pick any verified host.
QUOTA_HOST="https:favor-group.ru:443"
QUOTA_JSON=$(curl -fsS --max-time 30 \
  -H "Authorization: OAuth $YANDEX_WEBMASTER_TOKEN" \
  "https://api.webmaster.yandex.net/v4/user/$YANDEX_WEBMASTER_USER_ID/hosts/$QUOTA_HOST/recrawl/quota/")
DAILY=$(echo "$QUOTA_JSON" | jq -r '.daily_quota')
REMAINING=$(echo "$QUOTA_JSON" | jq -r '.quota_remainder')
if [ -z "$REMAINING" ] || [ "$REMAINING" = "null" ]; then
  echo "FATAL: bad quota response: $QUOTA_JSON"
  exit 1
fi
echo "quota: $REMAINING remaining of $DAILY daily"

if [ "$REMAINING" -le 0 ]; then
  echo "no quota remaining -- exiting"
  exit 0
fi

QUEUE_LEN=$(wc -l <"$QUEUE")
BATCH=$((REMAINING < QUEUE_LEN ? REMAINING : QUEUE_LEN))
echo "queue: $QUEUE_LEN urls, will attempt: $BATCH"

OK=0
FAIL=0
ATTEMPTED=0

while IFS= read -r URL; do
  [ "$ATTEMPTED" -ge "$BATCH" ] && break
  ATTEMPTED=$((ATTEMPTED + 1))

  # Skip blanks/comments without consuming a slot (rare but possible).
  case "$URL" in
  '' | \#*)
    ATTEMPTED=$((ATTEMPTED - 1))
    continue
    ;;
  esac

  HOST_PART=$(echo "$URL" | awk -F/ '{print $3}')
  if [ -z "$HOST_PART" ]; then
    echo "FAIL (bad url) $URL"
    FAIL=$((FAIL + 1))
    continue
  fi
  HOST_ID="https:${HOST_PART}:443"

  RESP=$(curl -sS --max-time 30 -X POST \
    -H "Authorization: OAuth $YANDEX_WEBMASTER_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"url\":\"$URL\"}" \
    "https://api.webmaster.yandex.net/v4/user/$YANDEX_WEBMASTER_USER_ID/hosts/$HOST_ID/recrawl/queue/" 2>&1 ||
    echo '{"error_code":"CURL_FAILED"}')

  if echo "$RESP" | grep -q '"task_id"'; then
    OK=$((OK + 1))
    echo "OK   $URL"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL $URL :: $RESP"
  fi
  sleep 0.2
done <"$QUEUE"

# Remove the first ATTEMPTED lines from the queue (success or fail -- both consume quota,
# and a persistent failure should not block the queue head). Operator can re-queue from logs.
if [ "$ATTEMPTED" -gt 0 ]; then
  tail -n +"$((ATTEMPTED + 1))" "$QUEUE" >"$QUEUE.tmp"
  mv "$QUEUE.tmp" "$QUEUE"
fi
REMAINING_LINES=$(wc -l <"$QUEUE")

{
  echo
  echo "### $(date -u +'%Y-%m-%d %H:%M') UTC -- server cron"
  echo "- Attempted: $ATTEMPTED (ok $OK / fail $FAIL)"
  echo "- Quota at start: $REMAINING / $DAILY"
  echo "- Removed from queue.txt: $ATTEMPTED"
  echo "- Remaining in queue.txt: $REMAINING_LINES"
  echo "- Log: $LOG"
} >>"$PROGRESS"

echo "=== $(ts) done: ok=$OK fail=$FAIL remaining=$REMAINING_LINES ==="
