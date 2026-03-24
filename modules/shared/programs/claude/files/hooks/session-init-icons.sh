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
    #
    # === Change Intent Record ===
    # v1 (PR #263): SessionStart hook에서 AskUserQuestion으로 Jira/Slack/Figma 링크를
    #    proactive하게 질문 + Memo 아이콘 자동 등록. 매 세션마다 링크를 물어봄.
    #    AskUserQuestion 호출 방식만 6회 시행착오 (3회개별→1회일괄→탭UI 등).
    # v2 (d65e7d0): 링크 불필요한 세션이 대다수라 매번 묻는 것이 방해됨.
    #    AskUserQuestion 지시 제거, /set-icons 스킬 호출 시에만 링크 설정.
    #    단, Memo는 항상 유용하다고 판단하여 자동 등록 유지 → 상태바에 Memo 노출.
    # v3 (d3bbb3c, 이번): Memo도 불필요 시 상태바를 차지하므로 자동 등록 제거.
    #    빈 객체({})로 시작, 모든 아이콘을 스킬 호출 시에만 등록.
    #    trade-off: 메모를 쓰려면 스킬을 먼저 호출해야 하지만,
    #              깨끗한 상태바가 대다수 세션에서 더 나은 UX.
    echo '{}' > "$STATE_FILE"

    # 30일 초과 파일 정리
    find "$STATE_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    find "$MEMO_DIR" -name "*.md" -mtime +30 -delete 2>/dev/null || true

    CONTEXT="Status bar icons 초기화됨.
상태 파일: $STATE_FILE
메모: $MEMO_FILE
링크 설정: /set-icons 스킬로 Jira, Slack, Figma 링크를 추가할 수 있습니다."
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
