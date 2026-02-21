# shellcheck shell=bash
# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

: "${FALLBACK_DIR:?FALLBACK_DIR is required}"
: "${FAILED_URL_QUEUE_FILE:?FAILED_URL_QUEUE_FILE is required}"
: "${KARAKEEP_BASE_URL:?KARAKEEP_BASE_URL is required}"

STATE_DIR=$(dirname "$FAILED_URL_QUEUE_FILE")
LOCK_FILE="${STATE_DIR}/fallback-sync.lock"
FAILED_URL_QUEUE_LOCK_FILE="${FAILED_URL_QUEUE_LOCK_FILE:-${FAILED_URL_QUEUE_FILE}.lock}"
PROCESSED_FILE="${STATE_DIR}/fallback-processed.tsv"
NOTIFY_STATE_FILE="${STATE_DIR}/fallback-notify-state.tsv"
UNMATCHED_NOTIFIED_FILE="${STATE_DIR}/fallback-unmatched-notified.tsv"
NOTIFY_DEDUP_WINDOW_SEC=1800
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
UNMATCHED_STATE_RETENTION_DAYS="${UNMATCHED_STATE_RETENTION_DAYS:-30}"
PROCESSED_STATE_RETENTION_DAYS="${PROCESSED_STATE_RETENTION_DAYS:-30}"
NOTIFY_STATE_RETENTION_SEC="${NOTIFY_STATE_RETENTION_SEC:-86400}"

mkdir -p "$STATE_DIR"
touch "$FAILED_URL_QUEUE_FILE" "$PROCESSED_FILE" "$NOTIFY_STATE_FILE" "$UNMATCHED_NOTIFIED_FILE"

QUEUE_LOCK_ENABLED=0
if command -v flock > /dev/null 2>&1; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo "Another karakeep-fallback-sync run is in progress"
    exit 0
  fi
  exec 10>"$FAILED_URL_QUEUE_LOCK_FILE"
  QUEUE_LOCK_ENABLED=1
else
  echo "WARNING: flock command not found; running without queue lock"
fi

API_KEY="${KARAKEEP_API_KEY:-${KARAKEEP_SINGLEFILE_API_KEY:-}}"
if [ -z "$API_KEY" ]; then
  echo "KARAKEEP_API_KEY is not set in PUSHOVER_CRED_FILE; skipping auto relink"
  exit 0
fi

timestamp_to_epoch() {
  local raw="$1"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf "%s" "$raw"
    return 0
  fi

  date -d "$raw" +%s 2>/dev/null || printf "0"
}

gc_unmatched_notified_state() {
  local now cutoff tmp hash ts file_path epoch
  now=$(date +%s)
  cutoff=$((now - UNMATCHED_STATE_RETENTION_DAYS * 86400))
  tmp=$(mktemp -p "$STATE_DIR")

  while IFS=$'\t' read -r hash ts file_path || [ -n "${hash:-}" ]; do
    [ -n "${hash:-}" ] || continue
    [ -n "${file_path:-}" ] || continue
    [ -e "$file_path" ] || continue

    epoch=$(timestamp_to_epoch "${ts:-}")
    if [ "$epoch" -gt 0 ] && [ "$epoch" -lt "$cutoff" ]; then
      continue
    fi

    printf "%s\t%s\t%s\n" "$hash" "$ts" "$file_path" >> "$tmp"
  done < "$UNMATCHED_NOTIFIED_FILE"

  mv "$tmp" "$UNMATCHED_NOTIFIED_FILE"
}

gc_processed_state() {
  local now cutoff tmp hash failed_url file_path ts epoch
  now=$(date +%s)
  cutoff=$((now - PROCESSED_STATE_RETENTION_DAYS * 86400))
  tmp=$(mktemp -p "$STATE_DIR")

  while IFS=$'\t' read -r hash failed_url file_path ts || [ -n "${hash:-}" ]; do
    [ -n "${hash:-}" ] || continue
    [ -n "${file_path:-}" ] || continue
    [ -e "$file_path" ] || continue

    epoch=$(timestamp_to_epoch "${ts:-}")
    if [ "$epoch" -gt 0 ] && [ "$epoch" -lt "$cutoff" ]; then
      continue
    fi

    printf "%s\t%s\t%s\t%s\n" "$hash" "$failed_url" "$file_path" "$ts" >> "$tmp"
  done < "$PROCESSED_FILE"

  mv "$tmp" "$PROCESSED_FILE"
}

