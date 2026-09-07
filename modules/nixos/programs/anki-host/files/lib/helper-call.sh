# shellcheck shell=bash
# anki-host 헬퍼 애드온 호출 공용 함수 — sync·backup 스크립트가 같은 프로토콜로 헬퍼를 부른다.
# writeShellApplication text 앞부분에 결합되어 들어간다 (source가 아니라 텍스트 결합).
#
# anki_helper_call <url> <json-payload|""> <max-time-secs>
#   결과는 전역 변수로 돌려준다:
#     HELPER_RC    curl 종료 코드 (0이 아니면 연결/전송 실패)
#     HELPER_HTTP  HTTP 상태 코드 문자열 ("000"이면 응답 없음)
#     HELPER_BODY  응답 본문 (JSON 문자열)
#   호출자는 409(busy)·200·그 외를 각자 정책대로 다룬다.
#   빈 payload는 GET, 아니면 POST(JSON).

HELPER_RC=0
HELPER_HTTP="000"
HELPER_BODY=""

anki_helper_call() {
  local url="$1" payload="$2" max_time="$3"
  local raw
  HELPER_RC=0
  if [ -n "$payload" ]; then
    raw="$(curl -sS --max-time "$max_time" -o /dev/stdout -w '\n%{http_code}' \
      -H 'Content-Type: application/json' -d "$payload" "$url" 2>&1)" || HELPER_RC=$?
  else
    raw="$(curl -sS --max-time "$max_time" -o /dev/stdout -w '\n%{http_code}' "$url" 2>&1)" || HELPER_RC=$?
  fi
  HELPER_HTTP="$(printf '%s' "$raw" | tail -n1)"
  HELPER_BODY="$(printf '%s' "$raw" | sed '$d')"
  case "$HELPER_HTTP" in
    [0-9][0-9][0-9]) ;;
    *) HELPER_HTTP="000" ;;
  esac
}

# helper_ok  — 마지막 호출이 HTTP 200이고 본문의 .ok가 true인지
helper_ok() {
  [ "$HELPER_RC" -eq 0 ] && [ "$HELPER_HTTP" = "200" ] \
    && [ "$(printf '%s' "$HELPER_BODY" | jq -r '.ok' 2>/dev/null)" = "true" ]
}

# helper_busy — 마지막 호출이 409(다른 변경 작업 진행 중)인지
helper_busy() {
  [ "$HELPER_RC" -eq 0 ] && [ "$HELPER_HTTP" = "409" ]
}

# helper_error — 마지막 호출의 오류 요약 한 줄 (본문 .error 또는 curl/HTTP 상태)
helper_error() {
  local err
  err="$(printf '%s' "$HELPER_BODY" | jq -r '.error // empty' 2>/dev/null || true)"
  if [ -n "$err" ]; then
    printf '%s' "$err"
  else
    printf 'curl exit %s http %s: %s' "$HELPER_RC" "$HELPER_HTTP" "$(printf '%s' "$HELPER_BODY" | head -c 200)"
  fi
}
