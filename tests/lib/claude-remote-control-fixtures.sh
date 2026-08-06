# tests/lib/claude-remote-control-fixtures.sh — shared Claude Remote Control fixtures
# shellcheck shell=bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2154,SC2164

if [ "${CLAUDE_RC_FIXTURES_LOADED:-false}" = true ]; then
  return 0
fi
CLAUDE_RC_FIXTURES_LOADED=true

CLAUDE_RC_REAL_PID_ARGV_HELPER=""
CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER=""
CLAUDE_RC_SYNTHETIC_LOCK_PID=""
CLAUDE_RC_SYNTHETIC_LOCK_HOLD_SECONDS=30
CLAUDE_RC_SYNTHETIC_LOCK_POLL_ATTEMPTS=30
CLAUDE_RC_SYNTHETIC_LOCK_POLL_INTERVAL_SECONDS=0.1
# shellcheck disable=SC2034 # Consumed by sourced test suites.
CLAUDE_RC_LAUNCH_GROUP_STATUS_USAGE=64
# shellcheck disable=SC2034 # Consumed by sourced test suites.
CLAUDE_RC_LAUNCH_GROUP_STATUS_PUBLICATION_FAILED=73

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
  local bin_dir="$1" versions_dir="$2" bash_bin
  mkdir -p "$bin_dir" "$versions_dir"
  bash_bin="$versions_dir/bash"
  # macOS kills copied system executables when the copy no longer satisfies
  # the original code-signing contract. The process-identity boundary is
  # already injected through fake lsof/readlink below, so keep the signed Bash
  # interpreter in place and expose it through a version-dir symlink.
  ln -sf "$(command -v bash)" "$bash_bin"
  {
    printf '#!%s\n' "$bash_bin"
    cat <<'EOS'
set -euo pipefail
if [ -n "${FAKE_CLAUDE_START_DELAY_SECONDS:-}" ]; then
  sleep "$FAKE_CLAUDE_START_DELAY_SECONDS"
fi
printf '%s\t%s\t%s\n' "$PWD" "$0" "$*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
if [ -n "${FAKE_CLAUDE_ENV_LOG:-}" ]; then
  printf 'drift_policy=%s\tdrift_approval=%s\n' \
    "${CLAUDE_RC_DRIFT_POLICY-unset}" \
    "${CLAUDE_RC_DRIFT_APPROVAL_JSON-unset}" >> "$FAKE_CLAUDE_ENV_LOG"
  printf 'headless_marker=%s\theadless_generation=%s\tpath=%s\n' \
    "${NIXOS_CONFIG_HEADLESS_SSH-unset}" \
    "${NIXOS_CONFIG_HEADLESS_SSH_GENERATION-unset}" \
    "$PATH" >> "$FAKE_CLAUDE_ENV_LOG"
fi
if [ -n "${FAKE_STARTED_EXE_FILE:-}" ] && [ -n "${FAKE_CLAUDE_STARTED_EXE:-}" ]; then
  printf '%s\n' "$FAKE_CLAUDE_STARTED_EXE" > "$FAKE_STARTED_EXE_FILE"
fi
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
  } > "$bin_dir/claude"
  chmod +x "$bin_dir/claude"
  ln -sf claude "$bin_dir/claude-new"
}

