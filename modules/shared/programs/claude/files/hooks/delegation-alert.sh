#!/usr/bin/env bash
# delegation-alert.sh — PreToolUse 직접 편집 횟수 warn-only alert (Claude Code).
# 목적: 메인 에이전트가 한 턴에 Edit/Write/NotebookEdit를 과도하게 직접 수행하면
# Codex executor 위임 검토를 안내한다.
# 정책: warn-only, fail-open — 모든 실패는 출력 없이 exit 0. permissionDecision 사용 금지.
# [WHY] 사용자 세션 로그 2525턴 실측에서 턴당 직접 편집 p90=5였고, 임계 5는
# 전체 턴의 10%에서만 발동해 경고 피로를 제한한다.
#
# 알려진 한계 (의도적, warn-only 신호이므로 수용):
# - PreToolUse는 도구 실행 "전"에 발화하므로, 같은 matcher의 다른 guard가 deny한
#   편집도 카운트에 포함된다. 실제 수정 없이 경고가 앞당겨질 수 있다. 성공한 편집만
#   세려면 PostToolUse로 옮겨야 하나, 그 경우 경고가 편집 이후에만 도달한다.
# - 카운터는 호출 횟수만 세고 대상 파일 경로는 보지 않는다. CLAUDE.md 결정표의
#   "1개 파일·2회 이하" 예외와는 축이 다른 누적 신호다 (결정표에 명시).

DELEGATION_ALERT_THRESHOLD=5
# [WHY] 상태는 (session_id, prompt_id) 턴 경계 판별에만 쓰이고 세션 종료 후 가치가 없다.
# 7일은 장기 미사용 세션의 잔재를 정리하기 위한 넉넉한 상한이며, 짧게 잡아도 기능에
# 영향이 없다 (파일이 없으면 카운터가 1부터 다시 시작한다).
DELEGATION_STATE_RETENTION_DAYS=7
# [WHY] lock은 read-modify-write 직렬화 전용이라 수명이 밀리초 단위다. 프로세스가
# SIGKILL 등으로 죽으면 EXIT trap이 돌지 않아 lock 디렉터리가 남고, 그러면 그 세션의
# 경고가 영구 비활성화된다. 이 나이를 넘은 lock은 죽은 프로세스의 잔재로 보고 회수한다.
DELEGATION_LOCK_STALE_MINUTES=10

command -v jq >/dev/null 2>&1 || exit 0

# session_id allowlist 검증 SSOT. session-init-icons.sh와 동일 패턴:
# 설치된 $HOME/.claude/lib 우선, repo fallback.
SESSION_STATE_LIB="${SESSION_STATE_LIB:-$HOME/.claude/lib/session-state.sh}"
if [ ! -f "$SESSION_STATE_LIB" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SESSION_STATE_LIB="$SCRIPT_DIR/../lib/session-state.sh"
fi
[ -f "$SESSION_STATE_LIB" ] || exit 0
# shellcheck source=../lib/session-state.sh disable=SC1091
. "$SESSION_STATE_LIB" 2>/dev/null || exit 0

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

is_safe_session_id "$SESSION_ID" || exit 0

STATE_DIR="${CLAUDE_DELEGATION_STATE_DIR:-$HOME/.claude/delegation-state}"
umask 077
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

# stale lock 회수 — 죽은 프로세스가 남긴 lock이 세션 경고를 영구 비활성화하지 않도록,
# lock 획득 시도 전에 수행한다.
find "$STATE_DIR" -maxdepth 1 -type d -name '*.lock' \
  -mmin "+$DELEGATION_LOCK_STALE_MINUTES" -exec rmdir {} + 2>/dev/null || true

STATE_FILE="$STATE_DIR/$SESSION_ID"
LOCK_DIR="${STATE_FILE}.lock"
# [WHY] 경합 시 대기하지 않는다. 경고 한 번을 놓치는 것이 카운터를 깨뜨리거나 도구
# 호출을 지연시키는 것보다 낫다 (warn-only 신호).
mkdir "$LOCK_DIR" 2>/dev/null || exit 0

TMP_FILE=""
# shellcheck disable=SC2329  # EXIT trap이 간접 호출하는 cleanup 함수다.
_delegation_alert_cleanup() {
  if [ -n "$TMP_FILE" ]; then
    rm -f "$TMP_FILE" 2>/dev/null || true
  fi
  rmdir "$LOCK_DIR" 2>/dev/null || true
}
trap _delegation_alert_cleanup EXIT INT TERM HUP

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

find "$STATE_DIR" -maxdepth 1 -type f -mtime "+$DELEGATION_STATE_RETENTION_DAYS" -delete 2>/dev/null || true

if [ "$COUNT" -ge "$DELEGATION_ALERT_THRESHOLD" ]; then
  MESSAGE="[delegation] 이번 턴의 직접 편집이 ${COUNT}회입니다 (경고 임계 ${DELEGATION_ALERT_THRESHOLD}회 = 실측 p90). 남은 작업을 Codex executor에 위임할 수 있는지 검토하세요 — 판단 기준은 ~/.claude/CLAUDE.md의 위임 결정표입니다."
  OUTPUT=$(jq -n --arg message "$MESSAGE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$message}}' 2>/dev/null) || exit 0
  printf '%s\n' "$OUTPUT"
fi

exit 0
