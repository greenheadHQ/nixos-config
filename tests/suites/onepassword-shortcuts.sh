# shellcheck shell=bash
test_onepassword_shortcuts_preserve_mutable_settings() {
  python3 "$REPO_ROOT/tests/onepassword-shortcuts-tests.py"
}

test_onepassword_shortcuts_wrapper_explains_timeout() {
  local sandbox timeout_bin ok_bin timeout_log output wrapper status timeout_status
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

  for timeout_status in 124 137; do
    : >"$output"
    export FAKE_TIMEOUT_STATUS="$timeout_status"
    status=0
    onepassword_shortcuts_run "$timeout_bin" "$ok_bin" 2>"$output" || status=$?
    [ "$status" -eq "$timeout_status" ] || fail "timeout status $timeout_status must propagate, got $status"
    assert_contains "$(cat "$output")" "timed out"
    assert_contains "$(cat "$output")" "TCC prompt"
  done
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
