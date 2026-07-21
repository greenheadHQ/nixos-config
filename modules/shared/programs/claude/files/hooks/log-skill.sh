#!/usr/bin/env bash
# PreToolUse Hook: 스킬 호출 빈도 로깅
# Thariq(Anthropic) gist 기반 — privacy-safe v2 JSONL schema (#1099)
#
# Log format (v2 JSONL, 한 줄 한 event):
#   {"schema_version":2,"event_type":"skill_invocation","ts":<epoch>,"runtime":"claude-main","skill":"<name>","session_key":"<64 lowercase hex>"}
# scripts/ai/skill-usage-report.sh consumes this schema; update both files together.
# legacy TSV rows는 report가 read-only로 계속 읽는다 (기존 로그 rewrite 금지).
#
# 금지 필드: user, repo, args, prompt, cwd/path, raw session id, agent id.
# session_key는 owner-only 32-byte random local key(~/.claude/skill-usage.key)와
# session id를 stdin으로 이어 SHA-256한 per-host pseudonym이다.
# key 생성/읽기/hash 실패 시 raw id fallback 없이 event를 건너뛴다.

command -v jq >/dev/null 2>&1 || exit 0

HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
[ -f "$HOOK_RUNTIME_LIB" ] || exit 0
# shellcheck source=../lib/hook-runtime.sh
# shellcheck disable=SC1091
. "$HOOK_RUNTIME_LIB"

INPUT=$(cat)

# 서브에이전트 내부 호출은 제외
AGENT_ID=$(printf '%s' "$INPUT" | hook_parse_json_path '.agent_id // empty')
[ -n "$AGENT_ID" ] && exit 0

SKILL=$(printf '%s' "$INPUT" | hook_parse_json_path '.tool_input.skill // empty')
[ -z "$SKILL" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | hook_parse_session_id)

# 로그/키 파일 owner-only 권한 (pseudonym 연결 키 보호)
umask 077
SKILL_USAGE_LOG="${SKILL_USAGE_LOG:-$HOME/.claude/skill-usage.log}"
SKILL_USAGE_KEY="${SKILL_USAGE_KEY:-$HOME/.claude/skill-usage.key}"

# stdin을 SHA-256해 64 lowercase hex 출력. 도구 부재 시 실패 (caller가 event skip).
_sha256_stdin_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# <value>가 64 lowercase hex인지 검증
_is_64_hex() {
  case "$1" in
    *[!0-9a-f]*|"") return 1 ;;
  esac
  [ "${#1}" -eq 64 ]
}

# key가 없으면 32-byte random을 hex로 한 번만 생성 (same-directory temp + atomic rename).
# key material은 argv/stdout/stderr에 노출하지 않는다.
if [ ! -f "$SKILL_USAGE_KEY" ]; then
  KEY_TMP=$(mktemp "$(dirname "$SKILL_USAGE_KEY")/.skill-usage.key.XXXXXX" 2>/dev/null) || exit 0
  if ! head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n' > "$KEY_TMP" 2>/dev/null; then
    rm -f "$KEY_TMP"
    exit 0
  fi
  chmod 600 "$KEY_TMP" 2>/dev/null || { rm -f "$KEY_TMP"; exit 0; }
  # 경합으로 다른 프로세스가 먼저 만들었으면 mv -n이 no-op — 그쪽 key를 쓴다
  mv -n "$KEY_TMP" "$SKILL_USAGE_KEY" 2>/dev/null || true
  rm -f "$KEY_TMP"
fi

LOCAL_KEY=$(cat "$SKILL_USAGE_KEY" 2>/dev/null) || exit 0
_is_64_hex "$LOCAL_KEY" || exit 0

# raw session id는 저장하지 않는다 — key‖id를 stdin으로 이어 SHA-256한 pseudonym만 기록
SESSION_KEY=$(printf '%s%s' "$LOCAL_KEY" "$SESSION_ID" | _sha256_stdin_hex) || exit 0
_is_64_hex "$SESSION_KEY" || exit 0

EVENT=$(jq -cn \
  --argjson ts "$(date -u +%s)" \
  --arg skill "$SKILL" \
  --arg session_key "$SESSION_KEY" \
  '{schema_version: 2, event_type: "skill_invocation", ts: $ts,
    runtime: "claude-main", skill: $skill, session_key: $session_key}' \
  2>/dev/null) || exit 0
[ -n "$EVENT" ] || exit 0

printf '%s\n' "$EVENT" >> "$SKILL_USAGE_LOG" 2>/dev/null || exit 0
chmod 600 "$SKILL_USAGE_LOG" 2>/dev/null || true

exit 0
