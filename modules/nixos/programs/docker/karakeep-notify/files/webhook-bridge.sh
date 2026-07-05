#!/usr/bin/env bash
# Karakeep 웹훅 → Pushover 브리지
# socat EXEC: 핸들러로 실행됨 (stdin=HTTP 요청, stdout=HTTP 응답)
set -uo pipefail

# HTTP 헤더 읽기 (빈 줄까지 스킵)
content_length=0
authorization=""
while IFS= read -r line; do
  line="${line%%$'\r'}"
  [ -z "$line" ] && break
  if [[ "${line,,}" == content-length:* ]]; then
    content_length="${line#*:}"
    content_length="${content_length// /}"
  elif [[ "${line,,}" == authorization:* ]]; then
    authorization=$(printf '%s' "${line#*:}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
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

notification_allowed=true
if [ -n "${WEBHOOK_TOKEN_FILE:-}" ]; then
  expected_token=$({ tr -d '\r\n' < "$WEBHOOK_TOKEN_FILE"; } 2>/dev/null || true)
  if [ -z "$expected_token" ]; then
    echo "WARN: webhook-bridge: WEBHOOK_TOKEN_FILE token unavailable (notification skipped)" >&2
    notification_allowed=false
  elif [ "$authorization" != "Bearer $expected_token" ]; then
    echo "WARN: webhook-bridge: Authorization bearer token mismatch (notification skipped)" >&2
    notification_allowed=false
  fi
fi

# crawled 이벤트만 처리
if [ "$notification_allowed" = true ] && [ "$operation" = "crawled" ] && [ -n "$url" ]; then
  # 프로토콜 제거 (도메인+경로 유지, 쿼리스트링/트레일링 슬래시 제거)
  short_url=$(printf '%s' "$url" | sed -E 's|^https?://||; s|\?.*||; s|/$||')
  # shellcheck source=/dev/null
  # source 실패 시 진단만 남기고 흐름은 유지한다 — 이 핸들러는 set -e를 쓰지 않으므로(상단
  # set -uo pipefail) 흐름이 끊기지 않지만, 조용한 실패(알림 누락)의 원인을 journald에 남겨
  # 운영 진단을 돕는다. 스크립트 말미의 HTTP 200 응답 계약을 깨지 않도록 exit하지 않는다.
  source "$PUSHOVER_CRED_FILE" || echo "WARN: webhook-bridge: source 실패 PUSHOVER_CRED_FILE=$PUSHOVER_CRED_FILE (Pushover 자격 미로딩 → 알림 누락 가능)" >&2
  # shellcheck source=/dev/null
  source "$SERVICE_LIB" || echo "WARN: webhook-bridge: source 실패 SERVICE_LIB=$SERVICE_LIB (send_notification 미가용 → 알림 누락 가능)" >&2
  send_notification "Karakeep" "아카이브 완료: ${short_url}" 0 || true
fi

# HTTP 200 응답
printf "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
