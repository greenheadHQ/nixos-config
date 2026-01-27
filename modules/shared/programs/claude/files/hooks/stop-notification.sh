#!/usr/bin/env bash
# Claude Code Stop Hook - Pushover 알림 전송

# agenix로 관리되는 credentials 로드
CREDENTIALS_FILE="$HOME/.config/pushover/claude-code"

if [ -f "$CREDENTIALS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
else
  echo "Error: Pushover credentials not found at $CREDENTIALS_FILE" >&2
  exit 1
fi

# --- 정보 수집 ---
HOST=$(hostname -s 2>/dev/null || echo "?")
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)

if [ -n "$GIT_ROOT" ]; then
  REPO=$(basename "$GIT_ROOT")
  BRANCH=$(git branch --show-current 2>/dev/null)
  # detached HEAD: git branch --show-current는 exit 0이지만 빈 문자열 반환
  if [ -z "$BRANCH" ]; then
    BRANCH=$(git rev-parse --short HEAD 2>/dev/null || echo "?")
  fi
  MESSAGE="🖥️ $HOST
📁 $REPO · 🌿 $BRANCH"
else
  DIR=$(basename "$PWD")
  MESSAGE="🖥️ $HOST
📁 $DIR"
fi

curl -s \
  --form-string "token=$PUSHOVER_TOKEN" \
  --form-string "user=$PUSHOVER_USER" \
  --form-string "title=Claude Code [✅작업 완료]" \
  -F "sound=jobs_done" \
  --form-string "message=$MESSAGE" \
  https://api.pushover.net/1/messages.json > /dev/null