gc_notify_state() {
  local now cutoff tmp
  now=$(date +%s)
  cutoff=$((now - NOTIFY_STATE_RETENTION_SEC))
  tmp=$(mktemp -p "$STATE_DIR")

  awk -F '\t' -v cutoff="$cutoff" '
    NF >= 2 && $2 ~ /^[0-9]+$/ && $2 >= cutoff { print $1 "\t" $2 }
  ' "$NOTIFY_STATE_FILE" > "$tmp"

  mv "$tmp" "$NOTIFY_STATE_FILE"
}

gc_state_files() {
  gc_unmatched_notified_state
  gc_processed_state
  gc_notify_state
}

normalize_url() {
  local url="$1"
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%#*}"
  url="${url%/}"
  printf "%s" "$url"
}

normalize_url_loose() {
  local url
  url=$(normalize_url "$1")
  url="${url%%\?*}"
  printf "%s" "$url"
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

should_notify_key() {
  local key="$1"
  local now previous tmp
  now=$(date +%s)
  previous=$(awk -F '\t' -v key="$key" '$1 == key { print $2 }' "$NOTIFY_STATE_FILE" | tail -n 1)
  previous="${previous:-0}"

  if (( now - previous < NOTIFY_DEDUP_WINDOW_SEC )); then
    return 1
  fi

  tmp=$(mktemp -p "$STATE_DIR")
  awk -F '\t' -v key="$key" '$1 != key { print }' "$NOTIFY_STATE_FILE" > "$tmp"
  printf "%s\t%s\n" "$key" "$now" >> "$tmp"
  mv "$tmp" "$NOTIFY_STATE_FILE"
  return 0
}

is_unmatched_notified() {
  local file_hash="$1"
  awk -F '\t' -v hash="$file_hash" '$1 == hash { found = 1 } END { exit(found ? 0 : 1) }' "$UNMATCHED_NOTIFIED_FILE"
}

record_unmatched_notified() {
  local file_hash="$1"
  local file_path="$2"
  printf "%s\t%s\t%s\n" "$file_hash" "$(date -Iseconds)" "$file_path" >> "$UNMATCHED_NOTIFIED_FILE"
}

remove_queue_url() {
  local target="$1"
  local tmp rc
  rc=0

  if (( QUEUE_LOCK_ENABLED )); then
    flock -x 10
  fi

  tmp=$(mktemp -p "$STATE_DIR")

  awk -v target="$target" '
    BEGIN { removed = 0 }
    {
      if (!removed && $0 == target) {
        removed = 1
        next
      }
      print
    }
    END {
      if (!removed) exit 1
    }
  ' "$FAILED_URL_QUEUE_FILE" > "$tmp" || rc=1

  if [ "$rc" -ne 0 ]; then
    rm -f "$tmp"
  else
    mv "$tmp" "$FAILED_URL_QUEUE_FILE" || { rm -f "$tmp"; rc=1; }
  fi

  if (( QUEUE_LOCK_ENABLED )); then
    flock -u 10
  fi

  return "$rc"
}

extract_url_candidates() {
  local file="$1"
  local snippet quote_class
  snippet=$(mktemp)
  quote_class='["'"'"']'
  head -c 2097152 "$file" > "$snippet"

  {
    grep -Eoi "<link[^>]+rel=${quote_class}canonical${quote_class}[^>]*>" "$snippet" \
      | sed -En "s/.*href=${quote_class}([^\"']+)${quote_class}.*/\\1/ip"
    grep -Eoi "<meta[^>]+property=${quote_class}og:url${quote_class}[^>]*>" "$snippet" \
      | sed -En "s/.*content=${quote_class}([^\"']+)${quote_class}.*/\\1/ip"
    grep -Eoi "<meta[^>]+name=${quote_class}twitter:url${quote_class}[^>]*>" "$snippet" \
      | sed -En "s/.*content=${quote_class}([^\"']+)${quote_class}.*/\\1/ip"
    grep -Eom200 "https?://[^\"' <>)]+" "$snippet"
  } | sed -E 's/&amp;/\&/g' | grep -E '^https?://' | sort -u

  rm -f "$snippet"
}

find_matching_failed_url() {
  local file="$1"
  local queue_url queue_norm queue_loose
  local candidate candidate_norm candidate_loose
  local -a queue_urls candidates

  if (( QUEUE_LOCK_ENABLED )); then
    flock -s 10
  fi
  mapfile -t queue_urls < "$FAILED_URL_QUEUE_FILE"
  if (( QUEUE_LOCK_ENABLED )); then
    flock -u 10
  fi
  [ "${#queue_urls[@]}" -gt 0 ] || return 1

  mapfile -t candidates < <(extract_url_candidates "$file")
  [ "${#candidates[@]}" -gt 0 ] || return 1

  for queue_url in "${queue_urls[@]}"; do
    queue_norm=$(normalize_url "$queue_url")
    queue_loose=$(normalize_url_loose "$queue_url")
    for candidate in "${candidates[@]}"; do
      candidate_norm=$(normalize_url "$candidate")
      candidate_loose=$(normalize_url_loose "$candidate")
      if [ "$candidate_norm" = "$queue_norm" ] || [ "$candidate_loose" = "$queue_loose" ]; then
        printf "%s" "$queue_url"
        return 0
      fi
    done
  done

  return 1
}

upload_singlefile_archive() {
  local file="$1"
  local url="$2"
  local endpoint response_file http_code curl_exit
  endpoint="${KARAKEEP_BASE_URL%/}/api/v1/bookmarks/singlefile?ifexists=overwrite"
  response_file=$(mktemp)

  http_code=$(curl -sS -o "$response_file" -w "%{http_code}" --max-time 240 \
    -H "Authorization: Bearer ${API_KEY}" \
    --form-string "url=${url}" \
    -F "file=@${file}" \
    "$endpoint")
  curl_exit=$?

  if [ "$curl_exit" -ne 0 ]; then
    echo "Upload curl error (exit=${curl_exit}, http=${http_code:-000}): $url"
    rm -f "$response_file"
    return 1
  fi

  if ! [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
    echo "Upload failed with invalid HTTP code '${http_code}': $url"
    rm -f "$response_file"
    return 1
  fi

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "Upload failed with HTTP ${http_code}: $url"
    echo "Response: $(head -c 300 "$response_file" | tr '\n' ' ')"
    rm -f "$response_file"
    return 1
  fi

  rm -f "$response_file"
  return 0
}

process_file() {
  local file="$1"
  local file_hash failed_url short_url notify_key message
  file_hash=$(sha256sum "$file" | cut -d ' ' -f 1)

  if grep -Fq "${file_hash}" "$PROCESSED_FILE"; then
    return 0
  fi

  failed_url=$(find_matching_failed_url "$file" || true)
  if [ -z "$failed_url" ]; then
    if is_unmatched_notified "$file_hash"; then
      echo "Unmatched fallback already notified once: $file"
      return 0
    fi

    message=$(printf "자동 재연결 보류: %s\n원인: 실패 URL 매칭 불가\n확인 경로: %s" "$(basename "$file")" "$FALLBACK_DIR")
    if send_notification_strict "Karakeep" "$message" 0; then
      record_unmatched_notified "$file_hash" "$file"
    else
      echo "Unmatched fallback notification failed; will retry later: $file"
    fi
    echo "No matching failed URL for file: $file"
    return 0
  fi

  if upload_singlefile_archive "$file" "$failed_url"; then
    remove_queue_url "$failed_url" || true
    printf "%s\t%s\t%s\t%s\n" "$file_hash" "$failed_url" "$file" "$(date -Iseconds)" >> "$PROCESSED_FILE"
    short_url=$(shorten_url "$failed_url")
    message=$(printf "자동 재연결 완료: %s\n파일: %s" "$short_url" "$(basename "$file")")
    send_notification "Karakeep" "$message" 0
    echo "Auto relink succeeded: $failed_url <- $file"
    return 0
  fi

  notify_key="upload-failed:$(normalize_url_loose "$failed_url")"
  if should_notify_key "$notify_key"; then
    message=$(printf "자동 재연결 실패: %s\n파일: %s\njournalctl -u karakeep-fallback-sync 확인 필요" "$(shorten_url "$failed_url")" "$(basename "$file")")
    send_notification "Karakeep" "$message" 0
  fi
  echo "Auto relink failed: $failed_url <- $file"
  return 1
}

if [ ! -d "$FALLBACK_DIR" ]; then
  echo "Fallback directory does not exist: $FALLBACK_DIR"
  exit 0
fi

gc_state_files

if ! [ -s "$FAILED_URL_QUEUE_FILE" ]; then
  echo "No pending failed URLs in queue"
  exit 0
fi

mapfile -t fallback_files < <(
  find "$FALLBACK_DIR" -maxdepth 1 -type f \( -name "*.html" -o -name "*.htm" -o -name "*.xhtml" \) \
    -printf '%T@ %p\n' | sort -n | sed -E 's/^[0-9.]+ //'
)

if [ "${#fallback_files[@]}" -eq 0 ]; then
  echo "No fallback HTML files found"
  exit 0
fi

consecutive_failures=0
for file in "${fallback_files[@]}"; do
  if process_file "$file"; then
    consecutive_failures=0
    continue
  fi

  consecutive_failures=$((consecutive_failures + 1))
  echo "Fallback sync failure count: ${consecutive_failures}/${MAX_CONSECUTIVE_FAILURES}"
  if [ "$consecutive_failures" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
    echo "Stopping batch after ${consecutive_failures} consecutive failures"
    break
  fi
done
