# tests/suites/codex-remote-control.sh — Codex remote-control maintenance fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_codex_rc_script() {
  printf '%s\n' "$REPO_ROOT/modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh"
}

_codex_rc_make_package() {
  local tarball="$1"
  local work_dir="$2"
  local version="${3:-0.142.4}"

  mkdir -p "$work_dir/pkg/bin" "$work_dir/pkg/codex-path" "$work_dir/pkg/codex-resources"
  cat > "$work_dir/pkg/bin/codex" <<'EOS'
#!/usr/bin/env bash
echo "codex-cli ${FAKE_STANDALONE_VERSION:-0.142.4}"
EOS
  chmod +x "$work_dir/pkg/bin/codex"
  printf '{"version":"%s"}\n' "$version" > "$work_dir/pkg/codex-package.json"
  tar -czf "$tarball" -C "$work_dir/pkg" .
}

_codex_rc_make_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FAKE_CODEX_LOG:-/dev/null}"

case "$*" in
  "--version")
    echo "codex-cli ${FAKE_CODEX_VERSION:-0.142.4}"
    ;;
  "login status")
    echo "${FAKE_LOGIN_STATUS:-Logged in using ChatGPT}"
    exit "${FAKE_LOGIN_RC:-0}"
    ;;
  "app-server daemon version")
    if [ "${FAKE_DAEMON_MALFORMED:-0}" = "1" ]; then
      echo "{bad json"
      exit 0
    fi
    if [ "${FAKE_DAEMON_RC:-0}" != "0" ]; then
      echo "${FAKE_DAEMON_ERR:-daemon not running}" >&2
      exit "$FAKE_DAEMON_RC"
    fi
    if [ -n "${FAKE_DAEMON_JSON:-}" ]; then
      printf '%s\n' "$FAKE_DAEMON_JSON"
    else
      printf '{"status":"running","managedCodexVersion":"0.142.4","appServerVersion":"0.142.4"}\n'
    fi
    ;;
  "remote-control start --json")
    if [ "${FAKE_START_RC:-0}" != "0" ]; then
      echo "${FAKE_START_ERR:-start failed}" >&2
      exit "$FAKE_START_RC"
    fi
    if [ -n "${FAKE_START_JSON:-}" ]; then
      printf '%s\n' "$FAKE_START_JSON"
    else
      printf '{"mode":"daemon","status":"connected","serverName":"greenhead-minipc","daemon":{"status":"alreadyRunning","managedCodexVersion":"0.142.4","appServerVersion":"0.142.4"}}\n'
    fi
    ;;
  "remote-control stop --json")
    if [ "${FAKE_STOP_RC:-0}" != "0" ]; then
      echo "${FAKE_STOP_ERR:-stop failed}" >&2
      exit "$FAKE_STOP_RC"
    fi
    printf '{"status":"stopped"}\n'
    ;;
  *)
    echo "unexpected fake codex invocation: $*" >&2
    exit 99
    ;;
esac
EOS
  chmod +x "$bin_dir/codex"
}

_codex_rc_setup() {
  local sandbox="$1"
  COD_RC_HOME="$sandbox/home"
  COD_RC_STATE="$sandbox/state"
  COD_RC_FAKE_BIN="$sandbox/fake-bin"
  COD_RC_PKG="$sandbox/codex-package.tar.gz"
  COD_RC_LOG="$sandbox/codex.log"
  COD_RC_NORMAL="/nix/store/nonexistent-codex-0.142.4/bin/codex"
  mkdir -p "$COD_RC_HOME" "$COD_RC_STATE"
  _codex_rc_make_fake_codex "$COD_RC_FAKE_BIN"
  _codex_rc_make_package "$COD_RC_PKG" "$sandbox/package-work"
}

_codex_rc_env() {
  local state_dir="${STATE_DIR:-$COD_RC_STATE}"
  local codex_operator="${CODEX_OPERATOR:-$COD_RC_FAKE_BIN/codex}"
  local normal_codex_name="${NORMAL_CODEX_NAME:-$COD_RC_NORMAL}"
  local path_value="${CODEX_RC_PATH:-$COD_RC_FAKE_BIN:$PATH}"

  env \
    HOME="$COD_RC_HOME" \
    CODEX_HOME="$COD_RC_HOME/.codex" \
    STATE_DIR="$state_dir" \
    DESIRED_VERSION="0.142.4" \
    STANDALONE_PACKAGE="$COD_RC_PKG" \
    STANDALONE_TRIPLE="x86_64-unknown-linux-musl" \
    CODEX_OPERATOR="$codex_operator" \
    NORMAL_CODEX_NAME="$normal_codex_name" \
    FAKE_CODEX_LOG="$COD_RC_LOG" \
    PATH="$path_value" \
    "$@"
}

