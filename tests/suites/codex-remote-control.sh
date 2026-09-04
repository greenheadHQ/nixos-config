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
    if [ -n "${FAKE_START_DAEMON_FD_FILE:-}" ]; then
      # 실제 codex remote-control start처럼 장기 실행 데몬을 detach로 남긴다.
      # 데몬은 자기 fd 테이블을 기록해 부모(maint 스크립트)의 lock fd 상속 여부를 노출한다.
      (
        ls -l "/proc/$BASHPID/fd/" > "$FAKE_START_DAEMON_FD_FILE" 2>&1
        sleep 5
      ) &
      disown
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

_codex_rc_make_alerting() {
  local sandbox="$1"
  COD_RC_ALERT_LOG="$sandbox/alerts.log"
  COD_RC_SERVICE_LIB="$sandbox/service-lib.sh"
  COD_RC_PUSHOVER_CRED="$sandbox/pushover.env"

  cat > "$COD_RC_SERVICE_LIB" <<'EOS'
send_notification() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ALERT_LOG"
}
EOS
  printf '%s\n' \
    'PUSHOVER_TOKEN=test-token' \
    'PUSHOVER_USER=test-user' \
    > "$COD_RC_PUSHOVER_CRED"
}

_codex_rc_assert_alert_count() {
  local needle="$1"
  local expected="$2"
  local actual

  actual="$(
    if [ -f "$COD_RC_ALERT_LOG" ]; then
      awk -v needle="$needle" 'index($0, needle) { count++ } END { print count + 0 }' "$COD_RC_ALERT_LOG"
    else
      printf '0\n'
    fi
  )"
  [ "$actual" = "$expected" ] \
    || fail "expected $expected alert(s) containing '$needle' in $COD_RC_ALERT_LOG, got $actual"
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

test_codex_remote_control_spawned_daemon_does_not_inherit_lock_fd() {
  local sandbox fd_file
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  fd_file="$sandbox/daemon-fds.txt"

  FAKE_START_DAEMON_FD_FILE="$fd_file" _codex_rc_env bash "$(_codex_rc_script)" ensure-running >/dev/null 2>&1 \
    || fail "ensure-running should succeed on the healthy fixture path"

  local _i
  for _i in {1..50}; do
    [ ! -s "$fd_file" ] || break
    sleep 0.1
  done
  [ -s "$fd_file" ] || fail "fake daemon did not record its fd table"

  # 데몬이 lock fd를 상속하면 maint 스크립트 종료 후에도 flock이 유지되어
  # 이후 모든 타이머 실행이 lock-acquire-timeout으로 실패한다 (2026-07 실장애).
  assert_not_contains "$(cat "$fd_file")" 'maintenance.lock'
  flock --timeout 1 --exclusive "$COD_RC_STATE/maintenance.lock" -c true \
    || fail "maintenance lock still held after ensure-running exited (fd leaked to spawned daemon)"
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

test_codex_remote_control_alert_recovery_after_failure() {
  local sandbox state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'failed\n' > "$COD_RC_STATE/last-health-state"

  ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "healthy" ] || fail "recovery should update health state to healthy, got: $state"
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 1
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
}

test_codex_remote_control_alert_success_without_failure_is_quiet() {
  local sandbox state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"

  ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "healthy" ] || fail "healthy run should write healthy state, got: $state"
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
}

test_codex_remote_control_alert_failure_sets_failed_and_cools_down() {
  local sandbox first_last second_last state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' > "$COD_RC_STATE/last-health-state"

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail for malformed daemon JSON"
  fi

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "failed" ] || fail "failed run should write failed state, got: $state"
  [ -s "$COD_RC_STATE/last-failure-alert" ] || fail "failed run should record last failure alert timestamp"
  first_last="$(cat "$COD_RC_STATE/last-failure-alert")"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 1

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should keep failing for malformed daemon JSON"
  fi

  state="$(cat "$COD_RC_STATE/last-health-state")"
  second_last="$(cat "$COD_RC_STATE/last-failure-alert")"
  [ "$state" = "failed" ] || fail "repeated failure should keep failed state, got: $state"
  [ "$second_last" = "$first_last" ] || fail "cooldown should not rewrite last failure alert timestamp"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 1
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
}

test_codex_remote_control_alert_without_pushover_token_does_not_mutate_state() {
  local sandbox state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' > "$COD_RC_STATE/last-health-state"

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$sandbox/missing-pushover.env" \
    CREDENTIALS_DIRECTORY='' \
    PUSHOVER_TOKEN='' \
    PUSHOVER_USER='' \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail for malformed daemon JSON"
  fi

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "healthy" ] || fail "missing Pushover token should leave health state unchanged, got: $state"
  [ ! -e "$COD_RC_STATE/last-failure-alert" ] || fail "missing Pushover token should not write failure alert timestamp"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
}

