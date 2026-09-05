# tests/suites/claude-remote-control-maint.sh — Claude Remote Control fixtures
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031,SC2034,SC2154,SC2164
# shellcheck source=../lib/claude-remote-control-fixtures.sh
. "$SCRIPT_DIR/lib/claude-remote-control-fixtures.sh"

test_claude_remote_control_maint_rejects_joined_managed_argv_decoy() {
  local sandbox repo slug lock_path lock_pid status rc lock_remained_held
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_running_server_mocks
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "same-dir" "null" "bypassPermissions" "manual"
  slug="$(_claude_rc_slug "$repo")"
  mkdir -p "$CLAUDE_RC_STATE/$slug"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"

  _claude_rc_acquire_synthetic_lock "$lock_path" "joined-argv"
  lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"
  _claude_rc_write_pid_argv_fixture 6262 \
    claude 'remote-control --no-create-session-in-dir' \
    --spawn same-dir --permission-mode bypassPermissions
  _claude_rc_write_pid_argv_fixture 6261 \
    flock -n "$lock_path" claude 'remote-control --no-create-session-in-dir' \
    --spawn same-dir --permission-mode bypassPermissions

  rc=0
  FAKE_SERVER_CWD="$repo" \
  FAKE_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
  FAKE_SERVER_LOCK_PATH="$lock_path" \
  FAKE_SERVER_FLOCK_EXE="$CLAUDE_RC_REAL_FLOCK" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  lock_remained_held=false
  if ! "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    lock_remained_held=true
  fi
  _claude_rc_release_synthetic_lock "$lock_pid"

  [ "$rc" -ne 0 ] || fail "joined managed tokens in one argv element must be rejected"
  [ "$lock_remained_held" = true ] || fail "joined-argv decoy lock holder must not be disturbed"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .instances[0].action == "no-server-process"
    and .instances[0].processState == "unknown"
    and .instances[0].runningVersion == ""
  ' <<<"$status" >/dev/null || fail "joined-argv decoy status mismatch: $status"
}

test_claude_remote_control_maint_rejects_unmanaged_same_cwd_server() {
  local sandbox repo status rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_unmanaged_process_mocks

  rc=0
  FAKE_UNMANAGED_CWD="$repo"
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_SERVER_EXE"
  _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  unset FAKE_UNMANAGED_CWD FAKE_UNMANAGED_EXE
  [ "$rc" -ne 0 ] || fail "maint should fail when unmanaged same-cwd server exists"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .exitCode != 0
    and .instances[0].action == "unmanaged-server-present"
  ' <<<"$status" >/dev/null || fail "unmanaged status mismatch: $status"
  [ ! -s "$CLAUDE_RC_LOG" ] || fail "maint unmanaged guard must not start claude: $(cat "$CLAUDE_RC_LOG")"
}

test_claude_remote_control_maint_reports_missing_path_with_live_lock() {
  local sandbox repo slug lock_path lock_pid status rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  slug="$(_claude_rc_slug "$repo")"
  mkdir -p "$CLAUDE_RC_STATE/$slug"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"
  _claude_rc_acquire_synthetic_lock "$lock_path" "missing path with live lock"
  lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"
  rm -rf "$repo"

  rc=0
  _claude_rc_run_maint "$sandbox" bash "$(_claude_rc_maint_script)" ensure \
    >/dev/null 2>&1 || rc=$?
  _claude_rc_release_synthetic_lock "$lock_pid"

  [ "$rc" -ne 0 ] || fail "missing path with held lock must fail closed"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .exitCode != 0
    and .instances[0].action == "path-missing-lock-held"
    and .instances[0].processState == "unknown"
    and .instances[0].runningVersion == ""
  ' <<<"$status" >/dev/null || fail "missing-path held-lock status mismatch: $status"
}

test_claude_remote_control_maint_propagates_result_write_failure() (
  local sandbox missing maint out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  missing="$sandbox/missing"
  maint="$(_claude_rc_maint_script)"
  _claude_rc_install_results_write_failure_mktemp
  export CLAUDE_RC_DECLARED_INSTANCES
  CLAUDE_RC_DECLARED_INSTANCES="$(
    jq -nc --arg path "$missing" \
      '[{path:$path,spawn:"worktree",capacity:null,permissionMode:"bypassPermissions"}]'
  )"

  rc=0
  out="$(_claude_rc_run_maint "$sandbox" "$maint" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "result write failure must make ensure fail: $out"
)

test_claude_remote_control_maint_propagates_status_write_failure() (
  local sandbox repo maint out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  maint="$(_claude_rc_maint_script)"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_status_write_failure_mktemp
  : > "$CLAUDE_RC_HOLD_FILE"

  rc=0
  out="$(_claude_rc_run_maint "$repo" bash "$maint" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "final status write failure must make ensure fail: $out"
  assert_contains "$out" "failed to write final status"
  [ ! -e "$CLAUDE_RC_STATE/status.json" ] \
    || fail "failed final status write unexpectedly published status.json"

  _claude_rc_release_server "$repo"
)

test_claude_remote_control_start_failure_preserves_unknown_state() {
  local sandbox repo status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_launch_pid_failure_mktemp

  rc=0
  out="$(_claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "launcher setup failure must fail ensure: $out"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .instances[0].action == "start-failed"
    and .instances[0].processState == "unknown"
  ' <<<"$status" >/dev/null \
    || fail "unverified launch failure must preserve unknown state: $status"
}

test_claude_remote_control_slug_uses_hash_for_same_basename() {
  local sandbox repo_a repo_b slug_a slug_b status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo_a="$sandbox/a/project"
  repo_b="$sandbox/b/project"
  _claude_rc_make_repo "$repo_a" "$CLAUDE_RC_HOME"
  _claude_rc_make_repo "$repo_b" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  _claude_rc_run "$repo_a" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_run "$repo_b" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  slug_a="$(_claude_rc_slug "$repo_a")"
  slug_b="$(_claude_rc_slug "$repo_b")"
  [ "$slug_a" != "$slug_b" ] || fail "same basename paths should produce distinct slugs"
  [ -d "$CLAUDE_RC_STATE/$slug_a" ] || fail "missing state dir for $repo_a"
  [ -d "$CLAUDE_RC_STATE/$slug_b" ] || fail "missing state dir for $repo_b"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg a "$repo_a" --arg b "$repo_b" '.instances | has($a) and has($b)' <<<"$status" >/dev/null \
    || fail "both same-basename repos should be registered: $status"

  rm -f "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_wait_lock_free "$CLAUDE_RC_STATE/$slug_a/lock" || fail "repo_a lock remained held"
  _claude_rc_wait_lock_free "$CLAUDE_RC_STATE/$slug_b/lock" || fail "repo_b lock remained held"
}