# fake readlink는 resolve_claude_launcher의 CLAUDE_BIN `readlink -f`만 조작한다. 그 외 호출은
# 실제 도구로 passthrough해야 한다 — Linux의 pid_exe_path는 `readlink /proc/PID/exe`
# (옵션 없음)를 쓰므로, 여기서 exit 1로 막으면 Linux에서만 실행 버전 조회가 실패해
# running-version-unresolvable 오탐이 난다 (macOS는 lsof 경로라 안 걸리는 플랫폼 비대칭).
_claude_rc_install_exe_identity_mocks() {
  local bin_dir="$1" real_readlink real_lsof
  # 생성 시점 PATH에는 fake-bin이 없으므로 실제 readlink가 잡힌다.
  real_readlink="$(command -v readlink)" || fail "required test tool not found: readlink"
  real_lsof="$(_claude_rc_find_tool lsof)" || fail "required test tool not found: lsof"
  {
    printf '#!/usr/bin/env bash\nREAL_READLINK=%q\n' "$real_readlink"
    cat <<'EOS'
set -euo pipefail
if [ "${1:-}" = "-f" ] \
  && [ -n "${FAKE_CLAUDE_RESOLVED_EXE:-}" ] \
  && [ "${2:-}" = "${CLAUDE_BIN:-}" ]; then
  printf '%s\n' "$FAKE_CLAUDE_RESOLVED_EXE"
  exit 0
fi
case "${1:-}" in
  /proc/*/exe)
    if [ -n "${FAKE_STARTED_EXE_FILE:-}" ] && [ -f "$FAKE_STARTED_EXE_FILE" ]; then
      real_exe="$($REAL_READLINK "$1" 2>/dev/null || true)"
      case "${real_exe% (deleted)}" in
        */flock) exec "$REAL_READLINK" "$@" ;;
      esac
      exe="$(cat "$FAKE_STARTED_EXE_FILE")"
      [ "$exe" != "UNRESOLVABLE" ] || exit 1
      printf '%s\n' "$exe"
      exit 0
    fi
    ;;
esac
exec "$REAL_READLINK" "$@"
EOS
  } > "$bin_dir/readlink"
  {
    printf '#!/usr/bin/env bash\nREAL_LSOF=%q\n' "$real_lsof"
    cat <<'EOS'
set -euo pipefail
args=" $* "
if [[ "$args" == *" -d txt "* ]] \
  && [ -n "${FAKE_STARTED_EXE_FILE:-}" ] \
  && [ -f "$FAKE_STARTED_EXE_FILE" ]; then
  pid=""
  previous=""
  for arg in "$@"; do
    if [ "$previous" = "-p" ]; then
      pid="$arg"
      break
    fi
    previous="$arg"
  done
  [ -n "$pid" ] || exit 1
  real_exe="$("$REAL_LSOF" -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ {print substr($0, 2); exit}')"
  case "$real_exe" in
    */flock) exec "$REAL_LSOF" "$@" ;;
  esac
  exe="$(cat "$FAKE_STARTED_EXE_FILE")"
  [ "$exe" != "UNRESOLVABLE" ] || exit 1
  printf 'p%s\nn%s\n' "$pid" "$exe"
  exit 0
fi
exec "$REAL_LSOF" "$@"
EOS
  } > "$bin_dir/lsof"
  chmod +x "$bin_dir/readlink" "$bin_dir/lsof"
}

_claude_rc_install_results_write_failure_mktemp() {
  local real_mktemp
  real_mktemp="$(_claude_rc_find_tool mktemp)" || fail "required test tool not found: mktemp"
  {
    printf '#!/usr/bin/env bash\nREAL_MKTEMP=%q\n' "$real_mktemp"
    cat <<'EOS'
set -euo pipefail
if [ "$#" -eq 1 ] && [ "$1" = "$STATE_DIR/results.XXXXXX" ]; then
  denied="$STATE_DIR/results.denied"
  : > "$denied"
  chmod 0400 "$denied"
  printf '%s\n' "$denied"
  exit 0
fi
exec "$REAL_MKTEMP" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/mktemp"
  chmod +x "$CLAUDE_RC_FAKE_BIN/mktemp"
}

_claude_rc_install_status_write_failure_mktemp() {
  local real_mktemp
  real_mktemp="$(_claude_rc_find_tool mktemp)" || fail "required test tool not found: mktemp"
  {
    printf '#!/usr/bin/env bash\nREAL_MKTEMP=%q\n' "$real_mktemp"
    cat <<'EOS'
set -euo pipefail
case "${1:-}" in
  */status.XXXXXX) exit 73 ;;
  *) exec "$REAL_MKTEMP" "$@" ;;
esac
EOS
  } > "$CLAUDE_RC_FAKE_BIN/mktemp"
  chmod +x "$CLAUDE_RC_FAKE_BIN/mktemp"
}

_claude_rc_install_launch_pid_failure_mktemp() {
  local real_mktemp
  real_mktemp="$(_claude_rc_find_tool mktemp)" || fail "required test tool not found: mktemp"
  {
    printf '#!/usr/bin/env bash\nREAL_MKTEMP=%q\n' "$real_mktemp"
    cat <<'EOS'
set -euo pipefail
case "${1:-}" in
  */launch-pid.XXXXXX) exit 73 ;;
  *) exec "$REAL_MKTEMP" "$@" ;;
esac
EOS
  } > "$CLAUDE_RC_FAKE_BIN/mktemp"
  chmod +x "$CLAUDE_RC_FAKE_BIN/mktemp"
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

_claude_rc_find_trusted_flock() {
  local found
  found="$(command -v flock 2>/dev/null)" || return 1
  found="$(readlink -f "$found" 2>/dev/null)" || return 1
  case "$(uname -s):$found" in
    Darwin:/nix/store/*-flock-*/bin/flock | Linux:/nix/store/*-util-linux-*/bin/flock)
      printf '%s\n' "$found"
      ;;
    *) return 1 ;;
  esac
}

