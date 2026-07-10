#!/usr/bin/env bash
set -euo pipefail

toss_notify_enabled() {
  local no_notify="${1:-0}"
  [ "$no_notify" != "1" ] || return 1
  [ "${TOSS_NOTIFY:-1}" != "0" ] || return 1
  return 0
}

toss_notify_cred_file() {
  printf '%s\n' "${TOSS_PUSHOVER_CRED_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pushover/share}"
}

toss_notify_warn_not_sent() {
  local reason="$1"
  echo "warning: toss safeguarded-success notification not sent ($reason); check Pushover setup" >&2
}

# 알림은 best-effort(주문 명령 자체를 nonzero로 만들지 않음)를 유지하되,
# 전송 실패/불능은 stderr 경고 + ledger notificationStatus로 관측 가능하게 한다.
# 명시적 off(--no-notify, TOSS_NOTIFY=0)는 의도된 상태이므로 경고·기록하지 않는다.
toss_notify_safeguarded_api_success() {
  local no_notify="${1:-0}"
  local method="$2"
  local path="$3"
  local account_seq="$4"
  local http_status="$5"

  toss_notify_enabled "$no_notify" || return 0

  local helper="${TOSS_PUSHOVER_HELPER:-${TOSS_SHARED_LIB_DIR:-$HOME/.local/lib}/pushover.sh}"
  local cred_file
  cred_file="$(toss_notify_cred_file)"

  if [ ! -r "$helper" ]; then
    toss_notify_warn_not_sent "pushover helper not readable: $helper"
    toss_ledger_record_notification "$method" "$path" "failed-helper-missing"
    return 0
  fi
  if [ ! -r "$cred_file" ]; then
    toss_notify_warn_not_sent "pushover credential file not readable: $cred_file"
    toss_ledger_record_notification "$method" "$path" "failed-credentials-missing"
    return 0
  fi

  # shellcheck source=/dev/null
  if ! source "$helper" 2>/dev/null; then
    toss_notify_warn_not_sent "failed to source pushover helper: $helper"
    toss_ledger_record_notification "$method" "$path" "failed-helper-source"
    return 0
  fi

  local message
  if [ -n "$account_seq" ]; then
    message="$method $path completed with HTTP $http_status (account $account_seq)"
  else
    message="$method $path completed with HTTP $http_status"
  fi

  if pushover_send "$cred_file" "Toss safeguarded API success" "$message" 0; then
    toss_ledger_record_notification "$method" "$path" "sent"
  else
    toss_notify_warn_not_sent "pushover_send failed"
    toss_ledger_record_notification "$method" "$path" "failed-send"
  fi
  return 0
}
