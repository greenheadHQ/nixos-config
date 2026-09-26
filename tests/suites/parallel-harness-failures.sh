# tests/suites/parallel-harness-failures.sh — 병렬·순차 실행의 실패 분류 일치 계약 (#1363)
# shellcheck shell=bash
# shellcheck disable=SC2154  # REPO_ROOT는 aggregator가 제공한다.

# 이 suite가 중첩으로 부르는 bash(PATH의 bash)가 병렬 경로를 쓰는지 판정한다. 하네스는 bash 4.3
# 미만(wait -n 없음)에서 순차로 폴백하므로, 그때는 병렬 모드 전용 검사가 성립하지 않는다.
# tests/suites/parallel-harness-markers.sh(#1432)도 이 헬퍼를 그대로 쓴다 — 이름을 바꾸면 거기도
# 같이 고쳐야 한다. 한쪽만 개명하면 없는 함수 호출이 조용히 SKIP 로 빠질 뿐 에러가 나지 않는다.
_phf_nested_bash_runs_parallel() {
  bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }'
}

# 병렬 모드 전용 검사를 건너뛸 때 canonical SKIP 마커(실행 bash 역량 부족 → coverage gap)를 낸다.
# tests/suites/parallel-harness-markers.sh(#1432)도 사용한다.
_phf_skip_parallel_only() {
  echo "SKIP: $1 requires nested bash 4.3+ for the parallel harness path (found $(bash -c 'printf %s.%s "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'))" >&2
}

# fixture 함수 하나만 등록한 중첩 aggregator를 TEST_JOBS=<jobs>로 실행한다. 모든 fixture는 마지막에
# <marker_dir>/after 를 만든다 — 성공형은 끝까지 실행됐다는 증거이고, 실패형은 실패 뒤 명령이
# 실행됐다는(실패가 가려졌다는) 증거다.
_phf_run_fixture() {
  local jobs="$1" kind="$2" marker_dir="$3"
  TEST_JOBS="$jobs" bash -c '
    set -euo pipefail
    source "$1/tests/lib/parallel-harness.sh"
    marker_dir="$3"
    passes() {
      true
      true | cat
      touch "$marker_dir/after"
    }
    mid_command_failure() {
      false
      touch "$marker_dir/after"
    }
    python_assertion_failure() {
      PYTHON_COLORS=0 python3 -c "assert 1 == 2, \"synthetic assertion\""
      touch "$marker_dir/after"
    }
    explicit_exit() {
      exit 37
      touch "$marker_dir/after"
    }
    pipeline_failure() {
      false | cat
      touch "$marker_dir/after"
    }
    run_test "fixture $2" "$2"
    parallel_barrier
  ' _ "$REPO_ROOT" "$kind" "$marker_dir"
}

test_parallel_harness_classifies_failures_like_sequential() (
  local entry kind expected jobs jobs_modes="1 2" sandbox output rc
  if ! _phf_nested_bash_runs_parallel; then
    _phf_skip_parallel_only "parallel-mode failure classification (sequential classification still checked)"
    jobs_modes="1"
  fi
  for entry in passes:pass mid_command_failure:fail python_assertion_failure:fail \
    explicit_exit:fail pipeline_failure:fail; do
    kind="${entry%%:*}"
    expected="${entry##*:}"
    for jobs in $jobs_modes; do
      sandbox="$(new_sandbox)"
      rc=0
      output="$(_phf_run_fixture "$jobs" "$kind" "$sandbox" 2>&1)" || rc=$?
      if [ "$expected" = pass ]; then
        [ "$rc" -eq 0 ] ||
          fail "$kind TEST_JOBS=$jobs: 성공 fixture가 exit $rc 로 끝났다: $output"
        [ -e "$sandbox/after" ] ||
          fail "$kind TEST_JOBS=$jobs: 성공 fixture가 끝까지 실행되지 않았다"
        if [ "$jobs" != 1 ]; then
          assert_not_contains "$output" "[FAIL]"
          assert_contains "$output" "통과 1 · 실패 0"
        fi
        continue
      fi
      [ "$rc" -ne 0 ] ||
        fail "$kind TEST_JOBS=$jobs: 실패 fixture가 exit 0 으로 끝났다: $output"
      [ ! -e "$sandbox/after" ] ||
        fail "$kind TEST_JOBS=$jobs: 실패 뒤 명령이 실행됐다"
      if [ "$jobs" != 1 ]; then
        assert_contains "$output" "==> fixture $kind  [FAIL]"
        assert_contains "$output" "통과 0 · 실패 1"
      fi
      if [ "$kind" = python_assertion_failure ]; then
        assert_contains "$output" "AssertionError: synthetic assertion"
      fi
    done
  done
)

