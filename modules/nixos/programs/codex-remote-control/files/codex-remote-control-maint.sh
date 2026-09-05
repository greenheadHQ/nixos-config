#!/usr/bin/env bash
# Maintain the Codex mobile remote-control app-server on greenhead-minipc.
set -euo pipefail

CODEX_OPERATOR="${CODEX_OPERATOR:-codex}"
NORMAL_CODEX_NAME="${NORMAL_CODEX_NAME:-codex}"
HOME="${HOME:-/home/greenhead}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
STATE_DIR="${STATE_DIR:-/var/lib/codex-remote-control}"
DESIRED_VERSION="${DESIRED_VERSION:-}"
STANDALONE_TRIPLE="${STANDALONE_TRIPLE:-x86_64-unknown-linux-musl}"
STANDALONE_PACKAGE="${STANDALONE_PACKAGE:-}"
STANDALONE_ROOT="${STANDALONE_ROOT:-$CODEX_HOME/packages/standalone}"
STANDALONE_RELEASE_DIR="${STANDALONE_RELEASE_DIR:-$STANDALONE_ROOT/releases/${DESIRED_VERSION}-${STANDALONE_TRIPLE}}"
STANDALONE_CURRENT="${STANDALONE_CURRENT:-$STANDALONE_ROOT/current}"
STANDALONE_BIN="$STANDALONE_CURRENT/bin/codex"
STATUS_FILE="$STATE_DIR/status.json"
LOCK_FILE="$STATE_DIR/maintenance.lock"
MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"
PUSHOVER_CRED_FILE="${PUSHOVER_CRED_FILE:-}"
SERVICE_LIB="${SERVICE_LIB:-}"
CODEX_REMOTE_CONTROL_PS_FILE="${CODEX_REMOTE_CONTROL_PS_FILE:-}"
CODEX_REMOTE_CONTROL_EXE_FILE="${CODEX_REMOTE_CONTROL_EXE_FILE:-}"
KILL_LOG="${KILL_LOG:-}"
DAEMON_LOG_PATH="${DAEMON_LOG_PATH:-$CODEX_HOME/app-server-daemon/app-server.stderr.log}"
# ensure 시작 시점의 데몬 로그 크기. 알림 근거는 이 offset 이후에 새로 쓰인 ERROR만
# "이번 실행" 것으로 본다 (데몬 로그는 append-only이고 실행마다 지워지지 않는다).
DAEMON_LOG_OFFSET=0

readonly ACTION_NONE="none"
readonly RC_NORMAL_CODEX_STANDALONE=20
readonly RC_NORMAL_CODEX_NOT_NIX=21
readonly RC_STANDALONE_PACKAGE_MISSING=22
readonly RC_STANDALONE_PACKAGE_MISSING_BIN=23
readonly RC_STANDALONE_PACKAGE_VERSION_MISMATCH=24
readonly RC_OPERATOR_CODEX_NOT_FOUND=25
readonly RC_AUTH_API_KEY=30
readonly RC_AUTH_NOT_CHATGPT=31
readonly RC_DAEMON_MALFORMED_JSON=40
readonly RC_DAEMON_NOT_RUNNING=41
readonly RC_REMOTE_START_NOT_CONNECTED=50
readonly RC_REMOTE_START_MALFORMED_JSON=51
readonly RC_REMOTE_START_FAILED=52
readonly RC_REMOTE_STOP_FAILED=53
readonly RC_REMOTE_START_VERSION_DRIFT=54
readonly RC_SOCKET_CLEANUP_REFUSED=60
readonly RC_UNMANAGED_WITHOUT_STALE_PROOF=61
readonly RC_UNMANAGED=75
readonly SOCKET_CLEANUP_AFTER_VERIFIED_KILL="after-verified-kill"
readonly SOCKET_CLEANUP_NO_PID_REQUIRED="no-pid-required"

LAST_ACTION="$ACTION_NONE"
LAST_REPAIR_REASON=""
OPERATOR_CLI=""
OPERATOR_CLI_RESOLVED=""
NORMAL_CODEX_PATH=""
NORMAL_CODEX_RESOLVED=""
STANDALONE_VERSION=""
LOGIN_STATUS=""
AUTH_MODE="unknown"
DAEMON_STATUS="unknown"
MANAGED_CODEX_VERSION=""
APP_SERVER_VERSION=""
REMOTE_CONTROL_ENABLED="null"
SERVER_NAME=""
PID_EVIDENCE=""
START_STDERR=""
DAEMON_STDERR=""

die() {
  echo "ERROR: $*" >&2
  return 1
}

set_last_action_if_none() {
  local action="$1"
  [ "$LAST_ACTION" != "$ACTION_NONE" ] || LAST_ACTION="$action"
}

require_config() {
  [ -n "$DESIRED_VERSION" ] || die "DESIRED_VERSION is required"
  [ -n "$STANDALONE_PACKAGE" ] || die "STANDALONE_PACKAGE is required"
}

mkdir_state() {
  mkdir -p "$STATE_DIR"
}