test_claude_remote_control_cleanup_removes_only_orphan_worktrees() {
  local sandbox repo live_dir orphan_dir
  sandbox="$(_claude_rc_new_sandbox)"
  repo="$sandbox/repo"
  create_git_fixture_repo "$repo"
  _claude_rc_setup "$sandbox"
  live_dir="$repo/.claude/worktrees/feature_one"
  orphan_dir="$repo/.claude/worktrees/orphan_one"
  mkdir -p "$orphan_dir"

  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" cleanup >/dev/null
  [ -d "$live_dir" ] || fail "registered worktree should be preserved"
  [ ! -e "$orphan_dir" ] || fail "orphan worktree dir should be removed"
}

test_claude_remote_control_maint_reconciles_declared_instances() {
  local sandbox declared_path manual_path payload status registered_at
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  declared_path="$sandbox/missing-project"
  payload="$(jq -n -c --arg path "$declared_path" '[{path: $path, spawn: "worktree", capacity: null, permissionMode: "bypassPermissions"}]')"

  CLAUDE_RC_DECLARED_INSTANCES="$payload" _claude_rc_run_maint "$sandbox" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$declared_path" '
    .instances[$path].source == "declared"
    and .instances[$path].spawn == "worktree"
    and .instances[$path].capacity == null
    and .instances[$path].permissionMode == "bypassPermissions"
  ' <<<"$status" >/dev/null || fail "declared seed schema mismatch: $status"
  registered_at="$(jq -r --arg path "$declared_path" '.instances[$path].registeredAt' <<<"$status")"

  payload="$(jq -n -c --arg path "$declared_path" '[{path: $path, spawn: "same-dir", capacity: 9, permissionMode: "plan"}]')"
  CLAUDE_RC_DECLARED_INSTANCES="$payload" _claude_rc_run_maint "$sandbox" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$declared_path" --arg registeredAt "$registered_at" '
    .instances[$path].source == "declared"
    and .instances[$path].spawn == "same-dir"
    and .instances[$path].capacity == 9
    and .instances[$path].permissionMode == "plan"
    and .instances[$path].registeredAt == $registeredAt
  ' <<<"$status" >/dev/null || fail "declared instance should reconcile to current declaration: $status"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  manual_path="$sandbox/manual-project"
  _claude_rc_write_instance "$manual_path" "same-dir" "9" "plan" "manual"
  payload="$(jq -n -c --arg path "$manual_path" '[{path: $path, spawn: "worktree", capacity: null, permissionMode: "bypassPermissions"}]')"
  CLAUDE_RC_DECLARED_INSTANCES="$payload" _claude_rc_run_maint "$sandbox" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$manual_path" '
    .instances[$path].source == "declared"
    and .instances[$path].spawn == "worktree"
    and .instances[$path].capacity == null
    and .instances[$path].permissionMode == "bypassPermissions"
  ' <<<"$status" >/dev/null || fail "declared path should override manual registry entry: $status"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  manual_path="$sandbox/manual-project"
  declared_path="$sandbox/declared-project"
  _claude_rc_write_instance "$manual_path" "same-dir" "9" "plan" "manual"
  payload="$(jq -n -c --arg path "$declared_path" '[{path: $path, spawn: "worktree", capacity: null, permissionMode: "bypassPermissions"}]')"
  CLAUDE_RC_DECLARED_INSTANCES="$payload" _claude_rc_run_maint "$sandbox" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$manual_path" --arg declared "$declared_path" '
    .instances[$path].source == "manual"
    and .instances[$path].spawn == "same-dir"
    and .instances[$path].capacity == 9
    and .instances[$path].permissionMode == "plan"
    and .instances[$declared].source == "declared"
  ' <<<"$status" >/dev/null || fail "undeclared manual instance should remain untouched: $status"
}

test_claude_remote_control_maint_uses_effective_spawn_for_drift_gate() {
  local sandbox repo slug lock_path lock_pid status mode
  local -a server_argv parent_argv

  for mode in explicit-spawn default-spawn
  do
    sandbox="$(_claude_rc_new_sandbox)"
    _claude_rc_setup "$sandbox"
    _claude_rc_install_running_server_mocks
    repo="$sandbox/repo"
    _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
    _claude_rc_write_instance "$repo" "same-dir" "null" "bypassPermissions" "manual"
    _claude_rc_make_recent_worktree_transcript "$repo"
    slug="$(_claude_rc_slug "$repo")"
    mkdir -p "$CLAUDE_RC_STATE/$slug"
    lock_path="$CLAUDE_RC_STATE/$slug/lock"

    _claude_rc_acquire_synthetic_lock "$lock_path" "effective spawn"
    lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"
    if [ "$mode" = explicit-spawn ]; then
      server_argv=(claude remote-control --spawn worktree --permission-mode bypassPermissions --no-create-session-in-dir)
    else
      server_argv=(claude remote-control --permission-mode bypassPermissions --no-create-session-in-dir)
    fi
    parent_argv=(flock -n "$lock_path" "${server_argv[@]}")
    _claude_rc_write_pid_argv_fixture 6262 "${server_argv[@]}"
    _claude_rc_write_pid_argv_fixture 6261 "${parent_argv[@]}"

    CLAUDE_RC_DRIFT_POLICY=automatic \
    FAKE_SERVER_CWD="$repo" \
    FAKE_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
    FAKE_SERVER_LOCK_PATH="$lock_path" \
    FAKE_SERVER_FLOCK_EXE="$CLAUDE_RC_REAL_FLOCK" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
    _claude_rc_release_synthetic_lock "$lock_pid"
    status="$(cat "$CLAUDE_RC_STATE/status.json")"
    jq -e '
      .action == "completed"
      and .instances[0].action == "deferred-active-sessions"
    ' <<<"$status" >/dev/null || fail "effective spawn drift gate mismatch for [$mode]: $status"
  done
}

test_claude_remote_control_maint_accepts_previous_generation_flock() {
  local family sandbox repo slug lock_path lock_pid status fake_hash previous_flock
  local -a server_argv parent_argv
  fake_hash="$(printf '%032d' 0)"
  for family in util-linux flock; do
    sandbox="$(_claude_rc_new_sandbox)"
    _claude_rc_setup "$sandbox"
    _claude_rc_install_running_server_mocks
    repo="$sandbox/repo"
    _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
    _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
    _claude_rc_make_recent_worktree_transcript "$repo"
    slug="$(_claude_rc_slug "$repo")"
    mkdir -p "$CLAUDE_RC_STATE/$slug"
    lock_path="$CLAUDE_RC_STATE/$slug/lock"
    previous_flock="/nix/store/${fake_hash}-${family}-0/bin/flock"
    [ "$previous_flock" != "$CLAUDE_RC_REAL_FLOCK" ] \
      || fail "previous-generation $family fixture must differ from the current runtime"

    _claude_rc_acquire_synthetic_lock "$lock_path" "previous-generation $family flock"
    lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"
    server_argv=(claude remote-control --spawn worktree --permission-mode bypassPermissions --no-create-session-in-dir)
    parent_argv=(flock -n "$lock_path" "${server_argv[@]}")
    _claude_rc_write_pid_argv_fixture 6262 "${server_argv[@]}"
    _claude_rc_write_pid_argv_fixture 6261 "${parent_argv[@]}"

    CLAUDE_RC_DRIFT_POLICY=automatic \
    FAKE_SERVER_CWD="$repo" \
    FAKE_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
    FAKE_SERVER_LOCK_PATH="$lock_path" \
    FAKE_SERVER_FLOCK_EXE="$previous_flock" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
    _claude_rc_release_synthetic_lock "$lock_pid"
    status="$(cat "$CLAUDE_RC_STATE/status.json")"
    jq -e '
      .action == "completed"
      and .instances[0].action == "deferred-active-sessions"
      and .instances[0].processState == "running"
    ' <<< "$status" >/dev/null \
      || fail "previous-generation $family flock lineage was not preserved: $status"
  done
}

