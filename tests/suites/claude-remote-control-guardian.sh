# tests/suites/claude-remote-control-guardian.sh — Claude Remote Control fixtures
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2164
# shellcheck source=../lib/claude-remote-control-fixtures.sh
. "$SCRIPT_DIR/lib/claude-remote-control-fixtures.sh"

test_claude_remote_control_maint_reaps_delayed_failed_launcher() (
  local sandbox repo maint lock_path out rc log_count_after
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  maint="$(_claude_rc_maint_script)"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_install_delayed_launcher_flock
  export CLAUDE_RC_DECLARED_INSTANCES
  CLAUDE_RC_DECLARED_INSTANCES="$(
    jq -nc --arg path "$repo" \
      '[{path:$path,spawn:"worktree",capacity:null,permissionMode:"bypassPermissions"}]'
  )"

  rc=0
  out="$(_claude_rc_run_maint "$repo" env \
    SERVER_START_SETTLE_SECONDS=0.05 \
    STARTED_IDENTITY_POLL_ATTEMPTS=1 \
    STARTED_IDENTITY_POLL_INTERVAL_SECONDS=0.01 \
    LAUNCH_GUARD_ACK_ATTEMPTS=0 \
    FAKE_FLOCK_LAUNCH_PATH="$lock_path" \
    FAKE_FLOCK_LAUNCH_DELAY_SECONDS=0.3 \
    bash "$maint" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "delayed launcher fixture must cross the startup deadline: $out"
  log_count_after="$(grep -Fc 'remote-control' "$CLAUDE_RC_LOG" 2>/dev/null || true)"
  sleep 0.5
  "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "failed startup must not leave a delayed server holding the instance lock"
  [ "$(grep -Fc 'remote-control' "$CLAUDE_RC_LOG" 2>/dev/null || true)" = "$log_count_after" ] \
    || fail "failed startup must not launch the delayed server after returning"
  rm -f "$CLAUDE_RC_HOLD_FILE"
)

test_claude_remote_control_launch_guard_survives_early_launcher_exit() {
  local sandbox repo wrapper probe_guard_pid probe_launcher_pid probe_group_pid
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"

  (
    # shellcheck source=/dev/null
    source "$wrapper"
    export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
    export STATE_DIR="$CLAUDE_RC_STATE"
    spawn_guarded_server_launch \
      "$repo" "worktree" "" "bypassPermissions" "/usr/bin/false" \
      probe_guard_pid probe_launcher_pid probe_group_pid \
      || fail "spawn_guarded_server_launch did not return the guardian identity"

    # A launcher can fail before the caller reaches its settle/deadline path.
    # Keep the guardian as the live, non-reusable signal target until the
    # caller explicitly cancels or hands it off.
    sleep 0.1
    kill -0 "$probe_guard_pid" 2>/dev/null \
      || fail "launch guardian exited before the caller made a lifecycle decision"
    cancel_launch_guard "$probe_guard_pid" "$probe_group_pid" \
      || fail "live guardian did not acknowledge exact-group cancellation"
  )
}