_claude_rc_build_pid_argv_helper() {
  local build_dir
  if [ -n "$CLAUDE_RC_REAL_PID_ARGV_HELPER" ] \
    && [ -x "$CLAUDE_RC_REAL_PID_ARGV_HELPER" ]; then
    return 0
  fi
  build_dir="$(_claude_rc_new_sandbox)"
  CLAUDE_RC_REAL_PID_ARGV_HELPER="$build_dir/claude-rc-pid-argv"
  cc -std=c11 -O2 -Wall -Wextra -Werror \
    "$REPO_ROOT/modules/nixos/scripts/claude-rc-pid-argv.c" \
    -o "$CLAUDE_RC_REAL_PID_ARGV_HELPER"
}

_claude_rc_build_launch_group_helper() {
  local build_dir
  if [ -n "$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER" ] \
    && [ -x "$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER" ]; then
    return 0
  fi
  build_dir="$(_claude_rc_new_sandbox)"
  CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER="$build_dir/claude-rc-launch-group"
  cc -std=c11 -O2 -Wall -Wextra -Werror \
    "$REPO_ROOT/modules/nixos/scripts/claude-rc-launch-group.c" \
    -o "$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER"
}

_claude_rc_install_pid_argv_dispatcher() {
  {
    printf '#!/usr/bin/env bash\nREAL_PID_ARGV_HELPER=%q\nPID_ARGV_FIXTURE_DIR=%q\n' \
      "$CLAUDE_RC_REAL_PID_ARGV_HELPER" "$CLAUDE_RC_PID_ARGV_FIXTURE_DIR"
    cat <<'EOS'
set -euo pipefail
if [ "${1:-}" = "--start-identity" ]; then
  exec "$REAL_PID_ARGV_HELPER" "$@"
fi
pid="${1:-}"
[ -n "$pid" ] || exit 2

fixture="$PID_ARGV_FIXTURE_DIR/$pid.argv"
if [ -f "$fixture" ]; then
  cat "$fixture"
  exit 0
fi

exec "$REAL_PID_ARGV_HELPER" "$pid"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/claude-rc-pid-argv"
  chmod +x "$CLAUDE_RC_FAKE_BIN/claude-rc-pid-argv"
}

_claude_rc_write_pid_argv_fixture() {
  local pid="$1"
  shift
  [ "$#" -gt 0 ] || fail "pid argv fixture requires at least one argument"
  printf '%s\0' "$@" >"$CLAUDE_RC_PID_ARGV_FIXTURE_DIR/$pid.argv"
}

_claude_rc_setup() {
  local sandbox="$1"
  CLAUDE_RC_HOME="$sandbox/home"
  CLAUDE_RC_STATE="$sandbox/state"
  CLAUDE_RC_FAKE_BIN="$sandbox/fake-bin"
  CLAUDE_RC_MANAGED_BIN="$sandbox/managed-bin"
  CLAUDE_RC_VERSIONS="$sandbox/versions"
  CLAUDE_RC_SERVER_EXE="$CLAUDE_RC_VERSIONS/claude-server"
  CLAUDE_RC_STARTED_EXE_FILE="$sandbox/started-exe"
  CLAUDE_RC_PID_ARGV_FIXTURE_DIR="$sandbox/pid-argv"
  CLAUDE_RC_LOG="$sandbox/claude.log"
  CLAUDE_RC_HOLD_FILE="$sandbox/hold-server"
  mkdir -p \
    "$CLAUDE_RC_HOME" \
    "$CLAUDE_RC_STATE" \
    "$CLAUDE_RC_FAKE_BIN" \
    "$CLAUDE_RC_MANAGED_BIN" \
    "$CLAUDE_RC_PID_ARGV_FIXTURE_DIR" \
    "$CLAUDE_RC_VERSIONS"
  _claude_rc_build_pid_argv_helper
  _claude_rc_build_launch_group_helper
  _claude_rc_install_pid_argv_dispatcher
  _claude_rc_make_fake_claude "$CLAUDE_RC_FAKE_BIN" "$CLAUDE_RC_VERSIONS"
  # Keep a shadow `claude` in PATH and a distinct managed `claude` entrypoint.
  # The maint launcher may be a stable symlink with any basename, but its
  # canonical executable must remain inside VERSIONS_DIR.
  ln -sf "$CLAUDE_RC_FAKE_BIN/claude" "$CLAUDE_RC_MANAGED_BIN/claude"
  ln -sf "$CLAUDE_RC_FAKE_BIN/claude" "$CLAUDE_RC_VERSIONS/claude-new"
  ln -sf "$(command -v bash)" "$CLAUDE_RC_SERVER_EXE"
  CLAUDE_RC_REAL_FLOCK="$(_claude_rc_find_trusted_flock)" \
    || fail "required trusted Nix-store flock not found"
  CLAUDE_RC_REAL_PGREP="$(_claude_rc_find_tool pgrep)" || fail "required test tool not found: pgrep"
  ln -sf "$CLAUDE_RC_REAL_FLOCK" "$CLAUDE_RC_FAKE_BIN/flock"
  ln -sf "$CLAUDE_RC_REAL_LAUNCH_GROUP_HELPER" "$CLAUDE_RC_FAKE_BIN/claude-rc-launch-group"
  _claude_rc_install_exe_identity_mocks "$CLAUDE_RC_FAKE_BIN"
}


_claude_rc_run() {
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env \
      HOME="$CLAUDE_RC_HOME" \
      STATE_DIR="$CLAUDE_RC_STATE" \
      VERSIONS_DIR="$CLAUDE_RC_VERSIONS" \
      CLAUDE_RC_DRIFT_POLICY="${CLAUDE_RC_DRIFT_POLICY:-}" \
      CLAUDE_RC_DRIFT_APPROVAL_JSON="${CLAUDE_RC_DRIFT_APPROVAL_JSON:-}" \
      CLAUDE_RC_BRIDGE_PATH="${CLAUDE_RC_BRIDGE_PATH:-}" \
      CLAUDE_RC_HEADLESS_SSH_MARKER="${CLAUDE_RC_HEADLESS_SSH_MARKER:-}" \
      CLAUDE_RC_ENVIRONMENT_GENERATION="${CLAUDE_RC_ENVIRONMENT_GENERATION:-}" \
      PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
      FAKE_CLAUDE_LOG="$CLAUDE_RC_LOG" \
      FAKE_CLAUDE_HOLD_FILE="${CLAUDE_RC_HOLD_FILE:-}" \
      FAKE_CLAUDE_ENV_LOG="${FAKE_CLAUDE_ENV_LOG:-}" \
      FAKE_STARTED_EXE_FILE="$CLAUDE_RC_STARTED_EXE_FILE" \
      FAKE_CLAUDE_STARTED_EXE="${FAKE_CLAUDE_STARTED_EXE:-$CLAUDE_RC_SERVER_EXE}" \
      FAKE_UNMANAGED_CWD="${FAKE_UNMANAGED_CWD:-}" \
      FAKE_UNMANAGED_EXE="${FAKE_UNMANAGED_EXE:-}" \
      FAKE_UNMANAGED_COMMAND="${FAKE_UNMANAGED_COMMAND:-}" \
      FAKE_CHILD_CWD="${FAKE_CHILD_CWD:-}" \
      "$@"
  )
}

