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

    # 초기 상태 파일 생성 (memo만)
    jq -n --arg path "$MEMO_FILE" \
      '{"memo":{"path":$path,"label":"Memo"}}' > "$STATE_FILE"

    # 30일 초과 파일 정리
    find "$STATE_DIR" -name "*.json" -mtime +30 -delete 2>/dev/null || true
    find "$MEMO_DIR" -name "*.md" -mtime +30 -delete 2>/dev/null || true

    CONTEXT="Status bar icons 초기화됨.
상태 파일: $STATE_FILE
메모: $MEMO_FILE

[ACTION REQUIRED] 첫 응답 시 AskUserQuestion을 1회 호출하되, questions 배열에 3개 질문을 넣어 탭 UI로 표시하세요.

AskUserQuestion 호출 형식 (options 최소 2개 필수, Other는 자동 추가됨):
  questions: [
    { header: 'Jira', question: '이 세션에서 사용할 Jira 링크가 있나요?', multiSelect: false, options: [{label: '없음', description: '나중에 /managing-status-icons로 설정'}, {label: 'URL 입력', description: 'Other에 Jira URL을 입력해주세요'}] },
    { header: 'Slack', question: '이 세션에서 사용할 Slack 링크가 있나요?', multiSelect: false, options: [{label: '없음', description: '나중에 /managing-status-icons로 설정'}, {label: 'URL 입력', description: 'Other에 Slack URL을 입력해주세요'}] },
    { header: 'Figma', question: '이 세션에서 사용할 Figma 링크가 있나요?', multiSelect: false, options: [{label: '없음', description: '나중에 /managing-status-icons로 설정'}, {label: 'URL 입력', description: 'Other에 Figma URL을 입력해주세요'}] }
  ]

사용자가 URL을 입력하면 기존 파일을 읽고 업데이트하세요.
주의: jq -n 사용 금지! 기존 memo 키가 덮어씌워집니다.
반드시 기존 파일을 입력으로 사용하세요: tmp=\$(mktemp) && jq '...' \$STATE_FILE > \$tmp && mv \$tmp \$STATE_FILE

JSON 키 구조 (label 필수):
  .jira = {\"url\": URL, \"label\": 이슈번호}    ← URL에서 [A-Z]+-[0-9]+ 추출
  .slack = {\"url\": URL, \"label\": \"Slack\"}
  .figma = {\"url\": URL, \"label\": \"Figma\"}"
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
