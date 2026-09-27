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

# URL 동일성: scheme(http/https), `#` 뒤, 경로 끝 `/` 하나의 차이만 무시한다. 쿼리는 끝 `/`까지
# 정확히 비교한다. 쿼리 값 끝의 `/`를 지우면 서로 다른 URL이 같아져 다른 북마크를 덮어쓴다 (#1495).
normalize_url() {
  local url="$1"
  local path query=""
  url="${url#http://}"
  url="${url#https://}"
  url="${url%%#*}"
  path="${url%%\?*}"
  if [ "$path" != "$url" ]; then
    query="${url:${#path}}"
  fi
  path="${path%/}"
  printf "%s%s" "$path" "$query"
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

is_processed() {
  local file_hash="$1"
  awk -F '\t' -v hash="$file_hash" '$1 == hash { found = 1 } END { exit(found ? 0 : 1) }' "$PROCESSED_FILE"
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

# SingleFile 저장 주석(`Page saved with SingleFile` 블록, 보통 <html> 직후)의 `url:` 줄만 읽는다.
# 주석 밖 본문이나 마커 없는 주석의 `url:` 텍스트는 원문 식별자가 아니다. `url:` 줄이 있는 첫
# 저장 주석에서 멈춰 문서 중간의 가짜 저장 주석은 읽지 않는다. 줄을 `<!--`로 한 번에 나누고
# 블록 본문을 쌓지 않아 주석이 많은 긴 줄에서도 입력 크기에 비례한 시간만 쓰며, 비교 대상이
# ASCII라 바이트 단위(LC_ALL=C)로 처리한다.
extract_singlefile_saved_url() {
  LC_ALL=C awk '
    # seg는 주석 안 한 줄의 조각이다. 줄 머리 조각만 `url:`로 시작할 수 있다.
    function scan(seg,   url) {
      if (index(seg, "Page saved with SingleFile")) has_marker = 1
      if (seg !~ /^[ \t]*url:/) return
      url = seg
      sub(/^[ \t]*url:[ \t]*/, "", url)
      sub(/[ \t\r]+$/, "", url)
      if (url != "") urls = urls url "\n"
    }
    {
      n = split($0, parts, "<!--")
      for (i = 1; i <= n; i++) {
        seg = parts[i]
        if (i > 1) {
          if (in_comment) {
            # 주석 안의 `<!--`는 여는 표시가 아니라 본문이다.
            seg = "<!--" seg
          } else {
            in_comment = 1
            has_marker = 0
            urls = ""
          }
        }
        if (!in_comment) continue
        close_pos = index(seg, "-->")
        if (close_pos == 0) {
          scan(seg)
          continue
        }
        scan(substr(seg, 1, close_pos - 1))
        in_comment = 0
        # url 줄이 없는 저장 주석이면 뒤의 실제 저장 주석을 계속 찾는다.
        if (has_marker && urls != "") {
          printf "%s", urls
          exit
        }
      }
    }
  ' "$1"
}

tag_identifier_source() {
  awk -v source="$1" '{ print source "\t" $0 }'
}

# 평탄화한 snippet에서 canonical link와 og:url·twitter:url meta의 URL을 "출처<TAB>URL"로 낸다.
# 태그는 `<link`·`<meta` 뒤가 공백이나 `/`인 곳부터 첫 `>`까지다. 속성은 HTML 문법대로 읽는다:
# 이름과 키워드의 대소문자 무시, `=` 앞뒤 공백, 큰·작은따옴표와 따옴표 없는 값, 순서 무관,
# 중복 속성은 첫 값, 값 앞뒤 공백 제거. rel은 공백으로 나눈 토큰 집합이라 canonical 토큰이
# 있으면 된다. 따옴표 안의 `>`는 지원하지 않는다. 값이 `>`에서 잘려 닫는 따옴표가 없으면
# 그 속성부터 버리므로 식별자가 빠져 보류 쪽으로 떨어진다.
extract_identifier_tags() {
  LC_ALL=C awk -v q="'" '
    function parse_attrs(s,   name, value, quote, close_pos) {
      split("", attrs)
      while (1) {
        sub(/^[[:space:]\/]+/, "", s)
        if (!match(s, /^[^[:space:]\/>=]+/)) return
        name = tolower(substr(s, 1, RLENGTH))
        s = substr(s, RLENGTH + 1)
        value = ""
        if (match(s, /^[[:space:]]*=[[:space:]]*/)) {
          s = substr(s, RLENGTH + 1)
          quote = substr(s, 1, 1)
          if (quote == "\"" || quote == q) {
            close_pos = index(substr(s, 2), quote)
            if (close_pos == 0) return
            value = substr(s, 2, close_pos - 1)
            s = substr(s, close_pos + 2)
          } else if (match(s, /^[^[:space:]>]+/)) {
            value = substr(s, 1, RLENGTH)
            s = substr(s, RLENGTH + 1)
          }
        }
        if (!(name in attrs)) attrs[name] = value
      }
    }
    function trim(v) {
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      return v
    }
    {
      n = split($0, parts, "<")
      for (i = 2; i <= n; i++) {
        seg = parts[i]
        tag = tolower(substr(seg, 1, 4))
        if (tag != "link" && tag != "meta") continue
        if (substr(seg, 5, 1) !~ /^[[:space:]\/]$/) continue
        close_pos = index(seg, ">")
        if (close_pos == 0) continue
        parse_attrs(substr(seg, 5, close_pos - 5))
        if (!(tag == "link" ? ("href" in attrs) : ("content" in attrs))) continue
        if (tag == "link") {
          rel = " " tolower(attrs["rel"]) " "
          gsub(/[[:space:]]+/, " ", rel)
          if (index(rel, " canonical ")) print "canonical\t" trim(attrs["href"])
        } else {
          if (tolower(trim(attrs["property"])) == "og:url") print "og:url\t" trim(attrs["content"])
          if (tolower(trim(attrs["name"])) == "twitter:url") print "twitter:url\t" trim(attrs["content"])
        }
      }
    }
  ' "$1"
}

# 원문 식별자만 "출처<TAB>URL"로 출력한다. 본문의 일반 링크는 관련 글일 수 있어
# overwrite 대상 판정 근거에서 뺀다 (#1388). 한 단계라도 실패하면 일부 식별자만으로
# 판정하지 않도록 전체를 실패로 돌려준다.
# 태그 속성은 여러 줄에 걸칠 수 있어 태그 파서는 CR·LF를 공백으로 바꾼 사본을 읽는다.
# 태그는 첫 `>`에서 끝나므로 평탄화해도 다른 태그와 섞이지 않는다. 저장 주석 파서는 줄 머리의
# `url:`을 봐야 하므로 원본을 쓴다.
extract_url_candidates() {
  local file="$1"
  local snippet flat_snippet candidates rc=0
  snippet=$(mktemp) || return 1
  if ! flat_snippet=$(mktemp); then
    rm -f "$snippet"
    return 1
  fi

  candidates=$(
    head -c 2097152 "$file" > "$snippet" &&
      tr '\r\n' '  ' < "$snippet" > "$flat_snippet" &&
      {
        extract_singlefile_saved_url "$snippet" | tag_identifier_source singlefile &&
          extract_identifier_tags "$flat_snippet"
      } | sed -E 's/&amp;/\&/g' | awk -F '\t' '$2 ~ /^https?:\/\//' | sort -u
  ) || rc=$?

  rm -f "$snippet" "$flat_snippet"
  [ "$rc" -eq 0 ] || return 1
  if [ -n "$candidates" ]; then
    printf '%s\n' "$candidates"
  fi
}

list_contains() {
  local needle="$1"
  shift
  local value
  for value in "$@"; do
    if [ "$value" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# 원문 식별자와 실패 URL 큐를 대조한다. 식별자와 엄격 정규화(normalize_url)로 같은 큐 URL이
# 정확히 하나일 때만 고른다. 쿼리만 다른 URL은 다른 글일 수 있어 일치로 보지 않고, 식별자
# 출처 사이에는 우선순위를 두지 않는다 (#1388).
# 출력 첫 줄은 판정(matched/no-identifier/no-match/ambiguous)이다. 이어서 추출한 식별자를
# "identifier<TAB>출처<TAB>URL"로, 일치한 큐 URL을 "queue<TAB>URL<TAB>출처들"로 낸다.
# 식별자 추출이나 큐 읽기가 실패하면 판정 없이 실패로 돌려준다.
find_matching_failed_url() {
  local file="$1"
  local candidates identifier_source identifier_url queue_url queue_norm sources i queue_read_rc=0
  local -a identifier_sources=() identifier_urls=() identifier_norms=() queue_urls=()
  local -a matches=() match_sources=()

  candidates=$(extract_url_candidates "$file") || return 1
  if [ -z "$candidates" ]; then
    echo "no-identifier"
    return 0
  fi
  while IFS=$'\t' read -r identifier_source identifier_url; do
    identifier_sources+=("$identifier_source")
    identifier_urls+=("$identifier_url")
    identifier_norms+=("$(normalize_url "$identifier_url")")
  done <<< "$candidates"

  if (( QUEUE_LOCK_ENABLED )); then
    flock -s 10 || return 1
  fi
  mapfile -t queue_urls < "$FAILED_URL_QUEUE_FILE" || queue_read_rc=1
  if (( QUEUE_LOCK_ENABLED )); then
    flock -u 10
  fi
  [ "$queue_read_rc" -eq 0 ] || return 1

  for queue_url in "${queue_urls[@]}"; do
    [ -n "$queue_url" ] || continue
    # 같은 URL이 큐에 여러 줄 있어도 한 북마크다.
    if list_contains "$queue_url" "${matches[@]}"; then
      continue
    fi
    queue_norm=$(normalize_url "$queue_url")
    sources=""
    for i in "${!identifier_norms[@]}"; do
      [ "${identifier_norms[$i]}" = "$queue_norm" ] || continue
      case ",${sources}," in
        *",${identifier_sources[$i]},"*) ;;
        *) sources="${sources:+${sources},}${identifier_sources[$i]}" ;;
      esac
    done
    if [ -n "$sources" ]; then
      matches+=("$queue_url")
      match_sources+=("$sources")
    fi
  done

  case "${#matches[@]}" in
    0) echo "no-match" ;;
    1) echo "matched" ;;
    *) echo "ambiguous" ;;
  esac
  for i in "${!identifier_urls[@]}"; do
    printf 'identifier\t%s\t%s\n' "${identifier_sources[$i]}" "${identifier_urls[$i]}"
  done
  for i in "${!matches[@]}"; do
    printf 'queue\t%s\t%s\n' "${matches[$i]}" "${match_sources[$i]}"
  done
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

