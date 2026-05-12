#!/usr/bin/env bash
# Claude Code SessionStart Hook - Status bar icons 초기화/복원
# stdin: JSON (session_id, transcript_path, source, cwd 등)
# stdout: JSON (hookSpecificOutput with additionalContext)
#
# 권한 정책:
# - umask 077 + chmod 700 디렉토리 / 600 파일. status JSON에는 Jira/Slack/Figma
#   private URL이, memo MD에는 세션 메모가 담길 수 있어 동일 사용자만 접근 가능.
#
# Lineage 복원 (cwd-encoded marker):
# - Stop hook(record-last-session.sh)이 매 턴 종료에 cwd-encoded 마커 파일에
#   last_session_id를 기록한다. /clear가 새 session_id를 발급해 STATE_FILE이
#   부재할 때, 같은 cwd 마커의 sid에서 sidecar/memo를 deep clone 복원한다.
# - 글로벌 mtime 기반 탐색은 cross-cwd 누수를 일으키므로 사용하지 않는다.
#
# Retention 정책: 없음. 아카이빙 우선 — sidecar/memo/marker는 자동 삭제하지
# 않는다. 사용자가 명시적으로 정리하거나 별도 도구로 처리.

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

# jq 필수 — 없으면 graceful skip
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# stdin JSON 읽기
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

if [ -z "$INPUT" ]; then
  exit 0
fi

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null) || true
TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null) || true
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null) || true
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || true