with_lock() {
  mkdir_state || {
    LAST_REPAIR_REASON="state-dir-unavailable"
    return 1
  }
  exec 9>"$LOCK_FILE" || {
    LAST_REPAIR_REASON="lock-open-failed"
    return 1
  }
  flock --timeout "$MAINT_LOCK_TIMEOUT_SECONDS" 9 || {
    LAST_REPAIR_REASON="lock-acquire-timeout"
    return 1
  }
  # fd 9는 이 셸이 락을 유지하는 동안만 살아야 한다. 리다이렉트 없이 실행하면
  # codex remote-control start가 detach하는 app-server 데몬이 fd 9를 상속해
  # 스크립트 종료 후에도 락을 영구 점유하고, 이후 모든 타이머 실행이
  # lock-acquire-timeout으로 실패한다. 9>&-는 명령 스코프에서만 fd 9를 닫으므로
  # (bash가 원본 fd를 CLOEXEC 임시 fd로 보존) 이 셸의 락은 유지된다.
  "$@" 9>&-
}

path_under() {
  local path="$1"
  local root="$2"
  case "$path" in
    "$root" | "$root"/*) return 0 ;;
    *) return 1 ;;
  esac
}

text_mentions_path() {
  local text="$1"
  local root="$2"
  case "$text" in
    *"$root"*) return 0 ;;
    *) return 1 ;;
  esac
}

version_from_output() {
  awk '{print $NF}' <<<"$1"
}

resolve_operator_cli() {
  if OPERATOR_CLI="$(command -v "$CODEX_OPERATOR" 2>/dev/null)" && [ -n "$OPERATOR_CLI" ]; then
    OPERATOR_CLI_RESOLVED="$(readlink -f "$OPERATOR_CLI" 2>/dev/null || printf '%s' "$OPERATOR_CLI")"
  else
    OPERATOR_CLI=""
    OPERATOR_CLI_RESOLVED=""
  fi
}

resolve_normal_codex() {
  if NORMAL_CODEX_PATH="$(command -v "$NORMAL_CODEX_NAME" 2>/dev/null)" && [ -n "$NORMAL_CODEX_PATH" ]; then
    NORMAL_CODEX_RESOLVED="$(readlink -f "$NORMAL_CODEX_PATH" 2>/dev/null || printf '%s' "$NORMAL_CODEX_PATH")"
  else
    NORMAL_CODEX_PATH=""
    NORMAL_CODEX_RESOLVED=""
  fi
}

check_standalone_version() {
  STANDALONE_VERSION=""
  if [ -x "$STANDALONE_BIN" ]; then
    STANDALONE_VERSION="$(version_from_output "$("$STANDALONE_BIN" --version 2>/dev/null || true)")"
  fi
}

ensure_path_invariant() {
  local local_codex="$HOME/.local/bin/codex"
  local target=""

  if [ -L "$local_codex" ]; then
    target="$(readlink -f "$local_codex" 2>/dev/null || true)"
    if [ -n "$target" ] && path_under "$target" "$STANDALONE_ROOT"; then
      rm -f "$local_codex"
      LAST_ACTION="removed-standalone-path-shadow"
    fi
  fi

  resolve_normal_codex
  if [ -n "$NORMAL_CODEX_RESOLVED" ] && path_under "$NORMAL_CODEX_RESOLVED" "$STANDALONE_ROOT"; then
    LAST_REPAIR_REASON="normal-codex-resolves-to-standalone"
    return "$RC_NORMAL_CODEX_STANDALONE"
  fi
  case "$NORMAL_CODEX_RESOLVED" in
    /nix/store/*-codex-* | /etc/profiles/per-user/*/bin/codex | /run/current-system/sw/bin/codex | "")
      return 0
      ;;
    *)
      LAST_REPAIR_REASON="normal-codex-not-nix-managed:$NORMAL_CODEX_PATH->$NORMAL_CODEX_RESOLVED"
      return "$RC_NORMAL_CODEX_NOT_NIX"
      ;;
  esac
}

sync_standalone_package() {
  require_config || return $?
  ensure_path_invariant || return $?
  check_standalone_version

  if [ "$STANDALONE_VERSION" = "$DESIRED_VERSION" ] \
    && [ -x "$STANDALONE_RELEASE_DIR/bin/codex" ] \
    && [ -L "$STANDALONE_CURRENT" ]; then
    [ -L "$STANDALONE_RELEASE_DIR/codex" ] || ln -sfn bin/codex "$STANDALONE_RELEASE_DIR/codex"
    set_last_action_if_none "standalone-already-current"
    return 0
  fi

  [ -f "$STANDALONE_PACKAGE" ] || {
    LAST_REPAIR_REASON="standalone-package-missing:$STANDALONE_PACKAGE"
    return "$RC_STANDALONE_PACKAGE_MISSING"
  }

  mkdir -p "$STANDALONE_ROOT/releases" || {
    LAST_REPAIR_REASON="standalone-sync-failed:mkdir-releases"
    return 1
  }
  local staging
  staging="$(mktemp -d "$STANDALONE_ROOT/releases/.staging-${DESIRED_VERSION}.XXXXXX")" || {
    LAST_REPAIR_REASON="standalone-sync-failed:mktemp"
    return 1
  }
  tar -xzf "$STANDALONE_PACKAGE" -C "$staging" || {
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-sync-failed:extract"
    return 1
  }
  if [ ! -x "$staging/bin/codex" ]; then
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-package-missing-bin-codex"
    return "$RC_STANDALONE_PACKAGE_MISSING_BIN"
  fi

  local extracted_version
  extracted_version="$(version_from_output "$("$staging/bin/codex" --version 2>/dev/null || true)")"
  if [ "$extracted_version" != "$DESIRED_VERSION" ]; then
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-package-version-mismatch:$extracted_version"
    return "$RC_STANDALONE_PACKAGE_VERSION_MISMATCH"
  fi

  chmod -R u+rwX,go-rwx "$staging" || {
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-sync-failed:chmod"
    return 1
  }
  ln -sfn bin/codex "$staging/codex" || {
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-sync-failed:release-link"
    return 1
  }
  rm -rf "$STANDALONE_RELEASE_DIR" || {
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-sync-failed:remove-old-release"
    return 1
  }
  mv "$staging" "$STANDALONE_RELEASE_DIR" || {
    rm -rf "$staging"
    LAST_REPAIR_REASON="standalone-sync-failed:move-release"
    return 1
  }

  if [ -e "$STANDALONE_CURRENT" ] && [ ! -L "$STANDALONE_CURRENT" ]; then
    rm -rf "$STANDALONE_CURRENT" || {
      LAST_REPAIR_REASON="standalone-sync-failed:remove-current"
      return 1
    }
  fi
  ln -sfn "$STANDALONE_RELEASE_DIR" "$STANDALONE_ROOT/.current.tmp" || {
    LAST_REPAIR_REASON="standalone-sync-failed:current-link"
    return 1
  }
  mv -Tf "$STANDALONE_ROOT/.current.tmp" "$STANDALONE_CURRENT" || {
    rm -f "$STANDALONE_ROOT/.current.tmp"
    LAST_REPAIR_REASON="standalone-sync-failed:current-swap"
    return 1
  }
  STANDALONE_VERSION="$DESIRED_VERSION"
  LAST_ACTION="synced-standalone-package"
}

