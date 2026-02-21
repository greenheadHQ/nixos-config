# shellcheck shell=bash
# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

COPYPARTY_UPLOAD_URL="${COPYPARTY_FALLBACK_URL:-https://copyparty.greenhead.dev/archive-fallback/}"
DEDUP_WINDOW_SEC=1800
FAILED_URL_QUEUE_FILE="${FAILED_URL_QUEUE_FILE:-/var/lib/karakeep-log-monitor/failed-urls.queue}"
FAILED_URL_QUEUE_LOCK_FILE="${FAILED_URL_QUEUE_LOCK_FILE:-${FAILED_URL_QUEUE_FILE}.lock}"
FAILED_URL_QUEUE_MAX="${FAILED_URL_QUEUE_MAX:-200}"
NOTIFY_STATE_FILE="${NOTIFY_STATE_FILE:-/var/lib/karakeep-log-monitor/notified-urls.tsv}"
LAST_CRAWL_URL=""
declare -A NOTIFIED_URLS=()

mkdir -p "$(dirname "$FAILED_URL_QUEUE_FILE")"
touch "$FAILED_URL_QUEUE_FILE" "$NOTIFY_STATE_FILE"

QUEUE_LOCK_ENABLED=0
if command -v flock > /dev/null 2>&1; then
  exec 10>"$FAILED_URL_QUEUE_LOCK_FILE"
  QUEUE_LOCK_ENABLED=1
else
  echo "WARNING: flock command not found; queue writes are unlocked"
fi

load_notify_state() {
  local url ts
  while IFS=$'\t' read -r url ts; do
    [ -n "$url" ] || continue
    [[ "$ts" =~ ^[0-9]+$ ]] || continue
    NOTIFIED_URLS["$url"]="$ts"
  done < "$NOTIFY_STATE_FILE"
}

shorten_url() {
  local url="$1"
  if [ "$url" = "(unknown URL)" ]; then
    printf "%s" "$url"
    return 0
  fi

  url="${url#http://}"
  url="${url#https://}"
  url="${url%%\?*}"
  url="${url%/}"
  printf "%s" "$url"
}

should_notify_url() {
  local url="$1"
  local now previous tmp
  now=$(date +%s)
  previous="${NOTIFIED_URLS[$url]-0}"

  if (( now - previous < DEDUP_WINDOW_SEC )); then
    return 1
  fi

  tmp=$(mktemp)
  awk -F '\t' -v key="$url" '$1 != key { print }' "$NOTIFY_STATE_FILE" > "$tmp"
  printf "%s\t%s\n" "$url" "$now" >> "$tmp"
  mv "$tmp" "$NOTIFY_STATE_FILE"
  NOTIFIED_URLS[$url]="$now"
  return 0
}

enqueue_failed_url() {
  local failed_url="$1"
  local tmp
  local rc
  rc=0

  if [ -z "$failed_url" ] || [ "$failed_url" = "(unknown URL)" ]; then
    return 0
  fi

  if (( QUEUE_LOCK_ENABLED )); then
    flock -x 10
  fi

  if grep -Fxq "$failed_url" "$FAILED_URL_QUEUE_FILE"; then
    if (( QUEUE_LOCK_ENABLED )); then
      flock -u 10
    fi
    return 0
  fi

  printf "%s\n" "$failed_url" >> "$FAILED_URL_QUEUE_FILE" || rc=1
  tmp=$(mktemp)
  if [ "$rc" -eq 0 ]; then
    if ! tail -n "$FAILED_URL_QUEUE_MAX" "$FAILED_URL_QUEUE_FILE" > "$tmp"; then
      rc=1
    elif ! mv "$tmp" "$FAILED_URL_QUEUE_FILE"; then
      rc=1
    fi
  fi
  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
  fi

  if (( QUEUE_LOCK_ENABLED )); then
    flock -u 10
  fi
  return "$rc"
}

send_failure_alert() {
  local reason="$1"
  local priority="$2"
  local explicit_url="${3:-}"
  local failed_url short_url message

  if [ -n "$explicit_url" ]; then
    failed_url="$explicit_url"
  elif [ -n "$LAST_CRAWL_URL" ]; then
    failed_url="$LAST_CRAWL_URL"
  else
    failed_url="(unknown URL)"
  fi

  enqueue_failed_url "$failed_url"

  if ! should_notify_url "$failed_url"; then
    echo "Dedup: skipped alert for ${failed_url}"
    return 0
  fi

  short_url=$(shorten_url "$failed_url")
  message=$(printf "아카이브 실패: %s\n원인: %s\n수동 보관: %s" "$short_url" "$reason" "$COPYPARTY_UPLOAD_URL")
  send_notification "Karakeep" "$message" "$priority"
  echo "Alert sent: ${reason} (${short_url})"
}

echo "Karakeep log monitor started"
echo "Watching podman-karakeep.service..."
load_notify_state

while IFS= read -r line; do
  if [[ "$line" =~ Will\ crawl\ \"([^\"]+)\" ]]; then
    LAST_CRAWL_URL="${BASH_REMATCH[1]}"
    echo "Tracked URL: ${LAST_CRAWL_URL}"
    continue
  fi

  if [[ "$line" =~ FATAL\ ERROR.*heap ]]; then
    send_failure_alert "V8 heap OOM" 1
    continue
  fi

  if [[ "$line" =~ OOM\ killed\ \(exit\ code\ [0-9]+\) ]]; then
    send_failure_alert "Parser subprocess OOM" 0
    continue
  fi

  if [[ "$line" =~ Crawling\ job\ failed: ]]; then
    failed_url=""
    if [[ "$line" =~ \"([^\"]+)\" ]]; then
      failed_url="${BASH_REMATCH[1]}"
    fi
    send_failure_alert "Crawling job failed" 0 "$failed_url"
    continue
  fi
done < <(journalctl -u podman-karakeep.service -f -o cat --since "now" --no-pager)
