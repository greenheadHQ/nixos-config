#!/usr/bin/env bash
# DA 주간 리포트 수집 전날 사전 리마인더.
set -euo pipefail
umask 077

USERNAME_FOR_PATHS="${DA_WEEKLY_USERNAME:-${USER:-$(id -un)}}"
HOME="${HOME:-/home/$USERNAME_FOR_PATHS}"

PUSHOVER_HELPER="${PUSHOVER_HELPER:-$HOME/.local/lib/pushover.sh}"
PUSHOVER_SHARE_CRED="${PUSHOVER_SHARE_CRED:-$HOME/.config/pushover/share}"
PUSHOVER_TITLE="DA weekly reminder"
PUSHOVER_BODY="내일 오전 DA 주간 리포트 수집. MacBook을 깨워두면 완전한 리포트가 됩니다."
# 공통 fail-soft 전송 헬퍼 (report 파이프라인과 공유 — drift 방지 단일 소스).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "${PUSHOVER_LIB:-$SCRIPT_DIR/pushover-lib.sh}"

send_pushover_fail_soft "$PUSHOVER_HELPER" "$PUSHOVER_SHARE_CRED" "$PUSHOVER_TITLE" "$PUSHOVER_BODY" 0 || true

exit 0
