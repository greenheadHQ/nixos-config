# tests/suites/claude-remote-control.sh — Claude remote-control headless fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_claude_rc_wrapper_script() {
  _claude_rc_concat_script "$REPO_ROOT/modules/nixos/scripts/claude-rc.sh"
}

_claude_rc_maint_script() {
  _claude_rc_concat_script "$REPO_ROOT/modules/nixos/programs/claude-remote-control/files/claude-rc-maint.sh"
}

_claude_rc_concat_script() {
  local body="$1" sandbox out
  sandbox="$(new_sandbox)"
  out="$sandbox/$(basename "$body")"
  cat "$REPO_ROOT/modules/nixos/scripts/claude-rc-lib.sh" > "$out"
  printf '\n' >> "$out"
  cat "$body" >> "$out"
  chmod +x "$out"
  printf '%s\n' "$out"
}

_claude_rc_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

_claude_rc_slug() {
  local path="$1" base digest
  base="$(basename "$path")"
  digest="$(_claude_rc_sha256 "$path")"
  printf '%s-%s\n' "$base" "${digest:0:8}"
}

_claude_rc_new_sandbox() {
  local sandbox
  sandbox="$(new_sandbox)"
  (cd "$sandbox" && pwd -P)
}

_claude_rc_make_repo() {
  local repo="$1"
  local home="$2"
  mkdir -p "$repo" "$home"
  (
    cd "$repo"
    HOME="$home" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      git -c init.templateDir= init >/dev/null 2>&1
  )
}

_claude_rc_make_fake_claude() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/claude" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\t%s\n' "$PWD" "$*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
if [ "${FAKE_CLAUDE_RC:-0}" != "0" ]; then
  echo "${FAKE_CLAUDE_ERR:-fake claude failure}" >&2
  exit "$FAKE_CLAUDE_RC"
fi
echo "environment=https://example.invalid/claude-rc-test"
if [ -n "${FAKE_CLAUDE_HOLD_FILE:-}" ]; then
  while [ -e "$FAKE_CLAUDE_HOLD_FILE" ]; do
    sleep 0.1
  done
fi
EOS
  chmod +x "$bin_dir/claude"
}

_claude_rc_make_fake_readlink() {
  local bin_dir="$1"
  cat > "$bin_dir/readlink" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-f" ]; then
  shift
  case "${1:-}" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
  exit 0
fi
exit 1
EOS
  chmod +x "$bin_dir/readlink"
}

_claude_rc_find_tool() {
  local name="$1" found
  if found="$(command -v "$name" 2>/dev/null)"; then
    printf '%s\n' "$found"
    return 0
  fi
  found="$(find /nix/store -maxdepth 3 -type f -path "*/bin/$name" 2>/dev/null | head -n 1)"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# fake-bin은 테스트가 절대경로("$CLAUDE_RC_FAKE_BIN/<tool>")로 참조하는 자기완결
# 도구 디렉토리다. PATH에 도구가 있어도 링크를 생략하면(구현 초기 버그) macOS
# devShell(flock 부재 → 링크 생성)에서는 통과하고 Linux CI(util-linux flock이
# PATH에 존재 → 링크 미생성)에서만 "No such file or directory"로 깨진다.
# 따라서 발견 경로와 무관하게 항상 링크한다.
_claude_rc_link_tool() {
  local name="$1" found
  found="$(_claude_rc_find_tool "$name")" || fail "required test tool not found: $name"
  ln -sf "$found" "$CLAUDE_RC_FAKE_BIN/$name"
}

_claude_rc_setup() {
  local sandbox="$1"
  CLAUDE_RC_HOME="$sandbox/home"
  CLAUDE_RC_STATE="$sandbox/state"
  CLAUDE_RC_FAKE_BIN="$sandbox/fake-bin"
  CLAUDE_RC_LOG="$sandbox/claude.log"
  CLAUDE_RC_HOLD_FILE="$sandbox/hold-server"
  mkdir -p "$CLAUDE_RC_HOME" "$CLAUDE_RC_STATE" "$CLAUDE_RC_FAKE_BIN"
  _claude_rc_make_fake_claude "$CLAUDE_RC_FAKE_BIN"
  _claude_rc_link_tool flock
}

_claude_rc_run() {
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env \
      HOME="$CLAUDE_RC_HOME" \
      STATE_DIR="$CLAUDE_RC_STATE" \
      PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
      FAKE_CLAUDE_LOG="$CLAUDE_RC_LOG" \
      FAKE_CLAUDE_HOLD_FILE="${CLAUDE_RC_HOLD_FILE:-}" \
      FAKE_UNMANAGED_CWD="${FAKE_UNMANAGED_CWD:-}" \
      FAKE_UNMANAGED_EXE="${FAKE_UNMANAGED_EXE:-}" \
      FAKE_CHILD_CWD="${FAKE_CHILD_CWD:-}" \
      "$@"
  )
}

