#!/usr/bin/env bash
set -euo pipefail
# Codex-only divergence from Claude hook: skip programmatic/nested codex sessions
# to avoid duplicate notifications + statusline TTL contamination.
# Keep in sync with ~/.claude/hooks/record-last-stop.sh (issue #585).
if [ "${CLAUDECODE:-}" = "1" ] || [ "${CODEX_PROGRAMMATIC:-}" = "1" ]; then
  exit 0
fi
# record-last-stop.sh — 프롬프트 캐시 TTL 추적용 타임스탬프 기록
# statusline.sh가 세션별 파일을 읽어 캐시 남은 시간을 계산한다.
# 주의: settings.json의 Stop 훅 배열에서 첫 번째로 실행되어야 한다.
# 다른 Stop 훅보다 먼저 타임스탬프를 기록하여
# statusline 카운트다운의 레이스 컨디션을 최소화한다.
# Codex에서는 _stop-dispatcher.sh가 이 순서를 직렬로 보장한다 (issue #585).

# stdin에서 세션 정보 읽기 (Codex 0.124+ schema는 agent_id 키 없음 — issue #585 DA C-2).
# Claude 원본의 agent_id subagent guard는 Codex에서는 항상 비활성이므로 제거했다.
# subagent Stop이 main으로 기록되는 한계는 #586 fixture가 측정한다 (openai/codex#16226).
INPUT=""
[ ! -t 0 ] && INPUT=$(cat)

if [ -n "$INPUT" ]; then
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