_claude_rc_process_has_exact_argv_token() {
  local pid="$1" expected_token="$2" arg
  while IFS= read -r -d '' arg; do
    [ "$arg" = "$expected_token" ] && return 0
  done < <("$CLAUDE_RC_REAL_PID_ARGV_HELPER" "$pid" 2>/dev/null)
  return 1
}

_claude_rc_has_process_with_exact_argv_token() {
  local expected_token="$1" escaped_pattern pid
  escaped_pattern="$(printf '%s' "$expected_token" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    _claude_rc_process_has_exact_argv_token "$pid" "$expected_token" && return 0
  done < <("$CLAUDE_RC_REAL_PGREP" -f "$escaped_pattern" 2>/dev/null || true)
  return 1
}

_claude_rc_run_maint() {
  local cwd="$1"
  shift
  (
    cd "$cwd"
    env \
      HOME="$CLAUDE_RC_HOME" \
      STATE_DIR="$CLAUDE_RC_STATE" \
      VERSIONS_DIR="$CLAUDE_RC_VERSIONS" \
      CLAUDE_BIN="${CLAUDE_RC_TEST_MAINT_BIN:-$CLAUDE_RC_MANAGED_BIN/claude}" \
      CLAUDE_RC_DRIFT_POLICY="${CLAUDE_RC_DRIFT_POLICY:-defer}" \
      CLAUDE_RC_DRIFT_APPROVAL_JSON="${CLAUDE_RC_DRIFT_APPROVAL_JSON:-[]}" \
      CLAUDE_RC_BRIDGE_PATH="${CLAUDE_RC_BRIDGE_PATH:-}" \
      CLAUDE_RC_HEADLESS_SSH_MARKER="${CLAUDE_RC_HEADLESS_SSH_MARKER:-}" \
      CLAUDE_RC_ENVIRONMENT_GENERATION="${CLAUDE_RC_ENVIRONMENT_GENERATION:-}" \
      FAKE_CLAUDE_RESOLVED_EXE="${FAKE_CLAUDE_RESOLVED_EXE_OVERRIDE:-$CLAUDE_RC_VERSIONS/claude-new}" \
      PATH="$CLAUDE_RC_FAKE_BIN:$PATH" \
      FAKE_CLAUDE_LOG="$CLAUDE_RC_LOG" \
      FAKE_CLAUDE_HOLD_FILE="${CLAUDE_RC_HOLD_FILE:-}" \
      FAKE_CLAUDE_ENV_LOG="${FAKE_CLAUDE_ENV_LOG:-}" \
      FAKE_STARTED_EXE_FILE="$CLAUDE_RC_STARTED_EXE_FILE" \
      FAKE_CLAUDE_STARTED_EXE="${FAKE_CLAUDE_STARTED_EXE:-$CLAUDE_RC_VERSIONS/claude-new}" \
      FAKE_UNMANAGED_CWD="${FAKE_UNMANAGED_CWD:-}" \
      FAKE_UNMANAGED_EXE="${FAKE_UNMANAGED_EXE:-}" \
      FAKE_UNMANAGED_COMMAND="${FAKE_UNMANAGED_COMMAND:-}" \
      FAKE_SERVER_CWD="${FAKE_SERVER_CWD:-}" \
      FAKE_SERVER_EXE="${FAKE_SERVER_EXE:-}" \
      FAKE_SERVER_PID="${FAKE_SERVER_PID:-}" \
      FAKE_SERVER_PARENT_PID="${FAKE_SERVER_PARENT_PID:-}" \
      FAKE_SERVER_LOCK_PATH="${FAKE_SERVER_LOCK_PATH:-}" \
      FAKE_SERVER_FLOCK_EXE="${FAKE_SERVER_FLOCK_EXE:-}" \
      FAKE_FLOCK_DELAY_PATH="${FAKE_FLOCK_DELAY_PATH:-}" \
      FAKE_FLOCK_DELAY_STATE="${FAKE_FLOCK_DELAY_STATE:-}" \
      FAKE_ORPHAN_PID="${FAKE_ORPHAN_PID:-}" \
      FAKE_ORPHAN_CWD="${FAKE_ORPHAN_CWD:-}" \
      FAKE_ORPHAN_EXE="${FAKE_ORPHAN_EXE:-}" \
      FAKE_ORPHAN_PPID="${FAKE_ORPHAN_PPID:-}" \
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

_claude_rc_acquire_synthetic_lock() {
  local lock_path="$1" context="$2" attempt

  "$CLAUDE_RC_FAKE_BIN/flock" "$lock_path" \
    sleep "$CLAUDE_RC_SYNTHETIC_LOCK_HOLD_SECONDS" &
  CLAUDE_RC_SYNTHETIC_LOCK_PID=$!
  for ((attempt = 0; attempt < CLAUDE_RC_SYNTHETIC_LOCK_POLL_ATTEMPTS; attempt++)); do
    if ! "$CLAUDE_RC_FAKE_BIN/flock" -n "$lock_path" true; then
      return 0
    fi
    sleep "$CLAUDE_RC_SYNTHETIC_LOCK_POLL_INTERVAL_SECONDS"
  done

  _claude_rc_release_synthetic_lock "$CLAUDE_RC_SYNTHETIC_LOCK_PID"
  fail "test failed to acquire synthetic lock: $context"
}

_claude_rc_release_synthetic_lock() {
  local lock_pid="$1"
  kill "$lock_pid" 2>/dev/null || true
  wait "$lock_pid" 2>/dev/null || true
  if [ "$CLAUDE_RC_SYNTHETIC_LOCK_PID" = "$lock_pid" ]; then
    CLAUDE_RC_SYNTHETIC_LOCK_PID=""
  fi
}

_claude_rc_release_server() {
  local repo="$1"
  local lock_path
  lock_path="$CLAUDE_RC_STATE/$(_claude_rc_slug "$repo")/lock"
  rm -f "$CLAUDE_RC_HOLD_FILE"
  _claude_rc_wait_lock_free "$lock_path" || fail "server lock remained held: $lock_path"
}

_claude_rc_wait_fake_claude_log() {
  local needle="${1:-remote-control}" _i
  for _i in {1..50}; do
    if [ -f "$CLAUDE_RC_LOG" ] && grep -F -- "$needle" "$CLAUDE_RC_LOG" >/dev/null; then
      return 0
    fi
    sleep 0.1
  done
  return 1
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
  local base_lsof
  base_lsof="$CLAUDE_RC_FAKE_BIN/lsof-unmanaged-base"
  cp "$CLAUDE_RC_FAKE_BIN/lsof" "$base_lsof" || fail "failed to preserve base lsof mock"
  chmod +x "$base_lsof"
  # Force the Darwin pid_exe_path branch so this fake PID's txt path is fully
  # controlled by the lsof mock, matching the running-server mock strategy.
  cat > "$CLAUDE_RC_FAKE_BIN/uname" <<'EOS'
#!/usr/bin/env bash
echo Darwin
EOS
  {
    printf '#!/usr/bin/env bash\nREAL_PGREP=%q\n' "$CLAUDE_RC_REAL_PGREP"
    cat <<'EOS'
set -euo pipefail
pattern=""
for arg in "$@"; do
  pattern="$arg"
done
command_line="${FAKE_UNMANAGED_COMMAND:-claude remote-control --spawn worktree}"
if [ -n "$pattern" ] && printf '%s\n' "$command_line" | grep -Eq -- "$pattern"; then
  echo 4242
fi
"$REAL_PGREP" "$@" 2>/dev/null || true
EOS
  } > "$CLAUDE_RC_FAKE_BIN/pgrep"
  {
    printf '#!/usr/bin/env bash\nBASE_LSOF=%q\n' "$base_lsof"
    cat <<'EOS'
set -euo pipefail
args=" $* "
case "$args" in
  *" -p 4242 "*"cwd"*)
    printf 'p4242\nn%s\n' "$FAKE_UNMANAGED_CWD"
    ;;
  *" -p 4242 "*"txt"*)
    printf 'p4242\nn%s\n' "$FAKE_UNMANAGED_EXE"
    ;;
  *) exec "$BASE_LSOF" "$@" ;;
esac
EOS
  } > "$CLAUDE_RC_FAKE_BIN/lsof"
  _claude_rc_write_pid_argv_fixture 4242 claude remote-control --spawn worktree
  chmod +x \
    "$CLAUDE_RC_FAKE_BIN/uname" \
    "$CLAUDE_RC_FAKE_BIN/pgrep" \
    "$CLAUDE_RC_FAKE_BIN/lsof"
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

