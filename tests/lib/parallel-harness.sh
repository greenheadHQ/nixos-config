# tests/lib/parallel-harness.sh — run_test 를 job-pool 병렬 실행으로 교체하는 공유 하네스.
# shellcheck shell=bash
#
# aggregator(shell-script-tests.sh / test-codex-hook-fixtures.sh)가 자신의 run_test 정의 "뒤"에
# 이 파일을 source 하여 run_test 를 override 하고, 모든 run_test 등록 후 `parallel_barrier` 로
# 완료를 수집한다. 각 테스트는 독립 sandbox(new_sandbox / new_hook_sandbox)라 병렬 격리가 성립한다
# (실측: shell-script-tests 순차 112s → 병렬 35s, 실패 0 동일 — I/O 바운드라 CPU 배수보단 낮다).
#
# 동시성: TEST_JOBS(기본 CPU 코어수). TEST_JOBS=1 이면 순차(즉시 출력)로 폴백하여 디버깅/결정성을
#   보장한다 — 이 경우 run_test 는 기존과 동일하게 즉시 실행하고 첫 실패에서 set -e 로 중단한다.
# 출력: 병렬 모드는 각 테스트의 stdout/stderr 를 per-test 파일에 모으고, barrier 에서 등록 순서대로
#   일괄 출력한다(결정적). 통과는 "==> name", 실패는 그 출력 전체를 들여쓰기해 함께 보여준다.
#   성공한 테스트 안의 canonical `SKIP:` marker는 상위 통합 runner가 coverage gap을 집계할 수 있게
#   그대로 전파한다. 플랫폼상 적용 불가능한 `N/A:`도 관찰 가능하게 전파하되 SKIP과 구분한다.
# 격리: 각 job 은 독립 subshell 이라 실패가 다른 job 에 전파되지 않으며, 실패가 하나라도 있으면
#   parallel_barrier 가 non-zero 로 종료한다(aggregator 의 set -e 가 이를 최종 실패로 전파).
# 분류: run_test 를 aggregator 최상위(if·&&·|| 조건 문맥 밖)에서 호출하면 테스트 본문은 set -euo
#   pipefail 을 그대로 받아 순차 모드와 같은 지점에서 실패한다 — 중간 명령·파이프라인·assertion
#   실패 뒤의 성공 명령으로 PASS 가 되지 않는다(#1363). 조건 문맥에서 호출하면 순차·병렬 모두
#   set -e 가 무시된다. 결과·출력 파일을 남기지 못하고 죽은 job 도 FAIL 로 집계하고, 나머지 결과와
#   요약은 그대로 출력한다.

# 동시성 결정 (TEST_JOBS override > nproc > sysctl > 4)
_ph_detect_jobs() {
  if [ -n "${TEST_JOBS:-}" ]; then printf '%s' "$TEST_JOBS"; return 0; fi
  { command -v nproc >/dev/null 2>&1 && nproc; } 2>/dev/null \
    || sysctl -n hw.ncpu 2>/dev/null \
    || echo 4
}
_PH_JOBS="$(_ph_detect_jobs)"
# wait -n 은 bash 4.3+ 기능이다. 그 미만(예: macOS 기본 /bin/bash 3.2)에서는 아래 job-pool 상한
# 게이트의 `wait -n`이 매번 `invalid option`으로 실패해 게이트가 무력화되고 unbounded 병렬이 된다.
# lefthook 훅은 push 셸의 PATH(bash 포함)를 상속하므로 devShell 밖에서 구형 bash 가 잡힐 수 있어,
# 안전하게 순차로 폴백한다(정확성 우선 — 병렬 이득은 bash 4.3+ 에서만 취한다).
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
  _PH_JOBS=1
fi
_PH_RESULT_DIR=""
_PH_SEQ=0

_ph_init() {
  [ -n "$_PH_RESULT_DIR" ] && return 0
  _PH_RESULT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/parallel-harness.XXXXXX")"
}

# run_test 를 override. 순차(_PH_JOBS=1)면 즉시 실행, 아니면 job-pool 병렬 큐잉.
run_test() {
  local name="$1"
  shift
  if [ "$_PH_JOBS" = "1" ]; then
    echo "==> $name"
    "$@"
    return
  fi
  _ph_init
  local seq="$_PH_SEQ"
  _PH_SEQ=$((_PH_SEQ + 1))
  printf '%s\n' "$name" > "$_PH_RESULT_DIR/$seq.name"
  # 동시성 상한: 실행 중 job 이 상한이면 하나 끝날 때까지 대기
  while [ "$(jobs -rp | wc -l)" -ge "$_PH_JOBS" ]; do
    wait -n 2>/dev/null || break
  done
  {
    # 테스트 본문은 조건 문맥 밖의 비동기 자식으로 실행하고, 종료 상태는 wait 로 따로 모은다.
    # `if ( "$@" )`·`( "$@" ) || …`처럼 조건 문맥에 두면 bash 가 그 안(함수 본문 포함)의 set -e 를
    # 무시해, 중간 명령이 실패해도 마지막 명령이 성공하면 PASS 가 된다(#1363). 비동기 자식은 호출자의
    # set -e 무시 상태를 물려받으므로, 순차 모드와 같은 set -e 적용은 run_test 를 aggregator 최상위
    # (조건 문맥 밖)에서 호출할 때 성립한다 — 조건 문맥에서 호출하면 순차·병렬 모두 set -e 가 무시된다.
    local rc=0
    "$@" > "$_PH_RESULT_DIR/$seq.out" 2>&1 &
    wait "$!" || rc=$?
    if [ "$rc" -eq 0 ]; then
      printf 'PASS\n' > "$_PH_RESULT_DIR/$seq.status"
    else
      printf 'FAIL\n' > "$_PH_RESULT_DIR/$seq.status"
    fi
  } &
}

# aggregator 끝에서 호출. 모든 job 대기 후 등록 순서대로 결과 출력. 실패가 있으면 non-zero 반환.
parallel_barrier() {
  [ "$_PH_JOBS" = "1" ] && return 0
  [ -n "$_PH_RESULT_DIR" ] || return 0
  wait
  local total="$_PH_SEQ" seq=0 pass=0 fail=0 name status
  while [ "$seq" -lt "$total" ]; do
    name="$(cat "$_PH_RESULT_DIR/$seq.name" 2>/dev/null)"
    # status 파일이 없으면 cat 실패가 set -e 로 barrier 를 죽여 나머지 결과·요약을 잃는다 → 빈 값으로 둔다.
    status="$(cat "$_PH_RESULT_DIR/$seq.status" 2>/dev/null)" || status=""
    if [ "$status" = "PASS" ]; then
      pass=$((pass + 1))
      echo "==> $name"
      grep -E '^(SKIP:|N/A:)' "$_PH_RESULT_DIR/$seq.out" 2>/dev/null || true
    else
      # status 파일 부재(=job 이 비정상 종료해 기록조차 못 함)도 FAIL 로 취급한다(fail-closed).
      fail=$((fail + 1))
      echo "==> $name  [FAIL]"
      sed 's/^/    | /' "$_PH_RESULT_DIR/$seq.out" 2>/dev/null || true
    fi
    seq=$((seq + 1))
  done
  printf '병렬 실행 요약: 통과 %d · 실패 %d (jobs=%d)\n' "$pass" "$fail" "$_PH_JOBS"
  rm -rf "$_PH_RESULT_DIR"
  [ "$fail" -eq 0 ]
}
