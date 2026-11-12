# shellcheck shell=bash
# shellcheck disable=SC2154  # REPO_ROOT and common assertions come from the aggregator.

# Keep the real loader, selector and finalization, replacing only the registrations
# and domain suites with cheap fixtures. This also exercises the public wrapper.
_stf_create_fixture() {
  local fixture
  fixture="$(new_sandbox)"
  mkdir -p "$fixture/tests/lib" "$fixture/tests/suites" "$fixture/scripts/ai/lib" \
    "$fixture/bin" "$fixture/markers"
  cp "$REPO_ROOT/tests/lib/test-common.sh" "$fixture/tests/lib/"
  cp "$REPO_ROOT/tests/lib/parallel-harness.sh" "$fixture/tests/lib/"
  cp "$REPO_ROOT/tests/run-shell-script-tests.sh" "$fixture/tests/"
  cp "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh" "$fixture/scripts/ai/lib/"
  {
    awk '/^run_test "/ { exit } { print }' "$REPO_ROOT/tests/shell-script-tests.sh"
    cat <<'REGISTRATIONS'
run_test "label-only first" fixture_pick_alpha
run_test "label-only second" fixture_pick_beta
run_test "label-only other" fixture_other
REGISTRATIONS
    awk '/^parallel_barrier$/ { copying = 1 } copying { print }' "$REPO_ROOT/tests/shell-script-tests.sh"
  } > "$fixture/tests/shell-script-tests.sh"
  cat > "$fixture/tests/suites/fixture.sh" <<'SUITE'
fixture_pick_alpha() {
  : > "$FILTER_FIXTURE_MARKERS/alpha"
  bash -c '
    set -euo pipefail
    . "$1/tests/lib/parallel-harness.sh"
    nested_first() {
      : > "$FILTER_FIXTURE_MARKERS/nested-first"
      echo "SKIP: fixture coverage gap"
    }
    nested_second() {
      : > "$FILTER_FIXTURE_MARKERS/nested-second"
      echo "N/A: fixture platform exclusion"
    }
    run_test "nested first" nested_first
    run_test "nested second" nested_second
    parallel_barrier
  ' _ "$REPO_ROOT"
}
fixture_pick_beta() {
  : > "$FILTER_FIXTURE_MARKERS/beta"
  if [ "${FILTER_FIXTURE_FAIL:-0}" = 1 ]; then
    false
  fi
  : > "$FILTER_FIXTURE_MARKERS/beta-after"
}
fixture_other() {
  : > "$FILTER_FIXTURE_MARKERS/other"
}
SUITE
  cat > "$fixture/scripts/ai/test-runtime-profile.sh" <<'PROFILE'
function test_runtime_profile_activate {
  if [ "$FILTER_FIXTURE_BOOTSTRAP" = fast ]; then
    : > "$FILTER_FIXTURE_MARKERS/bootstrap-fast"
    export _TOMLKIT_BOOTSTRAP_READY=1
    return 0
  fi
  return 1
}
PROFILE
  cat > "$fixture/bin/nix" <<'NIX'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = shell ] && [ "$3" = --command ]
shift 3
: > "$FILTER_FIXTURE_MARKERS/bootstrap-reexec"
exec "$@"
NIX
  chmod +x "$fixture/bin/nix"
  printf '%s\n' "$fixture"
}

_stf_run() {
  local fixture="$1" jobs="$2" bootstrap="$3"
  shift 3
  # Local-selection cases must also run inside the required CI suite. The parent
  # environment remains unchanged; the CI rejection cases set CI explicitly.
  env -u CI -u _TOMLKIT_BOOTSTRAP_READY \
    PATH="$fixture/bin:$PATH" TEST_JOBS="$jobs" \
    FILTER_FIXTURE_MARKERS="$fixture/markers" FILTER_FIXTURE_BOOTSTRAP="$bootstrap" \
    "$@"
}

test_shell_filter_selects_function_names_in_both_modes() {
  local jobs kind fixture output
  for jobs in 1 2; do
    for kind in all one many; do
      fixture="$(_stf_create_fixture)"
      case "$kind" in
        all) output="$(_stf_run "$fixture" "$jobs" fast bash "$fixture/tests/run-shell-script-tests.sh")" ;;
        one) output="$(_stf_run "$fixture" "$jobs" fast bash "$fixture/tests/run-shell-script-tests.sh" --filter pick_alpha)" ;;
        many) output="$(_stf_run "$fixture" "$jobs" fast bash "$fixture/tests/run-shell-script-tests.sh" --filter pick_)" ;;
      esac
      [ -e "$fixture/markers/alpha" ] || fail "selected first fixture did not run"
      [ -e "$fixture/markers/nested-first" ] && [ -e "$fixture/markers/nested-second" ] \
        || fail "outer selection changed nested harness registrations"
      assert_contains "$output" "SKIP: fixture coverage gap"
      assert_contains "$output" "N/A: fixture platform exclusion"
      case "$kind" in
        all)
          [ -e "$fixture/markers/beta" ] && [ -e "$fixture/markers/other" ] \
            || fail "default execution did not run all fixtures"
          assert_contains "$output" "Shell tests passed: 3"
          ;;
        one)
          [ ! -e "$fixture/markers/beta" ] && [ ! -e "$fixture/markers/other" ] \
            || fail "single selection ran unrelated fixtures"
          assert_contains "$output" "Selected shell tests passed: 1"
          ;;
        many)
          [ -e "$fixture/markers/beta" ] && [ ! -e "$fixture/markers/other" ] \
            || fail "group selection ran the wrong fixtures"
          assert_contains "$output" "Selected shell tests passed: 2"
          ;;
      esac
      assert_not_contains "$output" "All shell script tests passed."
    done
  done
}