capture_login_status() {
  local raw_status
  raw_status="$("$CODEX_OPERATOR" login status 2>&1 || true)"
  case "$raw_status" in
    *"Logged in using ChatGPT"*)
      AUTH_MODE="chatgpt"
      LOGIN_STATUS="$AUTH_MODE"
      return 0
      ;;
    *"API key"* | *"api key"* | *"API_KEY"*)
      AUTH_MODE="api-key"
      LOGIN_STATUS="$AUTH_MODE"
      LAST_REPAIR_REASON="auth-not-chatgpt"
      return "$RC_AUTH_API_KEY"
      ;;
    *)
      AUTH_MODE="unknown"
      LOGIN_STATUS="$AUTH_MODE"
      LAST_REPAIR_REASON="auth-status-not-chatgpt"
      return "$RC_AUTH_NOT_CHATGPT"
      ;;
  esac
}

capture_daemon_version() {
  local out
  local err
  err="$(mktemp)"
  if out="$("$CODEX_OPERATOR" app-server daemon version 2>"$err")"; then
    DAEMON_STDERR="$(cat "$err")"
    rm -f "$err"
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
      DAEMON_STATUS="$(jq -r '.status // "unknown"' <<<"$out")"
      MANAGED_CODEX_VERSION="$(jq -r '.managedCodexVersion // ""' <<<"$out")"
      APP_SERVER_VERSION="$(jq -r '.appServerVersion // ""' <<<"$out")"
      return 0
    fi
    DAEMON_STATUS="malformed-json"
    DAEMON_STDERR="$out"
    return "$RC_DAEMON_MALFORMED_JSON"
  fi

  DAEMON_STDERR="$(cat "$err")"
  rm -f "$err"
  DAEMON_STATUS="not-running"
  return "$RC_DAEMON_NOT_RUNNING"
}

contains_unmanaged_error() {
  local text="$1"
  case "$text" in
    *"not managed by codex app-server daemon"* | *"WebSocket protocol error"* | *"Connection reset without closing handshake"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remote_start_versions_current() {
  [ "$MANAGED_CODEX_VERSION" = "$DESIRED_VERSION" ] && [ "$APP_SERVER_VERSION" = "$DESIRED_VERSION" ]
}

remote_start() {
  local out
  local err
  err="$(mktemp)"
  if out="$("$CODEX_OPERATOR" remote-control start --json 2>"$err")"; then
    START_STDERR="$(cat "$err")"
    rm -f "$err"
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
      SERVER_NAME="$(jq -r '.serverName // ""' <<<"$out")"
      MANAGED_CODEX_VERSION="$(jq -r '.daemon.managedCodexVersion // .managedCodexVersion // ""' <<<"$out")"
      APP_SERVER_VERSION="$(jq -r '.daemon.appServerVersion // .appServerVersion // ""' <<<"$out")"
      DAEMON_STATUS="$(jq -r '.daemon.status // .status // "unknown"' <<<"$out")"
      if jq -e '(.remoteControlEnabled == true) or (.status == "connected")' >/dev/null 2>&1 <<<"$out"; then
        if ! remote_start_versions_current; then
          REMOTE_CONTROL_ENABLED="false"
          LAST_REPAIR_REASON="remote-control-start-version-drift:${MANAGED_CODEX_VERSION:-missing}/${APP_SERVER_VERSION:-missing}"
          return "$RC_REMOTE_START_VERSION_DRIFT"
        fi
        REMOTE_CONTROL_ENABLED="true"
        return 0
      fi
      REMOTE_CONTROL_ENABLED="false"
      LAST_REPAIR_REASON="remote-control-start-not-connected"
      return "$RC_REMOTE_START_NOT_CONNECTED"
    fi
    REMOTE_CONTROL_ENABLED="false"
    LAST_REPAIR_REASON="remote-control-start-malformed-json"
    return "$RC_REMOTE_START_MALFORMED_JSON"
  fi

  START_STDERR="$(cat "$err")"
  rm -f "$err"
  REMOTE_CONTROL_ENABLED="false"
  if contains_unmanaged_error "$START_STDERR"; then
    LAST_REPAIR_REASON="remote-control-start-unmanaged"
    return "$RC_UNMANAGED"
  fi
  LAST_REPAIR_REASON="remote-control-start-failed"
  return "$RC_REMOTE_START_FAILED"
}

remote_stop() {
  local out
  local err
  err="$(mktemp)"
  if out="$("$CODEX_OPERATOR" remote-control stop --json 2>"$err")"; then
    rm -f "$err"
    return 0
  fi
  out="$(cat "$err")"
  rm -f "$err"
  if contains_unmanaged_error "$out"; then
    LAST_REPAIR_REASON="remote-control-stop-unmanaged"
    return "$RC_UNMANAGED"
  fi
  LAST_REPAIR_REASON="remote-control-stop-failed"
  return "$RC_REMOTE_STOP_FAILED"
}

collect_pid_evidence() {
  if [ -n "$CODEX_REMOTE_CONTROL_PS_FILE" ]; then
    PID_EVIDENCE="$(cat "$CODEX_REMOTE_CONTROL_PS_FILE" 2>/dev/null || true)"
  else
    local current_user
    current_user="$(id -un)"
    PID_EVIDENCE="$(
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s %s %s\n' "$(awk '{print $1}' <<<"$line")" "$current_user" "$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' <<<"$line")"
      done < <(pgrep -a -u "$(id -u)" -f 'codex .*app-server|app-server --listen unix://' || true)
    )"
  fi
}

