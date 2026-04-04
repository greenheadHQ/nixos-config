#!/usr/bin/env bash
# Claude Code SessionEnd hook: 세션 종료 시 자동 아카이빙
# stdin: JSON (session_id, cwd, transcript_path, permission_mode, hook_event_name)
#
# SessionEnd는 비차단 훅이므로 실패해도 세션 종료에 영향 없음.
# --session <id>로 PID 파일에 의존하지 않고 정확한 세션을 아카이빙.

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -z "$INPUT" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true

ARCHIVE_SCRIPT="$HOME/.claude/scripts/claude-archive.sh"
[ -f "$ARCHIVE_SCRIPT" ] || exit 0

LOG_FILE="$HOME/.claude/logs/auto-archive.log"
mkdir -p "$(dirname "$LOG_FILE")"

# session_id가 있으면 --session으로 직접 지정 (PID 파일 시점 의존성 제거)
# CWD로 cd해야 encode_path가 올바른 프로젝트 디렉토리를 찾음
if [ -n "$SESSION_ID" ] && [ -n "$CWD" ]; then
  cd "$CWD" 2>/dev/null || cd "$HOME" || exit 0
  bash "$ARCHIVE_SCRIPT" --session "$SESSION_ID" >>"$LOG_FILE" 2>&1 || true
elif [ -n "$CWD" ]; then
  cd "$CWD" 2>/dev/null || cd "$HOME" || exit 0
  bash "$ARCHIVE_SCRIPT" >>"$LOG_FILE" 2>&1 || true
fi

exit 0