_claude_rc_run_maint() {
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env \
      HOME="$CLAUDE_RC_HOME" \
      STATE_DIR="$CLAUDE_RC_STATE" \
      CLAUDE_BIN="$CLAUDE_RC_FAKE_BIN/claude-new" \
      PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
      FAKE_CLAUDE_LOG="$CLAUDE_RC_LOG" \
      FAKE_CLAUDE_HOLD_FILE="${CLAUDE_RC_HOLD_FILE:-}" \
      FAKE_UNMANAGED_CWD="${FAKE_UNMANAGED_CWD:-}" \
      FAKE_UNMANAGED_EXE="${FAKE_UNMANAGED_EXE:-}" \
      FAKE_SERVER_CWD="${FAKE_SERVER_CWD:-}" \
      FAKE_SERVER_EXE="${FAKE_SERVER_EXE:-}" \
      FAKE_SERVER_COMMAND="${FAKE_SERVER_COMMAND:-}" \
      "$@"
  )
}

_claude_rc_wait_lock_free() {
  local lock_path="$1"
  local _i
  for _i in {1..60}; do
    if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

_claude_rc_release_server() {
  local repo="$1"
  local lock_path
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  rm -f "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_wait_lock_free "$lock_path" || fail "server lock remained held: $lock_path"
}

_claude_rc_write_instance() {
  local path="$1" spawn="$2" capacity_json="$3" permission_mode="$4" source="$5"
  mkdir -p "$CLAUDE_RC_STATE"
  jq -n \
    --arg path "$path" \
    --arg spawn "$spawn" \
    --arg permissionMode "$permission_mode" \
    --arg source "$source" \
    --argjson capacity "$capacity_json" \
    '{version: 1, instances: {($path): {
      spawn: $spawn,
      capacity: $capacity,
      permissionMode: $permissionMode,
      registeredAt: "2026-07-08T00:00:00+09:00",
      source: $source
    }}}' > "$CLAUDE_RC_STATE/instances.json"
}

_claude_rc_install_unmanaged_process_mocks() {
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"claude remote-control"*) echo 4242 ;;
  *) exit 1 ;;
esac
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/lsof" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
case "$args" in
  *"cwd"*)
    printf 'p4242\nn%s\n' "$FAKE_UNMANAGED_CWD"
    ;;
  *"txt"*)
    printf 'p4242\nn%s\n' "$FAKE_UNMANAGED_EXE"
    ;;
  *)
    exit 1
    ;;
esac
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/pgrep" "$CLAUDE_RC_FAKE_BIN/lsof"
}

_claude_rc_install_child_process_mocks() {
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"[-]-sdk-url"*) echo 5252 ;;
  *) exit 1 ;;
esac
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/lsof" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
case "$args" in
  *"cwd"*)
    printf 'p5252\nn%s\n' "$FAKE_CHILD_CWD"
    ;;
  *)
    exit 1
    ;;
esac
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/pgrep" "$CLAUDE_RC_FAKE_BIN/lsof"
}

_claude_rc_install_no_process_mocks() {
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/pgrep"
}

_claude_rc_install_running_server_mocks() {
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"claude remote-control"*) echo 6262 ;;
  *) exit 1 ;;
esac
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/lsof" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
case "$args" in
  *"cwd"*)
    printf 'p6262\nn%s\n' "$FAKE_SERVER_CWD"
    ;;
  *"txt"*)
    printf 'p6262\nn%s\n' "$FAKE_SERVER_EXE"
    ;;
  *)
    exit 1
    ;;
esac
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/ps" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_SERVER_COMMAND:-claude remote-control}"
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/pgrep" "$CLAUDE_RC_FAKE_BIN/lsof" "$CLAUDE_RC_FAKE_BIN/ps"
}

_claude_rc_make_recent_worktree_transcript() {
  local repo="$1" prefix
  prefix="$(printf '%s' "$repo" | sed 's/[^[:alnum:]]/-/g')"
  mkdir -p "$CLAUDE_RC_HOME/.claude/projects/${prefix}--claude-worktrees-bridge-cse-1"
  : > "$CLAUDE_RC_HOME/.claude/projects/${prefix}--claude-worktrees-bridge-cse-1/session.jsonl"
}

test_claude_remote_control_start_requires_git_repo() {
  local sandbox out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  mkdir -p "$sandbox/not-repo"

  rc=0
  out="$(_claude_rc_run "$sandbox/not-repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] || fail "start outside git repo should exit 1, got $rc: $out"
  assert_contains "$out" "git repo가 아님"
}