test_claude_remote_control_maint_rejects_bridge_with_separate_lock_holder() {
  local mode sandbox repo slug lock_path lock_pid status rc lock_remained_held
  local flock_exe
  local -a server_argv parent_argv

  for mode in unlocked-target wrong-lock untrusted-flock; do
    sandbox="$(_claude_rc_new_sandbox)"
    _claude_rc_setup "$sandbox"
    _claude_rc_install_running_server_mocks
    repo="$sandbox/repo"
    _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
    _claude_rc_write_instance "$repo" "same-dir" "null" "bypassPermissions" "manual"
    slug="$(_claude_rc_slug "$repo")"
    mkdir -p "$CLAUDE_RC_STATE/$slug"
    lock_path="$CLAUDE_RC_STATE/$slug/lock"

    _claude_rc_acquire_synthetic_lock "$lock_path" "separate holder $mode"
    lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"

    server_argv=(claude remote-control --spawn same-dir --permission-mode bypassPermissions --no-create-session-in-dir)
    flock_exe="$CLAUDE_RC_REAL_FLOCK"
    case "$mode" in
      unlocked-target) parent_argv=(flock -u "$lock_path" "${server_argv[@]}") ;;
      wrong-lock) parent_argv=(flock -n "$sandbox/other.lock" "${server_argv[@]}") ;;
      untrusted-flock)
        parent_argv=(flock -n "$lock_path" "${server_argv[@]}")
        flock_exe="$sandbox/untrusted/flock"
        ;;
    esac
    _claude_rc_write_pid_argv_fixture 6262 "${server_argv[@]}"
    _claude_rc_write_pid_argv_fixture 6261 "${parent_argv[@]}"

    rc=0
    FAKE_SERVER_CWD="$repo" \
    FAKE_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
    FAKE_SERVER_LOCK_PATH="$lock_path" \
    FAKE_SERVER_FLOCK_EXE="$flock_exe" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
    lock_remained_held=false
    if ! "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
      lock_remained_held=true
    fi
    _claude_rc_release_synthetic_lock "$lock_pid"

    [ "$rc" -ne 0 ] || fail "maint must reject unproven lock lineage: $mode"
    [ "$lock_remained_held" = true ] || fail "maint must not disturb separate lock holder: $mode"
    status="$(cat "$CLAUDE_RC_STATE/status.json")"
    jq -e '
      .action == "failed"
      and .instances[0].action == "no-server-process"
    ' <<<"$status" >/dev/null || fail "separate lock holder status mismatch ($mode): $status"
  done
}

_claude_rc_install_delayed_free_flock() {
  unlink "$CLAUDE_RC_FAKE_BIN/flock"
  {
    printf '#!/usr/bin/env bash\nREAL_FLOCK=%q\n' "$CLAUDE_RC_REAL_FLOCK"
    cat <<'EOS'
set -euo pipefail
if [ "$#" -eq 3 ] \
  && [ "$1" = "-n" ] \
  && [ -n "${FAKE_FLOCK_DELAY_PATH:-}" ] \
  && [ "$2" = "$FAKE_FLOCK_DELAY_PATH" ] \
  && [ "$3" = "true" ]; then
  if "$REAL_FLOCK" "$@"; then
    remaining=0
    if [ -f "${FAKE_FLOCK_DELAY_STATE:-}" ]; then
      remaining=$(cat "$FAKE_FLOCK_DELAY_STATE")
    fi
    if [ "${remaining:-0}" -gt 0 ]; then
      printf '%s\n' "$((remaining - 1))" > "$FAKE_FLOCK_DELAY_STATE"
      exit 1
    fi
    exit 0
  fi
  exit 1
fi
exec "$REAL_FLOCK" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/flock"
  chmod +x "$CLAUDE_RC_FAKE_BIN/flock"
}

test_claude_remote_control_maint_rejects_invalid_declared_instances() {
  local sandbox repo payload status rc

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  rc=0
  CLAUDE_RC_DECLARED_INSTANCES='{"path":"/path/to/project"}' \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "non-array declared instances should fail"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '.action == "declared-instances-invalid" and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "non-array invalid status mismatch: $status"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  payload='[{"path":"relative/project","spawn":"worktree","capacity":null}]'
  rc=0
  CLAUDE_RC_DECLARED_INSTANCES="$payload" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "relative declared path should fail"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '.action == "declared-instances-invalid" and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "relative path invalid status mismatch: $status"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  payload="$(jq -n -c --arg path "$repo" '[{path: $path, spawn: "bad-spawn", capacity: null}]')"
  rc=0
  CLAUDE_RC_DECLARED_INSTANCES="$payload" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "invalid declared spawn should fail"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '.action == "declared-instances-invalid" and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "invalid spawn status mismatch: $status"
}

test_claude_remote_control_transcript_gate_scopes_to_worktree_dirs() {
  local sandbox repo copy out
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  copy="$(_claude_rc_maint_script)"
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/pgrep"

  out="$(
    HOME="$CLAUDE_RC_HOME" STATE_DIR="$CLAUDE_RC_STATE" PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
      bash -c '
        set -euo pipefail
        # shellcheck source=/dev/null
        . "$1"
        repo="$2"
        prefix="$(normalized_instance_prefix "$repo")"
        mkdir -p "$PROJECTS_DIR/$prefix"
        : > "$PROJECTS_DIR/$prefix/root.jsonl"
        root_count="$(count_recent_instance_transcripts "$repo")"
        root_gate=0
        restart_gate "$repo" || root_gate=$?
        mkdir -p "$PROJECTS_DIR/${prefix}--claude-worktrees-bridge-cse-1"
        : > "$PROJECTS_DIR/${prefix}--claude-worktrees-bridge-cse-1/worktree.jsonl"
        worktree_count="$(count_recent_instance_transcripts "$repo")"
        worktree_gate=0
        restart_gate "$repo" || worktree_gate=$?
        printf "root_count=%s root_gate=%s worktree_count=%s worktree_gate=%s\n" \
          "$root_count" "$root_gate" "$worktree_count" "$worktree_gate"
      ' _ "$copy" "$repo"
  )"
  [ "$out" = "root_count=0 root_gate=0 worktree_count=1 worktree_gate=1" ] \
    || fail "transcript gate scope mismatch: $out"
}