_claude_rc_install_orphan_session_mocks() {
  local real_pgrep base_lsof real_ps
  real_pgrep="$(_claude_rc_find_tool pgrep)" || fail "required test tool not found: pgrep"
  base_lsof="$CLAUDE_RC_FAKE_BIN/lsof-base"
  cp "$CLAUDE_RC_FAKE_BIN/lsof" "$base_lsof" || fail "failed to preserve base lsof mock"
  chmod +x "$base_lsof"
  real_ps="$(_claude_rc_find_tool ps)" || fail "required test tool not found: ps"
  cat > "$CLAUDE_RC_FAKE_BIN/uname" <<'EOS'
#!/usr/bin/env bash
echo Darwin
EOS
  {
    printf '#!/usr/bin/env bash\nREAL_PGREP=%q\n' "$real_pgrep"
    cat <<'EOS'
case "$*" in
  *"[-]-sdk-url"*)
    [ -n "${FAKE_ORPHAN_PID:-}" ] || exit 1
    echo "$FAKE_ORPHAN_PID"
    ;;
  *) exec "$REAL_PGREP" "$@" ;;
esac
EOS
  } > "$CLAUDE_RC_FAKE_BIN/pgrep"
  {
    printf '#!/usr/bin/env bash\nBASE_LSOF=%q\n' "$base_lsof"
    cat <<'EOS'
set -euo pipefail
args=" $* "
case "$args" in
  *" -p ${FAKE_ORPHAN_PID:-__none__} "*"txt"*)
    [ -n "${FAKE_ORPHAN_EXE:-}" ] || exit 1
    printf 'p%s\nn%s\n' "$FAKE_ORPHAN_PID" "$FAKE_ORPHAN_EXE"
    ;;
  *" -p ${FAKE_ORPHAN_PID:-__none__} "*"cwd"*)
    printf 'p%s\nn%s\n' "$FAKE_ORPHAN_PID" "$FAKE_ORPHAN_CWD"
    ;;
  *)
    exec "$BASE_LSOF" "$@"
    ;;
