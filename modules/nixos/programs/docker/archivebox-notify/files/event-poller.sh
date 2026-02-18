#!/usr/bin/env bash
# writeShellApplication provides set -euo pipefail

: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${DB_FILE:?DB_FILE is required}"
: "${QUEUE_FILE:?QUEUE_FILE is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${SUCCESS_ENABLED:?SUCCESS_ENABLED is required}"
: "${INCLUDE_FULL_URL:?INCLUDE_FULL_URL is required}"
: "${SILENCE_SUCCESS_NIGHT:?SILENCE_SUCCESS_NIGHT is required}"
: "${NIGHT_HOURS:?NIGHT_HOURS is required}"
: "${ARCHIVEBOX_BASE_URL:?ARCHIVEBOX_BASE_URL is required}"
: "${MAX_LOOKUPS_PER_CYCLE:?MAX_LOOKUPS_PER_CYCLE is required}"
: "${PENDING_CAP:?PENDING_CAP is required}"
: "${PENDING_RECOVER_THRESHOLD:?PENDING_RECOVER_THRESHOLD is required}"
: "${PENDING_TIMEOUT_SEC:?PENDING_TIMEOUT_SEC is required}"
: "${DEGRADE_INTERVAL_SEC:?DEGRADE_INTERVAL_SEC is required}"
: "${POLL_P95_BUDGET_MS:?POLL_P95_BUDGET_MS is required}"

# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

mkdir -p "$STATE_DIR/state" "$STATE_DIR/metrics"

LOCK_FILE="$STATE_DIR/state/poller.lock"
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "archivebox-event-poller: already running, skip"
  exit 0
}

PENDING_FILE="$STATE_DIR/state/pending.json"
NOTIFIED_FILE="$STATE_DIR/state/notified.json"
LAST_LINE_FILE="$STATE_DIR/state/queue-last-line"
LAST_RESULT_ROWID_FILE="$STATE_DIR/state/last-result-rowid"
DEGRADED_FILE="$STATE_DIR/state/degraded-mode"
LAST_FULL_RUN_FILE="$STATE_DIR/state/last-full-run"
RECOVER_STREAK_FILE="$STATE_DIR/state/recover-streak"
LAST_OVERLOAD_NOTIFY_FILE="$STATE_DIR/state/last-overload-notify"
LAST_PERF_NOTIFY_FILE="$STATE_DIR/state/last-perf-notify"
METRICS_FILE="$STATE_DIR/metrics/poller-ms.log"
ARCHIVERESULT_OUTPUT_EXPR="''"
DB_SQLITE_TARGET="$DB_FILE"

ensure_json_object() {
  local file="$1"

  if [ ! -s "$file" ]; then
    echo '{}' > "$file"
    return
  fi

  if ! jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
    echo '{}' > "$file"
  fi
}

json_update() {
  local file="$1"
  shift

  local tmp
  tmp=$(mktemp)
  jq "$@" "$file" > "$tmp"
  mv "$tmp" "$file"
}

bool_is_true() {
  local value
  value=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  [ "$value" = "true" ] || [ "$value" = "1" ] || [ "$value" = "yes" ]
}

send_event_notification() {
  local title="$1"
  local message="$2"
  local priority="$3"

  if declare -F send_notification_strict > /dev/null 2>&1; then
    send_notification_strict "$title" "$message" "$priority"
  else
    send_notification "$title" "$message" "$priority"
  fi
}

current_epoch() {
  date +%s
}

epoch_ms() {
  local raw
  raw=$(date +%s%3N 2>/dev/null || true)
  if echo "$raw" | rg -q '^[0-9]+$'; then
    echo "$raw"
  else
    echo "$(( $(date +%s) * 1000 ))"
  fi
}

load_int_file() {
  local file="$1"
  local default="$2"
  if [ -f "$file" ]; then
    cat "$file" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

save_int_file() {
  local file="$1"
  local value="$2"
  echo "$value" > "$file"
}

sanitize_domain() {
  local url="$1"
  local domain
  domain=$(echo "$url" | sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@:]+).*$#\1#')
  if [ -z "$domain" ] || [ "$domain" = "$url" ]; then
    echo "unknown"
  else
    echo "$domain"
  fi
}

