#!/usr/bin/env bash
set -euo pipefail
# Programmatic/nested Codex 세션은 상위 세션의 마커를 덮어쓰지 않도록 제외한다.
# Codex 전용 hook — Claude 쪽 동일 hook 은 statusline Cache TTL 기능 제거로 삭제됨 (issue #585).
if [ "${CLAUDECODE:-}" = "1" ] || [ "${CODEX_PROGRAMMATIC:-}" = "1" ]; then
  exit 0
fi
# record-prompt-submit.sh — 프롬프트 전송 시 세션별 last-stop 마커에 0을 기록한다.
# 현재 저장소의 statusline.sh는 이 마커를 읽지 않는다. 외부 소비 여부를 확인하기 전까지
# 0(응답 진행 중), 타임스탬프(Stop)의 기존 마커 형식과 배선은 유지한다.
# 공통 helper SSOT: modules/shared/programs/claude/files/lib/hook-runtime.sh.
# 정책: hook-runtime.sh 미발견 시 inline fallback 자체 로직 실행 (자체 동작 보존).

# stdin에서 세션 정보 읽기 (Codex 0.124+ schema는 agent_id 키 없음 — issue #585 DA C-2).
# Claude 원본의 agent_id subagent guard는 Codex에서는 항상 비활성이므로 제거했다.
# subagent UserPromptSubmit이 main으로 기록되는 한계는 #586 fixture가 측정한다 (openai/codex#16226).
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

# hook-runtime.sh source 시도. 실패 시 inline fallback 으로 session_id 파싱.
HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.codex/lib/hook-runtime.sh}"
if [ -f "$HOOK_RUNTIME_LIB" ] && command -v jq >/dev/null 2>&1; then
  # shellcheck source=../../../claude/files/lib/hook-runtime.sh
  . "$HOOK_RUNTIME_LIB"
  [ -n "$INPUT" ] && SESSION_ID=$(printf '%s' "$INPUT" | hook_parse_session_id)
else
  # inline fallback — hook-runtime.sh 또는 jq 미발견 시 자체 파싱.
  if [ -n "$INPUT" ] && command -v jq >/dev/null 2>&1; then
    SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  fi
fi

# fallback: env var → 빈 문자열
[ -z "${SESSION_ID:-}" ] && SESSION_ID="${CLAUDE_SESSION_ID:-}"

DATADIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-hooks"
mkdir -p "$DATADIR"

if [ -n "$SESSION_ID" ]; then
  echo 0 > "$DATADIR/last-stop-${SESSION_ID}"
else
  # 글로벌 fallback (SESSION_ID 없는 환경용)
  echo 0 > "$DATADIR/last-stop"
fi
