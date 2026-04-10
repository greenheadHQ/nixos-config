#!/usr/bin/env bash
set -euo pipefail
# record-last-stop.sh — 프롬프트 캐시 TTL 추적용 타임스탬프 기록
# statusline.sh가 세션별 파일을 읽어 캐시 남은 시간을 계산한다.

# stdin에서 세션 정보 읽기 (agent_id 가드 + session_id 파싱 공용)
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

if [ -n "$INPUT" ]; then
  # 서브에이전트 내부 Stop은 무시 (메인 턴 완료만 추적)
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
  date +%s > "$DATADIR/last-stop-${SESSION_ID}"
else
  # 글로벌 fallback (SESSION_ID 없는 환경용)
  date +%s > "$DATADIR/last-stop"
fi
