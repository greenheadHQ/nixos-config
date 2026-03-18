#!/usr/bin/env bash
# Claude Code PreToolUse Hook - AskUserQuestion Pushover 알림
# Claude가 사용자에게 질문할 때 Pushover 알림을 보냅니다.
#
# [중요] PreToolUse hook의 stdout은 tool call을 수정/차단할 수 있으므로,
# 모든 외부 명령 출력을 반드시 /dev/null로 리다이렉트해야 합니다.
# Stop hook과 달리 stdout 오염이 Claude 동작에 직접 영향을 줍니다.
#
# [iOS 푸시 알림 표시 한계] (iPhone 14 Pro Max, iOS 26.3 기준)
# - Lock screen: ~115자 (헤더 2줄 + 본문 약 1줄)
# - Long press (확장): ~253자 (헤더 2줄 + 본문 약 4~5줄)
# Pushover API 자체 제한(1024자)과 별개로 iOS가 표시 영역을 자름.

# UTF-8 인코딩 강제 설정 (Claude Code 환경에서 LANG이 미설정될 수 있음)
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# jq 미설치 시 조용히 종료 (방어적 가드)
command -v jq >/dev/null 2>&1 || exit 0

CREDENTIALS_FILE="$HOME/.config/pushover/claude-code"

PUSHOVER_AVAILABLE=false
if [ -f "$CREDENTIALS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
  PUSHOVER_AVAILABLE=true
fi

# Pushover도 없고 macOS도 아니면 알림 채널이 없으므로 조기 종료
if [ "$PUSHOVER_AVAILABLE" = false ] && [[ "$OSTYPE" != darwin* ]]; then
  exit 0
fi

# stdin에서 JSON 입력 읽기
INPUT=$(cat)

# agent_id 가드: 서브에이전트 내부에서 PreToolUse가 발동한 경우 알림 불필요
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
if [ -n "$AGENT_ID" ]; then
  exit 0
fi

# 질문 추출 (최대 4개 가능, printf로 안정적 UTF-8 전달)
QUESTION_COUNT=$(printf '%s' "$INPUT" | jq -r '.tool_input.questions | length' 2>/dev/null)
FIRST_QUESTION=$(printf '%s' "$INPUT" | jq -r '.tool_input.questions[0].question // empty' 2>/dev/null)

if [ -z "$FIRST_QUESTION" ]; then
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

# 질문 + 선택지 포맷
QUESTION_LINE=""
for i in $(seq 0 $((QUESTION_COUNT - 1))); do
  Q=$(printf '%s' "$INPUT" | jq -r ".tool_input.questions[$i].question // empty" 2>/dev/null)

  # 다중 질문이면 Q1. Q2. 접두사 추가
  if [ "$QUESTION_COUNT" -gt 1 ] 2>/dev/null; then
    Q="Q$((i + 1)). $Q"
  fi

  # 선택지 레이블 추출
  OPTION_LABELS=$(printf '%s' "$INPUT" | jq -r ".tool_input.questions[$i].options[]?.label // empty" 2>/dev/null)
  if [ -n "$OPTION_LABELS" ]; then
    # printf '%s\n'으로 마지막 줄에도 개행 보장 (read가 모든 항목을 처리하도록)
    while IFS= read -r opt || [ -n "$opt" ]; do
      Q="$Q
· $opt"
    done <<< "$OPTION_LABELS"
  fi

  if [ -n "$QUESTION_LINE" ]; then
    QUESTION_LINE="$QUESTION_LINE
"
  fi
  QUESTION_LINE="${QUESTION_LINE}${Q}"
done

MESSAGE="🖥️ $HOST
$CONTEXT
$QUESTION_LINE"

# CIR: hs.notify 성공 시 Pushover skip (중복 알림 해소) → stop-notification.sh 참조

# macOS 로컬 데스크탑 알림 (Hammerspoon hs.notify)
# hs.notify 성공 시 HS_SENT=true → Pushover skip. 실패 시 Pushover 폴백.
HS_SENT=false
if [[ "$OSTYPE" == darwin* ]] && command -v hs >/dev/null 2>&1; then
  # 세션 이름 추출: transcript JSONL의 custom-title 엔트리
  HS_SESSION_NAME=""
  HS_TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [ -n "$HS_TRANSCRIPT" ] && [ -f "$HS_TRANSCRIPT" ]; then
    HS_SESSION_NAME=$(grep '"custom-title"' "$HS_TRANSCRIPT" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null || true)
  fi
  # CIR: 호스트 제외 + subtitle→body 이동 의사결정 → stop-notification.sh 참조
  HS_REPO="$REPO"
  HS_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$HS_COMMON_DIR" ] && [ "$HS_COMMON_DIR" != ".git" ]; then
    HS_REPO=$(basename "$(cd "$HS_COMMON_DIR/.." 2>/dev/null && pwd)")
  fi
  HS_BODY=""
  if [ -n "$HS_SESSION_NAME" ]; then
    HS_BODY="$HS_SESSION_NAME"
  fi
  if [ -n "$HS_REPO" ]; then
    HS_BODY="${HS_BODY:+$HS_BODY
}📁 ${HS_REPO}${BRANCH:+ · 🌿 $BRANCH}"
  fi
  HS_ICON="$HOME/.claude/assets/notification-icon.png"
  # Lua single-quoted string 삽입: ' \ 제거(Lua escape 방어) + " $ ` 제거(bash interpolation 방어)
  HS_BODY_SAFE="${HS_BODY//\'/}"
  HS_BODY_SAFE="${HS_BODY_SAFE//\"/}"
  HS_BODY_SAFE="${HS_BODY_SAFE//\\/}"
  HS_BODY_SAFE="${HS_BODY_SAFE//\`/}"
  HS_BODY_SAFE="${HS_BODY_SAFE//\$/}"
  HS_BODY_SAFE="${HS_BODY_SAFE//$'\n'/\\n}"
  timeout 2 hs -c "
    local n = hs.notify.new({
      title = 'Claude Code [📝질문 대기]',
      informativeText = '${HS_BODY_SAFE}',
      soundName = 'Glass',
      -- CIR: withdrawAfter 의사결정 → stop-notification.sh Lua 블록 참조
      withdrawAfter = 0
    })
    local img = hs.image.imageFromPath('${HS_ICON}')
    if img then n:contentImage(img) end
    n:send()
  " >/dev/null 2>&1 && HS_SENT=true || true
fi

if [ "$PUSHOVER_AVAILABLE" = true ] && [ "$HS_SENT" = false ]; then
  curl -s --max-time 4 -X POST \
    -H "Content-Type: application/x-www-form-urlencoded; charset=utf-8" \
    --data-urlencode "token=$PUSHOVER_TOKEN" \
    --data-urlencode "user=$PUSHOVER_USER" \
    --data-urlencode "title=Claude Code [📝질문 대기]" \
    --data-urlencode "priority=0" \
    --data-urlencode "sound=falling" \
    --data-urlencode "message=$MESSAGE" \
    https://api.pushover.net/1/messages.json >/dev/null 2>&1
fi

exit 0