friendly_reason() {
  local reason="$1"
  local normalized
  normalized=$(echo "$reason" | tr '[:upper:]' '[:lower:]')

  if echo "$normalized" | rg -q "timeout|timed out|exceeded"; then
    echo "응답 대기 시간이 초과됐어요."
    return
  fi

  if echo "$normalized" | rg -q "auth|unauthorized|forbidden|permission"; then
    echo "인증 또는 권한 문제로 저장하지 못했어요."
    return
  fi

  if echo "$normalized" | rg -q "dns|name resolution|resolve|connection|network"; then
    echo "네트워크 연결 문제로 저장하지 못했어요."
    return
  fi

  echo "아카이빙 도중 오류가 발생했어요."
}

normalize_text() {
  local text="$1"
  text=$(echo "$text" | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')
  echo "${text:0:240}"
}

build_archive_url() {
  local snapshot_id="$1"
  local snapshot_ts
  snapshot_ts=$(sqlite3 "$DB_SQLITE_TARGET" "SELECT COALESCE(timestamp, '') FROM core_snapshot WHERE id='${snapshot_id}' LIMIT 1;" 2>/dev/null || true)

  if [ -n "$snapshot_ts" ]; then
    echo "${ARCHIVEBOX_BASE_URL%/}/archive/${snapshot_ts}/index.html"
  else
    echo "${ARCHIVEBOX_BASE_URL%/}/admin/core/snapshot/${snapshot_id}/change/"
  fi
}

is_night_time() {
  local now_h start end start_h end_h
  now_h=$(date +%H)
  start="${NIGHT_HOURS%-*}"
  end="${NIGHT_HOURS#*-}"
  start_h="${start%%:*}"
  end_h="${end%%:*}"

  if [ "$start_h" -lt "$end_h" ]; then
    [ "$now_h" -ge "$start_h" ] && [ "$now_h" -lt "$end_h" ]
  else
    [ "$now_h" -ge "$start_h" ] || [ "$now_h" -lt "$end_h" ]
  fi
}

mark_notified() {
  local snapshot_id="$1"
  local status="$2"
  local now="$3"
  local result_rowid="$4"

  # shellcheck disable=SC2016
  json_update "$NOTIFIED_FILE" \
    --arg id "$snapshot_id" \
    --arg status "$status" \
    --argjson now "$now" \
    --argjson result_rowid "$result_rowid" \
    '.[$id] = {"status": $status, "notified_at": $now, "result_rowid": $result_rowid}'
}

remove_pending() {
  local snapshot_id="$1"
  # shellcheck disable=SC2016
  json_update "$PENDING_FILE" --arg id "$snapshot_id" 'del(.[$id])'
}

notified_result_rowid() {
  local snapshot_id="$1"
  jq -r --arg id "$snapshot_id" '(.[$id].result_rowid // 0) | tonumber? // 0' "$NOTIFIED_FILE"
}

upsert_pending() {
  local snapshot_id="$1"
  local url="$2"
  local domain="$3"
  local now="$4"
  local result_rowid="$5"

  # shellcheck disable=SC2016
  json_update "$PENDING_FILE" \
    --arg id "$snapshot_id" \
    --arg url "$url" \
    --arg domain "$domain" \
    --argjson now "$now" \
    --argjson result_rowid "$result_rowid" \
    '.[$id] = (
      .[$id] as $prev
      | ($prev // {"url": $url, "domain": $domain, "first_seen": $now, "last_result_rowid": 0})
      + {
        "url": $url,
        "domain": $domain,
        "last_seen": $now,
        "last_result_rowid": ([($prev.last_result_rowid // 0), $result_rowid] | max)
      }
    )'
}

is_notified_for_rowid() {
  local snapshot_id="$1"
  local rowid="$2"

  jq -e \
    --arg id "$snapshot_id" \
    --argjson rowid "$rowid" \
    '((.[$id].result_rowid // 0) | tonumber? // 0) >= $rowid' \
    "$NOTIFIED_FILE" > /dev/null 2>&1
}

failure_priority() {
  local reason="$1"
  local normalized
  normalized=$(echo "$reason" | tr '[:upper:]' '[:lower:]')

  if echo "$normalized" | rg -q "auth|unauthorized|forbidden|permission|timeout|max attempts|max_url_attempts|exceeded"; then
    echo "1"
  else
    echo "0"
  fi
}

send_success() {
  local snapshot_id="$1"
  local url="$2"
  local _domain="$3"

  if ! bool_is_true "$SUCCESS_ENABLED"; then
    return
  fi

  if bool_is_true "$SILENCE_SUCCESS_NIGHT" && is_night_time; then
    echo "archivebox-event-poller: success suppressed in night hours"
    return
  fi

  local archive_url
  archive_url=$(build_archive_url "$snapshot_id")

  local message
  printf -v message '%s\n%s\n%s' \
    "아카이빙이 완료됐어요." \
    "원본 URL: ${url}" \
    "보관 URL: ${archive_url}"
  send_event_notification "ArchiveBox 아카이빙 성공" "$message" -1
}

send_failure() {
  local snapshot_id="$1"
  local url="$2"
  local _domain="$3"
  local reason="$4"

  local archive_url
  archive_url=$(build_archive_url "$snapshot_id")

  local priority
  priority=$(failure_priority "$reason")

  local friendly
  friendly=$(friendly_reason "$reason")

  local reason_short
  reason_short=$(normalize_text "$reason")

  local message
  printf -v message '%s\n%s\n%s\n%s\n%s' \
    "아카이빙에 실패했어요." \
    "원본 URL: ${url}" \
    "보관 URL: ${archive_url}" \
    "이유: ${friendly}" \
    "상세: ${reason_short}"
  send_event_notification "ArchiveBox 아카이빙 실패" "$message" "$priority"
}

classify_snapshot() {
  local snapshot_id="$1"

  local rows
  rows=$(sqlite3 -json "$DB_SQLITE_TARGET" "SELECT rowid, status, ${ARCHIVERESULT_OUTPUT_EXPR} AS output_str FROM core_archiveresult WHERE snapshot_id='${snapshot_id}' ORDER BY rowid DESC;" 2>/dev/null || true)
  if [ -z "$rows" ] || ! echo "$rows" | jq -e 'type == "array"' > /dev/null 2>&1; then
    rows="[]"
  fi

  local latest_rowid
  latest_rowid=$(echo "$rows" | jq '([.[].rowid] | max // 0)')
  if ! echo "$latest_rowid" | rg -q '^[0-9]+$'; then
    latest_rowid="0"
  fi

  local count
  count=$(echo "$rows" | jq 'length')
  if [ "$count" -eq 0 ]; then
    jq -nc --arg state "pending" --arg reason "" --argjson result_rowid "$latest_rowid" \
      '{state: $state, reason: $reason, result_rowid: $result_rowid}'
    return
  fi

  if echo "$rows" | jq -e 'any(.[]; .status == "queued" or .status == "started" or .status == "backoff")' > /dev/null; then
    jq -nc --arg state "pending" --arg reason "" --argjson result_rowid "$latest_rowid" \
      '{state: $state, reason: $reason, result_rowid: $result_rowid}'
    return
  fi

  if echo "$rows" | jq -e 'any(.[]; .status == "failed")' > /dev/null; then
    local reason
    reason=$(echo "$rows" | jq -r '([.[] | select(.status == "failed")][0].output_str // "archive result failed")')
    jq -nc --arg state "failure" --arg reason "$reason" --argjson result_rowid "$latest_rowid" \
      '{state: $state, reason: $reason, result_rowid: $result_rowid}'
    return
  fi

  if echo "$rows" | jq -e 'any(.[]; .status == "succeeded")' > /dev/null; then
    jq -nc --arg state "success" --arg reason "" --argjson result_rowid "$latest_rowid" \
      '{state: $state, reason: $reason, result_rowid: $result_rowid}'
    return
  fi

  if echo "$rows" | jq -e 'all(.[]; .status == "skipped")' > /dev/null; then
    jq -nc --arg state "failure" --arg reason "all hooks skipped" --argjson result_rowid "$latest_rowid" \
      '{state: $state, reason: $reason, result_rowid: $result_rowid}'
    return
  fi

  jq -nc --arg state "pending" --arg reason "" --argjson result_rowid "$latest_rowid" \
    '{state: $state, reason: $reason, result_rowid: $result_rowid}'
}

record_runtime_and_exit() {
  local code="$1"
  local now
  now=$(current_epoch)

  local end_ms duration_ms
  end_ms=$(epoch_ms)
  duration_ms=$((end_ms - START_MS))

  echo "$duration_ms" >> "$METRICS_FILE"
  tail -n 200 "$METRICS_FILE" > "$METRICS_FILE.tmp"
  mv "$METRICS_FILE.tmp" "$METRICS_FILE"

  local p95
  p95=$(sort -n "$METRICS_FILE" | awk '{a[NR]=$1} END { if (NR==0) { print 0; exit } idx=int((NR*95+99)/100); if (idx<1) idx=1; if (idx>NR) idx=NR; print a[idx] }')
  echo "archivebox-event-poller: duration=${duration_ms}ms p95=${p95}ms"

  if [ "$p95" -gt "$POLL_P95_BUDGET_MS" ]; then
    local last_perf_notify
    last_perf_notify=$(load_int_file "$LAST_PERF_NOTIFY_FILE" 0)
    if [ $((now - last_perf_notify)) -ge 1800 ]; then
      send_notification "ArchiveBox 알림 지연" "알림 처리 시간이 느려졌어요. 최근 p95 ${p95}ms (기준 ${POLL_P95_BUDGET_MS}ms)" 0
      save_int_file "$LAST_PERF_NOTIFY_FILE" "$now"
    fi
  fi

  exit "$code"
}

# init state files
ensure_json_object "$PENDING_FILE"
ensure_json_object "$NOTIFIED_FILE"

[ -f "$LAST_LINE_FILE" ] || echo "0" > "$LAST_LINE_FILE"
[ -f "$DEGRADED_FILE" ] || echo "0" > "$DEGRADED_FILE"
[ -f "$LAST_FULL_RUN_FILE" ] || echo "0" > "$LAST_FULL_RUN_FILE"
[ -f "$RECOVER_STREAK_FILE" ] || echo "0" > "$RECOVER_STREAK_FILE"

START_MS=$(epoch_ms)
NOW=$(current_epoch)
DEGRADED=$(load_int_file "$DEGRADED_FILE" 0)
LAST_FULL_RUN=$(load_int_file "$LAST_FULL_RUN_FILE" 0)

if [ "$DEGRADED" = "1" ] && [ $((NOW - LAST_FULL_RUN)) -lt "$DEGRADE_INTERVAL_SEC" ]; then
  echo "archivebox-event-poller: 대기열 보호 모드 유지"
  record_runtime_and_exit 0
fi

save_int_file "$LAST_FULL_RUN_FILE" "$NOW"

if [ ! -f "$DB_FILE" ]; then
  echo "archivebox-event-poller: DB file not found: $DB_FILE"
  record_runtime_and_exit 0
fi

DB_SQLITE_TARGET="file:${DB_FILE}?mode=ro&immutable=1"

ARCHIVERESULT_COLS=$(sqlite3 -json "$DB_SQLITE_TARGET" "PRAGMA table_info(core_archiveresult);" 2>/dev/null || true)
if [ -n "$ARCHIVERESULT_COLS" ] && echo "$ARCHIVERESULT_COLS" | jq -e 'type == "array"' > /dev/null 2>&1; then
  if echo "$ARCHIVERESULT_COLS" | jq -e 'any(.[]; .name == "output_str")' > /dev/null; then
    ARCHIVERESULT_OUTPUT_EXPR="COALESCE(output_str, '')"
  elif echo "$ARCHIVERESULT_COLS" | jq -e 'any(.[]; .name == "output")' > /dev/null; then
    ARCHIVERESULT_OUTPUT_EXPR="COALESCE(output, '')"
  fi
fi

# bootstrap result cursor on first run to avoid historic backlog flood
if [ ! -f "$LAST_RESULT_ROWID_FILE" ]; then
  BOOTSTRAP_ROWID=$(sqlite3 "$DB_SQLITE_TARGET" "SELECT COALESCE(MAX(rowid), 0) FROM core_archiveresult;" 2>/dev/null || echo "0")
  if ! echo "$BOOTSTRAP_ROWID" | rg -q '^[0-9]+$'; then
    BOOTSTRAP_ROWID="0"
  fi
  save_int_file "$LAST_RESULT_ROWID_FILE" "$BOOTSTRAP_ROWID"
fi

# ingest new queue events
LAST_LINE=$(load_int_file "$LAST_LINE_FILE" 0)
TOTAL_LINES=0
if [ -f "$QUEUE_FILE" ]; then
  TOTAL_LINES=$(wc -l < "$QUEUE_FILE")
fi

if [ "$TOTAL_LINES" -lt "$LAST_LINE" ]; then
  LAST_LINE=0
fi

if [ "$TOTAL_LINES" -gt "$LAST_LINE" ]; then
  tail -n "+$((LAST_LINE + 1))" "$QUEUE_FILE" | while IFS= read -r line; do
    snapshot_id=$(echo "$line" | jq -r '.snapshot_id // empty' 2>/dev/null || true)
    url=$(echo "$line" | jq -r '.url // empty' 2>/dev/null || true)
    domain=$(echo "$line" | jq -r '.domain // empty' 2>/dev/null || true)

    if [ -z "$snapshot_id" ]; then
      continue
    fi

    if [ -z "$domain" ] || [ "$domain" = "null" ]; then
      domain=$(sanitize_domain "$url")
    fi

    upsert_pending "$snapshot_id" "$url" "$domain" "$NOW" 0
  done
fi

save_int_file "$LAST_LINE_FILE" "$TOTAL_LINES"

# fallback ingest path: scan newly added archiveresults directly from DB
LAST_RESULT_ROWID=$(load_int_file "$LAST_RESULT_ROWID_FILE" 0)
if ! echo "$LAST_RESULT_ROWID" | rg -q '^[0-9]+$'; then
  LAST_RESULT_ROWID="0"
fi

NEW_RESULTS=$(sqlite3 -json "$DB_SQLITE_TARGET" "SELECT r.rowid, r.snapshot_id, COALESCE(s.url, '') AS url FROM core_archiveresult r LEFT JOIN core_snapshot s ON s.id = r.snapshot_id WHERE r.rowid > ${LAST_RESULT_ROWID} ORDER BY r.rowid ASC LIMIT ${MAX_LOOKUPS_PER_CYCLE};" 2>/dev/null || true)
if [ -z "$NEW_RESULTS" ] || ! echo "$NEW_RESULTS" | jq -e 'type == "array"' > /dev/null 2>&1; then
  NEW_RESULTS="[]"
fi

MAX_SEEN_ROWID="$LAST_RESULT_ROWID"
while IFS= read -r row; do
  rowid=$(echo "$row" | jq -r '.rowid // 0')
  snapshot_id=$(echo "$row" | jq -r '.snapshot_id // empty')
  url=$(echo "$row" | jq -r '.url // ""')

  if [ -z "$snapshot_id" ]; then
    continue
  fi

  if ! echo "$rowid" | rg -q '^[0-9]+$'; then
    rowid="0"
  fi

  if is_notified_for_rowid "$snapshot_id" "$rowid"; then
    if [ "$rowid" -gt "$MAX_SEEN_ROWID" ]; then
      MAX_SEEN_ROWID="$rowid"
    fi
    continue
  fi

  domain=$(sanitize_domain "$url")
  upsert_pending "$snapshot_id" "$url" "$domain" "$NOW" "$rowid"

  if [ "$rowid" -gt "$MAX_SEEN_ROWID" ]; then
    MAX_SEEN_ROWID="$rowid"
  fi
done <<EOF
$(echo "$NEW_RESULTS" | jq -c '.[]')
EOF

if [ "$MAX_SEEN_ROWID" -gt "$LAST_RESULT_ROWID" ]; then
  save_int_file "$LAST_RESULT_ROWID_FILE" "$MAX_SEEN_ROWID"
fi

# resolve pending snapshots (bounded work per cycle)
while IFS= read -r snapshot_id; do
  if [ -z "$snapshot_id" ]; then
    continue
  fi

  entry=$(jq -c --arg id "$snapshot_id" '.[$id]' "$PENDING_FILE")
  url=$(echo "$entry" | jq -r '.url // ""')
  domain=$(echo "$entry" | jq -r '.domain // "unknown"')
  first_seen=$(echo "$entry" | jq -r '.first_seen // 0')
  pending_result_rowid=$(echo "$entry" | jq -r '.last_result_rowid // 0')

  result=$(classify_snapshot "$snapshot_id")
  state=$(echo "$result" | jq -r '.state // "pending"')
  reason=$(echo "$result" | jq -r '.reason // ""')
  latest_result_rowid=$(echo "$result" | jq -r '.result_rowid // 0')

  if ! echo "$pending_result_rowid" | rg -q '^[0-9]+$'; then
    pending_result_rowid="0"
  fi
  if ! echo "$latest_result_rowid" | rg -q '^[0-9]+$'; then
    latest_result_rowid="0"
  fi
  if [ "$pending_result_rowid" -gt "$latest_result_rowid" ]; then
    latest_result_rowid="$pending_result_rowid"
  fi

  notified_rowid=$(notified_result_rowid "$snapshot_id")
  if ! echo "$notified_rowid" | rg -q '^[0-9]+$'; then
    notified_rowid="0"
  fi

  if [ "$latest_result_rowid" -gt 0 ] && [ "$notified_rowid" -ge "$latest_result_rowid" ]; then
    remove_pending "$snapshot_id"
    continue
  fi

  if [ "$state" = "pending" ]; then
    if [ $((NOW - first_seen)) -ge "$PENDING_TIMEOUT_SEC" ]; then
      if send_failure "$snapshot_id" "$url" "$domain" "timeout after ${PENDING_TIMEOUT_SEC}s"; then
        mark_notified "$snapshot_id" "failure" "$NOW" "$latest_result_rowid"
        remove_pending "$snapshot_id"
      fi
    fi
    continue
  fi

  if [ "$state" = "success" ]; then
    if send_success "$snapshot_id" "$url" "$domain"; then
      mark_notified "$snapshot_id" "success" "$NOW" "$latest_result_rowid"
      remove_pending "$snapshot_id"
    fi
    continue
  fi

  if [ "$state" = "failure" ]; then
    if send_failure "$snapshot_id" "$url" "$domain" "$reason"; then
      mark_notified "$snapshot_id" "failure" "$NOW" "$latest_result_rowid"
      remove_pending "$snapshot_id"
    fi
    continue
  fi
done <<EOF
$(jq -r 'keys[]' "$PENDING_FILE" | head -n "$MAX_LOOKUPS_PER_CYCLE")
EOF

PENDING_COUNT=$(jq 'length' "$PENDING_FILE")
RECOVER_STREAK=$(load_int_file "$RECOVER_STREAK_FILE" 0)

if [ "$PENDING_COUNT" -gt "$PENDING_CAP" ]; then
  save_int_file "$DEGRADED_FILE" 1
  save_int_file "$RECOVER_STREAK_FILE" 0

  LAST_OVERLOAD_NOTIFY=$(load_int_file "$LAST_OVERLOAD_NOTIFY_FILE" 0)
  if [ $((NOW - LAST_OVERLOAD_NOTIFY)) -ge 1800 ]; then
    send_notification "ArchiveBox 대기열 경고" "대기 작업이 많아 확인 주기를 5분으로 늘렸어요. 현재 ${PENDING_COUNT}건 (기준 ${PENDING_CAP}건)" 1
    save_int_file "$LAST_OVERLOAD_NOTIFY_FILE" "$NOW"
  fi
else
  if [ "$(load_int_file "$DEGRADED_FILE" 0)" = "1" ]; then
    if [ "$PENDING_COUNT" -lt "$PENDING_RECOVER_THRESHOLD" ]; then
      RECOVER_STREAK=$((RECOVER_STREAK + 1))
    else
      RECOVER_STREAK=0
    fi

    save_int_file "$RECOVER_STREAK_FILE" "$RECOVER_STREAK"

    if [ "$RECOVER_STREAK" -ge 3 ]; then
      save_int_file "$DEGRADED_FILE" 0
      save_int_file "$RECOVER_STREAK_FILE" 0
      send_notification "ArchiveBox 대기열 복구" "대기 작업이 줄어 확인 주기를 1분으로 복구했어요. 현재 ${PENDING_COUNT}건" 0
    fi
  fi
fi

record_runtime_and_exit 0
