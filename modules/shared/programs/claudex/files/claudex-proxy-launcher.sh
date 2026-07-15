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

usage() {
  echo "usage: claudex-proxy-launcher [--prepare-only]" >&2
}

mode="run"
case "$#" in
  0) ;;
  1)
    if [ "$1" = "--prepare-only" ]; then
      mode="prepare"
    else
      usage
      exit 2
    fi
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
assert_single_codex_credential
_claudex_assert_safe_work_dir

cd "$CLAUDEX_WORK_DIR"
exec "$CLAUDEX_ENV" -i \
  HOME="$CLAUDEX_HOME" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  TMPDIR="/tmp" \
  NO_PROXY="$CLAUDEX_NO_PROXY" \
  no_proxy="$CLAUDEX_NO_PROXY" \
  "$CLAUDEX_PROXY_BIN" \
    --config "$CLAUDEX_CONFIG_FILE" \
    --local-model