# session_id resolution — statusline.sh와 동일 fallback (D-8)
# stdin.session_id 우선, 비어있으면 transcript basename — 단, transcript는
# .jsonl 확장자 + $HOME/.claude/projects/ 하위에 있을 때만 fallback 허용
# (audit Edge Cases-3: non-jsonl/outside transcript basename으로 sidecar 생성 방지)
if [ -z "$SESSION_ID" ] && [ -n "$TRANSCRIPT" ]; then
  case "$TRANSCRIPT" in
    "$HOME"/.claude/projects/*/*.jsonl)
      SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
      ;;
  esac
fi
if ! is_safe_session_id "$SESSION_ID"; then
  # unsafe sid는 sidecar/marker 파일명에 사용할 수 없어 hook을 즉시 종료한다.
  # 운영자가 "왜 sidecar가 부재한가"를 추적할 수 있도록 진단 로그를 남긴다.
  session_hook_log session-start-unsafe "src=$SOURCE sid=$SESSION_ID cwd=$CWD"
  exit 0
fi

STATE_FILE="$SESSION_STATE_DIR/$SESSION_ID.json"
MEMO_FILE="$SESSION_MEMO_DIR/$SESSION_ID.md"

mkdir -p "$SESSION_STATE_DIR" "$SESSION_MEMO_DIR"
chmod 700 "$SESSION_STATE_DIR" "$SESSION_MEMO_DIR" 2>/dev/null || true

# 같은 cwd의 직전 sid sidecar를 deep clone 복원.
#
# Invariant (정확히):
# - return 0: STATE_FILE은 valid JSON, MEMO_FILE은 last_memo의 정확한 사본 또는
#   정상 빈 파일(last_memo 부재 시). 둘 다 자기 sid 경로에 있고 호출부는 그대로
#   사용할 수 있다.
# - return 1:
#   · 쓰기 시작 전 실패(marker_path_for_cwd 실패, 마커 부재, unsafe last_sid,
#     last_state 부재, last_sid==SESSION_ID): STATE_FILE/MEMO_FILE은 함수 진입
#     이전 상태 그대로 — 손대지 않는다.
#   · 복사/생성 시작 후 실패(cp/truncate/jq 실패): 부분 쓰기 흔적을 명시적
#     rm -f으로 제거한 뒤 return 1. 호출부 fallback(`echo '{}' > STATE_FILE`)이
#     깨끗하게 덮을 수 있다.
# - `if ! restore_from_cwd_lineage` 호출 컨텍스트에서 set -e가 함수 내부에서
#   비활성화되므로(POSIX/bash 동작) 매 단계의 실패를 명시적으로 처리한다.
#
# 보안 정책:
# - last_state JSON의 .memo.path는 set-icons 스킬을 통해 LLM이 임의로 설정 가능한
#   user-controlled 값이라 신뢰하지 않는다. memo 파일 경로는 sid에서 결정적으로
#   파생되므로 last_sid 기반으로 강제 재구성한다(`SESSION_MEMO_DIR/${last_sid}.md`).
#   이로써 `.memo.path = "$HOME/.ssh/known_hosts"` 류 임의 user-readable 파일을
#   새 MEMO_FILE로 cp해 LLM context로 누출시키는 표면을 제거한다.
restore_from_cwd_lineage() {
  [ -z "$CWD" ] && return 1
  local marker last_sid last_state last_memo
  marker=$(marker_path_for_cwd "$CWD") || return 1
  [ -f "$marker" ] || return 1
  last_sid=$(head -1 "$marker" 2>/dev/null | tr -d '[:space:]') || return 1
  is_safe_session_id "$last_sid" || return 1
  [ "$last_sid" = "$SESSION_ID" ] && return 1
  last_state="$SESSION_STATE_DIR/${last_sid}.json"
  [ -f "$last_state" ] || return 1

  # memo 경로는 sid로 결정적 재구성 — last_state의 .memo.path 신뢰 안 함.
  last_memo="$SESSION_MEMO_DIR/${last_sid}.md"
  if [ -f "$last_memo" ]; then
    # cp 실패(rofs/quota/permission)도 명시적 처리. 부분 쓰기 흔적을 정리하고
    # return 1으로 호출부 fallback에 위임.
    if ! cp "$last_memo" "$MEMO_FILE" 2>/dev/null; then
      rm -f "$MEMO_FILE"
      return 1
    fi
  elif ! : > "$MEMO_FILE" 2>/dev/null; then
    rm -f "$MEMO_FILE"
    return 1
  fi
  # status JSON 복사 + .memo.path를 새 sid 경로로 rewrite. jq 실패는 명시적
  # 처리 — 부분 쓰기 STATE_FILE과 새로 만든 MEMO_FILE을 모두 제거하고 return 1.
  if ! jq --arg new_memo "$MEMO_FILE" \
       'if .memo then .memo.path = $new_memo else . end' \
       "$last_state" > "$STATE_FILE" 2>/dev/null; then
    rm -f "$STATE_FILE" "$MEMO_FILE"
    return 1
  fi
  return 0
}

# 모든 source(unknown 포함)에 대해 진단 로그를 남긴다 — 디버그 활성 시
# unknown source 라벨의 실측 채집이 본 인프라의 본연 목적.
session_hook_log session-start "src=$SOURCE sid=$SESSION_ID cwd=$CWD state_exists=$([ -f "$STATE_FILE" ] && echo y || echo n)"

case "$SOURCE" in
  startup)
    # 새 세션 startup은 빈 sidecar로 시작하되 cwd 마커는 건드리지 않는다.
    # marker 관리는 전적으로 Stop hook(record-last-session.sh)의 책임이며,
    # 결과적으로 같은 cwd에서 동시에 두 인스턴스가 떠 있어도 startup이 다른
    # 인스턴스의 active marker를 덮어쓰지 않는다.
    #
    # STATE_FILE이 이미 존재하면 보존(동일 sid로 startup이 재발화되는 케이스
    # 방어). 부재면 빈 객체로 시작. lineage 복원은 clear|resume|compact 분기에서만
    # 수행되며, 사용자 의도("아카이빙 우선")에 따라 같은 cwd 재방문 시 직전
    # 세션의 jira/slack/figma/memo가 /clear 시점에 자동 복원된다.
    if [ ! -f "$STATE_FILE" ]; then
      echo '{}' > "$STATE_FILE"
      [ ! -f "$MEMO_FILE" ] && : > "$MEMO_FILE"
    fi
    [ ! -f "$MEMO_FILE" ] && : > "$MEMO_FILE"
    chmod 600 "$STATE_FILE" "$MEMO_FILE" 2>/dev/null || true

    if [ -f "$STATE_FILE" ]; then
      ACTIVE_ICONS=$(jq -r 'keys | join(", ")' "$STATE_FILE" 2>/dev/null) || ACTIVE_ICONS=""
      [ -z "$ACTIVE_ICONS" ] && ACTIVE_ICONS="없음"
    else
      ACTIVE_ICONS="없음"
    fi

    CONTEXT="Status bar icons 초기화됨.
상태 파일: $STATE_FILE
메모: $MEMO_FILE
활성 아이콘: $ACTIVE_ICONS
링크 설정: /set-icons 스킬로 Jira, Slack, Figma 링크를 추가할 수 있습니다."
    ;;

  clear|resume|compact)
    # /resume과 /compact는 같은 session_id를 유지하므로 STATE_FILE이 보통 존재
    # → 그대로 사용. /clear는 새 session_id를 발급하여 STATE_FILE이 부재 →
    # 같은 cwd 마커의 직전 sid에서 lineage 복원. 다른 cwd 마커와는 자연 격리됨.
    if [ ! -f "$STATE_FILE" ]; then
      if ! restore_from_cwd_lineage; then
        echo '{}' > "$STATE_FILE"
        [ ! -f "$MEMO_FILE" ] && : > "$MEMO_FILE"
      fi
      chmod 600 "$STATE_FILE" "$MEMO_FILE" 2>/dev/null || true
    fi

    ACTIVE_ICONS="없음"
    if [ -f "$STATE_FILE" ]; then
      ACTIVE_ICONS=$(jq -r 'keys | join(", ")' "$STATE_FILE" 2>/dev/null) || ACTIVE_ICONS="없음"
      [ -z "$ACTIVE_ICONS" ] && ACTIVE_ICONS="없음"
    fi

    CONTEXT="Status icons 복원됨.
상태 파일: $STATE_FILE
메모: $MEMO_FILE
활성 아이콘: $ACTIVE_ICONS"
    ;;

  *)
    # 알 수 없는 source — skip
    exit 0
    ;;
esac

# additionalContext 출력
jq -n --arg ctx "$CONTEXT" \
  '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'

exit 0
