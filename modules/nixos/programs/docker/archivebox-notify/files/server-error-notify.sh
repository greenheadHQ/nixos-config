#!/usr/bin/env bash
# writeShellApplication provides set -euo pipefail

: "${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
: "${SERVICE_LIB:?SERVICE_LIB is required}"
: "${STATE_DIR:?STATE_DIR is required}"
: "${TARGET_UNIT:?TARGET_UNIT is required}"
: "${DEDUPE_WINDOW_SEC:?DEDUPE_WINDOW_SEC is required}"

# shellcheck source=/dev/null
source "$PUSHOVER_CRED_FILE"
# shellcheck source=/dev/null
source "$SERVICE_LIB"

mkdir -p "$STATE_DIR/state"

LAST_FILE="$STATE_DIR/state/server-error-last"
NOW=$(date +%s)

# 최근 실패 요약 추출
EXCERPT=$(journalctl -u "$TARGET_UNIT" -n 80 --no-pager 2>/dev/null | tail -n 12 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-700)

if [ -z "$EXCERPT" ]; then
  EXCERPT="최근 로그를 가져오지 못했어요."
fi

HASH=$(printf '%s' "$EXCERPT" | sha256sum | awk '{print $1}')

if [ -f "$LAST_FILE" ]; then
  PREV_HASH=$(awk '{print $1}' "$LAST_FILE" 2>/dev/null || echo "")
  PREV_TS=$(awk '{print $2}' "$LAST_FILE" 2>/dev/null || echo "0")

  if [ "$PREV_HASH" = "$HASH" ] && [ $((NOW - PREV_TS)) -lt "$DEDUPE_WINDOW_SEC" ]; then
    echo "ArchiveBox server error deduped (same signature within window)"
    exit 0
  fi
fi

printf -v MESSAGE '%s\n%s\n%s\n%s' \
  "ArchiveBox 서버에 오류가 생겼어요." \
  "서비스: ${TARGET_UNIT}" \
  "최근 로그: ${EXCERPT}" \
  "확인 명령: journalctl -u ${TARGET_UNIT} -n 120 --no-pager"
if declare -F send_notification_strict > /dev/null 2>&1; then
  send_notification_strict "ArchiveBox 서버 오류" "$MESSAGE" 1
else
  send_notification "ArchiveBox 서버 오류" "$MESSAGE" 1
fi

echo "$HASH $NOW" > "$LAST_FILE"

echo "ArchiveBox server error notification sent"
