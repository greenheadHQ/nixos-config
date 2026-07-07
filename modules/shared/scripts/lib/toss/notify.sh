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

  [ -r "$helper" ] || return 0
  [ -r "$cred_file" ] || return 0

  # shellcheck source=/dev/null
  source "$helper" 2>/dev/null || return 0

  local message
  if [ -n "$account_seq" ]; then
    message="$method $path completed with HTTP $http_status (account $account_seq)"
  else
    message="$method $path completed with HTTP $http_status"
  fi

  pushover_send "$cred_file" "Toss safeguarded API success" "$message" 0 || true
}