parse_pid_line() {
  local line="$1"
  PID_FIELD="$(awk '{print $1}' <<<"$line")"
  USER_FIELD="$(awk '{print $2}' <<<"$line")"
  CMD_FIELD="$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+//' <<<"$line")"
}

is_app_server_line() {
  local cmd="$1"
  case "$cmd" in
    *"app-server --listen unix://"* | *"codex app-server"*) return 0 ;;
    *) return 1 ;;
  esac
}

is_same_user_app_server_line() {
  local line="$1"
  local current_user
  current_user="$(id -un)"
  parse_pid_line "$line"
  [ "$USER_FIELD" = "$current_user" ] || return 1
  is_app_server_line "$CMD_FIELD"
}

is_managed_standalone_cmd() {
  local cmd="$1"
  text_mentions_path "$cmd" "$STANDALONE_ROOT"
}

is_known_legacy_codex_cmd() {
  local cmd="$1"
  case "$cmd" in
    *"/.local/share/mise/installs/npm-openai-codex/"* | *"npm-openai-codex"* | *"/.local/share/mise/installs/node/"* | *"/vendor/"*"unknown-linux-musl/bin/codex app-server"*)
      return 0
      ;;
  esac
  return 1
}

# Resolve a PID's actual executable path. The kernel records /proc/$pid/exe at
# exec() time, so the `current` symlink can be re-pointed afterward without
# changing an already-running process's executable. A deleted executable is
# reported with a trailing " (deleted)" marker. Tests inject a PID-to-exe
# mapping file (one "<pid> <exe path>" line per PID) via CODEX_REMOTE_CONTROL_EXE_FILE.
pid_exe_path() {
  local pid="$1"
  if [ -n "$CODEX_REMOTE_CONTROL_EXE_FILE" ]; then
    [ -f "$CODEX_REMOTE_CONTROL_EXE_FILE" ] || return 0
    awk -v pid="$pid" '$1 == pid { sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); print; exit }' \
      "$CODEX_REMOTE_CONTROL_EXE_FILE" 2>/dev/null || true
  else
    readlink "/proc/$pid/exe" 2>/dev/null || true
  fi
}

# Decide whether an executable path proves a managed-standalone process is stale.
# It is stale only when the executable clearly originates from the managed
# standalone tree yet is no longer the desired release: either the binary was
# deleted (the `current` symlink moved and the old release was removed) or it
# still lives under an older release directory. Unknown/empty paths are never
# treated as stale — per-process proof stays required.
exe_indicates_stale_standalone() {
  local exe="$1"
  local clean="$exe"
  local is_deleted=0
  case "$exe" in
    *" (deleted)")
      clean="${exe% (deleted)}"
      is_deleted=1
      ;;
  esac
  # Only reason about executables that belong to the managed standalone tree.
  path_under "$clean" "$STANDALONE_ROOT" || return 1
  # A deleted managed binary can never be the live desired release.
  [ "$is_deleted" -eq 1 ] && return 0
  # A still-present binary under the desired release directory is current.
  path_under "$clean" "$STANDALONE_RELEASE_DIR" && return 1
  # Otherwise it runs a superseded release even though `current` has moved on.
  return 0
}

# Classify an app-server process — identified by its command line and PID — as
# stale (return 0) or not (non-zero). Shared by is_stale_unmanaged_line (ps/
# fixture evidence path) and current_pid_matches_stale_proof (production /proc
# revalidation before kill) so both paths classify identically; extend the rule
# here, in one place, rather than in either caller.
classify_stale_by_cmd_and_pid() {
  local cmd="$1"
  local pid="$2"
  if is_managed_standalone_cmd "$cmd"; then
    # A managed standalone command line usually means the current release, but
    # `current` is a symlink: an already-running process can keep executing an
    # old, since-removed release after `current` moved. Only per-process /proc
    # executable evidence — not global version drift — can prove that case.
    exe_indicates_stale_standalone "$(pid_exe_path "$pid")"
    return $?
  fi

  # Kill safety requires per-process evidence. Global daemon version drift is not
  # enough to prove that an arbitrary same-user app-server PID is stale.
  is_known_legacy_codex_cmd "$cmd"
}

