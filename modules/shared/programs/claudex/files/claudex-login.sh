#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"
CLAUDEX_PROXY_BIN="@proxyBin@"
CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"

if [ "$#" -ne 0 ]; then
  echo "usage: claudex-login" >&2
  exit 2
fi

prepare_state
canonical_count="$(credential_count)"
case "$canonical_count" in
  0) ;;
  1)
    if assert_single_codex_credential; then
      echo "claudex-login: canonical Codex credential is already ready"
      exit 0
    fi
    _claudex_error "canonical credential is invalid; remove it explicitly before logging in again"
    exit 1
    ;;
  *)
    _claudex_error "canonical auth directory contains $canonical_count entries; refusing to choose or delete one"
    exit 1
    ;;
esac

staging="$($CLAUDEX_MKTEMP -d "$CLAUDEX_STATE_DIR/auth.login.XXXXXX")"
"$CLAUDEX_CHMOD" 700 -- "$staging"
staging_auth="$staging/auth"
staging_config="$staging/config.yaml"
cleanup_staging() {
  "$CLAUDEX_RM" -rf -- "$staging"
}
trap cleanup_staging EXIT INT TERM

_claudex_ensure_private_dir "$staging_auth"
(
  CLAUDEX_AUTH_DIR="$staging_auth"
  CLAUDEX_CONFIG_FILE="$staging_config"
  _claudex_render_runtime_config_unlocked
)

echo "claudex-login: follow the device-code instructions printed by CLIProxyAPI"
set +e
(
  cd "$staging"
  exec "$CLAUDEX_ENV" -i \
    HOME="$CLAUDEX_HOME" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    TMPDIR="/tmp" \
    NO_PROXY="$CLAUDEX_NO_PROXY" \
    no_proxy="$CLAUDEX_NO_PROXY" \
    "$CLAUDEX_PROXY_BIN" \
      --config "$staging_config" \
      --codex-device-login \
      --no-browser \
      --local-model
)
login_rc=$?
set -e
if [ "$login_rc" -ne 0 ]; then
  _claudex_error "device login failed"
  exit "$login_rc"
fi

# Upstream has command paths that log an error and return success, so exit 0 is insufficient.
# Trust only the staged filesystem contract.
assert_single_codex_credential "$staging_auth" || {
  _claudex_error "device login did not produce exactly one valid Codex credential"
  exit 1
}

_claudex_promote_staged_credential() {
  local staged_path destination count
  count="$(credential_count "$CLAUDEX_AUTH_DIR")" || return 1
  if [ "$count" -ne 0 ]; then
    _claudex_error "another login changed the canonical auth directory; staged credential was not promoted"
    return 1
  fi
  staged_path="$(_claudex_single_credential_path "$staging_auth")" || return 1
  _claudex_credential_json_valid "$staged_path" || return 1
  destination="$CLAUDEX_AUTH_DIR/${staged_path##*/}"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _claudex_error "refusing to overwrite an existing canonical credential"
    return 1
  fi
  "$CLAUDEX_MV" -n -- "$staged_path" "$destination" || return 1
  if [ -e "$staged_path" ] || [ -L "$staged_path" ]; then
    _claudex_error "atomic credential promotion did not complete"
    return 1
  fi
  assert_single_codex_credential "$CLAUDEX_AUTH_DIR"
}

with_state_lock _claudex_promote_staged_credential
echo "claudex-login: canonical Codex credential is ready"