test_codex_remote_control_sync_standalone_package_success_links_current_release() {
  local sandbox release_dir status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  release_dir="$COD_RC_HOME/.codex/packages/standalone/releases/0.142.4-x86_64-unknown-linux-musl"

  _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone

  [ -L "$COD_RC_HOME/.codex/packages/standalone/current" ] \
    || fail "standalone current should be a symlink"
  [ "$(readlink "$COD_RC_HOME/.codex/packages/standalone/current")" = "$release_dir" ] \
    || fail "standalone current should point at desired release"
  [ -x "$release_dir/bin/codex" ] || fail "synced release should contain executable bin/codex"
  [ -L "$release_dir/codex" ] || fail "synced release should include compatibility codex symlink"
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastAction == "synced-standalone-package" and .standaloneVersion == "0.142.4" and .exitCode == 0' <<<"$status" >/dev/null \
    || fail "successful standalone sync was not recorded: $status"
}

test_codex_remote_control_sync_extract_failure_propagates_status() {
  local sandbox bad_package status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  bad_package="$sandbox/not-a-tarball.tar.gz"
  printf 'not a tarball\n' > "$bad_package"

  if COD_RC_PKG="$bad_package" _codex_rc_env bash "$(_codex_rc_script)" ensure-standalone 2>/dev/null; then
    fail "ensure-standalone should fail when package extraction fails"
  fi

  [ ! -e "$COD_RC_HOME/.codex/packages/standalone/current" ] \
    || fail "failed standalone sync should not publish current release"
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "standalone-sync-failed:extract" and .lastAction != "synced-standalone-package" and .exitCode == 1' <<<"$status" >/dev/null \
    || fail "standalone extract failure was not propagated: $status"
}

test_codex_remote_control_sync_records_login_status_success_and_api_key_paths() {
  local sandbox good_log good_status bad_log bad_status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  good_log="$COD_RC_LOG"
  good_status="$(cat "$COD_RC_STATE/status.json")"
  assert_file_contains "$good_log" "login status"
  jq -e '.authMode == "chatgpt" and .loginStatus == "chatgpt" and .exitCode == 0' <<<"$good_status" >/dev/null \
    || fail "ChatGPT login status was not recorded: $good_status"

  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  if FAKE_LOGIN_STATUS='Logged in using API key' _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail for API-key auth"
  fi
  bad_log="$COD_RC_LOG"
  bad_status="$(cat "$COD_RC_STATE/status.json")"
  assert_file_contains "$bad_log" "login status"
  jq -e '.authMode == "api-key" and .loginStatus == "api-key" and .lastRepairReason == "auth-not-chatgpt" and .exitCode == 30' <<<"$bad_status" >/dev/null \
    || fail "API-key login status was not recorded as unhealthy: $bad_status"
}

# 알림만 보고도 원인과 조치를 알 수 있어야 한다: 한국어 제목·본문, reason 코드의 설명/조치,
# app-server 데몬 로그의 마지막 ERROR 라인(ANSI 제거)을 근거로 포함한다.
test_codex_remote_control_alert_body_explains_cause_and_evidence() {
  local sandbox body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' > "$COD_RC_STATE/last-health-state"
  mkdir -p "$COD_RC_HOME/.codex/app-server-daemon"
  printf '%s\n' \
    'INFO app-server started' \
    $'\e[2m2026-09-04T04:00:50Z\e[0m \e[31mERROR\e[0m codex_login::auth::manager: Failed to refresh token: 401 Unauthorized: refresh_token_invalidated' \
    > "$COD_RC_HOME/.codex/app-server-daemon/app-server.stderr.log"

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail for malformed daemon JSON"
  fi

  _codex_rc_assert_alert_count "Codex 원격 제어 실패 · greenhead-minipc" 1
  body="$(cat "$COD_RC_ALERT_LOG")"
  for needle in \
    "greenhead-minipc의 Codex 원격 제어 점검이 실패했습니다 (exit=40, 코드: daemon-version-malformed-json" \
    "원인: codex CLI 출력이 JSON이 아님" \
    "조치: codex 업데이트로 출력 형식이 바뀌었는지 확인" \
    "근거:" \
    "app-server(이번 실행 이전 기록): 2026-09-04T04:00:50Z ERROR codex_login::auth::manager: Failed to refresh token: 401 Unauthorized: refresh_token_invalidated"; do
    grep -Fq -- "$needle" "$COD_RC_ALERT_LOG" || fail "alert body missing '$needle': $body"
  done
  if grep -q $'\e\[' "$COD_RC_ALERT_LOG"; then
    fail "alert body must not carry ANSI escapes: $body"
  fi
  grep -Fq -- "stderr:" "$COD_RC_ALERT_LOG" && fail "no start stderr captured, so no stderr line expected: $body"
  return 0
}

# maint 함수 격리 호출: 마지막 줄의 main "$@"를 떼고 source한다. T_REASON/T_STDERR/T_OFFSET은
# source 뒤에 대입한다 — 스크립트 상단이 이 변수들을 빈값으로 초기화하므로 env로는 못 넘긴다.
_codex_rc_call_fn() {
  CODEX_HOME="$COD_RC_HOME/.codex" STATE_DIR="$COD_RC_STATE" \
    bash -c 'set -uo pipefail; source <(sed "\$d" "$1"); shift; LAST_REPAIR_REASON="${T_REASON:-}"; START_STDERR="${T_STDERR:-}"; DAEMON_LOG_OFFSET="${T_OFFSET:-0}"; "$@"' _ "$(_codex_rc_script)" "$@"
}