test_claude_remote_control_launch_guard_reaps_early_exit_descendant() (
  local sandbox repo wrapper lock_path orphan_pid_file orphan_pid=""
  local probe_guard_pid="" probe_launcher_pid="" probe_group_pid=""
  local publish_attempt
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  orphan_pid_file="$sandbox/orphan.pid"
  _claude_rc_install_early_exit_descendant_flock

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_early_exit_descendant_fixture() {
    [ -z "$orphan_pid" ] || kill -KILL "$orphan_pid" 2>/dev/null || true
    [ -z "$probe_group_pid" ] || kill -KILL -- "-$probe_group_pid" 2>/dev/null || true
    [ -z "$probe_guard_pid" ] || kill -KILL "$probe_guard_pid" 2>/dev/null || true
    [ -z "$probe_guard_pid" ] || wait "$probe_guard_pid" 2>/dev/null || true
  }
  trap cleanup_early_exit_descendant_fixture EXIT

  # shellcheck source=/dev/null
  source "$wrapper"
  export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
  export STATE_DIR="$CLAUDE_RC_STATE"
  export FAKE_FLOCK_LAUNCH_PATH="$lock_path"
  export FAKE_FLOCK_ORPHAN_PID_FILE="$orphan_pid_file"
  spawn_guarded_server_launch \
    "$repo" "worktree" "" "bypassPermissions" "$CLAUDE_RC_FAKE_BIN/claude" \
    probe_guard_pid probe_launcher_pid probe_group_pid \
    || fail "early-exit descendant fixture did not publish guardian identities"

  # The guardian returns before the synthetic flock child is guaranteed a CPU
  # slice. Keep this fixture bounded, but tolerate scheduler pressure from the
  # ten-job shell suite instead of treating one busy second as a launch defect.
  for ((publish_attempt = 0; publish_attempt < 500; publish_attempt++)); do
    [ -s "$orphan_pid_file" ] && break
    sleep 0.01
  done
  [ -s "$orphan_pid_file" ] || fail "early-exit launcher did not publish its descendant"
  orphan_pid="$(cat "$orphan_pid_file")"
  kill -0 "$orphan_pid" 2>/dev/null || fail "early-exit descendant was not alive before cancellation"
  [ "$(pid_process_group "$probe_group_pid")" = "$probe_group_pid" ] \
    || fail "native supervisor was not its process-group leader"
  [ "$(pid_process_group "$probe_launcher_pid")" = "$probe_group_pid" ] \
    || fail "launcher did not inherit the supervisor process group"
  [ "$(pid_process_group "$orphan_pid")" = "$probe_group_pid" ] \
    || fail "reparented descendant escaped the supervisor process group"

  cancel_launch_guard "$probe_guard_pid" "$probe_group_pid" \
    || fail "guardian did not acknowledge early-exit descendant cancellation"
  ! kill -0 "$orphan_pid" 2>/dev/null \
    || pid_is_zombie_process "$orphan_pid" \
    || fail "guardian cancellation left the reparented descendant alive"
  "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "guardian cancellation left the reparented descendant lock held"
  probe_guard_pid=""
  probe_group_pid=""
  orphan_pid=""
  trap - EXIT
)

test_claude_remote_control_launch_group_rejects_unsafe_pid_files() (
  local sandbox helper marker target pid_file rc supervisor_pid="" child_pid=""
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  helper="$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER"
  marker="$sandbox/child-ran"
  target="$sandbox/pid-target"
  (umask 077 && : > "$target")

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_launch_group_security_fixture() {
    [ -z "$supervisor_pid" ] || kill -KILL -- "-$supervisor_pid" 2>/dev/null || true
    [ -z "$supervisor_pid" ] || wait "$supervisor_pid" 2>/dev/null || true
  }
  trap cleanup_launch_group_security_fixture EXIT

  ln -s "$target" "$sandbox/pid-symlink"
  ln "$target" "$sandbox/pid-hardlink"
  (umask 077 && : > "$sandbox/pid-public")
  chmod 0644 "$sandbox/pid-public"
  for pid_file in "$sandbox/pid-symlink" "$sandbox/pid-hardlink" "$sandbox/pid-public"; do
    rm -f "$marker"
    rc=0
    FAKE_LAUNCH_GROUP_MARKER="$marker" \
      "$helper" "$pid_file" /bin/sh -c 'printf child-ran > "$FAKE_LAUNCH_GROUP_MARKER"' \
      >/dev/null 2>&1 || rc=$?
    [ "$rc" = "$CLAUDE_RC_LAUNCH_GROUP_STATUS_PUBLICATION_FAILED" ] \
      || fail "unsafe PID file $(basename "$pid_file") returned $rc"
    [ ! -e "$marker" ] \
      || fail "unsafe PID file $(basename "$pid_file") released the exec gate"
  done

  # A child that fails exec remains pinned as a zombie until the caller makes
  # the bounded cancellation decision; it must not escape with the lock.
  pid_file="$sandbox/pid-exec-failure"
  (umask 077 && : > "$pid_file")
  "$helper" "$pid_file" "$sandbox/command-does-not-exist" &
  supervisor_pid=$!
  for _ in {1..100}; do
    [ -s "$pid_file" ] && break
    sleep 0.01
  done
  [ -s "$pid_file" ] || fail "exec-failure fixture did not publish its child PID"
  child_pid="$(cat "$pid_file")"
  kill -0 "$supervisor_pid" 2>/dev/null \
    || fail "exec-failure supervisor did not pin the failed launcher"
  kill -TERM "$supervisor_pid"
  wait "$supervisor_pid" 2>/dev/null || true
  supervisor_pid=""
  for _ in {1..100}; do
    if ! kill -0 "$child_pid" 2>/dev/null || pid_is_zombie_process "$child_pid"; then
      break
    fi
    sleep 0.01
  done
  ! kill -0 "$child_pid" 2>/dev/null \
    || pid_is_zombie_process "$child_pid" \
    || fail "failed exec child survived launch-group cancellation"
  trap - EXIT
)