test_claude_remote_control_session_matcher_honors_option_terminator() {
  local sandbox repo copy rc decoy
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  copy="$(_claude_rc_wrapper_script)"

  _claude_rc_write_pid_argv_fixture 5252 \
    /path/to/versions/2.0.0 --print --sdk-url https://example.invalid
  _claude_rc_run "$repo" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    pid_is_session_proc 5252
  ' _ "$copy" || fail "split sdk-url session shape must be recognized"

  _claude_rc_write_pid_argv_fixture 5252 \
    /path/to/versions/2.0.0 --print --sdk-url=https://example.invalid
  _claude_rc_run "$repo" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    pid_is_session_proc 5252
  ' _ "$copy" || fail "joined sdk-url session shape must be recognized"

  for decoy in split joined; do
    if [ "$decoy" = split ]; then
      _claude_rc_write_pid_argv_fixture 5252 \
        /path/to/versions/2.0.0 --print -- --sdk-url https://example.invalid
    else
      _claude_rc_write_pid_argv_fixture 5252 \
        /path/to/versions/2.0.0 --print -- --sdk-url=https://example.invalid
    fi
    rc=0
    _claude_rc_run "$repo" bash -c '
      # shellcheck source=/dev/null
      . "$1"
      pid_is_session_proc 5252
    ' _ "$copy" || rc=$?
    [ "$rc" -eq 1 ] || fail "$decoy sdk-url prompt decoy must not be a session process, got $rc"
  done

  _claude_rc_write_pid_argv_fixture 5252 /path/to/versions/2.0.0 --print --sdk-url
  rc=0
  _claude_rc_run "$repo" bash -c '
    # shellcheck source=/dev/null
    . "$1"
    pid_is_session_proc 5252
  ' _ "$copy" || rc=$?
  [ "$rc" -eq 1 ] || fail "sdk-url without a value must not be a session process, got $rc"
}

