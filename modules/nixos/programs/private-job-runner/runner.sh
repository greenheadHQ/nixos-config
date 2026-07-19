# shellcheck shell=bash
# Generic private job 실행기 — systemd user template unit(private-job@<slug>)이 호출한다.
#
# 이 실행기는 작업의 내용을 알지 못한다: slug의 로컬 디렉터리에서 run.sh를 실행하고,
# 로그를 로컬 상태 디렉터리(0700/0600)에 남기며, 실패 시 generic Pushover 알림
# (opaque slug·run id·exit class만)을 보낸다. 작업 실체·시크릿·로그 내용은 전부
# 기기 로컬 소유 — 이 repo·store·journal 어디에도 나타나지 않는다.
#
# 알림 소유권: 같은 run에 대한 외부 알림은 이 실행기가 소유한다(실패 시 1회).
# 개별 작업 래퍼는 자체 외부 push 알림을 배선하지 않는 것이 규약이다 — 이중 알림을
# 만들지 않기 위해서다 (작업 내부 로그·상태 파일은 자유).
#
# 필요 env (unit이 주입): PUSHOVER_LIB, PUSHOVER_CRED_FILE
set -euo pipefail
umask 0077

JOBS_ROOT="$HOME/.local/private-jobs"
STATE_ROOT="$HOME/.local/state/private-jobs"
LOG_RETENTION=30 # run 단위 — 주1회 작업 기준 반년 이상의 진단 이력

# shellcheck source=/dev/null
source "$PUSHOVER_LIB"

notify_failure() { # slug run_id detail
  # generic 필드만 — 작업 stdout/stderr·경로 내용은 알림에 싣지 않는다.
  pushover_send "$PUSHOVER_CRED_FILE" "private job failed" "job=$1 run=$2 $3" 1 \
    || echo "WARNING: failure notification could not be sent" >&2
}

fail() { # slug run_id detail → 알림 후 failed unit
  echo "ERROR: $3" >&2
  notify_failure "$1" "$2" "$3"
  exit 1
}

main() {
  local slug="${1:-}"
  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

  # slug는 중립 문자열만 — 경로 탈출·특수문자를 unit 이름 단계에서 차단한다.
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    fail "invalid" "$run_id" "invalid slug"
  fi

  local job_dir="$JOBS_ROOT/$slug"
  local run_sh="$job_dir/run.sh"

  # 작업 디렉터리·스크립트 검증 — symlink escape, 타 owner, group/world-writable을
  # 거부한다: user unit이 실행할 코드는 본인 소유의 잠긴 파일이어야 한다.
  # 작업 부재도 quiet skip이 아니라 failed unit + 알림이다 (timer만 남고 작업이
  # 사라진 상태를 조용히 지나치면 스케줄이 죽은 것을 아무도 모른다).
  [ -d "$job_dir" ] || fail "$slug" "$run_id" "job directory missing"
  [ ! -L "$job_dir" ] || fail "$slug" "$run_id" "job directory is a symlink"
  [ -O "$job_dir" ] || fail "$slug" "$run_id" "job directory not owned by user"
  [ -f "$run_sh" ] || fail "$slug" "$run_id" "run.sh missing"
  [ ! -L "$run_sh" ] || fail "$slug" "$run_id" "run.sh is a symlink"
  [ -O "$run_sh" ] || fail "$slug" "$run_id" "run.sh not owned by user"
  [ -x "$run_sh" ] || fail "$slug" "$run_id" "run.sh not executable"
  local perms
  perms="$(stat -c %a "$run_sh")"
  if [ $((8#$perms & 8#022)) -ne 0 ]; then
    fail "$slug" "$run_id" "run.sh is group/world-writable"
  fi

  local log_dir="$STATE_ROOT/$slug/logs"
  mkdir -p "$log_dir"
  local log_file="$log_dir/$run_id.log"

  # raw stdout/stderr는 journal이 아니라 로컬 0600 파일로만 — unit/journal 표면에는
  # generic run id만 남는다.
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
    notify_failure "$slug" "$run_id" "exit=$rc"
    echo "run=$run_id job=$slug failed exit=$rc" >&2
    exit "$rc"
  fi
  echo "run=$run_id job=$slug ok"
}

main "$@"