test_claude_remote_control_launch_guard_cancel_is_bounded() (
  local sandbox repo wrapper stubborn_bin lock_path server_pid_file leaf_pid_file
  local probe_guard_pid="" probe_launcher_pid="" probe_group_pid=""
  local server_pid="" leaf_pid="" start elapsed
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  stubborn_bin="$sandbox/stubborn-claude"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  server_pid_file="$sandbox/server.pid"
  leaf_pid_file="$sandbox/leaf.pid"
  cat > "$stubborn_bin" <<'EOS'
#!/usr/bin/env bash
trap '' HUP TERM INT
(
  trap '' HUP TERM INT
  (
    trap '' HUP TERM INT
    while :; do sleep 0.02; done
  ) &
  printf '%s\n' "$!" > "$FAKE_LEAF_PID_FILE"
  while :; do sleep 0.02; done
) &
printf '%s\n' "$!" > "$FAKE_SERVER_PID_FILE"
while :; do sleep 0.02; done
EOS
  chmod +x "$stubborn_bin"

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_launch_guard_group_fixture() {
    local pid
    [ -z "$probe_group_pid" ] || kill -KILL -- "-$probe_group_pid" 2>/dev/null || true
    for pid in "$leaf_pid" "$server_pid" "$probe_launcher_pid" "$probe_guard_pid"; do
      case "$pid" in
        ''|*[!0-9]*) continue ;;
      esac
      kill -KILL "$pid" 2>/dev/null || true
    done
    [ -z "$probe_guard_pid" ] || wait "$probe_guard_pid" 2>/dev/null || true
  }
  trap cleanup_launch_guard_group_fixture EXIT

  # shellcheck source=/dev/null
  source "$wrapper"
  export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
  export STATE_DIR="$CLAUDE_RC_STATE"
  export FAKE_SERVER_PID_FILE="$server_pid_file"
  export FAKE_LEAF_PID_FILE="$leaf_pid_file"
  spawn_guarded_server_launch \
    "$repo" "worktree" "" "bypassPermissions" "$stubborn_bin" \
    probe_guard_pid probe_launcher_pid probe_group_pid \
    || fail "stubborn launcher did not publish guardian identities"

  for _ in {1..200}; do
    [ -s "$server_pid_file" ] && [ -s "$leaf_pid_file" ] && break
    sleep 0.01
  done
  [ -s "$server_pid_file" ] && [ -s "$leaf_pid_file" ] \
    || fail "stuck process group did not publish its descendants"
  server_pid="$(cat "$server_pid_file")"
  leaf_pid="$(cat "$leaf_pid_file")"
  # Freeze the Bash guardian itself so cancel_launch_guard must exercise the
  # caller-side exact process-group fallback instead of racing its normal trap.
  kill -STOP "$probe_guard_pid"
  start=$SECONDS
  LAUNCH_GUARD_ACK_ATTEMPTS=0 \
  LAUNCH_GUARD_ACK_INTERVAL_SECONDS=0.01 \
    cancel_launch_guard "$probe_guard_pid" "$probe_group_pid" \
    || fail "exact-group fallback did not clean a non-acknowledging guardian"
  elapsed=$((SECONDS - start))

  [ "$elapsed" -lt 4 ] || fail "guardian cancellation exceeded its bounded deadline"
  for pid in "$probe_guard_pid" "$probe_group_pid" "$probe_launcher_pid" "$server_pid" "$leaf_pid"; do
    ! kill -0 "$pid" 2>/dev/null \
      || pid_is_zombie_process "$pid" \
      || fail "bounded fallback left descendant PID $pid alive"
  done
  "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "bounded group fallback left the instance lock held"
  probe_guard_pid=""
  probe_group_pid=""
  probe_launcher_pid=""
  server_pid=""
  leaf_pid=""
  trap - EXIT
)