is_stale_unmanaged_line() {
  local line="$1"
  is_same_user_app_server_line "$line" || return 1
  classify_stale_by_cmd_and_pid "$CMD_FIELD" "$PID_FIELD"
}

pid_is_numeric() {
  case "$1" in
    "" | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

remove_pid_from_fixture() {
  local pid="$1"
  [ -n "$CODEX_REMOTE_CONTROL_PS_FILE" ] && [ -f "$CODEX_REMOTE_CONTROL_PS_FILE" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v pid="$pid" '$1 != pid' "$CODEX_REMOTE_CONTROL_PS_FILE" >"$tmp"
  mv "$tmp" "$CODEX_REMOTE_CONTROL_PS_FILE"
}

current_pid_matches_stale_proof() {
  local pid="$1"
  pid_is_numeric "$pid" || return 1

  # Fixture mode uses fake PIDs; production revalidates live /proc state below.
  [ -z "$KILL_LOG" ] || return 0
  [ -r "/proc/$pid/status" ] && [ -r "/proc/$pid/cmdline" ] || return 1

  local current_uid
  local pid_uid
  local current_cmd
  current_uid="$(id -u)"
  pid_uid="$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)"
  [ "$pid_uid" = "$current_uid" ] || return 1

  current_cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  [ -n "$current_cmd" ] || return 1
  is_app_server_line "$current_cmd" || return 1
  classify_stale_by_cmd_and_pid "$current_cmd" "$pid"
}

kill_pid() {
  local pid="$1"
  current_pid_matches_stale_proof "$pid" || {
    LAST_REPAIR_REASON="stale-pid-revalidation-failed:$pid"
    return "$RC_UNMANAGED_WITHOUT_STALE_PROOF"
  }
  if [ -n "$KILL_LOG" ]; then
    printf '%s\n' "$pid" >>"$KILL_LOG"
    remove_pid_from_fixture "$pid"
  else
    kill "$pid" 2>/dev/null || true
    sleep 1
    if kill -0 "$pid" 2>/dev/null; then
      current_pid_matches_stale_proof "$pid" || {
        LAST_REPAIR_REASON="stale-pid-revalidation-failed-before-kill9:$pid"
        return "$RC_UNMANAGED_WITHOUT_STALE_PROOF"
      }
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
}

app_server_pid_exists() {
  collect_pid_evidence
  [ -z "$PID_EVIDENCE" ] && return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    parse_pid_line "$line"
    if is_app_server_line "$CMD_FIELD"; then
      return 0
    fi
  done <<<"$PID_EVIDENCE"
  return 1
}

cleanup_socket_files() {
  : "${1:-$SOCKET_CLEANUP_NO_PID_REQUIRED}"
  if app_server_pid_exists; then
    LAST_REPAIR_REASON="refusing-socket-cleanup-while-app-server-pid-exists"
    return "$RC_SOCKET_CLEANUP_REFUSED"
  fi

  rm -f \
    "$CODEX_HOME/app-server-control/app-server-control.sock" \
    "$CODEX_HOME/app-server-control/desktop-ssh-websocket-v0.sock" \
    "$CODEX_HOME/app-server-control/app-server-startup.lock" \
    "$CODEX_HOME/app-server-daemon/app-server.pid.lock" \
    "$CODEX_HOME/app-server-daemon/app-server-updater.pid.lock" \
    "$CODEX_HOME/app-server-daemon/daemon.lock"
  LAST_ACTION="cleaned-stale-app-server-sockets"
}

repair_unmanaged_core() {
  require_config || return $?
  collect_pid_evidence
  local killed=0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if is_stale_unmanaged_line "$line"; then
      parse_pid_line "$line"
      kill_pid "$PID_FIELD" || return $?
      killed=$((killed + 1))
    fi
  done <<<"$PID_EVIDENCE"

  if [ "$killed" -eq 0 ]; then
    LAST_REPAIR_REASON="unmanaged-error-without-stale-pid-proof"
    return "$RC_UNMANAGED_WITHOUT_STALE_PROOF"
  fi

  cleanup_socket_files "$SOCKET_CLEANUP_AFTER_VERIFIED_KILL" || return $?
  LAST_REPAIR_REASON="killed-stale-unmanaged-app-server:$killed"
  LAST_ACTION="repaired-unmanaged-app-server"
}

ensure_running_core() {
  require_config || return $?
  resolve_operator_cli
  [ -n "$OPERATOR_CLI" ] || {
    LAST_REPAIR_REASON="operator-codex-not-found"
    return "$RC_OPERATOR_CODEX_NOT_FOUND"
  }

  sync_standalone_package || return $?
  capture_login_status || return $?

  local daemon_rc=0
  if capture_daemon_version; then
    if [ "$MANAGED_CODEX_VERSION" != "$DESIRED_VERSION" ] || [ "$APP_SERVER_VERSION" != "$DESIRED_VERSION" ]; then
      LAST_REPAIR_REASON="daemon-version-drift:${MANAGED_CODEX_VERSION}/${APP_SERVER_VERSION}"
      local stop_rc=0
      remote_stop || stop_rc=$?
      if [ "$stop_rc" -ne 0 ]; then
        if [ "$stop_rc" -eq "$RC_UNMANAGED" ]; then
          repair_unmanaged_core || return $?
        else
          return "$stop_rc"
        fi
      fi
      cleanup_socket_files "$SOCKET_CLEANUP_NO_PID_REQUIRED" || return $?
      remote_start || {
        local rc=$?
        if [ "$rc" -eq "$RC_UNMANAGED" ]; then
          repair_unmanaged_core || return $?
          remote_start || return $?
        else
          return "$rc"
        fi
      }
      LAST_ACTION="restarted-version-drift"
      return 0
    fi
  else
    daemon_rc=$?
    if [ "$daemon_rc" -eq "$RC_DAEMON_MALFORMED_JSON" ]; then
      LAST_REPAIR_REASON="daemon-version-malformed-json"
      return "$daemon_rc"
    fi
    if contains_unmanaged_error "$DAEMON_STDERR"; then
      repair_unmanaged_core || return $?
    fi
  fi

  local start_rc=0
  remote_start || start_rc=$?
  if [ "$start_rc" -ne 0 ]; then
    if [ "$start_rc" -eq "$RC_UNMANAGED" ]; then
      repair_unmanaged_core || return $?
      remote_start || return $?
    else
      return "$start_rc"
    fi
  fi
  set_last_action_if_none "remote-control-healthy"
}

collect_probe() {
  resolve_operator_cli
  resolve_normal_codex
  check_standalone_version
  if [ -n "$OPERATOR_CLI" ]; then
    capture_login_status || true
    capture_daemon_version || true
  fi
}

collect_probe_preserving_reason() {
  local previous_reason="$LAST_REPAIR_REASON"
  collect_probe
  [ -z "$previous_reason" ] || LAST_REPAIR_REASON="$previous_reason"
}

status_json() {
  local exit_code="${1:-0}"
  jq -n \
    --arg timestamp "$(date -Is)" \
    --arg operatorCli "$OPERATOR_CLI_RESOLVED" \
    --arg normalCodexPath "$NORMAL_CODEX_PATH" \
    --arg normalCodexResolved "$NORMAL_CODEX_RESOLVED" \
    --arg standalonePath "$STANDALONE_BIN" \
    --arg desiredVersion "$DESIRED_VERSION" \
    --arg standaloneVersion "$STANDALONE_VERSION" \
    --arg managedCodexVersion "$MANAGED_CODEX_VERSION" \
    --arg appServerVersion "$APP_SERVER_VERSION" \
    --arg authMode "$AUTH_MODE" \
    --arg loginStatus "$LOGIN_STATUS" \
    --arg daemonStatus "$DAEMON_STATUS" \
    --arg serverName "$SERVER_NAME" \
    --arg lastAction "$LAST_ACTION" \
    --arg lastRepairReason "$LAST_REPAIR_REASON" \
    --arg pidEvidence "$PID_EVIDENCE" \
    --argjson remoteControlEnabled "$REMOTE_CONTROL_ENABLED" \
    --argjson exitCode "$exit_code" \
    '{
      timestamp: $timestamp,
      operatorCli: $operatorCli,
      normalCodexPath: $normalCodexPath,
      normalCodexResolved: $normalCodexResolved,
      standalonePath: $standalonePath,
      desiredVersion: $desiredVersion,
      standaloneVersion: $standaloneVersion,
      managedCodexVersion: $managedCodexVersion,
      appServerVersion: $appServerVersion,
      remoteControlEnabled: $remoteControlEnabled,
      authMode: $authMode,
      loginStatus: $loginStatus,
      daemonStatus: $daemonStatus,
      serverName: $serverName,
      lastAction: $lastAction,
      lastRepairReason: $lastRepairReason,
      pidEvidence: $pidEvidence,
      exitCode: $exitCode
    }'
}

write_status() {
  local exit_code="${1:-0}"
  mkdir_state || return $?
  local tmp
  tmp="$(mktemp "$STATE_DIR/status.XXXXXX")" || return $?
  status_json "$exit_code" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$STATUS_FILE"
}

load_alerting() {
  # shellcheck source=/dev/null
  [ -n "$SERVICE_LIB" ] && [ -f "$SERVICE_LIB" ] && source "$SERVICE_LIB"
  local pushover_cred="$PUSHOVER_CRED_FILE"
  if [ -z "$pushover_cred" ] && [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
    pushover_cred="$CREDENTIALS_DIRECTORY/pushover-system-monitor"
  fi
  if [ -n "$pushover_cred" ] && [ -r "$pushover_cred" ]; then
    # shellcheck source=/dev/null
    source "$pushover_cred"
  fi
}

ALERT_HOST="${ALERT_HOST:-greenhead-minipc}"
# Pushover 본문 상한(1024자) 안에서 근거 라인까지 담기 위한 예산.
ALERT_BODY_MAX_BYTES=1000
ALERT_EVIDENCE_LINE_MAX_BYTES=240

strip_ansi() {
  # BSD sed는 \x1b를 모르므로 awk (gawk/BSD awk 모두 \033 지원)
  awk '{ gsub(/\033\[[0-9;]*m/, ""); print }'
}

# 바이트 예산으로 자르되 꼬리의 잘린 UTF-8 시퀀스를 버린다. GNU cut -c는 바이트 단위라
# 한글(3바이트)이 쪼개져 잘못된 UTF-8이 Pushover로 갈 수 있다. 로케일에 의존하지 않는다.
truncate_utf8() {
  local text="$1" max="$2" s n i byte need
  s="$(printf '%s' "$text" | head -c "$max")"
  local LC_ALL=C
  n=${#s}
  if [ "$n" -lt "$max" ]; then
    printf '%s' "$s"
    return 0
  fi
  for ((i = 1; i <= 4 && i <= n; i++)); do
    byte=$(printf '%d' "'${s:n-i:1}")
    if ((byte < 0x80)); then
      printf '%s' "$s"
      return 0
    fi
    if ((byte >= 0xC0)); then
      if ((byte >= 0xF0)); then need=4; elif ((byte >= 0xE0)); then need=3; else need=2; fi
      if ((i < need)); then printf '%s' "${s:0:n-i}"; else printf '%s' "$s"; fi
      return 0
    fi
  done
  printf '%s' "$s"
}

capture_daemon_log_offset() {
  DAEMON_LOG_OFFSET=0
  [ -f "$DAEMON_LOG_PATH" ] || return 0
  DAEMON_LOG_OFFSET="$(wc -c <"$DAEMON_LOG_PATH" | tr -d '[:space:]')"
}

# app-server 로그가 원인을 말해 주는 실패만 근거 대상이다. lock·패키지 동기화·로그인
# 상태처럼 app-server를 건드리기 전에 끝난 실패에 데몬 로그를 붙이면 무관한 토큰 수리로
# 오도한다.
evidence_relevant_for_reason() {
  case "${1%%:*}" in
    remote-control-* | daemon-version-* | unmanaged-error-without-stale-pid-proof | stale-pid-* | refusing-socket-cleanup-while-app-server-pid-exists) return 0 ;;
    *) return 1 ;;
  esac
}

# LAST_REPAIR_REASON 코드 → 한국어 "원인<TAB>조치". `:` 뒤 상세는 코드 표시에만 남긴다.
# 알림만 보고도 왜 실패했고 무엇을 해야 하는지 알 수 있어야 한다 (2026-09-05 token_revoke
# 장애 때 "exit=52, reason=remote-control-start-failed"만으로는 하루종일 원인을 몰랐다).
repair_reason_explain() {
  local reason="${1:-unknown}" head
  head="${reason%%:*}"
  case "$head" in
    remote-control-start-not-connected)
      printf '%s\t%s' \
        "app-server가 백엔드에 연결되지 못한 채 timeout(connecting)" \
        "ChatGPT 토큰 revoke가 흔한 원인 — 아래 app-server 로그에 401 token_revoked가 보이면 MiniPC에서 'codex login --device-auth'로 재로그인 (시작 전 ~/.codex/auth.json 백업)"
      ;;
    remote-control-start-failed)
      printf '%s\t%s' \
        "'codex remote-control start' 명령 자체가 실패" \
        "아래 stderr/app-server 로그 확인. 401 token_revoked면 'codex login --device-auth' 재로그인, 그 외는 MiniPC에서 'codex remote-control start --json'을 직접 실행해 재현"
      ;;
    remote-control-start-malformed-json | daemon-version-malformed-json)
      printf '%s\t%s' \
        "codex CLI 출력이 JSON이 아님" \
        "codex 업데이트로 출력 형식이 바뀌었는지 확인 (codex-pin.json 버전 vs 'codex --version')"
      ;;
    remote-control-start-version-drift | daemon-version-drift)
      printf '%s\t%s' \
        "실행 중 app-server 버전이 pin과 다름" \
        "maint가 재시작을 시도함. 반복되면 'codex remote-control stop' 후 'systemctl start codex-remote-control-ensure'"
      ;;
    remote-control-start-unmanaged | remote-control-stop-unmanaged | unmanaged-error-without-stale-pid-proof | stale-pid-revalidation-failed | stale-pid-revalidation-failed-before-kill9 | refusing-socket-cleanup-while-app-server-pid-exists)
      printf '%s\t%s' \
        "관리 밖(수동 실행) app-server가 소켓/PID를 점유" \
        "'pgrep -a -u greenhead codex'로 확인 후 수동 프로세스를 종료하고 'systemctl start codex-remote-control-ensure'"
      ;;
    remote-control-stop-failed)
      printf '%s\t%s' \
        "app-server 정지 실패" \
        "'pgrep -a -u greenhead codex'로 남은 프로세스 확인 후 kill -TERM, 다음 ensure가 재시작"
      ;;
    auth-not-chatgpt | auth-status-not-chatgpt)
      printf '%s\t%s' \
        "ChatGPT 계정 로그인이 아님 (API key 모드 또는 미로그인)" \
        "MiniPC에서 'codex login --device-auth'"
      ;;
    lock-acquire-timeout | lock-open-failed | state-dir-unavailable)
      printf '%s\t%s' \
        "maint 상태 디렉토리 또는 lock 획득 실패" \
        "'pgrep -af codex-remote-control-maint'로 이전 실행 잔존 확인 (이름이 15자를 넘어 -f 없이는 못 찾음), /var/lib/codex-remote-control 권한 확인"
      ;;
    standalone-package-missing | standalone-package-missing-bin-codex | standalone-package-version-mismatch | standalone-sync-failed)
      printf '%s\t%s' \
        "standalone codex 패키지 동기화 실패" \
        "nrs로 codex-pin.json과 배포 generation을 맞추고 ~/.codex/packages/standalone 권한·디스크 확인"
      ;;
    normal-codex-resolves-to-standalone | normal-codex-not-nix-managed | operator-codex-not-found)
      printf '%s\t%s' \
        "PATH의 codex가 Nix 관리 바이너리가 아님" \
        "그림자 codex(~/.local/bin 등)를 제거하고 nrs"
      ;;
    *)
      printf '%s\t%s' \
        "분류되지 않은 실패 ($reason)" \
        "'journalctl -u codex-remote-control-ensure'와 /var/lib/codex-remote-control/status.json 확인"
      ;;
  esac
}