test_codex_remote_control_probe_parses_daemon_json() {
  local sandbox out
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  out="$(_codex_rc_env bash "$(_codex_rc_script)" probe)"
  jq -e '.daemonStatus == "running" and .managedCodexVersion == "0.142.4" and .appServerVersion == "0.142.4"' <<<"$out" >/dev/null \
    || fail "probe did not parse daemon version JSON: $out"
}

test_codex_remote_control_probe_marks_malformed_daemon_json() {
  local sandbox out
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  out="$(FAKE_DAEMON_MALFORMED=1 _codex_rc_env bash "$(_codex_rc_script)" probe)"
  jq -e '.daemonStatus == "malformed-json"' <<<"$out" >/dev/null \
    || fail "probe did not mark malformed daemon JSON: $out"
}

test_codex_remote_control_ensure_running_rejects_malformed_daemon_json() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if FAKE_DAEMON_MALFORMED=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail on malformed daemon JSON"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.daemonStatus == "malformed-json" and .lastRepairReason == "daemon-version-malformed-json" and .exitCode == 40' <<<"$status" >/dev/null \
    || fail "malformed daemon JSON was not recorded as unhealthy: $status"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start --json'
}

test_codex_remote_control_ensure_running_starts_when_absent() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  FAKE_DAEMON_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.remoteControlEnabled == true and .serverName == "greenhead-minipc" and .exitCode == 0' <<<"$status" >/dev/null \
    || fail "ensure-running did not record successful remote-control start: $status"
  grep -Fqx 'remote-control start --json' "$COD_RC_LOG" \
    || fail "ensure-running did not invoke remote-control start"
}

test_codex_remote_control_rejects_stale_start_versions() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if FAKE_DAEMON_RC=1 \
    FAKE_START_JSON='{"mode":"daemon","status":"connected","serverName":"greenhead-minipc","daemon":{"status":"started","managedCodexVersion":"0.133.0","appServerVersion":"0.133.0"}}' \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should reject connected start output with stale versions"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.remoteControlEnabled == false and (.lastRepairReason | startswith("remote-control-start-version-drift:0.133.0/0.133.0")) and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "stale start versions were not recorded as unhealthy: $status"
}

test_codex_remote_control_auth_failure_is_non_destructive() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if FAKE_LOGIN_STATUS='Logged in using API key' _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail for API-key auth"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.authMode == "api-key" and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "auth failure status not recorded: $status"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start --json'
}

test_codex_remote_control_login_status_is_sanitized() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  FAKE_LOGIN_STATUS='Logged in using ChatGPT as private@example.com' _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.authMode == "chatgpt" and .loginStatus == "chatgpt"' <<<"$status" >/dev/null \
    || fail "loginStatus should contain only sanitized auth mode: $status"
  assert_not_contains "$status" 'private@example.com'
}

test_codex_remote_control_missing_operator_reason_is_preserved() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if CODEX_OPERATOR="$sandbox/missing-codex" _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail when operator codex is missing"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "operator-codex-not-found" and .exitCode == 25' <<<"$status" >/dev/null \
    || fail "missing operator reason was not preserved: $status"
}

test_codex_remote_control_removes_standalone_path_shadow() {
  local sandbox local_codex
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone
  mkdir -p "$COD_RC_HOME/.local/bin"
  local_codex="$COD_RC_HOME/.local/bin/codex"
  ln -s "$COD_RC_HOME/.codex/packages/standalone/current/bin/codex" "$local_codex"

  PATH="$COD_RC_HOME/.local/bin:$PATH" _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone
  [ ! -e "$local_codex" ] && [ ! -L "$local_codex" ] \
    || fail "standalone PATH shadow symlink was not removed"
}

test_codex_remote_control_rejects_direct_standalone_path_shadow() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone

  if NORMAL_CODEX_NAME=codex \
    CODEX_RC_PATH="$COD_RC_HOME/.codex/packages/standalone/current/bin:$COD_RC_FAKE_BIN:$PATH" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone; then
    fail "ensure-standalone should fail when normal codex resolves to standalone"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "normal-codex-resolves-to-standalone" and .exitCode == 20' <<<"$status" >/dev/null \
    || fail "direct standalone PATH shadow was not recorded: $status"
}

test_codex_remote_control_rejects_non_nix_path_shadow() {
  local sandbox non_nix_bin status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  non_nix_bin="$sandbox/non-nix"
  mkdir -p "$non_nix_bin"
  cp "$COD_RC_FAKE_BIN/codex" "$non_nix_bin/codex"

  if NORMAL_CODEX_NAME=codex CODEX_RC_PATH="$non_nix_bin:$COD_RC_FAKE_BIN:$PATH" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone; then
    fail "ensure-standalone should fail when normal codex resolves to non-Nix path"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '(.lastRepairReason | startswith("normal-codex-not-nix-managed:")) and .exitCode == 21' <<<"$status" >/dev/null \
    || fail "non-Nix PATH shadow was not recorded: $status"
}

