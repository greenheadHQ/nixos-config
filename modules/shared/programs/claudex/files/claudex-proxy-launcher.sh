#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"

# These two paths are unconditional store references. Caller-controlled environment variables
# cannot swap either the reviewed binary or its security template.
CLAUDEX_PROXY_BIN="@proxyBin@"
CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"
CLAUDEX_GATE_BIN="@gateBin@"
CLAUDEX_GENERATION="@generation@"

usage() {
  echo "usage: claudex-proxy-launcher --managed|--prepare-only|--foreground --startup-lock-fd FD" >&2
}

mode=""
startup_lock_fd=-1
case "$#" in
  1)
    case "$1" in
      --managed) mode=managed ;;
      --prepare-only) mode=prepare ;;
      *)
        usage
        exit 2
        ;;
    esac
    ;;
  3)
    if [ "$1" != --foreground ] || [ "$2" != --startup-lock-fd ]; then
      usage
      exit 2
    fi
    case "$3" in
      "" | *[!0-9]*)
        usage
        exit 2
        ;;
    esac
    if [ "$3" -lt 3 ]; then
      usage
      exit 2
    fi
    mode=foreground
    startup_lock_fd="$3"
    ;;
  *)
    usage
    exit 2
    ;;
esac

if [ "$mode" = "prepare" ]; then
  prepare_state
  exit 0
fi

_claudex_run_gate_locked() {
  local -a startup_lock_args=()
  prepare_state
  # The proxy serves whatever valid set is present; the default contract (codex required,
  # claude optional) is the launch bar — mixed entitlement is asserted by `claudex --mixed`.
  assert_credential_set "$CLAUDEX_AUTH_DIR" default
  _claudex_assert_safe_work_dir
  if [ "$startup_lock_fd" -ge 0 ]; then
    startup_lock_args=(--startup-lock-fd "$startup_lock_fd")
  fi

  exec "$CLAUDEX_GATE_BIN" serve \
    --mode "$mode" \
    --state-dir "$CLAUDEX_STATE_DIR" \
    --auth-dir "$CLAUDEX_AUTH_DIR" \
    --work-dir "$CLAUDEX_WORK_DIR" \
    --config "$CLAUDEX_CONFIG_FILE" \
    --public-key-file "$CLAUDEX_API_KEY_FILE" \
    --backend-bin "$CLAUDEX_PROXY_BIN" \
    --generation "$CLAUDEX_GENERATION" \
    --public-address "$CLAUDEX_BIND_HOST:$CLAUDEX_PORT" \
    --backend-address "$CLAUDEX_BIND_HOST:@backendPort@" \
    --control-socket "$CLAUDEX_CONTROL_SOCKET" \
    --drain-seconds "@gracefulDrainSeconds@" \
    --child-stop-seconds "@childStopSeconds@" \
    --log-file "$CLAUDEX_LOG_FILE" \
    --home "$CLAUDEX_HOME" \
    "${startup_lock_args[@]}"
}

if [ "$mode" = "managed" ]; then
  # Manager restarts bypass the user-facing lifecycle command, so acquire the canonical
  # lifecycle lock in this process and hand descriptor 8 to the gate. The gate releases it
  # only after owning the runtime lock and control socket, preserving manager MainPID identity.
  _claudex_acquire_lifecycle_lock
  startup_lock_fd=8
fi
_claudex_run_gate_locked
