#!/usr/bin/env bash
# Claude Code Stop Hook - Pushover 알림 전송

# UTF-8 인코딩 강제 설정 (Claude Code 환경에서 LANG이 미설정될 수 있음)
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Pushover 메시지 최대 길이
MAX_MESSAGE_CHARS=1024

# agenix로 관리되는 credentials 로드
CREDENTIALS_FILE="${PUSHOVER_CREDENTIALS_FILE:-$HOME/.config/pushover/claude-code}"
PUSHOVER_API_URL="${PUSHOVER_API_URL:-https://api.pushover.net/1/messages.json}"

if [ -f "$CREDENTIALS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
else
  echo "Error: Pushover credentials not found at $CREDENTIALS_FILE" >&2
  exit 1
fi

# UTF-8 길이 계산 (jq 미설치 시 bash 길이로 폴백)
str_len() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -Rrn --arg s "$s" '$s | length' 2>/dev/null || printf '%s' "${#s}"
  else
    printf '%s' "${#s}"
  fi
}

# UTF-8 기준 뒤에서 n자 절단
clip_tail_chars() {
  local s="$1"
  local n="$2"

  if [ "$n" -le 0 ]; then
    printf ''
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -Rrn --arg s "$s" --argjson n "$n" '
      if ($s | length) <= $n then $s else $s[-$n:] end
    ' 2>/dev/null || printf '%s' "$s" | tail -c "$n"
  else
    printf '%s' "$s" | tail -c "$n"
  fi
}

# 줄바꿈/제어문자 정리
normalize_reply() {
  local s="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -Rrn --arg s "$s" '
      $s
      | gsub("\u0000"; "")
      | gsub("\r"; "")
      | gsub("\n{3,}"; "\n\n")
    ' 2>/dev/null || printf '%s' "$s"
  else
    printf '%s' "$s"
  fi
}

# transcript(JSONL)에서 마지막 assistant 텍스트 응답 추출
extract_last_assistant_text() {
  local transcript_path="$1"

  [ -n "$transcript_path" ] || return 0
  [ -f "$transcript_path" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  jq -Rrs '
    split("\n")
    | map(select(length > 0) | fromjson?)
    | map(
        select(.type == "assistant")
        | (
            if ((.message | type) == "object") and ((.message.content | type) == "array") then
              [ .message.content[]? | select(.type == "text") | .text ] | join("\n")
            else
              ""
            end
          )
      )
    | map(select(length > 0))
    | last // ""
  ' "$transcript_path" 2>/dev/null || true
}

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
  BASE_MESSAGE="🖥️ $HOST
📁 $REPO · 🌿 $BRANCH"
else
  DIR=$(basename "$PWD")
  BASE_MESSAGE="🖥️ $HOST
📁 $DIR"
fi

# Stop hook stdin에서 transcript_path 읽기
INPUT=""
TRANSCRIPT_PATH=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
  TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi

LAST_REPLY="$(extract_last_assistant_text "$TRANSCRIPT_PATH")"
LAST_REPLY="$(normalize_reply "$LAST_REPLY")"

# 응답 텍스트가 있으면 본문에 포함, 없으면 기존 컨텍스트만 전송
if [ -n "$LAST_REPLY" ]; then
  PREFIX="$BASE_MESSAGE
📝 "
  PREFIX_LEN=$(str_len "$PREFIX")
  BUDGET=$((MAX_MESSAGE_CHARS - PREFIX_LEN))
  if [ "$BUDGET" -lt 0 ]; then
    BUDGET=0
  fi
  CLIPPED_REPLY="$(clip_tail_chars "$LAST_REPLY" "$BUDGET")"
  if [ -z "$CLIPPED_REPLY" ]; then
    CLIPPED_REPLY="(응답 텍스트를 찾지 못했습니다)"
  fi
  MESSAGE="${PREFIX}${CLIPPED_REPLY}"
else
  MESSAGE="$BASE_MESSAGE"
fi

# 최종 안전망: 전체 메시지 1024자 상한 보장
MESSAGE="$(clip_tail_chars "$MESSAGE" "$MAX_MESSAGE_CHARS")"

# 디버그 로그 (원인 특정 후 삭제)
DEBUG_LOG="/tmp/claude-stop-hook-debug.log"
{
  echo "=== $(date -Iseconds) ==="
  echo "PATH=$PATH"
  echo "jq_path=$(command -v jq 2>&1 || echo 'NOT_FOUND')"
  echo "input_len=${#INPUT}"
  echo "transcript_path=$TRANSCRIPT_PATH"
  if [ -n "$TRANSCRIPT_PATH" ]; then
    echo "transcript_exists=$([ -f "$TRANSCRIPT_PATH" ] && echo "yes ($(du -h "$TRANSCRIPT_PATH" 2>/dev/null | cut -f1))" || echo "no")"
  fi
  echo "last_reply_len=${#LAST_REPLY}"
  echo "message_len=${#MESSAGE}"
  echo "message_first_200=${MESSAGE:0:200}"
  echo "---"
} >> "$DEBUG_LOG" 2>/dev/null

curl -s -X POST \
  -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
  --data-urlencode "token=$PUSHOVER_TOKEN" \
  --data-urlencode "user=$PUSHOVER_USER" \
  --data-urlencode "title=Claude Code [✅작업 완료]" \
  --data-urlencode "sound=jobs_done" \
  --data-urlencode "message=$MESSAGE" \
  "$PUSHOVER_API_URL" > /dev/null

exit 0
