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
# 스킬명 문법 검증 — 제어문자·개행·과대 길이가 v2 이벤트와 report 출력을 오염시키지 않게 한다.
case "$SKILL" in
  *[!A-Za-z0-9._:-]*) exit 0 ;;
esac
[ "${#SKILL}" -le 128 ] || exit 0

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

# GNU/BSD stat 겸용 파일 mode 조회 (예: "600").
_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
}

# 기존 파일이 owner-only 계약(regular file·비심링크·소유자·mode 600)을 만족하는지 검증.
# mode만 어긋나면 600 교정을 시도하고, 교정 불가·심링크·타소유는 이벤트를 포기한다
# (fail-closed — umask는 신규 inode에만 적용되므로 기존 파일은 매 실행 검증해야 한다).
_ensure_owner_only_file() {
  [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || return 1
  # macOS ACL은 POSIX mode와 별개 권한 축이라 %a/%Lp 검사에 잡히지 않는다 —
  # owner-only 보장 전에 제거한다 (chmod -N은 ACL이 없어도 성공, 실패 시 fail-closed).
  if [ "$(uname)" = "Darwin" ]; then
    /bin/chmod -N "$1" 2>/dev/null || return 1
  fi
  case "$(_file_mode "$1")" in
    600) return 0 ;;
  esac
  chmod 600 "$1" 2>/dev/null || return 1
  [ "$(_file_mode "$1")" = "600" ]
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

# 읽기 전 trust boundary 검증 — 심링크 치환·권한 완화된 기존 key는 사용하지 않는다.
_ensure_owner_only_file "$SKILL_USAGE_KEY" || exit 0
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

# append 전에 0600으로 미리 생성해 umask worst-case의 사후 chmod 의존을 제거하고,
# 기존 파일이면 owner-only 계약을 검증한다 (실패 시 이벤트 포기).
if [ ! -e "$SKILL_USAGE_LOG" ] && [ ! -L "$SKILL_USAGE_LOG" ]; then
  ( umask 077; : >> "$SKILL_USAGE_LOG" ) 2>/dev/null || exit 0
fi
_ensure_owner_only_file "$SKILL_USAGE_LOG" || exit 0
printf '%s\n' "$EVENT" >> "$SKILL_USAGE_LOG" 2>/dev/null || exit 0

exit 0