test_claude_remote_control_repeated_signal_cannot_strand_stopped_group() (
  local sandbox repo wrapper lock_path hold_file ready_file release_file failed_file
  local real_ps guard_pid="" launcher_pid="" group_pid="" injector_pid="" cancel_status=0
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  hold_file="$sandbox/hold-server"
  ready_file="$sandbox/group-stopped"
  release_file="$sandbox/release-ps"
  failed_file="$sandbox/injector-failed"
  real_ps="$(_claude_rc_find_tool ps)" || fail "repeated-signal fixture requires ps"
  : > "$hold_file"

  {
    printf '#!/usr/bin/env bash\nREAL_PS=%q\n' "$real_ps"
    cat <<'EOS'
set -euo pipefail
if [ "$*" = "-axo pid=,pgid=,state=" ] && [ -n "${FAKE_GROUP_STOPPED_FILE:-}" ]; then
  : > "$FAKE_GROUP_STOPPED_FILE"
  while [ ! -e "${FAKE_RELEASE_PS_FILE:?}" ]; do
    sleep 0.01
  done
fi
exec "$REAL_PS" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/ps"
  chmod +x "$CLAUDE_RC_FAKE_BIN/ps"

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_repeated_signal_fixture() {
    : > "$release_file"
    rm -f "$hold_file"
    [ -z "$injector_pid" ] || kill -KILL "$injector_pid" 2>/dev/null || true
    [ -z "$group_pid" ] || kill -CONT -- "-$group_pid" 2>/dev/null || true
    [ -z "$group_pid" ] || kill -KILL -- "-$group_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || kill -KILL "$guard_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || wait "$guard_pid" 2>/dev/null || true
  }
  trap cleanup_repeated_signal_fixture EXIT

  # shellcheck source=/dev/null
  source "$wrapper"
  export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
  export STATE_DIR="$CLAUDE_RC_STATE"
  export FAKE_CLAUDE_HOLD_FILE="$hold_file"
  export FAKE_GROUP_STOPPED_FILE="$ready_file"
  export FAKE_RELEASE_PS_FILE="$release_file"
  spawn_guarded_server_launch \
    "$repo" "worktree" "" "bypassPermissions" "$CLAUDE_RC_FAKE_BIN/claude" \
    guard_pid launcher_pid group_pid \
    || fail "repeated-signal fixture did not publish guardian identities"

  (
    for _ in {1..200}; do
      [ -e "$ready_file" ] && break
      sleep 0.01
    done
    if [ ! -e "$ready_file" ]; then
      : > "$failed_file"
      : > "$release_file"
      exit 0
    fi
    # The first TERM is sent by cancel_launch_guard. Deliver another while the
    # guardian is blocked after group-wide STOP but before SIGKILL.
    kill -TERM "$guard_pid" 2>/dev/null || : > "$failed_file"
    : > "$release_file"
  ) &
  injector_pid=$!

  cancel_launch_guard "$guard_pid" "$group_pid" || cancel_status=$?
  wait "$injector_pid"
  injector_pid=""
  [ ! -e "$failed_file" ] || fail "repeated-signal injector missed the cleanup critical section"
  [ "$cancel_status" -eq 0 ] \
    || fail "repeated-signal cleanup was not acknowledged: $cancel_status"
  _claude_rc_wait_lock_free "$lock_path" \
    || fail "repeated signal stranded the stopped process group lock"
  ! kill -0 "$group_pid" 2>/dev/null \
    || pid_is_zombie_process "$group_pid" \
    || fail "repeated signal left the process-group leader alive"
  guard_pid=""
  group_pid=""
  launcher_pid=""
  trap - EXIT
  rm -f "$hold_file"
)

test_claude_remote_control_stopped_group_resumes_after_probe_failure() (
  local sandbox wrapper pid_file group_pid="" launcher_pid="" expected_parent state
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  wrapper="$(_claude_rc_wrapper_script)"
  pid_file="$sandbox/launcher.pid"
  (umask 077 && : > "$pid_file")

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_stopped_group_fixture() {
    [ -z "$group_pid" ] || kill -CONT -- "-$group_pid" 2>/dev/null || true
    [ -z "$group_pid" ] || kill -KILL -- "-$group_pid" 2>/dev/null || true
    [ -z "$group_pid" ] || wait "$group_pid" 2>/dev/null || true
  }
  trap cleanup_stopped_group_fixture EXIT

  # shellcheck source=/dev/null
  source "$wrapper"
  "$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER" "$pid_file" /bin/sleep 30 &
  group_pid=$!
  for _ in {1..100}; do
    [ -s "$pid_file" ] && break
    sleep 0.01
  done
  [ -s "$pid_file" ] || fail "probe-failure fixture did not publish a launcher"
  launcher_pid="$(cat "$pid_file")"
  expected_parent="$(pid_parent_pid "$group_pid")"
  [ "$(pid_process_group "$launcher_pid")" = "$group_pid" ] \
    || fail "probe-failure fixture launcher did not inherit the group"

  # Force the post-SIGSTOP observation to fail. The recorded stable PGID must
  # still allow best-effort SIGCONT without a second ps dependency.
  # shellcheck disable=SC2329 # overrides production helper invoked by stop_owned_process_group
  process_group_members_are_stopped() { return 1; }
  export LAUNCH_GUARD_TERM_ATTEMPTS=1
  if stop_owned_process_group "$group_pid" "$expected_parent"; then
    fail "injected process-group probe failure unexpectedly succeeded"
  fi
  resume_owned_process_group "$group_pid" "$expected_parent" \
    || fail "recorded stopped group could not be resumed after probe failure"
  sleep 0.05
  state="$(ps -o state= -p "$launcher_pid" | tr -d '[:space:]')"
  case "$state" in
    T*) fail "probe failure left the launcher permanently stopped" ;;
  esac
  cleanup_stopped_group_fixture
  group_pid=""
  trap - EXIT
)

