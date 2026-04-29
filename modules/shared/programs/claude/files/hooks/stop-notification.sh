#!/usr/bin/env bash
# Claude Code Stop Hook - Pushover 알림 전송

# === Change Intent Record ===
# v1: --form-string/-F (multipart/form-data) 방식으로 Pushover 전송 → 간헐적으로 이모지/한글이 ?로 표시.
#     원인: multipart/form-data 인코딩에서 UTF-8 문자 처리가 불안정.
#     echo로 jq 출력을 파이프하면 플랫폼별 escape sequence 처리가 달라 UTF-8 추가 손상.
# v2 (이번): --data-urlencode로 통일 (application/x-www-form-urlencoded; charset=utf-8),
#     echo 대신 printf '%s'로 입력 그대로 전달, LANG/LC_ALL 강제 설정.
#     trade-off: 없음 — 세 가지 수정이 모두 호환성 향상.
# 적용 대상: stop-notification.sh, ask-notification.sh, plan-notification.sh (동일 패턴)
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Pushover 메시지 최대 길이
MAX_MESSAGE_CHARS=1024

# Transcript 파일이 완전히 기록될 때까지 대기
# Race condition 방어: Stop hook이 transcript flush보다 먼저 실행되는 경우
# 0.3초 간격으로 파일 크기 확인, 연속 2회 동일하면 안정화된 것으로 판단 (최대 3초)
wait_for_stable_transcript() {
  local file="$1"
  local prev_size=-1
  local curr_size

  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curr_size=$(wc -c < "$file" 2>/dev/null || echo 0)
    if [ "$curr_size" = "$prev_size" ] && [ "$curr_size" -gt 0 ]; then
      return 0
    fi
    prev_size=$curr_size
    sleep 0.3
  done
}

# agenix로 관리되는 credentials 로드
CREDENTIALS_FILE="$HOME/.config/pushover/claude-code"

PUSHOVER_AVAILABLE=false
if [ -f "$CREDENTIALS_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CREDENTIALS_FILE"
  PUSHOVER_AVAILABLE=true
fi

# Pushover도 없고 macOS도 아니면 알림 채널이 없으므로 조기 종료 (NixOS 불필요 연산 방지)
if [ "$PUSHOVER_AVAILABLE" = false ] && [[ "$OSTYPE" != darwin* ]]; then
  exit 0
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

# Hammerspoon 호출 timeout wrapper.
# macOS BSD coreutils에는 `timeout`이 없다. nix-darwin이 GNU coreutils를 PATH에 추가하면 정상이지만,
# nix 없는 macOS는 `command not found (exit 127)`로 빠진다. 이 hook의 fail-open 패턴은
# `timeout 2 hs -c "..." && HS_SENT=true || true` 형태라 exit 127이면 HS_SENT=false 유지 →
# Pushover fallback으로 전이된다. helper는 `timeout` 부재 시 직접 실행 대신 `return 127`로 동일한
# fail-open 신호를 유지하여 dispatcher hang을 방지한다. ask/plan-notification.sh 와 정책 일관성을
# 위해 `gtimeout` 분기는 두지 않는다 — Homebrew coreutils 사용자도 ask/plan과 동일하게 Pushover
# fallback으로 전이된다.
# Shared helper body mirrored between Codex/Claude stop-notification.sh; helper-equivalence test enforces this marked block only.
# === HELPER_BEGIN: run_with_timeout ===
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    return 127
  fi
}
# === HELPER_END: run_with_timeout ===