test_claude_remote_control_start_registers_manual_instance() {
  local sandbox repo lock_path status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    fail "server lock should be held after successful start"
  fi

  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '
    .version == 1
    and .instances[$path].spawn == "worktree"
    and .instances[$path].capacity == null
    and .instances[$path].permissionMode == "bypassPermissions"
    and .instances[$path].source == "manual"
  ' <<<"$status" >/dev/null || fail "manual instance schema mismatch: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_warns_when_running_options_differ() {
  local sandbox repo err out
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"

  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  out="$sandbox/start.out"
  err="$sandbox/start.err"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start \
    --spawn same-dir --capacity 7 --permission-mode plan > "$out" 2> "$err"

  assert_contains "$(cat "$out")" "이미 실행 중"
  assert_contains "$(cat "$err")" "실행 중인 서버에는 반영되지 않음"
  assert_contains "$(cat "$err")" "spawn: running=worktree, requested=same-dir"
  assert_contains "$(cat "$err")" "capacity: running=<omitted>, requested=7"
  assert_contains "$(cat "$err")" "permission-mode: running=bypassPermissions, requested=plan"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_warns_and_preserves_declared_registry() {
  local sandbox repo err status log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "declared"
  : > "$CLAUDE_RC_HOLD_FILE"

  err="$sandbox/start.err"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start \
    --spawn same-dir --capacity 7 --permission-mode plan >/dev/null 2> "$err"

  assert_contains "$(cat "$err")" "이 경로는 Nix 선언 관리 대상"
  assert_contains "$(cat "$err")" "spawn: declared=worktree, requested=same-dir"
  assert_contains "$(cat "$err")" "capacity: declared=<omitted>, requested=7"
  assert_contains "$(cat "$err")" "permission-mode: declared=bypassPermissions, requested=plan"

  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" "remote-control --spawn same-dir --permission-mode plan --capacity 7 --no-create-session-in-dir"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '
    .instances[$path].source == "declared"
    and .instances[$path].spawn == "worktree"
    and .instances[$path].capacity == null
    and .instances[$path].permissionMode == "bypassPermissions"
  ' <<<"$status" >/dev/null || fail "declared start should preserve registry entry: $status"

  _claude_rc_release_server "$repo"
}

test_claude_remote_control_start_rejects_unmanaged_same_cwd_server() {
  local sandbox repo out rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_install_unmanaged_process_mocks

  rc=0
  FAKE_UNMANAGED_CWD="$repo"
  FAKE_UNMANAGED_EXE="$sandbox/bin/claude"
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start 2>&1)" || rc=$?
  unset FAKE_UNMANAGED_CWD FAKE_UNMANAGED_EXE
  [ "$rc" -eq 1 ] || fail "unmanaged same-cwd server should be rejected, got $rc: $out"
  assert_contains "$out" "refusing duplicate start"
  [ ! -f "$CLAUDE_RC_STATE/instances.json" ] || fail "unmanaged rejection must not register instance"
}

test_claude_remote_control_maint_rejects_unmanaged_same_cwd_server() {
  local sandbox repo status rc
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_unmanaged_process_mocks

  rc=0
  FAKE_UNMANAGED_CWD="$repo"
  FAKE_UNMANAGED_EXE="$CLAUDE_RC_FAKE_BIN/claude"
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

test_claude_remote_control_stop_blocks_worktree_sessions_and_force_unregisters() {
  local sandbox repo child_dir out rc status dead_repo
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  child_dir="$repo/.claude/worktrees/session-one"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  mkdir -p "$child_dir"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_install_child_process_mocks

  rc=0
  FAKE_CHILD_CWD="$child_dir"
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop 2>&1)" || rc=$?
  unset FAKE_CHILD_CWD
  [ "$rc" -eq 1 ] || fail "stop should fail while worktree sessions exist, got $rc: $out"
  assert_contains "$out" "재시작 불가(tombstone) 세션 1개 존재"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "failed stop should preserve registration: $status"

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  : > "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" start >/dev/null
  _claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop --force >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "force stop should unregister instance: $status"
  rm -f "$CLAUDE_RC_HOLD_FILE"

  dead_repo="$sandbox/dead-repo"
  _claude_rc_make_repo "$dead_repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$dead_repo" "worktree" "null" "bypassPermissions" "manual"
  _claude_rc_run "$dead_repo" bash "$(_claude_rc_wrapper_script)" stop --force >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$dead_repo" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "dead server stop should only unregister: $status"
}