# 실패 시점 근거: start 명령 stderr 첫 줄 + app-server 데몬 로그의 마지막 ERROR 라인.
# token_revoked 같은 실제 원인은 status.json이 아니라 이 로그에만 남는다.
alert_evidence() {
  local reason="$1" out="" line label size offset
  if [ -n "$START_STDERR" ]; then
    line="$(truncate_utf8 "$(printf '%s\n' "$START_STDERR" | head -n 1)" "$ALERT_EVIDENCE_LINE_MAX_BYTES")"
    [ -z "$line" ] || out="stderr: $line"
  fi
  if evidence_relevant_for_reason "$reason" && [ -f "$DAEMON_LOG_PATH" ]; then
    size="$(wc -c <"$DAEMON_LOG_PATH" | tr -d '[:space:]')"
    offset="$DAEMON_LOG_OFFSET"
    # 데몬 재시작으로 로그가 비워졌으면 offset이 크기를 넘는다 → 처음부터 본다.
    [ "$offset" -le "$size" ] || offset=0
    line="$(tail -c +"$((offset + 1))" "$DAEMON_LOG_PATH" 2>/dev/null | grep -a 'ERROR' | tail -n 1 | strip_ansi)"
    label="app-server"
    if [ -z "$line" ]; then
      line="$(grep -a 'ERROR' "$DAEMON_LOG_PATH" 2>/dev/null | tail -n 1 | strip_ansi)"
      label="app-server(이번 실행 이전 기록)"
    fi
    if [ -n "$line" ]; then
      line="$(truncate_utf8 "$line" "$ALERT_EVIDENCE_LINE_MAX_BYTES")"
      out="${out:+$out
}${label}: $line"
    fi
  fi
  printf '%s' "$out"
}

