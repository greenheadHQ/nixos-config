#!/usr/bin/env bash
# delegation-alert.sh — PreToolUse 직접 편집 횟수 warn-only alert (Claude Code).
# 목적: 메인 에이전트가 한 턴에 Edit/Write/NotebookEdit를 과도하게 직접 수행하면
# Codex executor 위임 검토를 안내한다.
# 정책: warn-only, fail-open — 모든 실패는 출력 없이 exit 0. permissionDecision 사용 금지.
# [WHY] 사용자 세션 로그 2525턴 실측에서 턴당 직접 편집 p90=5였고, 임계 5는
# 전체 턴의 10%에서만 발동해 경고 피로를 제한한다.
#
# 동시성 정책 — lock을 쓰지 않는다.
# [WHY] 상태 갱신은 same-dir 임시 파일 + atomic rename만 사용한다. 병렬 편집 호출이
# 겹치면 read-modify-write 경합으로 카운트가 하나 덜 세어져 경고가 한 턴 늦을 수 있고,
# 그 손실은 warn-only 보조 신호에서 수용 가능하다. 반대로 lock을 두면 stale lock 회수,
# 소유권 토큰, 사망 프로세스 판정이 연쇄로 필요해지고 회수 로직 자체가 새 경쟁 조건을
# 만든다 (DA for_pr 라운드 1→2에서 실제로 그 경로를 밟았다).
#
# 알려진 한계 (의도적, warn-only 신호이므로 수용):
# - PreToolUse는 도구 실행 "전"에 발화하므로, 같은 matcher의 다른 guard가 deny한
#   편집도 카운트에 포함된다. 실제 수정 없이 경고가 앞당겨질 수 있다.
# - 카운터는 호출 횟수만 세고 대상 파일 경로는 보지 않는다. CLAUDE.md 위임 결정표의
#   "1개 파일·2회 이하" 예외와는 축이 다른 누적 신호다 (결정표에 명시).

DELEGATION_ALERT_THRESHOLD=5
# [WHY] 상태는 (session_id, prompt_id) 턴 경계 판별에만 쓰이고 세션 종료 후 가치가 없다.
# 이 값은 "정리 대상이 되는 최소 age(일)"이며 보존 상한이 아니다 — `find -mtime +N`은
# 완성된 일수 기준이라 실제로는 N+1일째부터 매치하고, 정리는 훅이 다시 실행될 때만
# 수행되는 기회성 작업이다. 짧게 잡아도 기능에는 영향이 없다 (상태 파일이 없으면
# 카운터가 1부터 다시 시작한다).
DELEGATION_STATE_MIN_CLEANUP_AGE_DAYS=7

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
STATE_FILE="$STATE_DIR/$SESSION_ID"

TMP_FILE=""
# shellcheck disable=SC2329  # EXIT trap이 간접 호출하는 cleanup 함수다.
_delegation_alert_cleanup() {
  if [ -n "$TMP_FILE" ]; then
    rm -f "$TMP_FILE" 2>/dev/null || true
  fi
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

find "$STATE_DIR" -maxdepth 1 -type f -mtime "+$DELEGATION_STATE_MIN_CLEANUP_AGE_DAYS" -delete 2>/dev/null || true

# [WHY] `-eq`로 임계 도달 시 한 번만 경고한다. `-ge`면 6·7·8회째에도 매번 주입되어
# 같은 턴에서 경고 피로를 만든다. 신호는 한 번이면 충분하다.
if [ "$COUNT" -eq "$DELEGATION_ALERT_THRESHOLD" ]; then
  MESSAGE="[delegation] 이번 턴의 직접 편집이 ${COUNT}회입니다 (경고 임계 ${DELEGATION_ALERT_THRESHOLD}회 = 실측 p90). 남은 작업을 Codex executor에 위임할 수 있는지 검토하세요 — 판단 기준은 ~/.claude/CLAUDE.md의 위임 결정표입니다."
  OUTPUT=$(jq -n --arg message "$MESSAGE" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",additionalContext:$message}}' 2>/dev/null) || exit 0
  printf '%s\n' "$OUTPUT"
fi

exit 0