esac
EOS
  } > "$CLAUDE_RC_FAKE_BIN/lsof"
  {
    printf '#!/usr/bin/env bash\nREAL_PS=%q\n' "$real_ps"
    cat <<'EOS'
args=" $* "
case "$args" in
  *"ppid="*" -p ${FAKE_ORPHAN_PID:-__none__} "*) echo "${FAKE_ORPHAN_PPID:-1}" ;;
  *) exec "$REAL_PS" "$@" ;;
esac
EOS
  } > "$CLAUDE_RC_FAKE_BIN/ps"
  chmod +x "$CLAUDE_RC_FAKE_BIN/uname" "$CLAUDE_RC_FAKE_BIN/pgrep" "$CLAUDE_RC_FAKE_BIN/lsof" "$CLAUDE_RC_FAKE_BIN/ps"
}

_claude_rc_install_no_process_mocks() {
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
exit 1
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/pgrep"
}

_claude_rc_install_instances_lock_failure_flock() {
  unlink "$CLAUDE_RC_FAKE_BIN/flock"
  {
    printf '#!/usr/bin/env bash\nREAL_FLOCK=%q\n' "$CLAUDE_RC_REAL_FLOCK"
    cat <<'EOS'
set -euo pipefail
if [ "$#" -eq 1 ] && [ "$1" = 8 ]; then
  exit 73
fi
exec "$REAL_FLOCK" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/flock"
  chmod +x "$CLAUDE_RC_FAKE_BIN/flock"
}

_claude_rc_install_delayed_launcher_flock() {
  unlink "$CLAUDE_RC_FAKE_BIN/flock"
  {
    printf '#!/usr/bin/env bash\nREAL_FLOCK=%q\n' "$CLAUDE_RC_REAL_FLOCK"
    cat <<'EOS'
set -euo pipefail
if [ "${1:-}" = "-n" ] \
  && [ -n "${FAKE_FLOCK_LAUNCH_PATH:-}" ] \
  && [ "${2:-}" = "$FAKE_FLOCK_LAUNCH_PATH" ] \
  && [ "${3:-}" != "true" ]; then
  if [ -n "${FAKE_FLOCK_LAUNCH_READY_FILE:-}" ]; then
    : > "$FAKE_FLOCK_LAUNCH_READY_FILE"
  fi
  sleep "${FAKE_FLOCK_LAUNCH_DELAY_SECONDS:-0.3}"
fi
exec "$REAL_FLOCK" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/flock"
  chmod +x "$CLAUDE_RC_FAKE_BIN/flock"
}

_claude_rc_install_early_exit_descendant_flock() {
  unlink "$CLAUDE_RC_FAKE_BIN/flock"
  {
    printf '#!/usr/bin/env bash\nREAL_FLOCK=%q\n' "$CLAUDE_RC_REAL_FLOCK"
    cat <<'EOS'
set -euo pipefail
if [ "${1:-}" = "-n" ] \
  && [ -n "${FAKE_FLOCK_LAUNCH_PATH:-}" ] \
  && [ "${2:-}" = "$FAKE_FLOCK_LAUNCH_PATH" ] \
  && [ "${3:-}" != "true" ]; then
  lock_path="$2"
  exec "$REAL_FLOCK" -n "$lock_path" bash -c '
    (
      trap "" HUP TERM INT
      while :; do sleep 0.02; done
    ) &
    printf "%s\n" "$!" > "$FAKE_FLOCK_ORPHAN_PID_FILE"
    exit 1
  '
fi
exec "$REAL_FLOCK" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/flock"
  chmod +x "$CLAUDE_RC_FAKE_BIN/flock"
}

_claude_rc_install_competing_launcher_flock() {
  unlink "$CLAUDE_RC_FAKE_BIN/flock"
  {
    printf '#!/usr/bin/env bash\nREAL_FLOCK=%q\n' "$CLAUDE_RC_REAL_FLOCK"
    cat <<'EOS'
set -euo pipefail
if [ "$#" -eq 3 ] \
  && [ "$1" = "-n" ] \
  && [ -n "${FAKE_FLOCK_LAUNCH_PATH:-}" ] \
  && [ "$2" = "$FAKE_FLOCK_LAUNCH_PATH" ] \
  && [ "$3" = "true" ] \
  && [ ! -e "$FAKE_FLOCK_COMPETITOR_MARKER" ]; then
  : > "$FAKE_FLOCK_COMPETITOR_MARKER"
  "$REAL_FLOCK" "$2" sleep "${FAKE_FLOCK_COMPETITOR_HOLD_SECONDS:-0.8}" &
  competitor_pid=$!
  printf '%s\n' "$competitor_pid" > "$FAKE_FLOCK_COMPETITOR_PID_FILE"
  for _ in {1..100}; do
    if ! "$REAL_FLOCK" -n "$2" true; then
      # The preflight observed the lock as free, but a competing process won it
      # immediately afterward. Return the earlier observation so production
      # enters the exact launch race under test.
      exit 0
    fi
    sleep 0.01
  done
  kill -TERM "$competitor_pid" 2>/dev/null || true
  exit 97
fi
if [ "${1:-}" = "-n" ] \
  && [ -n "${FAKE_FLOCK_LAUNCH_PATH:-}" ] \
  && [ "${2:-}" = "$FAKE_FLOCK_LAUNCH_PATH" ] \
  && [ "${3:-}" != "true" ]; then
  sleep "${FAKE_FLOCK_LAUNCH_DELAY_SECONDS:-1}"
fi
exec "$REAL_FLOCK" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/flock"
  chmod +x "$CLAUDE_RC_FAKE_BIN/flock"
}

_claude_rc_install_owned_lock_marker_flock() {
  unlink "$CLAUDE_RC_FAKE_BIN/flock"
  {
    printf '#!/usr/bin/env bash\nREAL_FLOCK=%q\n' "$CLAUDE_RC_REAL_FLOCK"
    cat <<'EOS'
set -euo pipefail
if [ "${1:-}" = "-n" ] \
  && [ -n "${FAKE_FLOCK_LAUNCH_PATH:-}" ] \
  && [ "${2:-}" = "$FAKE_FLOCK_LAUNCH_PATH" ] \
  && [ "${3:-}" != "true" ]; then
  exec 9>"$2"
  "$REAL_FLOCK" -n 9
  : > "$FAKE_FLOCK_OWNED_MARKER"
  shift 2
  exec "$@"
fi
exec "$REAL_FLOCK" "$@"
EOS
  } > "$CLAUDE_RC_FAKE_BIN/flock"
  chmod +x "$CLAUDE_RC_FAKE_BIN/flock"
}

_claude_rc_install_running_server_mocks() {
  # 이 mock 세트는 실존하지 않는 가짜 pid(6262)를 서버로 흉내낸다. 실행 바이너리
  # 조회의 Linux 분기(readlink /proc/PID/exe)는 커널 경로라 mock이 불가능하므로,
  # fake uname으로 Darwin 분기(lsof — 아래 mock이 커버)를 강제해 이 mock 세트가
  # 플랫폼과 무관하게 동작하게 한다. 없으면 Linux CI에서만 실행 버전 조회가
  # 실패해 running-version-unresolvable 오탐이 난다.
  cat > "$CLAUDE_RC_FAKE_BIN/uname" <<'EOS'
#!/usr/bin/env bash
echo Darwin
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *"remote-control"*) echo "${FAKE_SERVER_PID:-6262}" ;;
  *) exit 1 ;;
esac
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/lsof" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
server_pid="${FAKE_SERVER_PID:-6262}"
parent_pid="${FAKE_SERVER_PARENT_PID:-6261}"
case "$args" in
  *" -p $server_pid "*"cwd"*)
    printf 'p%s\nn%s\n' "$server_pid" "$FAKE_SERVER_CWD"
    ;;
  *" -p $server_pid "*"txt"*)
    printf 'p%s\nn%s\n' "$server_pid" "$FAKE_SERVER_EXE"
    ;;
  *" -p $parent_pid "*"txt"*)
    [ -n "${FAKE_SERVER_FLOCK_EXE:-}" ] || exit 1
    printf 'p%s\nn%s\n' "$parent_pid" "$FAKE_SERVER_FLOCK_EXE"
    ;;
  *" -p $server_pid "*" ${FAKE_SERVER_LOCK_PATH:-__none__} "*)
    printf 'p%s\nf3\nn%s\n' "$server_pid" "$FAKE_SERVER_LOCK_PATH"
    ;;
  *" -p $parent_pid "*" ${FAKE_SERVER_LOCK_PATH:-__none__} "*)
    printf 'p%s\nf3\nn%s\n' "$parent_pid" "$FAKE_SERVER_LOCK_PATH"
    ;;
  *)
    exit 1
    ;;
esac
EOS
  cat > "$CLAUDE_RC_FAKE_BIN/ps" <<'EOS'
#!/usr/bin/env bash
args=" $* "
parent_pid="${FAKE_SERVER_PARENT_PID:-6261}"
case "$args" in
  *"ppid="*) printf '%s\n' "$parent_pid" ;;
  *) exit 1 ;;
esac
EOS
  chmod +x "$CLAUDE_RC_FAKE_BIN/uname" "$CLAUDE_RC_FAKE_BIN/pgrep" "$CLAUDE_RC_FAKE_BIN/lsof" "$CLAUDE_RC_FAKE_BIN/ps"
}

_claude_rc_make_recent_worktree_transcript() {
  local repo="$1" prefix
  prefix="$(printf '%s' "$repo" | sed 's/[^[:alnum:]]/-/g')"
  mkdir -p "$CLAUDE_RC_HOME/.claude/projects/${prefix}--claude-worktrees-bridge-cse-1"
  : > "$CLAUDE_RC_HOME/.claude/projects/${prefix}--claude-worktrees-bridge-cse-1/session.jsonl"
}