test_claude_remote_control_maint_reaps_orphan_sessions_before_start() {
  local sandbox repo orphan_dir term_mark orphan_pid out status rc non_versioned_reaped
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  orphan_dir="$repo/.claude/worktrees/orphan-session"
  term_mark="$sandbox/orphan.term"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  mkdir -p "$orphan_dir"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_orphan_session_mocks
  : > "$CLAUDE_RC_HOLD_FILE"

  bash -c '
    set -euo pipefail
    cd "$1"
    trap '\''printf term >"$2"; exit 0'\'' TERM
    while :; do sleep 0.1; done
  ' _ "$orphan_dir" "$term_mark" &
  orphan_pid=$!
  _claude_rc_write_pid_argv_fixture "$orphan_pid" \
    /path/to/versions/2.0.0 --print --sdk-url https://example.invalid

  rc=0
  FAKE_ORPHAN_PID="$orphan_pid" \
  FAKE_ORPHAN_CWD="$orphan_dir" \
  FAKE_ORPHAN_EXE="$CLAUDE_RC_VERSIONS/claude-session" \
  FAKE_ORPHAN_PPID=1 \
    out="$(_claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?

  for _ in {1..20}; do
    [ -f "$term_mark" ] && break
    sleep 0.1
  done
  kill "$orphan_pid" 2>/dev/null || true
  wait "$orphan_pid" 2>/dev/null || true

  [ "$rc" -eq 0 ] || fail "maint should continue after orphan reap, got $rc: $out"
  assert_contains "$out" "reaped 1 orphan session process(es)"
  [ -f "$term_mark" ] || fail "orphan session did not receive SIGTERM before start"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .instances[0].action == "started"
  ' <<<"$status" >/dev/null || fail "orphan reap should continue into started status: $status"

  _claude_rc_release_server "$repo"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  orphan_dir="$repo/.claude/worktrees/non-versioned-session"
  term_mark="$sandbox/non-versioned.term"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  mkdir -p "$orphan_dir"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_orphan_session_mocks
  : > "$CLAUDE_RC_HOLD_FILE"

  bash -c '
    set -euo pipefail
    cd "$1"
    trap '\''printf term >"$2"; exit 0'\'' TERM
    while :; do sleep 0.1; done
  ' _ "$orphan_dir" "$term_mark" &
  orphan_pid=$!
  _claude_rc_write_pid_argv_fixture "$orphan_pid" \
    /path/to/versions/2.0.0 --print --sdk-url https://example.invalid

  rc=0
  FAKE_ORPHAN_PID="$orphan_pid" \
  FAKE_ORPHAN_CWD="$orphan_dir" \
  FAKE_ORPHAN_EXE="$sandbox/outside/not-claude" \
  FAKE_ORPHAN_PPID=1 \
    out="$(_claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?

  sleep 0.3
  non_versioned_reaped=false
  [ -f "$term_mark" ] && non_versioned_reaped=true
  kill "$orphan_pid" 2>/dev/null || true
  wait "$orphan_pid" 2>/dev/null || true

  [ "$rc" -eq 0 ] || fail "maint should continue when non-versioned sdk-url process is ignored, got $rc: $out"
  assert_not_contains "$out" "reaped"
  [ "$non_versioned_reaped" = false ] || fail "non-versioned --sdk-url process must not be reaped"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .instances[0].action == "started"
  ' <<<"$status" >/dev/null || fail "ignored non-versioned process should still allow start: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_status_schema() {
  local sandbox repo status log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  : > "$CLAUDE_RC_HOLD_FILE"

  _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "fake claude log did not appear before status assertion"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    (.timestamp | type == "string")
    and (.exitCode | type == "number")
    and (.action | type == "string")
    and (.instances | type == "array")
    and (.instances[0].action == "started")
    and .instances[0].processState == "running"
    and .instances[0].runningVersion == "claude-new"
    and .instances[0].observedVersion == "claude-new"
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "status schema mismatch: $status"

  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" $'\t'"$CLAUDE_RC_VERSIONS/claude-new"$'\tremote-control'
  assert_contains "$log" "remote-control --spawn worktree --permission-mode bypassPermissions --no-create-session-in-dir"
  assert_not_contains "$log" "--capacity"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_executes_canonical_nonstandard_launcher_target() {
  local sandbox repo launcher status log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  launcher="$CLAUDE_RC_MANAGED_BIN/bridge-entrypoint"
  ln -sf "$CLAUDE_RC_FAKE_BIN/claude" "$launcher"
  : > "$CLAUDE_RC_HOLD_FILE"

  CLAUDE_RC_TEST_MAINT_BIN="$launcher" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .instances[0].action == "started"
    and .instances[0].processState == "running"
    and .instances[0].runningVersion == "claude-new"
    and .instances[0].observedVersion == "claude-new"
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "nonstandard launcher status mismatch: $status"
  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" $'\t'"$CLAUDE_RC_VERSIONS/claude-new"$'\tremote-control'

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_rejects_launcher_outside_versions_before_exec() {
  local sandbox repo launcher external marker status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  launcher="$CLAUDE_RC_MANAGED_BIN/bridge-entrypoint"
  external="$sandbox/outside/claude-external"
  marker="$sandbox/external-launcher-ran"
  mkdir -p "$(dirname "$external")"
  cat > "$external" <<EOF
#!/usr/bin/env bash
printf 'ran\n' > "$marker"
exit 0
EOF
  chmod +x "$external"
  ln -sf "$external" "$launcher"

  rc=0
  out="$(
    CLAUDE_RC_TEST_MAINT_BIN="$launcher" \
    FAKE_CLAUDE_RESOLVED_EXE_OVERRIDE="$external" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1
  )" || rc=$?
  [ "$rc" -ne 0 ] || fail "external launcher target must fail before exec: $out"
  assert_contains "$out" "outside VERSIONS_DIR"
  [ ! -e "$marker" ] || fail "external launcher ran before the versions boundary rejected it"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "desired-version-unresolvable"
    and .exitCode != 0
    and (.instances | length) == 0
  ' <<<"$status" >/dev/null || fail "external launcher rejection status mismatch: $status"
}

test_claude_remote_control_maint_rejects_unverifiable_started_server() {
  local sandbox repo lock_path status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_no_process_mocks
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  : > "$CLAUDE_RC_HOLD_FILE"

  rc=0
  out="$(_claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  "$CLAUDE_RC_REAL_FLOCK" -n "$lock_path" true \
    || fail "unverifiable start must stop its exact guardian-owned replacement: $out"
  _claude_rc_release_server "$repo"

  [ "$rc" -ne 0 ] || fail "maint must reject a held lock without a verifiable server process: $out"
  assert_contains "$out" "server process/version unresolvable"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .exitCode != 0
    and (.instances | length == 1)
    and .instances[0].action == "start-version-unresolvable-cleaned"
    and .instances[0].processState == "stopped"
    and .instances[0].runningVersion == ""
    and .instances[0].observedVersion == ""
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "unverifiable start cleanup status mismatch: $status"
}

test_claude_remote_control_unverifiable_cleanup_does_not_claim_competitor_stopped() {
  local sandbox repo lock_path marker competitor_hold_file competitor_pid competitor_status timeout_bin status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_no_process_mocks
  _claude_rc_install_owned_lock_marker_flock
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  : > "$CLAUDE_RC_HOLD_FILE"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  marker="$sandbox/owned-lock.marker"
  competitor_hold_file="$sandbox/competitor.hold"
  timeout_bin="$(command -v timeout)" || fail "GNU timeout is required"
  : > "$competitor_hold_file"

  # shellcheck disable=SC2329 # invoked by the EXIT trap on fixture failure
  cleanup_unverifiable_competitor_fixture() {
    rm -f "$competitor_hold_file"
    if [ -n "${competitor_pid:-}" ]; then
      kill -TERM "$competitor_pid" 2>/dev/null || true
      wait "$competitor_pid" 2>/dev/null || true
    fi
    rm -f "$CLAUDE_RC_HOLD_FILE"
  }
  trap cleanup_unverifiable_competitor_fixture EXIT

  (
    for _ in {1..3000}; do
      [ -e "$marker" ] && break
      sleep 0.01
    done
    [ -e "$marker" ] || exit 98
    "$CLAUDE_RC_REAL_FLOCK" "$lock_path" \
      "$timeout_bin" -k 1s 300s bash -c \
      'while [ -e "$1" ]; do sleep 0.05; done' _ "$competitor_hold_file"
  ) &
  competitor_pid=$!

  rc=0
  out="$(_claude_rc_run_maint "$repo" env \
    STOPPED_LOCK_POLL_ATTEMPTS=2 \
    STOPPED_LOCK_POLL_INTERVAL_SECONDS=0.01 \
    FAKE_FLOCK_LAUNCH_PATH="$lock_path" \
    FAKE_FLOCK_OWNED_MARKER="$marker" \
    bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "unverifiable launch with a successor lock owner must fail: $out"
  if ! kill -0 "$competitor_pid" 2>/dev/null; then
    competitor_status=0
    wait "$competitor_pid" 2>/dev/null || competitor_status=$?
    fail "successor lock owner exited early (status=$competitor_status, hold=$([ -e "$competitor_hold_file" ] && echo present || echo missing))"
  fi
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .instances[0].action == "start-version-unresolvable"
    and .instances[0].processState == "unknown"
  ' <<<"$status" >/dev/null \
    || fail "competitor-held lock must not be reported as stopped: $status"

  cleanup_unverifiable_competitor_fixture
  competitor_pid=""
  trap - EXIT
}

test_claude_remote_control_maint_rejects_mismatched_started_version() {
  local sandbox repo lock_path status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  : > "$CLAUDE_RC_HOLD_FILE"

  rc=0
  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
    out="$(_claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true \
    || fail "mismatched start must terminate the wrong bridge and release its lock: $out"
  _claude_rc_release_server "$repo"

  [ "$rc" -ne 0 ] || fail "maint must reject a newly started wrong version: $out"
  assert_contains "$out" "start version mismatch"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .exitCode != 0
    and .instances[0].action == "start-version-mismatch"
    and .instances[0].processState == "stopped"
    and .instances[0].runningVersion == ""
    and .instances[0].observedVersion == "claude-old"
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "mismatched start must fail closed: $status"
}

test_claude_remote_control_maint_restart_records_verified_version() {
  local sandbox repo status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "initial fake server did not start before restart test"

  CLAUDE_RC_DRIFT_POLICY=automatic \
  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_VERSIONS/claude-new" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .exitCode == 0
    and .instances[0].action == "restarted-version-drift"
    and .instances[0].processState == "running"
    and .instances[0].runningVersion == "claude-new"
    and .instances[0].observedVersion == "claude-new"
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "restart must record the verified new version: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_default_policy_preserves_live_drift() {
  local sandbox repo status lock_path
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "initial fake server did not start before deferred drift test"

  unset CLAUDE_RC_DRIFT_POLICY
  _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .exitCode == 0
    and .instances[0].action == "deferred-restart-confirmation"
    and .instances[0].processState == "running"
    and .instances[0].runningVersion == "claude-server"
    and .instances[0].observedVersion == "claude-server"
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "default drift policy must preserve the verified live version: $status"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    fail "deferred drift must leave the existing bridge lock held"
  fi

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_confirmed_drift_binds_exact_snapshot() {
  local sandbox repo status approval bad_approval env_log lock_path out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  env_log="$sandbox/bridge-env.log"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "initial fake server did not start before confirmed drift test"

  CLAUDE_RC_DRIFT_POLICY=defer \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  approval="$(jq -c '
    [.instances[]
      | select(.action == "deferred-restart-confirmation")
      | {path, runningVersion, desiredVersion}]
    | sort_by([.path, .runningVersion, .desiredVersion])
  ' <<<"$status")"
  [ "$(jq 'length' <<<"$approval")" = "1" ] \
    || fail "confirmed drift fixture must produce exactly one approval: $approval"
  bad_approval="$(jq -c '.[0].desiredVersion = "claude-unapproved"' <<<"$approval")"

  rc=0
  out="$(
    CLAUDE_RC_DRIFT_POLICY=confirmed \
    CLAUDE_RC_DRIFT_APPROVAL_JSON="$bad_approval" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1
  )" || rc=$?
  [ "$rc" -ne 0 ] || fail "mismatched drift approval must fail closed: $out"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "invalid-drift-approval"
    and .exitCode != 0
    and (.instances | length) == 0
  ' <<<"$status" >/dev/null || fail "mismatched drift approval status mismatch: $status"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    fail "mismatched drift approval must not restart or release the existing bridge"
  fi

  CLAUDE_RC_DRIFT_POLICY=confirmed \
  CLAUDE_RC_DRIFT_APPROVAL_JSON="$approval" \
  FAKE_CLAUDE_ENV_LOG="$env_log" \
  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_VERSIONS/claude-new" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .exitCode == 0
    and .instances[0].action == "restarted-version-drift"
    and .instances[0].runningVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "exact confirmed drift approval did not restart: $status"
  grep -Fxq 'drift_policy=unset	drift_approval=unset' "$env_log" \
    || fail "restarted bridge inherited one-shot drift approval environment"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_reports_lock_setup_failure() {
  local sandbox status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  mkdir -p "$CLAUDE_RC_STATE/ensure.lock"

  rc=0
  out="$(_claude_rc_run_maint "$sandbox" bash "$(_claude_rc_maint_script)" ensure 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "lifecycle lock setup failure must fail ensure: $out"
  assert_contains "$out" "lifecycle lock setup failed"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "lock-setup-failed"
    and .exitCode != 0
    and (.instances | length) == 0
  ' <<<"$status" >/dev/null || fail "lock setup failure status mismatch: $status"
}

test_claude_remote_control_maint_waits_for_parent_lock_release() {
  local sandbox repo lock_path delay_state status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "initial fake server did not start before delayed lock-release test"

  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  delay_state="$sandbox/delayed-free-probes"
  printf '%s\n' 2 > "$delay_state"
  _claude_rc_install_delayed_free_flock

  CLAUDE_RC_DRIFT_POLICY=automatic \
  FAKE_FLOCK_DELAY_PATH="$lock_path" \
  FAKE_FLOCK_DELAY_STATE="$delay_state" \
  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_VERSIONS/claude-new" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null

  [ "$(cat "$delay_state")" = "0" ] \
    || fail "restart did not consume delayed lock-release probes"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "completed"
    and .exitCode == 0
    and .instances[0].action == "restarted-version-drift"
  ' <<<"$status" >/dev/null || fail "delayed lock release must still restart cleanly: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_restart_rejects_mismatched_version() {
  local sandbox repo lock_path status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "initial fake server did not start before mismatch restart test"

  rc=0
  out="$(
    CLAUDE_RC_DRIFT_POLICY=automatic \
    FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_VERSIONS/claude-wrong" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1
  )" || rc=$?
  [ "$rc" -ne 0 ] || fail "restart must reject a wrong replacement version: $out"
  assert_contains "$out" "restart version mismatch"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true \
    || fail "mismatched restart must terminate the wrong replacement and release its lock: $out"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .exitCode != 0
    and .instances[0].action == "restart-version-mismatch"
    and .instances[0].processState == "stopped"
    and .instances[0].runningVersion == ""
    and .instances[0].observedVersion == "claude-wrong"
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "mismatched restart must fail closed: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_restart_rejects_unverifiable_version() {
  local sandbox repo lock_path status out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  FAKE_CLAUDE_STARTED_EXE="$CLAUDE_RC_SERVER_EXE" \
    _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_wait_fake_claude_log "remote-control --spawn worktree" \
    || fail "initial fake server did not start before unverifiable restart test"

  rc=0
  out="$(
    CLAUDE_RC_DRIFT_POLICY=automatic \
    FAKE_CLAUDE_STARTED_EXE="UNRESOLVABLE" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure 2>&1
  )" || rc=$?
  [ "$rc" -ne 0 ] || fail "restart must reject an unverifiable replacement version: $out"
  assert_contains "$out" "server process/version unresolvable"
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    .action == "failed"
    and .exitCode != 0
    and .instances[0].action == "restart-version-unresolvable-cleaned"
    and .instances[0].processState == "stopped"
    and .instances[0].runningVersion == ""
    and .instances[0].observedVersion == ""
    and .instances[0].desiredVersion == "claude-new"
  ' <<<"$status" >/dev/null || fail "unverifiable restart cleanup status mismatch: $status"
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true \
    || fail "unverifiable replacement must be stopped through its exact guardian: $out"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_maint_action_taxonomy() {
  local script operator_doc actual action expected_state expected_failure
  local expected_snapshot expected_keys actual_keys
  local expected_global_snapshot expected_global_keys actual_global_keys
  local expected_diagnostic_snapshot expected_diagnostic_keys actual_diagnostic_keys
  local global_doc diagnostic_doc instance_doc
  script="$(_claude_rc_maint_script)"
  operator_doc="$REPO_ROOT/.claude/skills/managing-claude-rc/SKILL.md"

  (
    # shellcheck source=/dev/null
    source "$script"
    expected_snapshot="$(cat <<'EOF'
path-missing	stopped	false
path-missing-lock-held	unknown	true
started	running	false
healthy	running	false
restarted-version-drift	running	false
deferred-restart-confirmation	running	false
restart-approval-mismatch	running	true
deferred-active-sessions	running	false
deferred-unknown-activity	running	false
start-version-mismatch	stopped	true
restart-version-mismatch	stopped	true
restart-gate-failed	running	true
start-failed	dynamic	true
invalid-spawn	dynamic	true
invalid-capacity	unknown	true
invalid-permission-mode	unknown	true
unmanaged-server-present	unknown	true
start-version-unresolvable	unknown	true
start-version-unresolvable-cleaned	stopped	true
start-version-mismatch-cleanup-failed	unknown	true
no-server-process	unknown	true
running-version-unresolvable	unknown	true
restart-failed	unknown	true
restart-version-unresolvable	unknown	true
restart-version-unresolvable-cleaned	stopped	true
restart-version-mismatch-cleanup-failed	unknown	true
EOF
)"
    expected_keys="$(cut -f1 <<<"$expected_snapshot" | LC_ALL=C sort)"
    actual_keys="$(instance_action_metadata_table | cut -f1 | LC_ALL=C sort)"
    [ "$actual_keys" = "$expected_keys" ] \
      || fail "production action keys differ from expected snapshot: expected=[$expected_keys] actual=[$actual_keys]"

    expected_global_snapshot="$(cat <<'EOF'
flock-missing
lock-acquire-timeout
lock-setup-failed
declared-instances-invalid
invalid-drift-policy
invalid-drift-approval
desired-version-unresolvable
instances-read-failed
no-instances
completed
failed
EOF
)"
    expected_global_keys="$(LC_ALL=C sort <<<"$expected_global_snapshot")"
    actual_global_keys="$(global_status_action_keys | LC_ALL=C sort)"
    [ "$actual_global_keys" = "$expected_global_keys" ] \
      || fail "production global action keys differ from expected snapshot: expected=[$expected_global_keys] actual=[$actual_global_keys]"

    expected_diagnostic_snapshot="status-write-failed"
    expected_diagnostic_keys="$(LC_ALL=C sort <<<"$expected_diagnostic_snapshot")"
    actual_diagnostic_keys="$(global_diagnostic_action_keys | LC_ALL=C sort)"
    [ "$actual_diagnostic_keys" = "$expected_diagnostic_keys" ] \
      || fail "production diagnostic action keys differ from expected snapshot: expected=[$expected_diagnostic_keys] actual=[$actual_diagnostic_keys]"
    [ "$(global_action_keys | LC_ALL=C sort)" = "$(printf '%s\n%s\n' "$expected_global_snapshot" "$expected_diagnostic_snapshot" | LC_ALL=C sort)" ] \
      || fail "global action setter vocabulary differs from status plus diagnostic snapshots"

    global_doc="$(awk '
      /^### Top-level `status.action`$/ { inside = 1; next }
      inside && /^### / { exit }
      inside { print }
    ' "$operator_doc")"
    diagnostic_doc="$(awk '
      /^### Status publication failure$/ { inside = 1; next }
      inside && /^### / { exit }
      inside { print }
    ' "$operator_doc")"
    instance_doc="$(awk '
      /^### Per-instance `status.instances\[\]\.action`$/ { inside = 1; next }
      inside && /^### / { exit }
      inside { print }
    ' "$operator_doc")"

    while IFS= read -r action; do
      [ -n "$action" ] || continue
      grep -Fq "| \`$action\` |" <<<"$global_doc" \
        || fail "top-level status table omits production action: $action"
    done <<<"$expected_global_snapshot"

    while IFS= read -r action; do
      [ -n "$action" ] || continue
      grep -Fq "\`$action\`" <<<"$diagnostic_doc" \
        || fail "status publication failure docs omit diagnostic action: $action"
      if grep -Fq "| \`$action\` |" <<<"$global_doc"; then
        fail "non-publishable diagnostic action appears in top-level status table: $action"
      fi
    done <<<"$expected_diagnostic_snapshot"

    GLOBAL_ACTION="none"
    set_global_action completed \
      || fail "registered global action must be assignable"
    [ "$GLOBAL_ACTION" = "completed" ] \
      || fail "registered global action assignment mismatch: $GLOBAL_ACTION"
    if set_global_action unregistered-action >/dev/null 2>&1; then
      fail "unknown global action must not be assignable"
    fi
    [ "$GLOBAL_ACTION" = "completed" ] \
      || fail "unknown global action must not mutate the previous value"

    while IFS=$'\t' read -r action expected_state expected_failure; do
      [ -n "$action" ] || continue
      actual="$(instance_action_metadata "$action")" \
        || fail "missing action metadata: $action"
      [ "$actual" = "${expected_state}"$'\t'"${expected_failure}" ] \
        || fail "unexpected metadata for $action: $actual"
      grep -Fq "| \`$action\` |" <<<"$instance_doc" \
        || fail "per-instance status table omits production action: $action"
      if [ "$expected_failure" = "true" ]; then
        is_failure_action "$action" || fail "failure action classified healthy: $action"
      elif is_failure_action "$action"; then
        fail "healthy action classified failed: $action"
      fi
    done <<<"$expected_snapshot"

    if instance_action_metadata unregistered-action >/dev/null 2>&1; then
      fail "unknown action must not acquire implicit metadata"
    fi
    is_failure_action unregistered-action \
      || fail "unknown action must remain fail-closed"
  )
}

