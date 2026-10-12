# shellcheck shell=bash
test_onepassword_shortcuts_preserve_mutable_settings() {
  python3 "$REPO_ROOT/tests/onepassword-shortcuts-tests.py"
}

test_onepassword_shortcuts_wrapper_explains_timeout() {
  local sandbox timeout_bin ok_bin timeout_log output wrapper status
  sandbox="$(new_sandbox)"
  timeout_bin="$sandbox/timeout"
  ok_bin="$sandbox/ok"
  timeout_log="$sandbox/timeout.log"
  output="$sandbox/output.log"
  wrapper="$REPO_ROOT/modules/darwin/programs/onepassword/shortcuts-wrapper.sh"

  cat >"$timeout_bin" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_TIMEOUT_LOG"
if [ "${FAKE_TIMEOUT_STATUS:-0}" -ne 0 ]; then
  exit "$FAKE_TIMEOUT_STATUS"
fi
[ "$1" = "--kill-after=2s" ] && [ "$2" = "10s" ] || exit 98
shift 2
exec "$@"
FAKE
  printf '#!/usr/bin/env bash\nexit 0\n' >"$ok_bin"
  chmod +x "$timeout_bin" "$ok_bin"
  : >"$timeout_log"
  export FAKE_TIMEOUT_LOG="$timeout_log"

  # An inherited activation environment must not loosen the TCC deadline.
  export ONEPASSWORD_SHORTCUTS_DEADLINE=0 ONEPASSWORD_SHORTCUTS_KILL_AFTER=0
  # shellcheck source=/dev/null
  source "$wrapper"
  [ "$ONEPASSWORD_SHORTCUTS_DEADLINE" = "10s" ] || fail "inherited environment changed the deadline"
  [ "$ONEPASSWORD_SHORTCUTS_KILL_AFTER" = "2s" ] || fail "inherited environment changed the kill-after bound"

  : >"$output"
  export FAKE_TIMEOUT_STATUS=124
  status=0
  onepassword_shortcuts_run "$timeout_bin" "$ok_bin" 2>"$output" || status=$?
  [ "$status" -eq 124 ] || fail "timeout status 124 must propagate, got $status"
  assert_contains "$(cat "$output")" "timed out"
  assert_contains "$(cat "$output")" "TCC prompt"

  # GNU timeout also returns 137 when something else SIGKILLs the helper. An immediate 137
  # cannot be the kill-after path, so it must not be reported as a timeout.
  : >"$output"
  export FAKE_TIMEOUT_STATUS=137
  status=0
  onepassword_shortcuts_run "$timeout_bin" "$ok_bin" 2>"$output" || status=$?
  [ "$status" -eq 137 ] || fail "SIGKILL status 137 must propagate, got $status"
  assert_contains "$(cat "$output")" "killed"
  assert_contains "$(cat "$output")" "before the 10s deadline"
  assert_not_contains "$(cat "$output")" "timed out"
  unset FAKE_TIMEOUT_STATUS

  # A helper that fails on its own keeps its exit code and stderr, with no timeout guidance.
  : >"$output"
  status=0
  onepassword_shortcuts_run "$timeout_bin" /bin/sh -c 'echo helper-said-why >&2; exit 1' 2>"$output" || status=$?
  [ "$status" -eq 1 ] || fail "helper exit code must pass through, got $status"
  assert_contains "$(cat "$output")" "helper-said-why"
  assert_not_contains "$(cat "$output")" "timed out"

  # Success passes through silently.
  : >"$output"
  onepassword_shortcuts_run "$timeout_bin" "$ok_bin" 2>"$output" || fail "successful helper must return 0"
  [ ! -s "$output" ] || fail "successful helper must not emit wrapper noise"

  if grep -Fv -- '--kill-after=2s 10s ' "$timeout_log" | grep -q .; then
    fail "every helper run must keep the outer deadline"
  fi
}

test_onepassword_shortcuts_wrapper_classifies_exit_by_elapsed_time() {
  local wrapper="$REPO_ROOT/modules/darwin/programs/onepassword/shortcuts-wrapper.sh" output
  output="$(new_sandbox)/output.log"
  # shellcheck source=/dev/null
  source "$wrapper"

  # 124 is only ever produced by timeout itself.
  onepassword_shortcuts_explain_exit 124 0 2>"$output"
  assert_contains "$(cat "$output")" "timed out"

  # 137 after the deadline is the kill-after path.
  onepassword_shortcuts_explain_exit 137 10 2>"$output"
  assert_contains "$(cat "$output")" "timed out"

  # 137 before the deadline is an external SIGKILL, not a timeout.
  onepassword_shortcuts_explain_exit 137 3 2>"$output"
  assert_contains "$(cat "$output")" "killed"
  assert_not_contains "$(cat "$output")" "timed out"

  # Ordinary exits stay silent.
  for status in 0 1 2; do
    : >"$output"
    onepassword_shortcuts_explain_exit "$status" 0 2>"$output"
    [ ! -s "$output" ] || fail "exit $status must not produce wrapper guidance"
  done
}
