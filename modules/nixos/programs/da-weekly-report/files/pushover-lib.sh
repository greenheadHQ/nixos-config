# shellcheck shell=bash
# da-weekly-report/da-weekly-reminder 공통 Pushover fail-soft 전송 헬퍼.
# 두 entrypoint가 PUSHOVER_LIB env(store 경로, default.nix가 주입)로 source한다 —
# 실패 분류(WARN 사유)가 두 경로에서 drift하지 않도록 단일 소스로 유지한다.
# 반환: 0=성공, 1=전송 실패(재시도 의미 있음), 2=환경 결손(helper/credential 부재 — blocked).

PUSHOVER_SEND_REASON=""

send_pushover_fail_soft() {
  local helper="$1"
  local cred="$2"
  local title="$3"
  local body="$4"
  local priority="$5"
  local status
  PUSHOVER_SEND_REASON=""

  if [ ! -r "$helper" ]; then
    PUSHOVER_SEND_REASON="helper not readable: $helper"
    echo "WARN: Pushover $PUSHOVER_SEND_REASON" >&2
    return 2
  fi
  if [ ! -r "$cred" ]; then
    PUSHOVER_SEND_REASON="credential not readable: $cred"
    echo "WARN: Pushover $PUSHOVER_SEND_REASON" >&2
    return 2
  fi

  # shellcheck disable=SC1090
  if ! source "$helper"; then
    PUSHOVER_SEND_REASON="helper source failed: $helper"
    echo "WARN: Pushover $PUSHOVER_SEND_REASON" >&2
    return 2
  fi
  if ! declare -F pushover_send >/dev/null 2>&1; then
    PUSHOVER_SEND_REASON="pushover_send function not found"
    echo "WARN: $PUSHOVER_SEND_REASON" >&2
    return 2
  fi

  set +e
  pushover_send "$cred" "$title" "$body" "$priority"
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    PUSHOVER_SEND_REASON="pushover_send exited $status"
    echo "WARN: $PUSHOVER_SEND_REASON" >&2
    return 1
  fi
  return 0
}