test_codex_remote_control_sync_failure_is_not_marked_successful() {
  local sandbox bad_release status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  bad_release="$sandbox/missing-parent/release"

  if STANDALONE_RELEASE_DIR="$bad_release" _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone 2>/dev/null; then
    fail "ensure-standalone should fail when release move cannot complete"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "standalone-sync-failed:move-release" and .lastAction != "synced-standalone-package" and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "failed standalone sync was incorrectly marked successful: $status"
}

test_codex_remote_control_lock_failure_does_not_run_core_action() {
  local sandbox bad_state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  bad_state="$sandbox/not-a-directory"
  : > "$bad_state"

  if STATE_DIR="$bad_state" _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail when state dir cannot be created"
  fi
  assert_not_contains "$(cat "$COD_RC_LOG" 2>/dev/null || true)" 'remote-control start --json'
}

test_codex_remote_control_lock_acquire_timeout_is_recorded() {
  local sandbox ready lock_holder status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ready="$sandbox/lock-ready"

  flock "$COD_RC_STATE/maintenance.lock" bash -c 'touch "$1"; sleep 5' _ "$ready" &
  lock_holder=$!
  for _ in {1..50}; do
    [ ! -e "$ready" ] || break
    kill -0 "$lock_holder" 2>/dev/null || fail "lock holder exited before acquiring lock"
    sleep 0.1
  done
  [ -e "$ready" ] || fail "lock holder did not acquire lock"

  if MAINT_LOCK_TIMEOUT_SECONDS=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    kill "$lock_holder" 2>/dev/null || true
    wait "$lock_holder" 2>/dev/null || true
    fail "ensure-running should fail when maintenance lock acquisition times out"
  fi
  kill "$lock_holder" 2>/dev/null || true
  wait "$lock_holder" 2>/dev/null || true

  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "lock-acquire-timeout" and .exitCode != 0' <<<"$status" >/dev/null \
    || fail "lock timeout was not recorded as unhealthy: $status"
  assert_not_contains "$(cat "$COD_RC_LOG" 2>/dev/null || true)" 'remote-control start --json'
}

test_codex_remote_control_repair_kills_proven_stale_unmanaged_process() {
  local sandbox ps_file kill_log socket_file user
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  user="$(id -un)"
  ps_file="$sandbox/ps.txt"
  kill_log="$sandbox/kill.log"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"
  printf '12345 %s /home/%s/.local/share/mise/installs/npm-openai-codex/latest/bin/codex app-server --listen unix:///tmp/stale.sock\n' "$user" "$user" > "$ps_file"

  CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" KILL_LOG="$kill_log" _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged
  assert_file_contains "$kill_log" "12345"
  [ ! -e "$socket_file" ] || fail "socket should be removed after verified stale kill"
}

test_codex_remote_control_repair_refuses_socket_cleanup_when_pid_remains() {
  local sandbox ps_file kill_log socket_file user
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  user="$(id -un)"
  ps_file="$sandbox/ps.txt"
  kill_log="$sandbox/kill.log"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"
  {
    printf '12345 %s /home/%s/.local/share/mise/installs/npm-openai-codex/latest/bin/codex app-server --listen unix:///tmp/stale.sock\n' "$user" "$user"
    printf '23456 %s %s/bin/codex app-server --listen unix:///tmp/current.sock\n' "$user" "$COD_RC_HOME/.codex/packages/standalone/current"
  } > "$ps_file"

  if CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" KILL_LOG="$kill_log" _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged; then
    fail "repair-unmanaged should refuse socket cleanup while another app-server PID remains"
  fi
  assert_file_contains "$kill_log" "12345"
  [ -e "$socket_file" ] || fail "socket should be preserved while current app-server PID remains"
}

test_codex_remote_control_repair_does_not_kill_without_stale_proof() {
  local sandbox ps_file kill_log socket_file
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ps_file="$sandbox/ps.txt"
  kill_log="$sandbox/kill.log"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"
  printf '77777 other /home/other/.local/share/mise/installs/npm-openai-codex/latest/bin/codex app-server --listen unix:///tmp/stale.sock\n' > "$ps_file"

  if CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" KILL_LOG="$kill_log" _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged; then
    fail "repair-unmanaged should fail without same-user stale PID proof"
  fi
  [ ! -e "$kill_log" ] || fail "repair-unmanaged killed a process without stale proof"
  [ -e "$socket_file" ] || fail "socket should be preserved while app-server PID exists without stale proof"
}