failure_alert_body() {
  local exit_code="$1" reason="${LAST_REPAIR_REASON:-unknown}" cause fix evidence body
  IFS=$'\t' read -r cause fix <<<"$(repair_reason_explain "$reason")"
  body="${ALERT_HOST}의 Codex 원격 제어 점검이 실패했습니다 (exit=${exit_code}, 코드: ${reason}, auth=${AUTH_MODE:-unknown})
원인: ${cause}
조치: ${fix}"
  evidence="$(alert_evidence "$reason")"
  [ -z "$evidence" ] || body="${body}
근거:
${evidence}"
  truncate_utf8 "$body" "$ALERT_BODY_MAX_BYTES"
}

send_alerts() {
  local exit_code="$1"
  command -v send_notification >/dev/null 2>&1 || return 0
  [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ] || return 0

  local now
  now="$(date +%s)"
  local state_file="$STATE_DIR/last-health-state"
  local last_failure_file="$STATE_DIR/last-failure-alert"
  local previous="unknown"
  [ -f "$state_file" ] && previous="$(cat "$state_file" 2>/dev/null || echo unknown)"

  if [ "$exit_code" -eq 0 ]; then
    if [ "$previous" = "failed" ]; then
      send_notification "Codex 원격 제어 복구 · ${ALERT_HOST}" \
        "${ALERT_HOST}의 Codex 원격 제어가 정상으로 돌아왔습니다 (app-server ${APP_SERVER_VERSION:-unknown})." 0
    fi
    echo "healthy" >"$state_file"
    return 0
  fi

  local last=0
  [ -f "$last_failure_file" ] && last="$(cat "$last_failure_file" 2>/dev/null || echo 0)"
  if [ $((now - last)) -ge "$ALERT_COOLDOWN_SECONDS" ]; then
    send_notification "Codex 원격 제어 실패 · ${ALERT_HOST}" "$(failure_alert_body "$exit_code")" 0
    echo "$now" >"$last_failure_file"
  fi
  echo "failed" >"$state_file"
}