_assert_valid_utf8() {
  printf '%s' "$1" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
    || fail "$2: not valid UTF-8"
}

# 근거는 app-server를 실제로 건드린 실패에만, 그리고 이번 실행 중 새로 쓰인 ERROR를
# 우선한다. lock·패키지·로그인 실패에 오래된 데몬 ERROR가 붙으면 무관한 토큰 수리로 오도한다.
test_codex_remote_control_alert_evidence_scoped_to_current_failure() {
  local sandbox log body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  log="$COD_RC_HOME/.codex/app-server-daemon/app-server.stderr.log"
  mkdir -p "$(dirname "$log")"
  printf '%s\n' 'ERROR old: 401 token_revoked' > "$log"

  # (1) app-server와 무관한 실패: 데몬 로그를 근거로 붙이지 않는다
  body="$(T_REASON=lock-acquire-timeout _codex_rc_call_fn failure_alert_body 1)"
  assert_contains "$body" "원인: maint 상태 디렉토리 또는 lock 획득 실패"
  assert_not_contains "$body" "근거:"
  assert_not_contains "$body" "token_revoked"

  # (2) 관련 실패 + 이번 실행 중 새 ERROR 없음: 이전 기록임을 라벨로 명시
  body="$(T_REASON=remote-control-start-not-connected T_OFFSET="$(wc -c <"$log" | tr -d ' ')" _codex_rc_call_fn failure_alert_body 50)"
  assert_contains "$body" "app-server(이번 실행 이전 기록): ERROR old: 401 token_revoked"

  # (3) 관련 실패 + offset 이후 새 ERROR: 그 라인을 라벨 없이 싣고, stderr 첫 줄도 함께
  local offset
  offset="$(wc -c <"$log" | tr -d ' ')"
  printf '%s\n' 'INFO noise' 'ERROR new: refresh_token_invalidated' >> "$log"
  body="$(T_REASON=remote-control-start-failed T_STDERR=$'first stderr line\nsecond' T_OFFSET="$offset" _codex_rc_call_fn failure_alert_body 52)"
  assert_contains "$body" "stderr: first stderr line"
  assert_not_contains "$body" "second"
  assert_contains "$body" $'\napp-server: ERROR new: refresh_token_invalidated'
  assert_not_contains "$body" "이전 기록"
  assert_not_contains "$body" "ERROR old"

  # (4) 데몬 재시작으로 로그가 비워져 offset > size: 처음부터 본다
  printf '%s\n' 'ERROR after-restart' > "$log"
  body="$(T_REASON=daemon-version-drift:0.1/0.2 T_OFFSET=999999 _codex_rc_call_fn failure_alert_body 54)"
  assert_contains "$body" "app-server: ERROR after-restart"
}

# 한글 본문/근거를 바이트 예산으로 자를 때 3바이트 문자가 쪼개지면 안 된다.
test_codex_remote_control_alert_truncation_keeps_valid_utf8() {
  local sandbox out ga log body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ga="$(printf '가%.0s' $(seq 1 100))"   # 300 bytes

  out="$(_codex_rc_call_fn truncate_utf8 "$ga" 100)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 99 ] || fail "lead byte at boundary must be dropped: $(printf '%s' "$out" | wc -c)"
  _assert_valid_utf8 "$out" "max=100"
  out="$(_codex_rc_call_fn truncate_utf8 "$ga" 101)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 99 ] || fail "lead+1 continuation must be dropped"
  out="$(_codex_rc_call_fn truncate_utf8 "$ga" 102)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 102 ] || fail "complete 34 chars must be kept"
  out="$(_codex_rc_call_fn truncate_utf8 "abc" 100)"
  [ "$out" = "abc" ] || fail "short text must pass through: $out"
  out="$(_codex_rc_call_fn truncate_utf8 "$(printf 'x%.0s' $(seq 1 150))" 100)"
  [ "${#out}" = 100 ] || fail "ascii must cut at exactly max bytes"

  # 실제 근거 라인 경계: "ERROR: " 7바이트 + 가×100 → 240바이트 컷이 78번째 가를 쪼갠다
  log="$COD_RC_HOME/.codex/app-server-daemon/app-server.stderr.log"
  mkdir -p "$(dirname "$log")"
  printf 'ERROR: %s\n' "$ga" > "$log"
  body="$(T_REASON=remote-control-start-failed _codex_rc_call_fn failure_alert_body 52)"
  _assert_valid_utf8 "$body" "evidence line"
  [ "$(printf '%s' "$body" | grep -a '^app-server' | wc -c | tr -d ' ')" = $((12 + 7 + 231 + 1)) ] \
    || fail "evidence line must be 238 bytes of payload: $(printf '%s' "$body" | grep -a '^app-server' | wc -c)"
}