test_shell_filter_rejects_invalid_input_and_zero_matches() {
  local jobs kind fixture output rc
  for jobs in 1 2; do
    for kind in empty missing unknown extra duplicate absent case wildcard bracket display spaced; do
      fixture="$(_stf_create_fixture)"
      case "$kind" in
        empty) set -- --filter "" ;;
        missing) set -- --filter ;;
        unknown) set -- --unknown ;;
        extra) set -- --filter pick_ extra ;;
        duplicate) set -- --filter pick_ --filter alpha ;;
        absent) set -- --filter does_not_exist ;;
        case) set -- --filter PICK_ALPHA ;;
        wildcard) set -- --filter '*' ;;
        bracket) set -- --filter '[' ;;
        display) set -- --filter label-only ;;
        spaced) set -- --filter 'pick_ alpha' ;;
      esac
      rc=0
      output="$(_stf_run "$fixture" "$jobs" fast bash "$fixture/tests/run-shell-script-tests.sh" "$@" 2>&1)" || rc=$?
      [ "$rc" -ne 0 ] || fail "invalid or unmatched selection succeeded: $kind"
      [ ! -e "$fixture/markers/alpha" ] && [ ! -e "$fixture/markers/beta" ] \
        && [ ! -e "$fixture/markers/other" ] || fail "invalid selection ran a fixture: $kind"
      assert_not_contains "$output" "tests passed:"
      case "$kind" in
        absent|case|wildcard|bracket|display|spaced)
          assert_contains "$output" "No shell test function names match --filter"
          ;;
      esac
    done
  done
}

test_shell_filter_preserves_selected_failure_status() {
  local jobs fixture output rc
  for jobs in 1 2; do
    fixture="$(_stf_create_fixture)"
    rc=0
    output="$(_stf_run "$fixture" "$jobs" fast env FILTER_FIXTURE_FAIL=1 \
      bash "$fixture/tests/run-shell-script-tests.sh" --filter pick_beta 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || fail "selected failure was reported as success"
    [ -e "$fixture/markers/beta" ] || fail "selected failing fixture did not run"
    [ ! -e "$fixture/markers/beta-after" ] || fail "failure did not stop the fixture"
    [ ! -e "$fixture/markers/alpha" ] && [ ! -e "$fixture/markers/other" ] \
      || fail "failure selection ran unrelated fixtures"
    assert_not_contains "$output" "tests passed:"
  done
}

test_shell_filter_rejects_ci_selection_and_allows_full_run() {
  local ci_value entry fixture output rc
  for ci_value in 1 0; do
    for entry in run-shell-script-tests.sh shell-script-tests.sh; do
      fixture="$(_stf_create_fixture)"
      rc=0
      output="$(_stf_run "$fixture" 2 fast env CI="$ci_value" \
        bash "$fixture/tests/$entry" --filter pick_ 2>&1)" || rc=$?
      [ "$rc" -ne 0 ] || fail "nonempty CI allowed selection"
      [ ! -e "$fixture/markers/alpha" ] || fail "CI rejection ran a fixture"
      assert_contains "$output" "--filter is unavailable when CI is set"
      output="$(_stf_run "$fixture" 2 fast env CI="$ci_value" bash "$fixture/tests/$entry")"
      [ -e "$fixture/markers/alpha" ] && [ -e "$fixture/markers/beta" ] \
        && [ -e "$fixture/markers/other" ] || fail "CI default execution was narrowed"
      assert_contains "$output" "Shell tests passed: 3"
    done
  done
}

test_shell_filter_preserves_arguments_through_bootstrap() {
  local bootstrap fixture output rc
  for bootstrap in fast reexec; do
    fixture="$(_stf_create_fixture)"
    output="$(_stf_run "$fixture" 2 "$bootstrap" bash "$fixture/tests/run-shell-script-tests.sh" --filter pick_beta 2>&1)"
    [ -e "$fixture/markers/bootstrap-$bootstrap" ] || fail "bootstrap fixture did not use requested path"
    [ -e "$fixture/markers/beta" ] && [ ! -e "$fixture/markers/alpha" ] \
      && [ ! -e "$fixture/markers/other" ] || fail "bootstrap lost selection arguments"
    assert_contains "$output" "Selected shell tests passed: 1"
    rc=0
    output="$(_stf_run "$fixture" 2 "$bootstrap" bash "$fixture/tests/run-shell-script-tests.sh" --filter 'pick_ alpha' 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || fail "bootstrap changed a literal spaced argument"
    assert_contains "$output" "No shell test function names match --filter"
  done
}
