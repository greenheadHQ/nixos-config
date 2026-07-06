#!/usr/bin/env bash
# PreToolUse Hook: 스킬 호출 빈도 로깅
# Thariq(Anthropic) gist 기반 — session_id, repo context 추가
#
# Log format (TSV): timestamp user session_id repo skill args
# 예: 1742302800	greenhead	abc123	nixos-config	managing-minipc	""

command -v jq >/dev/null 2>&1 || exit 0

HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
[ -f "$HOOK_RUNTIME_LIB" ] || exit 0
# shellcheck source=../lib/hook-runtime.sh
. "$HOOK_RUNTIME_LIB"

INPUT=$(cat)

# 서브에이전트 내부 호출은 제외
AGENT_ID=$(printf '%s' "$INPUT" | hook_parse_json_path '.agent_id // empty')
[ -n "$AGENT_ID" ] && exit 0

SKILL=$(printf '%s' "$INPUT" | hook_parse_json_path '.tool_input.skill // empty')
[ -z "$SKILL" ] && exit 0

ARGS=$(printf '%s' "$INPUT" | hook_parse_json_path '.tool_input.args // ""')
SESSION_ID=$(printf '%s' "$INPUT" | hook_parse_session_id)
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null || true)

# 로그 파일 owner-only 권한 (민감 args 보호)
umask 077

printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date -u +%s)" "$USER" "${SESSION_ID:-unknown}" \
  "${REPO:-unknown}" "$SKILL" "$ARGS" \
  >> "$HOME/.claude/skill-usage.log" 2>/dev/null || true

exit 0
