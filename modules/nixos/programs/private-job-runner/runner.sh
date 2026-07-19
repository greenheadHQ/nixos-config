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
# 필요 env (unit이 주입): PRIVATE_JOBS_DEFINITIONS, PRIVATE_JOBS_STATE (HOME 상대)
set -euo pipefail
umask 0077

JOBS_ROOT="$HOME/$PRIVATE_JOBS_DEFINITIONS"
STATE_ROOT="$HOME/$PRIVATE_JOBS_STATE"
LOG_RETENTION=30 # run 단위 — 주1회 작업 기준 반년 이상의 진단 이력

fail() { # detail → failed unit (알림은 ExecStopPost 소유)
  echo "ERROR: $1" >&2
  exit 1
}

# 경로가 "본인 소유·비 symlink·group/world-write 금지"인지 — 실행할 코드에
# 닿는 모든 구성요소에 적용한다. 최종 파일만 검사하면 상위 디렉터리 교체·symlink로
# 우회된다. 검증~실행 사이의 좁은 TOCTOU 창은 남는다: 이 기기의 위협 모델은
# "다른 로컬 계정이 없는 단일 사용자 호스트"이고, 이 검증의 목적은 실수로 느슨한
# 권한·링크가 생긴 상태를 fail-closed로 드러내는 것이다.
assert_safe_path() { # path label
  local path="$1" label="$2" perms
  [ -e "$path" ] || fail "$label missing"
  [ ! -L "$path" ] || fail "$label is a symlink"
  [ -O "$path" ] || fail "$label not owned by user"
  perms="$(stat -c %a "$path")"
  if [ $((8#$perms & 8#022)) -ne 0 ]; then
    fail "$label is group/world-writable"
  fi
}

main() {
  local slug="${1:-}"
  local run_id
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"

  # slug는 중립 문자열만 — 경로 탈출·특수문자를 unit 이름 단계에서 차단한다.
  if ! [[ "$slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    fail "invalid slug"
  fi

  local job_dir="$JOBS_ROOT/$slug"
  local run_sh="$job_dir/run.sh"

  # 작업 부재·검증 실패도 quiet skip이 아니라 failed unit이다 (timer만 남고
  # 작업이 사라진 상태를 조용히 지나치면 스케줄이 죽은 것을 아무도 모른다).
  assert_safe_path "$JOBS_ROOT" "jobs root"
  assert_safe_path "$job_dir" "job directory"
  assert_safe_path "$run_sh" "run.sh"
  [ -x "$run_sh" ] || fail "run.sh not executable"
  # canonical 경로가 jobs root 아래인지 — 위 구성요소 검사와 함께 상위 symlink
  # 우회를 이중으로 막는다.
  [ "$(realpath "$run_sh")" = "$run_sh" ] || fail "run.sh resolves outside its declared path"

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
    echo "run=$run_id job=$slug failed exit=$rc" >&2
    exit "$rc"
  fi
  echo "run=$run_id job=$slug ok"
}

main "$@"