# no-server-process는 살아 있는 bridge를 술어 하나가 놓쳐도 난다. 원 스캔이 탈락시킨
# 술어(transient 실패의 유일한 증거)와 재스캔 raw 값, 타임스탬프가 로그에 남아야
# 라인 수 역산 없이 조사할 수 있다.
test_claude_remote_control_maint_logs_no_server_process_diagnostics() {
  local sandbox repo slug lock_path lock_pid rc stderr_file
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_running_server_mocks
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "same-dir" "null" "bypassPermissions" "manual"
  slug="$(_claude_rc_slug "$repo")"
  mkdir -p "$CLAUDE_RC_STATE/$slug"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"

  _claude_rc_acquire_synthetic_lock "$lock_path" "diag"
  lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"
  # joined token은 bridge_argv/managed_argv 술어에서 탈락하고 나머지는 통과하는 형태
  _claude_rc_write_pid_argv_fixture 6262 \
    claude 'remote-control --no-create-session-in-dir' \
    --spawn same-dir --permission-mode bypassPermissions
  _claude_rc_write_pid_argv_fixture 6261 \
    flock -n "$lock_path" claude 'remote-control --no-create-session-in-dir' \
    --spawn same-dir --permission-mode bypassPermissions

  stderr_file="$sandbox/maint.stderr"
  rc=0
  FAKE_SERVER_CWD="$repo" \
  FAKE_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
  FAKE_SERVER_LOCK_PATH="$lock_path" \
  FAKE_SERVER_FLOCK_EXE="$CLAUDE_RC_REAL_FLOCK" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>"$stderr_file" || rc=$?
  _claude_rc_release_synthetic_lock "$lock_pid"

  [ "$rc" -ne 0 ] || fail "diag scenario must still fail with no-server-process"
  grep -Eq '^\[claude-rc-maint [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9]{4}\] ERROR: lock held but server process not found: ' "$stderr_file" \
    || fail "timestamped no-server-process error missing: $(cat "$stderr_file")"
  # 원 스캔 기록: joined token은 find_bridge_pids_for_path의 bridge_argv 술어에서 탈락한다
  grep -Eq 'ERROR:   scan-rejects pid=6262:bridge_argv$' "$stderr_file" \
    || fail "original-scan rejection record missing: $(cat "$stderr_file")"
  grep -Eq 'rescan pid=6262 cwd=ok cwd_raw=.* bridge_argv=FAIL flock_exe=FAIL versions_exe=ok exe_raw=.*claude-old txt_list=.*claude-old managed_argv=FAIL parent=6261 ' "$stderr_file" \
    || fail "per-candidate rescan line mismatch: $(cat "$stderr_file")"
  grep -Eq 'pid_holds_lock=ok$' "$stderr_file" \
    || fail "diag must evaluate lock-holder predicates: $(cat "$stderr_file")"
  grep -Eq 'rescan candidates=1 lock_free=FAIL lock=' "$stderr_file" \
    || fail "rescan summary missing: $(cat "$stderr_file")"
  # 탈락 기록은 실행별 스크래치에만 쓰고 끝나면 지운다 — 공유 고정 경로가 있으면
  # lock 없는 claude-rc ls가 진행 중인 ensure의 기록을 덮어쓴다.
  [ ! -e "$CLAUDE_RC_STATE/scan-rejects.last" ] || fail "shared scan-rejects file must not exist"
  if compgen -G "$CLAUDE_RC_STATE/results.*.scan" >/dev/null; then
    fail "per-run scan scratch file must be cleaned up"
  fi
}

