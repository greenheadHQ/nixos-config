#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"
CLAUDEX_PROXY_BIN="@proxyBin@"
CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"

# Type-routed login: the no-arg path keeps the original Codex device-code flow; --claude
# adds the Anthropic OAuth credential that the --mixed session mode requires. Each path is
# idempotent per credential type and never touches the other type's canonical entry.
cred_type=codex
login_flag=--codex-device-login
case "$#" in
  0) ;;
  1)
    if [ "$1" = "--claude" ]; then
      cred_type=claude
      login_flag=--claude-login
    else
      echo "usage: claudex-login [--claude]" >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: claudex-login [--claude]" >&2
    exit 2
    ;;
esac

prepare_state
# The whole canonical directory must be well-formed before this command reports ready or
# promotes anything — a malformed sibling entry would otherwise be masked here and only
# surface when the next session start rejects the set.
_claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR" || {
  _claudex_error "canonical auth directory holds a malformed entry; remove it explicitly before logging in"
  exit 1
}
existing_rc=0
existing_path="$(_claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type")" || existing_rc=$?
case "$existing_rc" in
  0)
    if _claudex_credential_json_valid "$existing_path" "$cred_type"; then
      echo "claudex-login: canonical $cred_type credential is already ready"
      exit 0
    fi
    _claudex_error "canonical $cred_type credential is invalid; remove it explicitly before logging in again"
    exit 1
    ;;
  1) ;;
  *)
    _claudex_error "canonical auth directory holds duplicate $cred_type entries; refusing to choose or delete one"
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

echo "claudex-login: follow the $cred_type OAuth instructions printed by CLIProxyAPI"
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
      "$login_flag" \
      --no-browser \
      --local-model
)
login_rc=$?
set -e
if [ "$login_rc" -ne 0 ]; then
  _claudex_error "$cred_type login failed"
  exit "$login_rc"
fi

# Upstream has command paths that log an error and return success, so exit 0 is insufficient.
# Trust only the staged filesystem contract: exactly one entry, of the requested type.
staged_path="$(_claudex_single_credential_path "$staging_auth")" || {
  _claudex_error "$cred_type login did not produce exactly one credential"
  exit 1
}
_claudex_credential_json_valid "$staged_path" "$cred_type" || {
  _claudex_error "$cred_type login did not produce a valid $cred_type credential"
  exit 1
}

_claudex_promote_staged_credential() {
  local staged destination existing_rc
  # Validate the final state BEFORE moving anything: the canonical set must be well-formed
  # (a malformed sibling means the move would only produce another invalid state) and must
  # not already hold this type. The full default/mixed set contract is deliberately NOT
  # asserted here — codex-only and claude-only are legitimate mid-login states (either
  # login order is allowed); the per-mode contract is asserted at session start instead.
  _claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR" || {
    _claudex_error "canonical auth directory holds a malformed entry; staged credential was not promoted"
    return 1
  }
  existing_rc=0
  _claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type" >/dev/null || existing_rc=$?
  if [ "$existing_rc" -ne 1 ]; then
    _claudex_error "another login changed the canonical $cred_type credential; staged credential was not promoted"
    return 1
  fi
  staged="$(_claudex_single_credential_path "$staging_auth")" || return 1
  _claudex_credential_json_valid "$staged" "$cred_type" || return 1
  destination="$CLAUDEX_AUTH_DIR/${staged##*/}"
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    _claudex_error "refusing to overwrite an existing canonical credential"
    return 1
  fi
  "$CLAUDEX_MV" -n -- "$staged" "$destination" || return 1
  if [ -e "$staged" ] || [ -L "$staged" ]; then
    _claudex_error "atomic credential promotion did not complete"
    return 1
  fi
  _claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type" >/dev/null \
    && _claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR"
}

with_state_lock _claudex_promote_staged_credential
echo "claudex-login: canonical $cred_type credential is ready"
