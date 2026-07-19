# shellcheck shell=bash
# private-job@ unit의 ExecStopPost — run 실패 알림의 단일 소유자.
#
# runner 내부에서 알림을 보내면 systemd timeout·강제 종료 경로에서 알림이 증발한다.
# ExecStopPost는 시작 timeout을 포함한 모든 종료 뒤에 실행되고 $SERVICE_RESULT/
# $EXIT_STATUS를 받으므로, 여기서만 판정해 같은 run에 정확히 1회 보낸다.
# 알림 내용은 generic 필드(slug·invocation·result·exit)만 — 작업 실체는 싣지 않는다.
#
# 필요 env (unit이 주입): PUSHOVER_LIB, PUSHOVER_CRED_FILE
# systemd 제공 env: SERVICE_RESULT, EXIT_CODE, EXIT_STATUS, INVOCATION_ID
set -euo pipefail

# shellcheck source=/dev/null
source "$PUSHOVER_LIB"

slug="${1:-unknown}"
result="${SERVICE_RESULT:-unknown}"

if [ "$result" = "success" ]; then
  exit 0
fi

pushover_send "$PUSHOVER_CRED_FILE" "private job failed" \
  "job=$slug run=${INVOCATION_ID:0:8} result=$result exit=${EXIT_STATUS:-?}" 1 \
  || echo "WARNING: failure notification could not be sent" >&2