# Pushover 외부 전송 본문에서 알려진 secret pattern을 마스킹.
# 적용 시점: LAST_REPLY 추출 직후 — clip 전 원본에서 한 번 redact한다. clip은 LAST_REPLY를
# 그대로 자르므로 redact가 clip 후 원본 secret으로 되돌아오지 않는다. clip 이후 추가 redaction은
# redundant이므로 두지 않는다.
# Pattern order rationale:
# - Family 내부에서 prefix가 겹치거나 가까운 패턴은 specific -> generic 순서로 둔다.
#   Anthropic/OpenAI API keys: `sk-ant-...` before generic `sk-...`.
#   GitHub tokens: fine-grained PAT `github_pat_...` before classic `gh[opsu]_...`.
# - Family 간 overlap이 없는 JWT/AWS access key 패턴은 redaction test fixture의 family 순서를 따른다.
# - Redaction marker 자체는 다른 secret 패턴과 매칭되지 않으므로 후속 패턴에 의해 재치환되지 않는다.
# jq 부재 시 fail-closed: 빈 문자열 반환하여 본문이 외부로 전송되지 않도록 한다.
# extract_last_assistant_text/normalize_reply 등 다른 jq 의존 함수도 jq 부재 시 결과가 약화되므로 일관.
# JWT pattern: header/payload base64url segment는 JSON `{` 시작 인코딩이라 첫 두 글자가 `e[wy]`
# (`eyJ`/`eyA`/`ewo` 등 포함). whitespace JSON header 변형(`{ "...`)도 매칭하도록 prefix를 넓힌다.
# Shared helper body mirrored between Codex/Claude stop-notification.sh; helper-equivalence test enforces this marked block only.
# === HELPER_BEGIN: redact_secrets ===
redact_secrets() {
  local s="$1"
  command -v jq >/dev/null 2>&1 || { return 0; }
  jq -Rrn --arg s "$s" '
    $s
    | gsub("sk-ant-[a-zA-Z0-9_-]{20,}"; "***REDACTED***")
    | gsub("sk-[a-zA-Z0-9_-]{20,}"; "***REDACTED***")
    | gsub("github_pat_[A-Za-z0-9_]{82,}"; "***REDACTED***")
    | gsub("gh[opsu]_[A-Za-z0-9_]{36,}"; "***REDACTED***")
    | gsub("e[wy][A-Za-z0-9_-]{8,}\\.e[wy][A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{10,}"; "***REDACTED***")
    | gsub("A[KS]IA[0-9A-Z]{16}"; "***REDACTED***")
  ' 2>/dev/null
}
# === HELPER_END: redact_secrets ===

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
  # agent_id 가드: 서브에이전트 내부에서 Stop이 발동한 경우 알림 불필요
  AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
  if [ -n "$AGENT_ID" ]; then
    exit 0
  fi
  TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)
fi

# Transcript flush 대기 (race condition 방어)
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  wait_for_stable_transcript "$TRANSCRIPT_PATH"
fi

LAST_REPLY="$(extract_last_assistant_text "$TRANSCRIPT_PATH")"
LAST_REPLY="$(normalize_reply "$LAST_REPLY")"
# clip 전 원본에서 secret 마스킹.
LAST_REPLY="$(redact_secrets "$LAST_REPLY")"

# 응답 텍스트가 있으면 본문에 포함, 없으면 기존 컨텍스트만 전송
if [ -n "$LAST_REPLY" ]; then
  PREFIX="$BASE_MESSAGE
📝 "
  PREFIX_LEN=$(str_len "$PREFIX")
  ELLIPSIS="…"
  ELLIPSIS_LEN=1  # U+2026, 1 codepoint
  BUDGET=$((MAX_MESSAGE_CHARS - PREFIX_LEN - ELLIPSIS_LEN))
  if [ "$BUDGET" -lt 0 ]; then
    BUDGET=0
  fi
  REPLY_LEN=$(str_len "$LAST_REPLY")
  CLIPPED_REPLY="$(clip_tail_chars "$LAST_REPLY" "$BUDGET")"
  if [ -z "$CLIPPED_REPLY" ]; then
    CLIPPED_REPLY="(응답 텍스트를 찾지 못했습니다)"
  elif [ "$REPLY_LEN" -gt "$BUDGET" ]; then
    # 뒤에서 잘랐으므로 앞부분이 생략되었음을 표시
    CLIPPED_REPLY="${ELLIPSIS}${CLIPPED_REPLY}"
  fi
  MESSAGE="${PREFIX}${CLIPPED_REPLY}"
