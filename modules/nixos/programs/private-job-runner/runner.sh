# shellcheck shell=bash
# Generic private job 실행기 — systemd user template unit(private-job@<slug>)이 호출한다.
#
# 이 실행기는 작업의 내용을 알지 못한다: slug의 로컬 디렉터리에서 run.sh를 실행하고
# 로그를 로컬 상태 디렉터리(0700/0600)에 남긴다. 작업 실체·시크릿·로그 내용은 전부
# 기기 로컬 소유 — repo·store·journal 어디에도 나타나지 않는다.
#
# 실패 알림은 이 스크립트가 아니라 unit의 ExecStopPost(private-job-notify)가
# 소유한다 — 여기서 알림을 보내면 systemd timeout처럼 이 스크립트가 강제 종료되는
# 실패 경로에서 알림이 증발하고, 두 곳이 보내면 같은 run에 이중 알림이 된다.
#
# 필요 env (unit이 주입): PRIVATE_JOB_LIB, PRIVATE_JOBS_DEFINITIONS, PRIVATE_JOBS_STATE
set -euo pipefail
umask 0077

# shellcheck source=/dev/null
source "$PRIVATE_JOB_LIB"

JOBS_ROOT="$HOME/$PRIVATE_JOBS_DEFINITIONS"
STATE_ROOT="$HOME/$PRIVATE_JOBS_STATE"
LOG_RETENTION=30 # run 단위 — 주1회 작업 기준 반년 이상의 진단 이력

fail() { # detail → failed unit (알림은 ExecStopPost 소유)
  echo "ERROR: $1" >&2
  exit 1
}

assert_safe() { # path label type denymask
  local violation
  violation="$(path_violation "$1" "$2" "$3" "$4")"
  [ -z "$violation" ] || fail "$violation"
}

main() {
  local slug="${1:-}"
  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

  # slug는 중립 문자열만 — 경로 탈출·특수문자를 unit 이름 단계에서 차단한다.
  is_valid_slug "$slug" || fail "invalid slug"

  local job_dir="$JOBS_ROOT/$slug"
  local run_sh="$job_dir/run.sh"

  # 작업 부재·검증 실패도 quiet skip이 아니라 failed unit이다 (timer만 남고
  # 작업이 사라진 상태를 조용히 지나치면 스케줄이 죽은 것을 아무도 모른다).
  assert_safe "$JOBS_ROOT" "jobs root" d 022
  assert_safe "$job_dir" "job directory" d 022
  assert_safe "$run_sh" "run.sh" f 022
  [ -x "$run_sh" ] || fail "run.sh not executable"

  # raw 로그가 흐르는 상태 사슬은 0700/0600 계약(077 거부)으로 검증한다 — umask는
  # 새 객체에만 적용되므로 기존의 느슨한 모드·symlink(상위 포함)는 여기서
  # fail-closed로 드러낸다 (계약 밖 경로로의 로그 리다이렉트 차단).
  local log_dir="$STATE_ROOT/$slug/logs"
  mkdir -p "$log_dir"
  assert_safe "$STATE_ROOT" "state root" d 077
  assert_safe "$STATE_ROOT/$slug" "state directory" d 077
  assert_safe "$log_dir" "log directory" d 077
  local log_file="$log_dir/$run_id.log"
  # run id는 유니크(UTC초+pid)다 — 같은 이름이 이미 있으면 이상 상태이고, 기존
  # 파일·symlink 위에 열면 느슨한 모드·링크 대상을 그대로 물려받는다.
  [ ! -e "$log_file" ] && [ ! -L "$log_file" ] || fail "log file path already occupied"

  # raw stdout/stderr는 journal이 아니라 로컬 0600 파일로만 — unit/journal 표면에는
  # generic 식별자(run id·중립 slug)만 남는다.
  echo "run=$run_id job=$slug start"
  local rc=0
  "$run_sh" >"$log_file" 2>&1 || rc=$?

  # bounded retention — 오래된 로그를 지워 로컬 상태가 무한 성장하지 않게 한다.
  # (파일명은 이 실행기가 만든 run id뿐이라 공백·특수문자가 없다 — ls 파싱 안전)
  # shellcheck disable=SC2012
  ls -1t "$log_dir" | tail -n +"$((LOG_RETENTION + 1))" | while IFS= read -r f; do
    rm -f "$log_dir/$f"
  done

  if [ "$rc" -ne 0 ]; then
    echo "run=$run_id job=$slug failed exit=$rc" >&2
    exit "$rc"
  fi
  echo "run=$run_id job=$slug ok"
}

main "$@"
