#!/usr/bin/env bash
# PreToolUse Hook: 스킬 호출 빈도 로깅
# Thariq(Anthropic) gist 기반 — session_id, repo context 추가
#
# Log format (TSV): timestamp user session_id repo skill args
# 예: 1742302800	green	abc123	nixos-config	managing-minipc	""

# eval 모드에서는 로깅 스킵 — 실사용 데이터 오염 방지 (#283)
[[ -n "${SKILL_EVAL_MODE:-}" ]] && exit 0

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)

# 서브에이전트 내부 호출은 제외
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$AGENT_ID" ] && exit 0

SKILL=$(printf '%s' "$INPUT" | jq -r '.tool_input.skill // empty' 2>/dev/null)
[ -z "$SKILL" ] && exit 0

ARGS=$(printf '%s' "$INPUT" | jq -r '.tool_input.args // ""' 2>/dev/null)
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)

# 로그 파일 owner-only 권한 (민감 args 보호)
umask 077

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%s)" "$USER" "${SESSION_ID:-unknown}" \
  "${REPO:-unknown}" "$SKILL" "$ARGS" \
  >> "$HOME/.claude/skill-usage.log" 2>/dev/null || true

exit 0
