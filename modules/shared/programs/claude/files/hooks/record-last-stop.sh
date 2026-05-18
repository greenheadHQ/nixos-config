#!/usr/bin/env bash
set -euo pipefail
# record-last-stop.sh — 프롬프트 캐시 TTL 추적용 타임스탬프 기록
# statusline.sh가 세션별 파일을 읽어 캐시 남은 시간을 계산한다.
# 주의: settings.json의 Stop 훅 배열에서 첫 번째로 실행되어야 한다.
# 다른 Stop 훅보다 먼저 타임스탬프를 기록하여
# statusline 카운트다운의 레이스 컨디션을 최소화한다.
# 공통 helper SSOT: modules/shared/programs/claude/files/lib/hook-runtime.sh.
# 정책: hook-runtime.sh 미발견 시 inline fallback 자체 로직 실행 (자체 동작 보존).

# stdin에서 세션 정보 읽기 (agent_id 가드 + session_id 파싱 공용)
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

if [ -n "$INPUT" ]; then
  # 서브에이전트 내부 Stop은 무시 (메인 턴 완료만 추적) — claude 전용 런타임 가드, inline 유지.
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
  date +%s > "$DATADIR/last-stop-${SESSION_ID}"
else
  # 글로벌 fallback (SESSION_ID 없는 환경용)
  date +%s > "$DATADIR/last-stop"
fi
