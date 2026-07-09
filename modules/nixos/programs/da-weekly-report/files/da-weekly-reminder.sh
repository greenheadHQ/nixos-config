#!/usr/bin/env bash
# DA 주간 리포트 수집 전날 사전 리마인더.
set -euo pipefail

USERNAME_FOR_PATHS="${DA_WEEKLY_USERNAME:-${USER:-$(id -un)}}"
HOME="${HOME:-/home/$USERNAME_FOR_PATHS}"

PUSHOVER_HELPER="$HOME/.local/lib/pushover.sh"
PUSHOVER_CRED="$HOME/.config/pushover/share"
PUSHOVER_TITLE="DA weekly reminder"
PUSHOVER_BODY="내일 오전 DA 주간 리포트 수집. MacBook을 깨워두면 완전한 리포트가 됩니다."

if [ ! -r "$PUSHOVER_HELPER" ]; then
  echo "WARN: Pushover helper not readable: $PUSHOVER_HELPER" >&2
  exit 0
fi
if [ ! -r "$PUSHOVER_CRED" ]; then
  echo "WARN: Pushover credential not readable: $PUSHOVER_CRED" >&2
  exit 0
fi

# shellcheck disable=SC1090
source "$PUSHOVER_HELPER"
if ! declare -F pushover_send >/dev/null 2>&1; then
  echo "WARN: pushover_send function not found" >&2
  exit 0
fi

set +e
pushover_send "$PUSHOVER_CRED" "$PUSHOVER_TITLE" "$PUSHOVER_BODY" 0
PUSH_STATUS=$?
set -e
if [ "$PUSH_STATUS" -ne 0 ]; then
  echo "WARN: pushover_send exited $PUSH_STATUS" >&2
fi

exit 0