# 판정 실패는 보류 알림 기록에 남기지 않아 다음 실행에서 다시 판정하고, 알림은 키별 시간 창으로만 억제한다.
report_match_error() {
  local file="$1"
  local notify_key="$2"
  local message
  echo "Auto relink match error: $file"
  if should_notify_key "$notify_key"; then
    message=$(printf "자동 재연결 보류: %s\n원인: 판정 실패\njournalctl -u karakeep-fallback-sync 확인 필요" "$(basename "$file")")
    send_notification "Karakeep" "$message" 0
  fi
}

process_file() {
  local file="$1"
  local file_hash match_result match_status queue_line hold_reason failed_url match_sources
  local short_url notify_key message path_hash
  if ! file_hash=$(sha256sum "$file" | cut -d ' ' -f 1) || [ -z "$file_hash" ]; then
    # 해시가 없으면 처리·보류 기록과 대조할 수 없다. 알림 키는 파일 경로에서 만든다.
    path_hash=$(printf '%s' "$file" | sha256sum | cut -d ' ' -f 1)
    report_match_error "$file" "match-error:path:${path_hash}"
    return 1
  fi

  if is_processed "$file_hash"; then
    return 0
  fi

  match_result=$(find_matching_failed_url "$file") || match_result=""
  match_status="${match_result%%$'\n'*}"
  failed_url=""
  match_sources=""
  if [ "$match_status" = "matched" ]; then
    queue_line=$(printf '%s\n' "$match_result" | awk -F '\t' '$1 == "queue" { print; exit }')
    IFS=$'\t' read -r _ failed_url match_sources <<< "$queue_line"
  fi
  case "$match_status" in
    matched) [ -n "$failed_url" ] || match_status="error" ;;
    no-identifier | no-match | ambiguous) ;;
    *) match_status="error" ;;
  esac

  if [ "$match_status" = "error" ]; then
    report_match_error "$file" "match-error:${file_hash}"
    return 1
  fi

  if [ "$match_status" != "matched" ]; then
    # 보류: 업로드·큐 제거·processed 기록 없이 파일과 큐를 그대로 둔다.
    if is_unmatched_notified "$file_hash"; then
      echo "Unmatched fallback already notified once (${match_status}): $file"
      return 0
    fi

    case "$match_status" in
      no-identifier) hold_reason="원문 식별자 없음" ;;
      ambiguous) hold_reason="실패 URL 후보 여럿" ;;
      *) hold_reason="실패 URL 일치 없음" ;;
    esac
    message=$(printf "자동 재연결 보류: %s\n원인: %s\n확인 경로: %s" "$(basename "$file")" "$hold_reason" "$FALLBACK_DIR")
    if send_notification_strict "Karakeep" "$message" 0; then
      record_unmatched_notified "$file_hash" "$file"
    else
      echo "Unmatched fallback notification failed; will retry later: $file"
    fi
    echo "Auto relink held (${match_status}): $file"
    printf '%s\n' "$match_result" | awk -F '\t' '
      $1 == "identifier" { print "  identifier " $2 ": " $3 }
      $1 == "queue" { print "  candidate: " $2 " (" $3 ")" }
    ' || true
    return 0
  fi

  if upload_singlefile_archive "$file" "$failed_url"; then
    remove_queue_url "$failed_url" || true
    printf "%s\t%s\t%s\t%s\n" "$file_hash" "$failed_url" "$file" "$(date -Iseconds)" >> "$PROCESSED_FILE"
    short_url=$(shorten_url "$failed_url")
    message=$(printf "자동 재연결 완료: %s\n파일: %s" "$short_url" "$(basename "$file")")
    send_notification "Karakeep" "$message" 0
    echo "Auto relink succeeded: $failed_url <- $file (via ${match_sources})"
    return 0
  fi

  notify_key="upload-failed:$(normalize_url "$failed_url")"
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
