# tests/suites/parallel-harness-markers.sh — nested coverage marker propagation contract
# shellcheck shell=bash
# shellcheck disable=SC2154  # REPO_ROOT는 aggregator가 제공한다.

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

  assert_contains "$output" "SKIP: synthetic capability gap"
  assert_contains "$output" "N/A: synthetic platform exclusion"
  assert_not_contains "$output" "hidden skip detail"
  assert_not_contains "$output" "hidden N/A detail"
  assert_not_contains "$output" "hidden normal detail"
  [ "$(printf '%s\n' "$output" | grep -c '^SKIP:')" = "1" ] \
    || fail "nested SKIP marker must propagate exactly once"
  [ "$(printf '%s\n' "$output" | grep -c '^N/A:')" = "1" ] \
    || fail "nested N/A marker must propagate exactly once"
)
