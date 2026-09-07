# shellcheck shell=bash
# anki-host 헬퍼 애드온 호출 공용 함수 — sync·backup 스크립트가 같은 프로토콜로 헬퍼를 부른다.
# writeShellApplication text 앞부분에 결합되어 들어간다 (source가 아니라 텍스트 결합).
#
# 조정 가능한 값은 모두 env로 받는다 — nixos 모듈이 constants.ankiHost(단일 소스)에서 주입하고, 같은 값으로
# 유닛 TimeoutStartSec을 계산한다. 값이 빠지면 조용히 기본값을 쓰지 않고 즉시 실패한다.
#   READY_WAIT_TRIES / READY_WAIT_SECS / READY_PROBE_TIMEOUT   헬퍼 준비 대기 (최악 = tries × (probe + wait))
#   BUSY_RETRIES / BUSY_RETRY_SECS                            409(다른 변경 작업 진행 중) 재시도 (마지막 회차 뒤에는 대기하지 않는다)
#
# anki_helper_call <url> <json-payload|""> <max-time-secs>
#   결과는 전역 변수로 돌려준다:
#     HELPER_RC    curl 종료 코드 (0이 아니면 연결/전송 실패)
#     HELPER_HTTP  HTTP 상태 코드 문자열 ("000"이면 응답 없음)
#     HELPER_BODY  응답 본문 (JSON 문자열)
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

# anki_helper_wait_ready <base-url>
#   헬퍼의 즉시 응답(/status — 메인 스레드를 타지 않는다)으로 collection_open을 기다린다.
#   재배포·재부팅 직후 타이머가 돌면 Anki가 아직 뜨는 중일 수 있다. 준비되면 0, 예산을 다 쓰면 1.
#   마지막 응답은 HELPER_* 전역에 남는다 (login.status 판정 등에 재사용).
anki_helper_wait_ready() {
  local base="$1" i
  for i in $(seq 1 "${READY_WAIT_TRIES:?}"); do
    anki_helper_call "${base}/status" "" "${READY_PROBE_TIMEOUT:?}"
    if helper_ok && [ "$(printf '%s' "$HELPER_BODY" | jq -r '.result.collection_open')" = "true" ]; then
      return 0
    fi
    [ "$i" -lt "$READY_WAIT_TRIES" ] && sleep "${READY_WAIT_SECS:?}"
  done
  return 1
}

# anki_helper_call_retry_busy <url> <json-payload> <max-time-secs>
#   변경 작업 호출. 409(busy)면 BUSY_RETRY_SECS 뒤 다시 시도하고, BUSY_RETRIES회째 busy면 그대로 돌려준다
#   (마지막 회차 뒤에는 대기하지 않는다). 호출자는 helper_busy로 "여전히 busy"를 판정한다.
anki_helper_call_retry_busy() {
  local url="$1" payload="$2" max_time="$3" i
  for i in $(seq 1 "${BUSY_RETRIES:?}"); do
    anki_helper_call "$url" "$payload" "$max_time"
    helper_busy || return 0
    [ "$i" -lt "$BUSY_RETRIES" ] && sleep "${BUSY_RETRY_SECS:?}"
  done
  return 0
}
