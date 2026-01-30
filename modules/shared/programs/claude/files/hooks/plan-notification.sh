#!/usr/bin/env bash
# Claude Code PreToolUse Hook - ExitPlanMode Pushover 알림
# 계획 승인을 요청할 때 Pushover 알림을 보냅니다.
#
# [중요] PreToolUse hook의 stdout은 tool call을 수정/차단할 수 있으므로,
# 모든 외부 명령 출력을 반드시 /dev/null로 리다이렉트해야 합니다.

# UTF-8 인코딩 강제 설정 (Claude Code 환경에서 LANG이 미설정될 수 있음)
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

CREDENTIALS_FILE="$HOME/.config/pushover/claude-code"

if [ -f "$CREDENTIALS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
else
  exit 0
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
$CONTEXT"

curl -s -X POST \
  -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
  --data-urlencode "token=$PUSHOVER_TOKEN" \
  --data-urlencode "user=$PUSHOVER_USER" \
  --data-urlencode "title=Claude Code [🙏계획 승인 요청]" \
  --data-urlencode "priority=0" \
  --data-urlencode "sound=falling" \
  --data-urlencode "message=$MESSAGE" \
  https://api.pushover.net/1/messages.json > /dev/null

exit 0
