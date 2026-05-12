#!/usr/bin/env bash
# Claude Code Stop Hook - cwd 단위 last-session 마커 기록
#
# /clear는 새 session_id를 발급하지만 Claude Code의 SessionStart hook stdin
# schema에는 previous_session_id 류 필드가 없다. 그래서 SessionStart 시점에는
# 직전 sid를 알 수 없다. Stop hook을 매 turn 종료에 발동시켜 cwd-encoded
# 마커 파일에 last_session_id를 누적 갱신해두면, /clear 직후 SessionStart hook이
# "같은 cwd의 직전 sid"를 정확히 식별할 수 있다.
#
# cwd 단위 격리이므로 동시 진행 중인 다른 워크트리/프로젝트 세션과 마커가
# 섞이지 않는다.

set -euo pipefail
umask 077

# 공유 helper. marker 규약·session_id allowlist·debug 로그가 SSOT.
# pinning-guard.sh와 동일 패턴: 설치된 $HOME/.claude/lib 우선, repo fallback.
SESSION_STATE_LIB="${SESSION_STATE_LIB:-$HOME/.claude/lib/session-state.sh}"
if [ ! -f "$SESSION_STATE_LIB" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  SESSION_STATE_LIB="$SCRIPT_DIR/../lib/session-state.sh"
fi
# shellcheck source=../lib/session-state.sh disable=SC1091
. "$SESSION_STATE_LIB"

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

if [ -z "$INPUT" ]; then
  exit 0
fi

# subagent 내부 Stop은 무시 (메인 턴만 추적)
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null) || true
[ -n "$AGENT_ID" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true

if [ -z "$SESSION_ID" ] || [ -z "$CWD" ]; then
  exit 0
fi

is_safe_session_id "$SESSION_ID" || exit 0

mkdir -p "$SESSION_STATE_DIR"
chmod 700 "$SESSION_STATE_DIR" 2>/dev/null || true

MARKER_FILE=$(marker_path_for_cwd "$CWD") || exit 0

# atomic write — 같은 디렉토리의 mktemp로 cross-device rename 회피.
# mktemp template은 retention cleanup pattern과 동일 prefix를 공유하므로
# 정리 누락 위험 없음.
tmp=$(mktemp "$SESSION_STATE_DIR/${SESSION_MARKER_PREFIX}XXXXXX")
printf '%s\n' "$SESSION_ID" > "$tmp"
mv "$tmp" "$MARKER_FILE"
chmod 600 "$MARKER_FILE" 2>/dev/null || true

session_hook_log stop "sid=$SESSION_ID cwd=$CWD marker=$MARKER_FILE"

exit 0