cmd_probe() {
  require_config || return $?
  collect_probe
  status_json 0
}

cmd_health_json() {
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    cmd_probe
  fi
}

cmd_ensure_standalone() {
  local rc=0
  with_lock sync_standalone_package || rc=$?
  if [ "$rc" -eq 0 ]; then
    collect_probe
  else
    collect_probe_preserving_reason
  fi
  write_status "$rc" || true
  return "$rc"
}

cmd_repair_unmanaged() {
  local rc=0
  with_lock repair_unmanaged_core || rc=$?
  if [ "$rc" -eq 0 ]; then
    collect_probe
  else
    collect_probe_preserving_reason
  fi
  write_status "$rc" || true
  return "$rc"
}

cmd_ensure_running() {
  local rc=0
  capture_daemon_log_offset
  with_lock ensure_running_core || rc=$?
  if [ "$rc" -ne 0 ]; then
    collect_probe_preserving_reason
  fi
  write_status "$rc" || true
  load_alerting
  send_alerts "$rc" || true
  return "$rc"
}

usage() {
  cat >&2 <<'EOF'
Usage: codex-remote-control-maint <probe|ensure-standalone|ensure-running|repair-unmanaged|health-json>
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    probe) cmd_probe ;;
    ensure-standalone) cmd_ensure_standalone ;;
    ensure-running) cmd_ensure_running ;;
    repair-unmanaged) cmd_repair_unmanaged ;;
    health-json) cmd_health_json ;;
    -h | --help | help) usage ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
