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
  env \
    HOME="$COD_RC_HOME" \
    CODEX_HOME="$COD_RC_HOME/.codex" \
    STATE_DIR="$COD_RC_STATE" \
    DESIRED_VERSION="0.142.4" \
    STANDALONE_PACKAGE="$COD_RC_PKG" \
    STANDALONE_TRIPLE="x86_64-unknown-linux-musl" \
    CODEX_OPERATOR="$COD_RC_FAKE_BIN/codex" \
    NORMAL_CODEX_NAME="$COD_RC_NORMAL" \
    FAKE_CODEX_LOG="$COD_RC_LOG" \
    PATH="$COD_RC_FAKE_BIN:$PATH" \
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