# 병렬 job이 결과를 기록하기 전에 외부 SIGKILL로 죽는 경우(OOM killer 등)를 재현한다. fixture 셸($$)
# 아래에서 이 테스트를 위해 생긴 프로세스 체인 전체를 죽이므로, 본문은 실패한 명령 없이 끝나지만
# 하네스는 결과를 받지 못한다. 그래도 그 테스트는 실패로 집계되고 다른 테스트는 영향이 없어야 한다.
test_parallel_harness_fails_closed_when_job_dies_before_result() (
  local sandbox output rc=0
  if ! _phf_nested_bash_runs_parallel; then
    _phf_skip_parallel_only "job death before result"
    return 0
  fi
  sandbox="$(new_sandbox)"
  output="$(TEST_JOBS=2 bash -c '
    set -euo pipefail
    source "$1/tests/lib/parallel-harness.sh"
    marker_dir="$2"
    dies_before_result() {
      local pid="$BASHPID" ppid chain=""
      while [ "$pid" != "$$" ]; do
        ppid="$(ps -o ppid= -p "$pid" | tr -d " ")"
        # fixture 셸에 닿지 못하면 아무것도 죽이지 않고 성공으로 끝나 바깥 단언이 잡는다.
        case "$ppid" in "" | 0 | 1) return 0 ;; esac
        chain="$pid $chain"
        pid="$ppid"
      done
      : > "$marker_dir/killing-job"
      # chain은 바깥(job)부터 자기 자신 순이라, job이 결과를 기록할 틈 없이 먼저 죽는다.
      kill -KILL $chain
    }
    survivor() {
      echo "survivor ran"
    }
    run_test "dies before result" dies_before_result
    run_test "survivor" survivor
    parallel_barrier
  ' _ "$REPO_ROOT" "$sandbox" 2>&1)" || rc=$?

  [ -e "$sandbox/killing-job" ] || fail "fixture가 job 프로세스 체인을 찾지 못했다: $output"
  [ "$rc" -ne 0 ] || fail "결과 없이 죽은 job이 있는데 exit 0 으로 끝났다: $output"
  assert_contains "$output" "==> dies before result  [FAIL]"
  assert_contains "$output" "==> survivor"
  assert_not_contains "$output" "==> survivor  [FAIL]"
  assert_contains "$output" "통과 1 · 실패 1"
)

# 출력 파일까지 없는 실패 job(가장 이른 사망: job이 출력 리다이렉트 전에 죽음)도 barrier를 죽이지
# 않아야 한다. 그 시점은 본문에서 만들 수 없어, 본문이 TMPDIR 아래 자기 출력 파일을 지우고 실패하는
# 것으로 같은 barrier 상태(실패 + 출력 파일 없음)를 만든다.
test_parallel_harness_fails_closed_when_job_output_is_missing() (
  local sandbox output rc=0
  if ! _phf_nested_bash_runs_parallel; then
    _phf_skip_parallel_only "missing job output"
    return 0
  fi
  sandbox="$(new_sandbox)"
  mkdir "$sandbox/tmp"
  output="$(TMPDIR="$sandbox/tmp" TEST_JOBS=2 bash -c '
    set -euo pipefail
    source "$1/tests/lib/parallel-harness.sh"
    marker_dir="$2"
    loses_output() {
      local token="phf-lost-output-$BASHPID" own_output
      echo "$token"
      own_output="$(grep -rlF "$token" "$TMPDIR")" || return 0
      rm -f "$own_output"
      : > "$marker_dir/removed-output"
      false
    }
    survivor() {
      echo "survivor ran"
    }
    run_test "loses output" loses_output
    run_test "survivor" survivor
    parallel_barrier
  ' _ "$REPO_ROOT" "$sandbox" 2>&1)" || rc=$?

  [ -e "$sandbox/removed-output" ] || fail "fixture가 자기 출력 파일을 찾지 못했다: $output"
  [ "$rc" -ne 0 ] || fail "실패 job이 있는데 exit 0 으로 끝났다: $output"
  assert_contains "$output" "==> loses output  [FAIL]"
  assert_contains "$output" "==> survivor"
  assert_not_contains "$output" "==> survivor  [FAIL]"
  assert_contains "$output" "통과 1 · 실패 1"
  [ -z "$(find "$sandbox/tmp" -mindepth 1 -print -quit)" ] ||
    fail "barrier가 결과 디렉터리를 정리하지 않았다: $(find "$sandbox/tmp" -mindepth 1)"
)