test_claude_remote_control_stop_preserves_registration_when_lock_held_without_pid() {
  local sandbox repo slug lock_path lock_pid out rc status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_no_process_mocks
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  slug="$(_claude_rc_slug "$repo")"
  mkdir -p "$CLAUDE_RC_STATE/$slug"
  lock_path="$CLAUDE_RC_STATE/$slug/lock"

  "$CLAUDE_RC_FAKE_BIN/flock" "$lock_path" sleep 30 &
  lock_pid=$!
  for _ in {1..30}; do
    if ! "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
      break
    fi
    sleep 0.1
  done
  if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true
    fail "test failed to acquire synthetic lock"
  fi

  rc=0
  out="$(_claude_rc_run "$repo" bash "$(_claude_rc_wrapper_script)" stop --force 2>&1)" || rc=$?
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  [ "$rc" -eq 1 ] || fail "stop should fail on held lock without PID, got $rc: $out"
  assert_contains "$out" "no-server-process"
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$repo" '.instances | has($path)' <<<"$status" >/dev/null \
    || fail "held-lock stop must preserve registration: $status"
}

test_claude_remote_control_stop_path_removes_missing_registered_instance() {
  local sandbox stale_path status
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_install_no_process_mocks
  stale_path="$sandbox/missing-project"
  _claude_rc_write_instance "$stale_path" "worktree" "null" "bypassPermissions" "manual"

  _claude_rc_run "$sandbox" bash "$(_claude_rc_wrapper_script)" stop "$stale_path" >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/instances.json")"
  jq -e --arg path "$stale_path" '(.instances | has($path)) | not' <<<"$status" >/dev/null \
    || fail "stop <path> should remove missing stale registration: $status"
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
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
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
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
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
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
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
  local sandbox repo slug lock_path lock_pid status command

  for command in \
    "claude remote-control --spawn worktree --permission-mode bypassPermissions" \
    "claude remote-control --permission-mode bypassPermissions"
  do
    sandbox="$(_claude_rc_new_sandbox)"
    _claude_rc_setup "$sandbox"
    _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
    _claude_rc_install_running_server_mocks
    repo="$sandbox/repo"
    _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
    _claude_rc_write_instance "$repo" "same-dir" "null" "bypassPermissions" "manual"
    _claude_rc_make_recent_worktree_transcript "$repo"
    slug="$(_claude_rc_slug "$repo")"
    mkdir -p "$CLAUDE_RC_STATE/$slug"
    lock_path="$CLAUDE_RC_STATE/$slug/lock"

    "$CLAUDE_RC_FAKE_BIN/flock" "$lock_path" sleep 30 &
    lock_pid=$!
    for _ in {1..30}; do
      if ! "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
        break
      fi
      sleep 0.1
    done
    if "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
      kill "$lock_pid" 2>/dev/null || true
      wait "$lock_pid" 2>/dev/null || true
      fail "test failed to acquire synthetic lock"
    fi

    FAKE_SERVER_CWD="$repo" \
    FAKE_SERVER_EXE="$CLAUDE_RC_FAKE_BIN/claude-old" \
    FAKE_SERVER_COMMAND="$command" \
      _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true
    status="$(cat "$CLAUDE_RC_STATE/status.json")"
    jq -e '
      .action == "completed"
      and .instances[0].action == "deferred-active-sessions"
    ' <<<"$status" >/dev/null || fail "effective spawn drift gate mismatch for [$command]: $status"
  done
}

test_claude_remote_control_maint_rejects_invalid_declared_instances() {
  local sandbox repo payload status rc

  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
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
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
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
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
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

test_claude_remote_control_maint_status_schema() {
  local sandbox repo status log
  sandbox="$(_claude_rc_new_sandbox)"
  _claude_rc_setup "$sandbox"
  _claude_rc_make_fake_readlink "$CLAUDE_RC_FAKE_BIN"
  repo="$sandbox/repo"
  _claude_rc_make_repo "$repo" "$CLAUDE_RC_HOME"
  _claude_rc_write_instance "$repo" "worktree" "null" "bypassPermissions" "manual"
  : > "$CLAUDE_RC_HOLD_FILE"

  _claude_rc_run_maint "$repo" bash "$(_claude_rc_maint_script)" ensure >/dev/null
  status="$(cat "$CLAUDE_RC_STATE/status.json")"
  jq -e '
    (.timestamp | type == "string")
    and (.exitCode | type == "number")
    and (.action | type == "string")
    and (.instances | type == "array")
    and (.instances[0].action == "started")
  ' <<<"$status" >/dev/null || fail "status schema mismatch: $status"

  log="$(cat "$CLAUDE_RC_LOG")"
  assert_contains "$log" "remote-control --spawn worktree --permission-mode bypassPermissions --no-create-session-in-dir"
  assert_not_contains "$log" "--capacity"

  _claude_rc_release_server "$repo"
}