# launchd StandardOutPath는 append-only라 maint가 자기 로그를 LOG_MAX_BYTES 기준으로 rotate한다.
test_claude_remote_control_maint_rotates_ensure_log() {
  local sandbox repo log_file
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  log_file="$sandbox/ensure.log"

  head -c $((5 * 1024 * 1024 + 1)) /dev/zero >"$log_file"
  CLAUDE_RC_ENSURE_LOG="$log_file" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || true
  [ -f "$log_file.1" ] || fail "oversized ensure log must rotate to .1"
  [ ! -f "$log_file" ] || fail "rotated ensure log must not remain at the original path"

  rm -f "$log_file.1"
  printf 'small\n' >"$log_file"
  CLAUDE_RC_ENSURE_LOG="$log_file" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || true
  [ ! -f "$log_file.1" ] || fail "ensure log under the limit must not rotate"
  [ -f "$log_file" ] || fail "ensure log under the limit must remain"

  rm -f "$log_file" "$log_file.1"
  _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || true
  [ ! -e "$log_file" ] && [ ! -e "$log_file.1" ] || fail "unset CLAUDE_RC_ENSURE_LOG must not touch any log"
}

# 실패 알림만 보고도 어느 인스턴스가 왜 실패했고 무엇을 해야 하는지, 탈락 술어까지
# 읽혀야 한다 (2026-09 no-server-process 알림 폭주 때 "failed=<path>: no-server-process"가 전부였다).
test_claude_remote_control_maint_alert_body_explains_cause() {
  local sandbox repo slug lock_path lock_pid rc needle
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_running_server_mocks
  _claude_rc_make_alerting "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "same-dir" "null" "bypassPermissions" "manual"
  slug="$(_claude_rc_slug "$repo")"
  mkdir -p "$CLAUDE_RC_STATE/$slug"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"
  printf 'healthy\n' >"$CLAUDE_RC_STATE/last-health-state"

  _claude_rc_acquire_synthetic_lock "$lock_path" "alert-body"
  lock_pid="$CLAUDE_RC_SYNTHETIC_LOCK_PID"
  _claude_rc_write_pid_argv_fixture 6262 \
    claude 'remote-control --no-create-session-in-dir' \
    --spawn same-dir --permission-mode bypassPermissions
  _claude_rc_write_pid_argv_fixture 6261 \
    flock -n "$lock_path" claude 'remote-control --no-create-session-in-dir' \
    --spawn same-dir --permission-mode bypassPermissions

  rc=0
  FAKE_SERVER_CWD="$repo" \
  FAKE_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-old" \
  FAKE_SERVER_LOCK_PATH="$lock_path" \
  FAKE_SERVER_FLOCK_EXE="$CLAUDE_RC_REAL_FLOCK" \
  ALERT_LOG="$CLAUDE_RC_ALERT_LOG" \
  SERVICE_LIB="$CLAUDE_RC_SERVICE_LIB" \
  PUSHOVER_CRED_FILE="$CLAUDE_RC_PUSHOVER_CRED" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  _claude_rc_release_synthetic_lock "$lock_pid"

  [ "$rc" -ne 0 ] || fail "no-server-process scenario must fail"
  [ -f "$CLAUDE_RC_ALERT_LOG" ] || fail "failure must send an alert"
  for needle in \
    "Claude 원격 제어 실패 · " \
    "의 Claude 원격 제어 점검이 실패했습니다 (exit=1, 전체: failed" \
    "• $repo: no-server-process" \
    "원인: lock은 잡혀 있는데 관리 대상 bridge 프로세스를 식별하지 못함" \
    "조치: 'claude-rc ls'로 실제 생존 확인" \
    "근거: 탈락 술어: pid=6262:bridge_argv"; do
    grep -Fq -- "$needle" "$CLAUDE_RC_ALERT_LOG" \
      || fail "alert body missing '$needle': $(cat "$CLAUDE_RC_ALERT_LOG")"
  done
  grep -Fq -- "Claude RC Ensure Failed" "$CLAUDE_RC_ALERT_LOG" && fail "english title must be gone"
  [ "$(cat "$CLAUDE_RC_STATE/last-health-state")" = failed ] || fail "failure must record failed state"
  if compgen -G "$CLAUDE_RC_STATE/results.*.detail" >/dev/null; then
    fail "detail scratch file must be cleaned up"
  fi
  return 0
}

