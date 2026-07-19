# shellcheck shell=bash
# private-job@ unit의 ExecStopPost — run 실패 알림의 단일 소유자.
#
# runner 내부에서 알림을 보내면 systemd timeout·강제 종료 경로에서 알림이 증발한다.
# ExecStopPost는 시작 timeout을 포함한 모든 종료 뒤에 실행되고 $SERVICE_RESULT/
# $EXIT_STATUS를 받으므로, 여기서만 판정해 같은 run에 정확히 1회 보낸다.
# 알림 내용은 generic 필드(slug·invocation·result·exit)만 — 작업 실체는 싣지 않는다.
#
# 필요 env (unit이 주입): PRIVATE_JOB_LIB, PUSHOVER_LIB, PUSHOVER_CRED_FILE
# systemd 제공 env: SERVICE_RESULT, EXIT_CODE, EXIT_STATUS, INVOCATION_ID
set -euo pipefail

# shellcheck source=/dev/null
source "$PRIVATE_JOB_LIB"
# shellcheck source=/dev/null
source "$PUSHOVER_LIB"

slug="${1:-unknown}"
kind="${2:-job}" # job | sync — exit-code 해석은 호출자 종류별로 분리된 계약이다
result="${SERVICE_RESULT:-unknown}"

if [ "$result" = "success" ]; then
  exit 0
fi

# 실행기가 거부한 invalid instance 이름도 외부 채널에는 싣지 않는다 — 이름 자체가
# 작업 실체를 담을 수 있다 (검증은 runner와 같은 lib 계약).
is_valid_slug "$slug" || slug="withheld"

# sync가 스스로 판정·통지한 정의 오류(SYNC_HANDLED_EXIT 규약 — 값의 소유는
# default.nix)는 다시 보내지 않는다. 이 해석은 sync 호출에만 적용된다 — 일반
# 작업의 같은 exit 값은 평범한 실패이며 알림 대상이다.
if [ "$kind" = "sync" ] && [ "${EXIT_STATUS:-}" = "${SYNC_HANDLED_EXIT:?}" ]; then
  exit 0
fi

pushover_send "$PUSHOVER_CRED_FILE" "private job failed" \
  "job=$slug run=${INVOCATION_ID:0:8} result=$result exit=${EXIT_STATUS:-?}" 1 \
  || echo "WARNING: failure notification could not be sent" >&2
