# tests/suites/parallel-harness-markers.sh — nested coverage marker propagation contract
# shellcheck shell=bash
# shellcheck disable=SC2154  # REPO_ROOT는 aggregator가 제공한다.

# 중첩 bash가 4.3 미만이면 tests/lib/parallel-harness.sh가 순차(_PH_JOBS=1)로 폴백하고, 그
# run_test는 출력을 모으지 않고 그대로 내보낸다. 그래서 "통과한 job의 상세 출력은 숨기고
# SKIP:/N/A: 마커만 전파한다"는 계약은 병렬 경로 전용이다(#1432). 판정·SKIP 헬퍼는
# tests/suites/parallel-harness-failures.sh(#1363/#1430 선례)의 _phf_nested_bash_runs_parallel /
# _phf_skip_parallel_only를 그대로 쓴다 — find … | sort 로드 순서상 이 파일보다 먼저 source된다.
test_parallel_harness_propagates_coverage_markers() (
  local output
  output="$(TEST_JOBS=2 bash -c '
    set -euo pipefail
    source "$1/tests/lib/parallel-harness.sh"
    emits_skip() {
      echo "SKIP: synthetic capability gap"
      echo "hidden skip detail"
    }
    emits_not_applicable() {
      echo "N/A: synthetic platform exclusion"
      echo "hidden N/A detail"
    }
    emits_normal_output() {
      echo "hidden normal detail"
    }
    run_test "nested skip" emits_skip
    run_test "nested N/A" emits_not_applicable
    run_test "nested pass" emits_normal_output
    parallel_barrier
  ' _ "$REPO_ROOT")" || fail "nested parallel harness marker fixture failed"

  # 마커가 나타나고 정확히 한 번만 전파되는지는 순차 폴백에서도 성립한다(각 fixture 함수는 정확히
  # 한 번만 실행되므로) — 항상 확인한다.
  assert_contains "$output" "SKIP: synthetic capability gap"
  assert_contains "$output" "N/A: synthetic platform exclusion"
  [ "$(printf '%s\n' "$output" | grep -c '^SKIP:')" = "1" ] \
    || fail "nested SKIP marker must propagate exactly once"
  [ "$(printf '%s\n' "$output" | grep -c '^N/A:')" = "1" ] \
    || fail "nested N/A marker must propagate exactly once"

  if ! _phf_nested_bash_runs_parallel; then
    _phf_skip_parallel_only "hidden detail suppression (sequential fallback does not buffer output)"
    return 0
  fi

  assert_not_contains "$output" "hidden skip detail"
  assert_not_contains "$output" "hidden N/A detail"
  assert_not_contains "$output" "hidden normal detail"
)
