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

  # Exit 137 cannot distinguish timeout's kill-after from an external SIGKILL.
  : >"$output"
  export FAKE_TIMEOUT_STATUS=137
  status=0
  onepassword_shortcuts_run "$timeout_bin" "$ok_bin" 2>"$output" || status=$?
  [ "$status" -eq 137 ] || fail "SIGKILL status 137 must propagate, got $status"
  assert_contains "$(cat "$output")" "killed"
  assert_contains "$(cat "$output")" "cause cannot be determined"
  assert_not_contains "$(cat "$output")" "timed out"
  assert_not_contains "$(cat "$output")" "grant"
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

test_onepassword_shortcuts_wrapper_classifies_exit_status() {
  local wrapper="$REPO_ROOT/modules/darwin/programs/onepassword/shortcuts-wrapper.sh" output
  output="$(new_sandbox)/output.log"
  # shellcheck source=/dev/null
  source "$wrapper"

  onepassword_shortcuts_explain_exit 124 2>"$output"
  assert_contains "$(cat "$output")" "timed out"

  onepassword_shortcuts_explain_exit 137 2>"$output"
  assert_contains "$(cat "$output")" "killed"
  assert_contains "$(cat "$output")" "cause cannot be determined"
  assert_contains "$(cat "$output")" "kill-after"
  assert_not_contains "$(cat "$output")" "timed out"
  assert_not_contains "$(cat "$output")" "grant"

  # Ordinary exits stay silent.
  for status in 0 1 2; do
    : >"$output"
    onepassword_shortcuts_explain_exit "$status" 2>"$output"
    [ ! -s "$output" ] || fail "exit $status must not produce wrapper guidance"
  done
}

_onepassword_shortcuts_real_exit() {
  local mode="$1" expected="$2" timeout_bin output status=0
  timeout_bin="$(command -v timeout)"
  "$timeout_bin" --version | grep -q 'GNU coreutils' || fail "real timeout tests require GNU timeout"
  output="$(new_sandbox)/output.log"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/modules/darwin/programs/onepassword/shortcuts-wrapper.sh"

  # One Python process per probe: TERM/KILL cannot leave a child sleep behind.
  # Kill early to avoid a scheduling race with the 10s deadline in parallel CI.
  onepassword_shortcuts_run "$timeout_bin" python3 -c '
import os, signal, sys, time
if sys.argv[1] == "external-kill":
    time.sleep(0.1)
    os.kill(os.getpid(), signal.SIGKILL)
if sys.argv[1] == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
time.sleep(30)
' "$mode" 2>"$output" || status=$?

  [ "$status" -eq "$expected" ] || fail "$mode must return $expected, got $status: $(cat "$output")"
  if [ "$expected" -eq 124 ]; then
    assert_contains "$(cat "$output")" "timed out"
    assert_contains "$(cat "$output")" "TCC prompt"
  else
    assert_contains "$(cat "$output")" "killed"
    assert_contains "$(cat "$output")" "cause cannot be determined"
    assert_not_contains "$(cat "$output")" "timed out"
    assert_not_contains "$(cat "$output")" "grant"
  fi
}

test_onepassword_shortcuts_real_external_sigkill() {
  _onepassword_shortcuts_real_exit external-kill 137
}

test_onepassword_shortcuts_real_timeout_term() {
  _onepassword_shortcuts_real_exit default-term 124
}

test_onepassword_shortcuts_real_timeout_kill_after() {
  _onepassword_shortcuts_real_exit ignore-term 137
}
