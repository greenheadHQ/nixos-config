#!/usr/bin/env bash
# DA 주간 리포트 수집 전날 사전 리마인더.
set -euo pipefail
umask 077

USERNAME_FOR_PATHS="${DA_WEEKLY_USERNAME:-${USER:-$(id -un)}}"
HOME="${HOME:-/home/$USERNAME_FOR_PATHS}"

PUSHOVER_HELPER="$HOME/.local/lib/pushover.sh"
PUSHOVER_CRED="$HOME/.config/pushover/share"
PUSHOVER_TITLE="DA weekly reminder"
PUSHOVER_BODY="내일 오전 DA 주간 리포트 수집. MacBook을 깨워두면 완전한 리포트가 됩니다."
PUSHOVER_SEND_REASON=""

send_pushover_fail_soft() {
  local helper="$1"
  local cred="$2"
  local title="$3"
  local body="$4"
  local priority="$5"
  local status
  PUSHOVER_SEND_REASON=""

  # da-weekly-report/reminder는 별도 writeShellApplication 산출물이라 공통
  # store lib wiring 대신 entrypoint별 작은 fail-soft wrapper를 둔다.
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

send_pushover_fail_soft "$PUSHOVER_HELPER" "$PUSHOVER_CRED" "$PUSHOVER_TITLE" "$PUSHOVER_BODY" 0 || true

exit 0
