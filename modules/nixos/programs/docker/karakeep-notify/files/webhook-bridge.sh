#!/bin/bash
# Karakeep 웹훅 → Pushover 브리지
# socat EXEC: 핸들러로 실행됨 (stdin=HTTP 요청, stdout=HTTP 응답)
set -uo pipefail

# HTTP 헤더 읽기 (빈 줄까지 스킵)
content_length=0
while IFS= read -r line; do
  line="${line%%$'\r'}"
  [ -z "$line" ] && break
  if [[ "${line,,}" == content-length:* ]]; then
    content_length="${line#*:}"
    content_length="${content_length// /}"
  fi
done

# HTTP body 읽기
body=""
if [ "$content_length" -gt 0 ] 2>/dev/null; then
  body=$(head -c "$content_length")
fi

# JSON 파싱
operation=$(printf '%s' "$body" | jq -r '.operation // empty' 2>/dev/null)
url=$(printf '%s' "$body" | jq -r '.url // empty' 2>/dev/null)

# crawled 이벤트만 처리
if [ "$operation" = "crawled" ] && [ -n "$url" ]; then
  # 프로토콜 제거 (도메인+경로 유지, 쿼리스트링/트레일링 슬래시 제거)
  short_url=$(printf '%s' "$url" | sed -E 's|^https?://||; s|\?.*||; s|/$||')
  # shellcheck source=/dev/null
  source "$PUSHOVER_CRED_FILE"
  # shellcheck source=/dev/null
  source "$SERVICE_LIB"
  send_notification "Karakeep" "아카이브 완료: ${short_url}" 0 || true
fi

# HTTP 200 응답
printf "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
