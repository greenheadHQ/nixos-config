#!/usr/bin/env bash
# delegation-alert.sh — PreToolUse 직접 편집 횟수 warn-only alert (Claude Code).
# 목적: 메인 에이전트가 한 턴에 Edit/Write/NotebookEdit를 과도하게 직접 수행하면
# Codex executor 위임 검토를 안내한다.
# 정책: warn-only, fail-open — 모든 실패는 출력 없이 exit 0. permissionDecision 사용 금지.
# [WHY] 사용자 세션 로그 2525턴 실측에서 턴당 직접 편집 p90=5였고, 임계 5는
# 전체 턴의 10%에서만 발동해 경고 피로를 제한한다.

DEFAULT_DELEGATION_ALERT_THRESHOLD=5

command -v jq >/dev/null 2>&1 || exit 0

HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
[ -f "$HOOK_RUNTIME_LIB" ] || exit 0
# shellcheck source=../lib/hook-runtime.sh
# shellcheck disable=SC1091  # 환경변수로 주입되는 배포 경로를 동적 source한다.
. "$HOOK_RUNTIME_LIB" 2>/dev/null || exit 0

INPUT=$(cat) || exit 0

# log-skill.sh와 동일하게 서브에이전트 내부 호출은 제외한다.
AGENT_ID=$(printf '%s' "$INPUT" | hook_parse_json_path '.agent_id // empty')
[ -n "$AGENT_ID" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | hook_parse_tool_name)
case "$TOOL_NAME" in
  Edit | Write | NotebookEdit) ;;
  *) exit 0 ;;
esac

SESSION_ID=$(printf '%s' "$INPUT" | hook_parse_session_id)
PROMPT_ID=$(printf '%s' "$INPUT" | hook_parse_json_path '.prompt_id // empty')
[ -n "$SESSION_ID" ] && [ -n "$PROMPT_ID" ] || exit 0

# 정책 출처: lib/session-state.sh의 is_safe_session_id.
# 별도 lib 의존 없이 allowlist `[A-Za-z0-9._-]`와 `..` 차단을 inline 유지한다.
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]* | *..*) exit 0 ;;
esac

DELEGATION_ALERT_THRESHOLD="${CLAUDE_DELEGATION_ALERT_THRESHOLD:-$DEFAULT_DELEGATION_ALERT_THRESHOLD}"
case "$DELEGATION_ALERT_THRESHOLD" in
  *[!0-9]* | "") DELEGATION_ALERT_THRESHOLD="$DEFAULT_DELEGATION_ALERT_THRESHOLD" ;;
  *)
    [ "$DELEGATION_ALERT_THRESHOLD" -gt 0 ] 2>/dev/null ||
      DELEGATION_ALERT_THRESHOLD="$DEFAULT_DELEGATION_ALERT_THRESHOLD"
    ;;
esac

STATE_DIR="${CLAUDE_DELEGATION_STATE_DIR:-$HOME/.claude/delegation-state}"
umask 077
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

STATE_FILE="$STATE_DIR/$SESSION_ID"
LOCK_DIR="${STATE_FILE}.lock"
mkdir "$LOCK_DIR" 2>/dev/null || exit 0

TMP_FILE=""
# shellcheck disable=SC2329  # EXIT trap이 간접 호출하는 cleanup 함수다.
_delegation_alert_cleanup() {
  if [ -n "$TMP_FILE" ]; then
    rm -f "$TMP_FILE" 2>/dev/null || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap _delegation_alert_cleanup EXIT

COUNT=1
if [ -f "$STATE_FILE" ]; then
  STORED_PROMPT=""
  STORED_COUNT=""
  EXTRA=""
  if IFS=' ' read -r STORED_PROMPT STORED_COUNT EXTRA < "$STATE_FILE" &&
    [ -n "$STORED_PROMPT" ] &&
    [ -z "$EXTRA" ] &&
    [ "$(awk 'END { print NR }' "$STATE_FILE" 2>/dev/null)" = "1" ]; then
    case "$STORED_COUNT" in
      *[!0-9]* | "") ;;
      *)
        if [ "$STORED_COUNT" -gt 0 ] 2>/dev/null &&
          [ "$STORED_PROMPT" = "$PROMPT_ID" ]; then
          COUNT=$((10#$STORED_COUNT + 1))
        fi
        ;;
    esac
  fi
fi

TMP_FILE=$(mktemp "${STATE_FILE}.tmp.XXXXXX" 2>/dev/null) || exit 0
printf '%s %s\n' "$PROMPT_ID" "$COUNT" > "$TMP_FILE" 2>/dev/null || exit 0
mv "$TMP_FILE" "$STATE_FILE" 2>/dev/null || exit 0
TMP_FILE=""

find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true

if [ "$COUNT" -ge "$DELEGATION_ALERT_THRESHOLD" ]; then
  # [WHY] 임계값은 CLAUDE_DELEGATION_ALERT_THRESHOLD로 덮어쓸 수 있으므로 메시지에도
  # 리터럴이 아닌 실제 적용값을 넣는다. 기본값 5의 근거는 파일 상단 주석 참조.
  MESSAGE="[delegation] 이번 턴의 직접 편집이 ${COUNT}회입니다 (경고 임계 ${DELEGATION_ALERT_THRESHOLD}회). 남은 작업을 Codex executor에 위임할 수 있는지 검토하세요 — 판단 기준은 ~/.claude/CLAUDE.md의 \"위임\" 절입니다."
  OUTPUT=$(jq -n --arg message "$MESSAGE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$message}}' 2>/dev/null) || exit 0
  printf '%s\n' "$OUTPUT"
fi

exit 0