test_codex_remote_control_repair_does_not_kill_on_version_drift_only() {
  local sandbox ps_file kill_log user
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  user="$(id -un)"
  ps_file="$sandbox/ps.txt"
  kill_log="$sandbox/kill.log"
  printf '88888 %s /opt/codex/bin/codex app-server --listen unix:///tmp/unknown.sock\n' "$user" > "$ps_file"

  if APP_SERVER_VERSION="0.133.0" CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" KILL_LOG="$kill_log" _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged; then
    fail "repair-unmanaged should fail when only global version drift points at an unknown app-server PID"
  fi
  [ ! -e "$kill_log" ] || fail "version drift alone should not kill an unknown app-server PID"
}

test_codex_remote_control_repair_preserves_current_managed_app_server() {
  local sandbox ps_file exe_file kill_log socket_file user standalone_root release_dir
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  user="$(id -un)"
  ps_file="$sandbox/ps.txt"
  exe_file="$sandbox/exe.txt"
  kill_log="$sandbox/kill.log"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  standalone_root="$COD_RC_HOME/.codex/packages/standalone"
  release_dir="$standalone_root/releases/0.142.4-x86_64-unknown-linux-musl"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"
  printf '55555 %s %s/current/codex app-server daemon pid-update-loop\n' "$user" "$standalone_root" > "$ps_file"
  printf '55555 %s/bin/codex\n' "$release_dir" > "$exe_file"

  if CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" CODEX_REMOTE_CONTROL_EXE_FILE="$exe_file" KILL_LOG="$kill_log" \
    _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged; then
    fail "repair-unmanaged should not kill a managed app-server still running the current release"
  fi
  [ ! -e "$kill_log" ] || fail "current managed app-server must not be killed"
  [ -e "$socket_file" ] || fail "socket must be preserved while current managed app-server runs"
}

test_codex_remote_control_repair_kills_stale_deleted_managed_app_server() {
  local sandbox ps_file exe_file kill_log socket_file user standalone_root old_release
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  user="$(id -un)"
  ps_file="$sandbox/ps.txt"
  exe_file="$sandbox/exe.txt"
  kill_log="$sandbox/kill.log"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  standalone_root="$COD_RC_HOME/.codex/packages/standalone"
  old_release="$standalone_root/releases/0.142.3-x86_64-unknown-linux-musl"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"
  # cmdline mentions the managed `current` path, but /proc/$pid/exe resolves to a
  # deleted old release — the exact incident that previously exited 60.
  printf '4000136 %s %s/current/codex app-server daemon pid-update-loop\n' "$user" "$standalone_root" > "$ps_file"
  printf '4000136 %s/bin/codex (deleted)\n' "$old_release" > "$exe_file"

  CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" CODEX_REMOTE_CONTROL_EXE_FILE="$exe_file" KILL_LOG="$kill_log" \
    _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged
  assert_file_contains "$kill_log" "4000136"
  [ ! -e "$socket_file" ] || fail "socket should be removed after reaping a stale deleted managed app-server"
}

test_codex_remote_control_repair_kills_stale_superseded_managed_app_server() {
  local sandbox ps_file exe_file kill_log socket_file user standalone_root old_release
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  user="$(id -un)"
  ps_file="$sandbox/ps.txt"
  exe_file="$sandbox/exe.txt"
  kill_log="$sandbox/kill.log"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  standalone_root="$COD_RC_HOME/.codex/packages/standalone"
  old_release="$standalone_root/releases/0.142.3-x86_64-unknown-linux-musl"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"
  # `current` moved to the desired release but the old release still exists; the
  # running process's executable proves it is superseded.
  printf '4000200 %s %s/current/codex app-server --listen unix:///tmp/current.sock\n' "$user" "$standalone_root" > "$ps_file"
  printf '4000200 %s/bin/codex\n' "$old_release" > "$exe_file"

  CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" CODEX_REMOTE_CONTROL_EXE_FILE="$exe_file" KILL_LOG="$kill_log" \
    _codex_rc_env bash "$(_codex_rc_script)" repair-unmanaged
  assert_file_contains "$kill_log" "4000200"
  [ ! -e "$socket_file" ] || fail "socket should be removed after reaping a superseded managed app-server"
}

test_codex_remote_control_socket_cleanup_when_no_pid_after_drift() {
  local sandbox ps_file socket_file status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ps_file="$sandbox/ps-empty.txt"
  : > "$ps_file"
  socket_file="$COD_RC_HOME/.codex/app-server-control/app-server-control.sock"
  mkdir -p "$(dirname "$socket_file")"
  : > "$socket_file"

  FAKE_DAEMON_JSON='{"status":"running","managedCodexVersion":"0.133.0","appServerVersion":"0.133.0"}' \
    CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  status="$(cat "$COD_RC_STATE/status.json")"
  [ ! -e "$socket_file" ] || fail "socket should be removed when no app-server PID exists during drift restart"
  jq -e '.lastAction == "restarted-version-drift" and .exitCode == 0' <<<"$status" >/dev/null \
    || fail "drift restart status not recorded: $status"
}
