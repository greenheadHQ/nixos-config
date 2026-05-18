#!/usr/bin/env bash
set -euo pipefail
# record-prompt-submit.sh — 프롬프트 전송 시 캐시 TTL을 "in-flight" 상태로 전환
# "0"을 기록하면 statusline.sh가 mtime 기준 카운트다운 표시 (Stop 미기록 상태)
# 공통 helper SSOT: modules/shared/programs/claude/files/lib/hook-runtime.sh.
# 정책: hook-runtime.sh 미발견 시 inline fallback 자체 로직 실행 (자체 동작 보존).

# stdin에서 세션 정보 읽기 (agent_id 가드 + session_id 파싱 공용)
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

if [ -n "$INPUT" ]; then
  # 서브에이전트 내부 UserPromptSubmit은 무시 (메인 턴만 추적) — claude 전용 런타임 가드, inline 유지.
  AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
  [ -n "$AGENT_ID" ] && exit 0
fi

# hook-runtime.sh source 시도. 실패 시 inline fallback 으로 session_id 파싱.
HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
if [ -f "$HOOK_RUNTIME_LIB" ] && command -v jq >/dev/null 2>&1; then
  # shellcheck source=../lib/hook-runtime.sh
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
