#!/usr/bin/env bash
# Claude Code UserPromptSubmit Hook - Pain point 실시간 감지
# stdin: JSON {session_id, prompt, transcript_path, agent_id, ...}
# stdout: JSON (hookSpecificOutput with additionalContext) 또는 빈 출력
#
# 사용자 메시지에서 교정 키워드와 (pain) 접두사를 실시간 감지하여
# pain-points.jsonl에 즉시 기록. 감지 시 additionalContext로 Claude에 힌트 주입.

set -euo pipefail

umask 077

command -v jq >/dev/null 2>&1 || exit 0

[[ -n "${SKILL_EVAL_MODE:-}" ]] && exit 0
[[ -n "${PAIN_COLLECTING:-}" ]] && exit 0

# --- stdin 읽기 ---
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -n "$INPUT" ] || exit 0

# 서브에이전트 가드
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$AGENT_ID" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

[ -n "$PROMPT" ] || exit 0

# --- 설정 ---
PAIN_FILE="${PAIN_POINTS_FILE:-$HOME/.claude/pain-points.jsonl}"

# --- Git 정보 (worktree 보정) ---
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
REPO="${REPO:-unknown}"
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$COMMON_DIR" ] && [ "$COMMON_DIR" != ".git" ]; then
  REPO=$(basename "$(cd "$COMMON_DIR/.." 2>/dev/null && pwd)" 2>/dev/null || echo "$REPO")
fi

# --- 감지 로직 ---

# (pain) 접두사 감지 — 사용자가 명시적으로 태깅
IS_PAIN_TAG=false
USER_NOTE=""
if printf '%s' "$PROMPT" | grep -qi '^(pain)'; then
  IS_PAIN_TAG=true
  USER_NOTE=$(printf '%s' "$PROMPT" | sed 's/^([Pp][Aa][Ii][Nn])[ ]*//')
fi

# 교정 키워드 감지
# ;; → high severity, 나머지 → medium
HAS_DOUBLE_SEMI=false
HAS_KEYWORD=false
MATCHED_KEYWORD=""

if printf '%s' "$PROMPT" | grep -q ';;'; then
  HAS_DOUBLE_SEMI=true
  HAS_KEYWORD=true
  MATCHED_KEYWORD=";;"
elif printf '%s' "$PROMPT" | grep -qE '^아니[^면]|^아니$|^아니 '; then
  HAS_KEYWORD=true
  MATCHED_KEYWORD="아니"
elif printf '%s' "$PROMPT" | grep -q '해야지'; then
  HAS_KEYWORD=true
  MATCHED_KEYWORD="해야지"
elif printf '%s' "$PROMPT" | grep -q '그거 말고'; then
  HAS_KEYWORD=true
  MATCHED_KEYWORD="그거 말고"
elif printf '%s' "$PROMPT" | grep -qE '^야,|^야 '; then
  HAS_KEYWORD=true
  MATCHED_KEYWORD="야,"
fi

# 아무것도 감지 안 되면 exit
[ "$IS_PAIN_TAG" = true ] || [ "$HAS_KEYWORD" = true ] || exit 0

# --- severity 결정 ---
SEVERITY="medium"
[ "$HAS_DOUBLE_SEMI" = true ] && SEVERITY="high"

# --- source + description 결정 ---
if [ "$IS_PAIN_TAG" = true ]; then
  SOURCE="manual"
  DESCRIPTION="(pain) 태깅: ${USER_NOTE:-(내용 없음)}"
else
  SOURCE="auto"
  DESCRIPTION="키워드 감지: $MATCHED_KEYWORD"
fi

# --- 감지 시점 대화 컨텍스트 추출 (대시보드에서 "왜 pain인지" 파악용) ---
# UserPromptSubmit hook이므로 감지 시점의 최근 4턴이 정확한 pain 맥락.
# content가 배열(tool_use 등)이면 text 블록만 추출, 문자열이면 그대로 사용.
PAIN_CONTEXT="[]"
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  PAIN_CONTEXT=$(jq -Rrs '
    split("\n")
    | map(select(length > 0) | fromjson?)
    | map(select(.type == "user" or .type == "assistant"))
    | map({type, content: (
        .message.content // ""
        | if type == "string" then .[0:300]
          elif type == "array" then ([.[] | select(type == "object" and .type == "text") | .text] | first // "") | .[0:300]
          else "" end
      )})
    | map(select(.content | length > 0))
    | .[-4:]
  ' "$TRANSCRIPT_PATH" 2>/dev/null || echo "[]")
fi

# --- JSONL 기록 ---
TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")

# append는 OS 레벨에서 원자적 (1줄 JSONL < PIPE_BUF). lock 불필요.
jq -nc \
  --arg ts "$TS" \
  --arg sid "${SESSION_ID:-unknown}" \
  --arg repo "$REPO" \
  --arg branch "$BRANCH" \
  --arg source "$SOURCE" \
  --arg sev "$SEVERITY" \
  --arg keyword "$MATCHED_KEYWORD" \
  --arg desc "$DESCRIPTION" \
  --arg note "$USER_NOTE" \
  --arg tp "${TRANSCRIPT_PATH:-}" \
  --argjson ctx "$PAIN_CONTEXT" \
  '{
    ts: $ts, session_id: $sid, repo: $repo, branch: $branch,
    source: $source, severity: $sev,
    signals: { keyword: $keyword },
    description: $desc,
    user_note: (if $note == "" then null else $note end),
    transcript_path: (if $tp == "" then null else $tp end),
    context: $ctx
  }' >> "$PAIN_FILE" 2>/dev/null || true

# --- additionalContext 주입 (Claude에 힌트) ---
if [ "$IS_PAIN_TAG" = true ]; then
  # (pain) 태깅: Claude에게 사용자가 불편을 표현했음을 알림
  CONTEXT="[Pain Point 기록됨] 사용자가 (pain) 태깅으로 불편을 표현했습니다. 이전 행동을 되돌아보고 개선하세요."
  jq -n --arg ctx "$CONTEXT" \
    '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":$ctx}}'
fi

# 키워드 감지는 additionalContext 없이 조용히 기록만 함 (매번 힌트 주면 노이즈)

exit 0