test_claude_remote_control_maint_alert_recovery_is_korean() {
  local sandbox repo rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_make_alerting "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  printf 'failed\n' >"$CLAUDE_RC_STATE/last-health-state"

  rc=0
  ALERT_LOG="$CLAUDE_RC_ALERT_LOG" \
  SERVICE_LIB="$CLAUDE_RC_SERVICE_LIB" \
  PUSHOVER_CRED_FILE="$CLAUDE_RC_PUSHOVER_CRED" \
    _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "ensure with no registered instances must succeed (rc=$rc)"
  grep -Fq -- "Claude 원격 제어 복구 · " "$CLAUDE_RC_ALERT_LOG" \
    || fail "recovery title missing: $(cat "$CLAUDE_RC_ALERT_LOG" 2>/dev/null)"
  grep -Fq -- "의 Claude 원격 제어 점검이 정상으로 돌아왔습니다 (desired=" "$CLAUDE_RC_ALERT_LOG" \
    || fail "recovery body missing: $(cat "$CLAUDE_RC_ALERT_LOG")"
  [ "$(cat "$CLAUDE_RC_STATE/last-health-state")" = healthy ] || fail "recovery must record healthy state"
}

# 한글 본문을 바이트 예산으로 자를 때 3바이트 문자가 쪼개지면 안 된다 (Pushover는 UTF-8 요구).
test_claude_remote_control_maint_alert_truncation_keeps_valid_utf8() {
  local sandbox ga out
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  ga="$(printf '가%.0s' $(seq 1 100))"
  _claude_rc_truncate() {
    STATE_DIR="$CLAUDE_RC_STATE" bash -c 'set -uo pipefail; source "$1"; shift; truncate_utf8 "$@"' _ "$(_claude_rc_maint_script)" "$@"
  }
  out="$(_claude_rc_truncate "$ga" 100)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 99 ] || fail "lead byte at boundary must be dropped"
  printf '%s' "$out" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
    || fail "truncated body must stay valid UTF-8"
  out="$(_claude_rc_truncate "$ga" 102)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 102 ] || fail "complete chars must be kept"
  out="$(_claude_rc_truncate "short" 100)"
  [ "$out" = short ] || fail "short text must pass through"
}
