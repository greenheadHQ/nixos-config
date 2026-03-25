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

mkdir -p "$STATE_DIR" "$MEMO_DIR"

case "$SOURCE" in
  startup)
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

  clear|resume|compact)
    # /clear, /branch, /fork 등으로 session_id가 변경되면
    # 이전 세션의 상태 파일이 새 session_id 경로에 없다.
    # 가장 최근 수정된 상태 파일에서 복사하여 아이콘 보존.
    #
    # === Change Intent Record ===
    # v4 추가: /clear가 새 transcript(= 새 session_id)를 생성하는 것을
    # 디버그 로그로 확인. 기존 clear|resume|compact 분기는 STATE_FILE 존재를
    # 전제했으나, session_id 변경 시 STATE_FILE 미존재.
    # ls -t로 가장 최근 파일을 찾아 복사하는 방식 채택.
    # trade-off: 동시 세션에서 다른 세션의 아이콘이 복원될 수 있으나,
    #           /clear 직후는 대부분 단일 세션이므로 실용적.
    if [ ! -f "$STATE_FILE" ]; then
      LATEST=$(ls -t "$STATE_DIR"/*.json 2>/dev/null | head -1 || true)
      if [ -n "$LATEST" ] && [ -f "$LATEST" ]; then
        # Memo 파일: 원본의 복사본 생성 (참조 충돌 방지)
        OLD_MEMO=$(jq -r '.memo.path // empty' "$LATEST" 2>/dev/null)
        if [ -n "$OLD_MEMO" ] && [ -f "$OLD_MEMO" ]; then
          cp "$OLD_MEMO" "$MEMO_FILE"
        else
          touch "$MEMO_FILE"
        fi
        # icons JSON 복사 + memo 경로를 새 세션 파일로 갱신
        jq --arg new_memo "$MEMO_FILE" \
          'if .memo then .memo.path = $new_memo else . end' \
          "$LATEST" > "$STATE_FILE"
      else
        echo '{}' > "$STATE_FILE"
        touch "$MEMO_FILE"
      fi
    fi

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