else
  MESSAGE="$BASE_MESSAGE"
fi

# 최종 안전망: 전체 메시지 1024자 상한 보장
MESSAGE="$(clip_tail_chars "$MESSAGE" "$MAX_MESSAGE_CHARS")"

# === Change Intent Record: 중복 알림 해소 ===
# v1 (초기): Pushover와 hs.notify를 독립 실행 → 개인맥북에서 2중 알림(폰+데스크탑)으로 알림 피로 발생
# v2 (현재): hs.notify 성공 시 Pushover skip — HS_SENT 플래그 기반 fail-open 패턴
#
# 검토한 대안과 거부 이유:
# - OSTYPE==darwin이면 Pushover 무조건 skip: Hammerspoon 장애 시 알림 블랙홀 (fail-close)
# - hostname 분기: fragile, 머신 추가/변경 시 유지보수 비용
# - 환경변수 토글 (CLAUDE_NOTI_CHANNELS): 사용성 나쁨, 머신별 env 관리 필요
# - 자리 감지(screen lock 등): 과도한 복잡성
#
# 선택한 방식(HS_SENT 플래그)의 장점:
# - fail-open: hs.notify 실패(Hammerspoon 꺼짐/크래시/timeout) → HS_SENT=false → Pushover 폴백
# - NixOS: hs 블록 전체 skip → HS_SENT=false → Pushover만 전송 (기존과 동일)
# - macOS + Hammerspoon 정상: hs.notify만 전송 (중복 제거)

# macOS 로컬 데스크탑 알림 (Hammerspoon hs.notify)
# hs.notify 성공 시 HS_SENT=true → Pushover skip (중복 알림 방지)
# hs 미설치/에러/timeout 시 HS_SENT=false 유지 → Pushover 폴백
HS_SENT=false
if [[ "$OSTYPE" == darwin* ]] && command -v hs >/dev/null 2>&1; then
  # 세션 이름 추출: transcript JSONL의 custom-title 엔트리 (/rename으로 설정된 이름)
  HS_SESSION_NAME=""
  if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    HS_SESSION_NAME=$(grep '"custom-title"' "$TRANSCRIPT_PATH" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null || true)
  fi
  # CIR: 호스트(🖥️) 제외 — Hammerspoon은 macOS 전용이라 머신 구분 불필요. Pushover에는 유지(MiniPC 포함).
  # CIR: subtitle 대신 body에 세션이름+레포 배치 — subtitle은 macOS가 ~30자에서 잘라 세션이름이 말줄임됨.
  # worktree에서 REPO가 worktree 디렉토리명으로 잡히므로, 실제 repo 이름을 사용
  HS_REPO="$REPO"
  HS_COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null)
  if [ -n "$HS_COMMON_DIR" ] && [ "$HS_COMMON_DIR" != ".git" ]; then
    HS_REPO=$(basename "$(cd "$HS_COMMON_DIR/.." 2>/dev/null && pwd)")
  fi
  # body: 세션이름(있으면) + repo·branch — subtitle 대신 body에 모두 배치 (잘림 방지)
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
  run_with_timeout 2 hs -c "
    local n = hs.notify.new({
      title = 'Claude Code [✅작업 완료]',
      informativeText = '${HS_BODY_SAFE}',
      soundName = 'Purr',
      -- === Change Intent Record ===
      -- v1: withdrawAfter 미설정(기본값 5초) → 배너 사라진 뒤 NC에서도 완전 증발
      -- v2: withdrawAfter=0 + Alerts 스타일 → 알림이 화면에 상시 표시되어 둔감화 유발
      -- v3 (최종): withdrawAfter=0 + Banners 스타일(System Settings) →
      --   배너는 ~5초 후 자동 사라지되, NC에는 사용자가 직접 제거할 때까지 유지
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
    --data-urlencode "title=Claude Code [✅작업 완료]" \
    --data-urlencode "sound=jobs_done" \
    --data-urlencode "message=$MESSAGE" \
    https://api.pushover.net/1/messages.json >/dev/null 2>&1
fi

exit 0
