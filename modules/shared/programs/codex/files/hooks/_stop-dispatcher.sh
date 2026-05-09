#!/usr/bin/env bash
# Codex 0.124+ Stop hook single entry point.
#
# Codex는 같은 이벤트의 multiple command를 concurrent 실행하므로,
# Claude의 Stop hook 배열 ordering(record-last-stop first)을 보장하려면
# inline [[hooks.Stop]]에 dispatcher 1개만 등록하고 dispatcher가 sub-script를 순차 호출한다.
#
# Ordering rationale:
#   1. record-last-stop      — statusline TTL race 방어를 위해 first-write로 고정한다.
#   2. nrs-session-cleanup   — /tmp/nrs-state lock 즉시 해제. 동시 worktree의 새 nrs가
#                              lock 대기로 차단되는 회귀를 막는다.
#
# Claude 패턴에서는 nrs-session-cleanup.sh가 Stop과 SessionEnd 양쪽에서 호출되었으나,
# Codex는 SessionEnd 이벤트가 없으므로(0.124/0.125 미지원) Stop dispatcher에서만 호출한다.
# Stop이 main turn 종료를 cover하므로 lock cleanup 누락은 없다.
#
# 어느 sub-script가 실패해도 다음 sub-script는 계속 실행되며,
# dispatcher 자체는 항상 exit 0 (non-blocking).

set -u
INPUT=$(cat)

# Sub-script 경로를 dispatcher 시작 시점에 한 번 resolve한다.
# 다른 worktree의 nrs가 rebuild + nrs-relink로 ~/.codex/hooks/* symlink를 다른 worktree로
# relink할 수 있으므로, 실행 시점이 아닌 dispatcher 진입 시점에 경로를 고정해
# hook 사본 일관성을 구조적으로 보장한다.
HOOKS_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")

run_hook() {
  local name="$1"
  local path="$2"
  if ! printf '%s' "$INPUT" | "$path"; then
    printf 'codex stop dispatcher: %s exited non-zero (continuing)\n' "$name" >&2
  fi
}

run_hook record-last-stop      "$HOOKS_DIR/record-last-stop.sh"      # 1번: 타임스탬프 first-write
run_hook nrs-session-cleanup   "$HOOKS_DIR/nrs-session-cleanup.sh"   # 2번: nrs lock 즉시 해제

exit 0
