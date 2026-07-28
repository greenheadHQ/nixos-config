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
  echo "usage: claudex-proxy-launcher --managed|--foreground|--prepare-only" >&2
}

mode=""
case "$#" in
  1)
    case "$1" in
      --managed) mode=managed ;;
      --foreground) mode=foreground ;;
      --prepare-only) mode=prepare ;;
      *)
        usage
        exit 2
        ;;
    esac
    ;;
  *)
    usage
    exit 2
    ;;
esac

prepare_state
if [ "$mode" = "prepare" ]; then
  exit 0
fi
# The proxy serves whatever valid set is present; the default contract (codex required,
# claude optional) is the launch bar — mixed entitlement is asserted by `claudex --mixed`.
assert_credential_set "$CLAUDEX_AUTH_DIR" default
_claudex_assert_safe_work_dir

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
  --home "$CLAUDEX_HOME"
