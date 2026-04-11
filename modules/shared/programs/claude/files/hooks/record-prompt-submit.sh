#!/usr/bin/env bash
set -euo pipefail
# record-prompt-submit.sh — 프롬프트 전송 시 캐시 TTL을 "in-flight" 상태로 전환
# "0"을 기록하면 statusline.sh가 mtime 기준 카운트다운 표시 (Stop 미기록 상태)

# stdin에서 세션 정보 읽기 (agent_id 가드 + session_id 파싱 공용)
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

if [ -n "$INPUT" ]; then
  # 서브에이전트 내부 UserPromptSubmit은 무시 (메인 턴만 추적)
  AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
  [ -n "$AGENT_ID" ] && exit 0
  # stdin JSON에서 session_id 파싱 (env var보다 신뢰성 높음)
  SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
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
