#!/usr/bin/env bash
# Claude Code PreToolUse Hook - AskUserQuestion Pushover 알림
# Claude가 사용자에게 질문할 때 Pushover 알림을 보냅니다.
#
# [중요] PreToolUse hook의 stdout은 tool call을 수정/차단할 수 있으므로,
# 모든 외부 명령 출력을 반드시 /dev/null로 리다이렉트해야 합니다.
# Stop hook과 달리 stdout 오염이 Claude 동작에 직접 영향을 줍니다.

# jq 미설치 시 조용히 종료 (방어적 가드)
command -v jq >/dev/null 2>&1 || exit 0

CREDENTIALS_FILE="$HOME/.config/pushover/claude-code"

if [ -f "$CREDENTIALS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
else
  # PreToolUse: exit 0으로 tool call을 정상 통과시킴
  # (Stop hook의 exit 1과 다름 — credentials 없어도 Claude 동작에 영향 없음)
  exit 0
fi

# stdin에서 JSON 입력 읽기
INPUT=$(cat)

# 질문 추출 (최대 4개 가능)
QUESTION_COUNT=$(echo "$INPUT" | jq -r '.tool_input.questions | length' 2>/dev/null)
FIRST_QUESTION=$(echo "$INPUT" | jq -r '.tool_input.questions[0].question // empty' 2>/dev/null)

if [ -z "$FIRST_QUESTION" ]; then
  exit 0
fi

# 다중 질문 표시
if [ "$QUESTION_COUNT" -gt 1 ] 2>/dev/null; then
  QUESTION_LINE="❓ [$QUESTION_COUNT개 질문] $FIRST_QUESTION"
else
  QUESTION_LINE="❓ $FIRST_QUESTION"
fi

# 정보 수집
HOST=$(hostname -s 2>/dev/null || echo "?")
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

if [ -n "$GIT_ROOT" ]; then
  REPO=$(basename "$GIT_ROOT")
  BRANCH=$(git branch --show-current 2>/dev/null)
  if [ -z "$BRANCH" ]; then
    BRANCH=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
  fi
  CONTEXT="📁 $REPO · 🌿 $BRANCH"
else
  DIR=$(basename "$PWD")
  CONTEXT="📁 $DIR"
fi

MESSAGE="🖥️ $HOST
$CONTEXT
$QUESTION_LINE"

curl -s \
  --form-string "token=$PUSHOVER_TOKEN" \
  --form-string "user=$PUSHOVER_USER" \
  --form-string "title=Claude Code [📝질문 대기]" \
  -F "priority=0" \
  -F "sound=falling" \
  --form-string "message=$MESSAGE" \
  https://api.pushover.net/1/messages.json > /dev/null

exit 0
