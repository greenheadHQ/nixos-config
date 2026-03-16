#!/usr/bin/env bash
# Claude Code SessionStart Hook - Status bar icons 초기화/복원
# stdin: JSON (session_id, transcript_path, source 등)
# stdout: JSON (hookSpecificOutput with additionalContext)

set -euo pipefail

# jq 필수 — 없으면 graceful skip
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# stdin JSON 읽기
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

if [ -z "$INPUT" ]; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null) || true

# session_id가 비어있으면 skip
if [ -z "$SESSION_ID" ]; then
  exit 0
fi

STATE_DIR="$HOME/.claude/status-icons"
MEMO_DIR="$HOME/.claude/memos"
STATE_FILE="$STATE_DIR/$SESSION_ID.json"
MEMO_FILE="$MEMO_DIR/$SESSION_ID.md"

case "$SOURCE" in
  startup|clear)
    mkdir -p "$STATE_DIR" "$MEMO_DIR"
    touch "$MEMO_FILE"

    # 초기 상태 파일 생성 (빈 객체 — 아이콘은 스킬 호출 시 추가)
    echo '{}' > "$STATE_FILE"

    # 30일 초과 파일 정리
    find "$STATE_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    find "$MEMO_DIR" -name "*.md" -mtime +30 -delete 2>/dev/null || true

    CONTEXT="Status bar icons 초기화됨.
상태 파일: $STATE_FILE
메모: $MEMO_FILE
링크 설정: /managing-status-icons 스킬로 Jira, Slack, Figma 링크를 추가할 수 있습니다."
    ;;

  resume|compact)
    ACTIVE_ICONS="없음"
    if [ -f "$STATE_FILE" ]; then
      ACTIVE_ICONS=$(jq -r 'keys | join(", ")' "$STATE_FILE" 2>/dev/null) || ACTIVE_ICONS="없음"
    fi

    CONTEXT="Status icons 복원됨.
상태 파일: $STATE_FILE
메모: $MEMO_FILE
활성 아이콘: $ACTIVE_ICONS"
    ;;

  *)
    # 알 수 없는 source — skip
    exit 0
    ;;
esac

# additionalContext 출력
jq -n --arg ctx "$CONTEXT" \
  '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'

exit 0
