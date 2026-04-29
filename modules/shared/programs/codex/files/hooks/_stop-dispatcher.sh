#!/usr/bin/env bash
# Codex 0.124+ Stop hook single entry point.
#
# Codex는 같은 이벤트의 multiple command를 concurrent 실행하므로,
# Claude의 Stop hook 배열 ordering(record-last-stop first)을 보장하려면
# inline [[hooks.Stop]]에 dispatcher 1개만 등록하고 dispatcher가 sub-script를 순차 호출한다.
#
# Claude 패턴에서는 nrs-session-cleanup.sh가 Stop과 SessionEnd 양쪽에서 호출되었으나,
# Codex는 SessionEnd 이벤트가 없으므로(0.124/0.125 미지원) Stop dispatcher tail에서만 호출한다.
# Stop이 main turn 종료를 cover하므로 lock cleanup 누락은 없다.
#
# 어느 sub-script가 실패해도 다음 sub-script는 계속 실행되며,
# dispatcher 자체는 항상 exit 0 (non-blocking).

set -u
INPUT=$(cat)

run_hook() {
  local name="$1"
  local path="$2"
  if ! printf '%s' "$INPUT" | "$path"; then
    printf 'codex stop dispatcher: %s exited non-zero (continuing)\n' "$name" >&2
  fi
}

run_hook record-last-stop      "$HOME/.codex/hooks/record-last-stop.sh"      # 1번: 타임스탬프 first-write
run_hook stop-notification     "$HOME/.codex/hooks/stop-notification.sh"     # 2번: Pushover 알림
run_hook nrs-session-cleanup   "$HOME/.codex/hooks/nrs-session-cleanup.sh"   # 3번: nrs lock cleanup

exit 0
