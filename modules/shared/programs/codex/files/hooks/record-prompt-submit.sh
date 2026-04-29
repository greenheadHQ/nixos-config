#!/usr/bin/env bash
set -euo pipefail
# Codex-only divergence from Claude hook: skip programmatic/nested codex sessions
# to avoid duplicate notifications + statusline TTL contamination.
# Keep in sync with ~/.claude/hooks/record-prompt-submit.sh (issue #585).
if [ "${CLAUDECODE:-}" = "1" ] || [ "${CODEX_PROGRAMMATIC:-}" = "1" ]; then
  exit 0
fi
# record-prompt-submit.sh — 프롬프트 전송 시 캐시 TTL을 "in-flight" 상태로 전환
# "0"을 기록하면 statusline.sh가 mtime 기준 카운트다운 표시 (Stop 미기록 상태)

# stdin에서 세션 정보 읽기 (Codex 0.124+ schema는 agent_id 키 없음 — issue #585 DA C-2).
# Claude 원본의 agent_id subagent guard는 Codex에서는 항상 비활성이므로 제거했다.
# subagent UserPromptSubmit이 main으로 기록되는 한계는 #586 fixture가 측정한다 (openai/codex#16226).
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
  echo 0 > "$DATADIR/last-stop-${SESSION_ID}"
else
  # 글로벌 fallback (SESSION_ID 없는 환경용)
  echo 0 > "$DATADIR/last-stop"
fi