test_claude_remote_control_group_escape_never_claims_cleaned() (
  local sandbox repo wrapper escape_source escape_bin escape_pid_file lock_path
  local result_status="" result_pid="" result_version="" escape_pid=""
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  escape_source="$sandbox/group-escape.c"
  escape_bin="$sandbox/group-escape"
  escape_pid_file="$sandbox/escape.pid"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  cat > "$escape_source" <<'EOF'
#define _POSIX_C_SOURCE 200809L
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
int main(void) {
    const char *path = getenv("FAKE_ESCAPE_PID_FILE");
    FILE *file;
    if (path == NULL || setpgid(0, 0) != 0) return 70;
    signal(SIGHUP, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    file = fopen(path, "w");
    if (file == NULL) return 71;
    if (fprintf(file, "%ld\n", (long)getpid()) < 0 || fclose(file) != 0) return 72;
    for (;;) pause();
}
EOF
  cc -std=c11 -O2 -Wall -Wextra -Werror "$escape_source" -o "$escape_bin"

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_group_escape_fixture() {
    [ -z "$escape_pid" ] || kill -KILL "$escape_pid" 2>/dev/null || true
    [ -z "$escape_pid" ] || wait "$escape_pid" 2>/dev/null || true
  }
  trap cleanup_group_escape_fixture EXIT

  # shellcheck source=/dev/null
  source "$wrapper"
  export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
  export STATE_DIR="$CLAUDE_RC_STATE"
  export VERSIONS_DIR="$CLAUDE_RC_VERSIONS"
  export FAKE_ESCAPE_PID_FILE="$escape_pid_file"
  export SERVER_START_SETTLE_SECONDS=0.05
  export STARTED_IDENTITY_POLL_ATTEMPTS=1
  export STARTED_IDENTITY_POLL_INTERVAL_SECONDS=0.01
  launch_and_verify_server \
    "$repo" "worktree" "" "bypassPermissions" "$escape_bin" \
    result_status result_pid result_version

  [ -s "$escape_pid_file" ] || fail "group-escape fixture did not publish its PID"
  escape_pid="$(cat "$escape_pid_file")"
  [ "$result_status" = "identity-unresolvable" ] \
    || fail "escaped lock holder must remain unknown, got $result_status"
  [ -z "$result_pid" ] || fail "group-escape result unexpectedly exposed PID $result_pid"
  [ -z "$result_version" ] \
    || fail "group-escape result unexpectedly exposed version $result_version"
  ! "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "group-escape fixture did not retain the inherited lock"
  kill -KILL "$escape_pid" 2>/dev/null || true
  for _ in {1..100}; do
    "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true && break
    sleep 0.01
  done
  "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "group-escape cleanup did not release the inherited lock"
  escape_pid=""
  trap - EXIT
)

test_claude_remote_control_launch_guard_handles_hup() (
  local sandbox repo wrapper lock_path guard_pid="" launcher_pid="" group_pid="" wait_status=0
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  : > "$CLAUDE_RC_HOLD_FILE"

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_launch_guard_hup_fixture() {
    rm -f "$CLAUDE_RC_HOLD_FILE"
    [ -z "$guard_pid" ] || kill -KILL "$guard_pid" 2>/dev/null || true
    [ -z "$group_pid" ] || kill -KILL -- "-$group_pid" 2>/dev/null || true
    [ -z "$launcher_pid" ] || kill -KILL "$launcher_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || wait "$guard_pid" 2>/dev/null || true
  }
  trap cleanup_launch_guard_hup_fixture EXIT

  # shellcheck source=/dev/null
  source "$wrapper"
  export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
  export STATE_DIR="$CLAUDE_RC_STATE"
  export FAKE_CLAUDE_LOG="$CLAUDE_RC_LOG"
  export FAKE_CLAUDE_HOLD_FILE="$CLAUDE_RC_HOLD_FILE"
  spawn_guarded_server_launch \
    "$repo" "worktree" "" "bypassPermissions" "$CLAUDE_RC_FAKE_BIN/claude" \
    guard_pid launcher_pid group_pid \
    || fail "HUP fixture did not publish the guardian identity"
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "HUP fixture launcher did not start"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"

  kill -HUP "$guard_pid"
  wait "$guard_pid" 2>/dev/null || wait_status=$?
  [ "$wait_status" -eq "$LAUNCH_GUARD_CLEANED_STATUS" ] \
    || fail "guardian HUP cleanup returned $wait_status"
  _claude_rc_wait_lock_free "$lock_path" || fail "guardian HUP cleanup left the instance lock held"
  ! kill -0 "$launcher_pid" 2>/dev/null \
    || pid_is_zombie_process "$launcher_pid" \
    || fail "guardian HUP cleanup left its launcher alive"
  if find "$(dirname "$lock_path")" -maxdepth 1 \
      \( -name 'launch-guard.*' -o -name 'launch-pid.*' -o -name 'launch-group.*' \) -print -quit | grep -q .; then
    fail "guardian HUP cleanup left a handshake file"
  fi
  guard_pid=""
  launcher_pid=""
  group_pid=""
  trap - EXIT
  rm -f "$CLAUDE_RC_HOLD_FILE"
)

test_claude_remote_control_launch_guard_handles_parent_exit() (
  local sandbox repo wrapper lock_path guard_pid_file launcher_pid_file group_pid_file
  local guard_pid="" launcher_pid="" group_pid=""
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  guard_pid_file="$sandbox/guard.pid"
  launcher_pid_file="$sandbox/launcher.pid"
  group_pid_file="$sandbox/group.pid"
  : > "$CLAUDE_RC_HOLD_FILE"

  # shellcheck disable=SC2329 # invoked indirectly by the EXIT trap
  cleanup_launch_guard_parent_exit_fixture() {
    rm -f "$CLAUDE_RC_HOLD_FILE"
    [ -z "$group_pid" ] || kill -KILL -- "-$group_pid" 2>/dev/null || true
    [ -z "$launcher_pid" ] || kill -KILL "$launcher_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || kill -KILL "$guard_pid" 2>/dev/null || true
  }
  trap cleanup_launch_guard_parent_exit_fixture EXIT
  # shellcheck source=/dev/null
  source "$wrapper"

  (
    local child_guard_pid child_launcher_pid child_group_pid
    export PATH="$CLAUDE_RC_FAKE_BIN:$PATH"
    export STATE_DIR="$CLAUDE_RC_STATE"
    export FAKE_CLAUDE_LOG="$CLAUDE_RC_LOG"
    export FAKE_CLAUDE_HOLD_FILE="$CLAUDE_RC_HOLD_FILE"
    spawn_guarded_server_launch \
      "$repo" "worktree" "" "bypassPermissions" "$CLAUDE_RC_FAKE_BIN/claude" \
      child_guard_pid child_launcher_pid child_group_pid \
      || exit 1
    printf '%s\n' "$child_guard_pid" > "$guard_pid_file"
    printf '%s\n' "$child_launcher_pid" > "$launcher_pid_file"
    printf '%s\n' "$child_group_pid" > "$group_pid_file"
    # Deliberately exit without cancel or handoff. The guardian must notice
    # the original parent edge disappearing and clean its pending tree.
  )

  [ -s "$guard_pid_file" ] && [ -s "$launcher_pid_file" ] && [ -s "$group_pid_file" ] \
    || fail "parent-exit fixture did not publish guardian identities"
  guard_pid="$(cat "$guard_pid_file")"
  launcher_pid="$(cat "$launcher_pid_file")"
  group_pid="$(cat "$group_pid_file")"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  _claude_rc_wait_lock_free "$lock_path" \
    || fail "guardian parent-exit cleanup left the instance lock held"
  for _ in {1..100}; do
    if { ! kill -0 "$guard_pid" 2>/dev/null || pid_is_zombie_process "$guard_pid"; } \
      && { ! kill -0 "$launcher_pid" 2>/dev/null || pid_is_zombie_process "$launcher_pid"; }; then
      break
    fi
    sleep 0.02
  done
  ! kill -0 "$guard_pid" 2>/dev/null \
    || pid_is_zombie_process "$guard_pid" \
    || fail "guardian survived its original parent"
  ! kill -0 "$launcher_pid" 2>/dev/null \
    || pid_is_zombie_process "$launcher_pid" \
    || fail "launcher survived guardian parent-exit cleanup"
  if find "$(dirname "$lock_path")" -maxdepth 1 \
      \( -name 'launch-guard.*' -o -name 'launch-pid.*' -o -name 'launch-group.*' \) -print -quit | grep -q .; then
    fail "guardian parent-exit cleanup left a handshake file"
  fi
  guard_pid=""
  launcher_pid=""
  group_pid=""
  trap - EXIT
  rm -f "$CLAUDE_RC_HOLD_FILE"
)

test_claude_remote_control_launch_guard_supports_system_bash() (
  local sandbox repo wrapper out
  if [ "$(uname -s)" != "Darwin" ]; then
    printf 'N/A: claude remote-control system Bash guardian fixture requires Darwin (runner=%s)\n' \
      "$(uname -s)" >&2
    return 0
  fi
  [ -x /bin/bash ] || fail "Darwin system Bash is unavailable at /bin/bash"
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  wrapper="$(_claude_rc_wrapper_script)"
  : > "$CLAUDE_RC_HOLD_FILE"
  trap 'rm -f "$CLAUDE_RC_HOLD_FILE"' EXIT

  out="$(_claude_rc_run "$repo" /bin/bash -u "$wrapper" start 2>&1)" \
    || fail "system Bash could not execute the guardian handshake: $out"
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "system Bash start did not launch the bridge"
  assert_not_contains "$out" "BASHPID"
  _claude_rc_release_server "$repo"
  trap - EXIT
)

test_claude_remote_control_maint_does_not_handoff_competing_lock() (
  local sandbox repo maint lock_path marker_file pid_file competitor_pid out rc log_count_after
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  maint="$(_claude_rc_maint_script)"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  marker_file="$sandbox/competitor.marker"
  pid_file="$sandbox/competitor.pid"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_install_competing_launcher_flock
  export CLAUDE_RC_DECLARED_INSTANCES
  CLAUDE_RC_DECLARED_INSTANCES="$(
    jq -nc --arg path "$repo" \
      '[{path:$path,spawn:"worktree",capacity:null,permissionMode:"bypassPermissions"}]'
  )"

  rc=0
  out="$(_claude_rc_run_maint "$repo" env \
    SERVER_START_SETTLE_SECONDS=0.25 \
    STARTED_IDENTITY_POLL_ATTEMPTS=1 \
    STARTED_IDENTITY_POLL_INTERVAL_SECONDS=0.01 \
    FAKE_FLOCK_LAUNCH_PATH="$lock_path" \
    FAKE_FLOCK_LAUNCH_DELAY_SECONDS=1 \
    FAKE_FLOCK_COMPETITOR_HOLD_SECONDS=0.8 \
    FAKE_FLOCK_COMPETITOR_MARKER="$marker_file" \
    FAKE_FLOCK_COMPETITOR_PID_FILE="$pid_file" \
    bash "$maint" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "competing lock fixture must not produce a successful ensure"
  [ -s "$pid_file" ] || fail "competing lock fixture did not run: $out"
  competitor_pid="$(cat "$pid_file")"
  log_count_after="$(grep -Fc 'remote-control' "$CLAUDE_RC_LOG" 2>/dev/null || true)"
  for _ in {1..100}; do
    kill -0 "$competitor_pid" 2>/dev/null || break
    sleep 0.02
  done

  "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "failed startup must not hand off a delayed launcher because another process held the lock"
  [ "$(grep -Fc 'remote-control' "$CLAUDE_RC_LOG" 2>/dev/null || true)" = "$log_count_after" ] \
    || fail "failed competing launch must not start after ensure returned"
  rm -f "$CLAUDE_RC_HOLD_FILE"
)
