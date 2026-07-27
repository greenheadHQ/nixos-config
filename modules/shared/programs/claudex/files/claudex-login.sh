#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"
CLAUDEX_PROXY_BIN="@proxyBin@"
CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"

_claudex_quiet_chmod() {
  "$CLAUDEX_CHMOD" "$@" 2>/dev/null
}

_claudex_quiet_cp() {
  "$CLAUDEX_CP" "$@" 2>/dev/null
}

_claudex_quiet_mv() {
  "$CLAUDEX_MV" "$@" 2>/dev/null
}

_claudex_quiet_rm() {
  "$CLAUDEX_RM" "$@" 2>/dev/null
}

# Type-routed login: the no-arg path keeps the original Codex device-code flow; --claude
# adds the Anthropic OAuth credential that the --mixed session mode requires. --replace
# explicitly replaces only the selected provider after a complete staged OAuth flow.
cred_type=codex
login_flag=--codex-device-login
replace=false
seen_claude=false
seen_replace=false
for arg in "$@"; do
  case "$arg" in
    --claude)
      if [ "$seen_claude" = true ]; then
        echo "usage: claudex-login [--claude] [--replace]" >&2
        exit 2
      fi
      seen_claude=true
      cred_type=claude
      login_flag=--claude-login
      ;;
    --replace)
      if [ "$seen_replace" = true ]; then
        echo "usage: claudex-login [--claude] [--replace]" >&2
        exit 2
      fi
      seen_replace=true
      replace=true
      ;;
    *)
      echo "usage: claudex-login [--claude] [--replace]" >&2
      exit 2
      ;;
  esac
done

prepare_state
# The whole canonical directory must be well-formed before this command reports ready or
# promotes anything — a malformed sibling entry would otherwise be masked here and only
# surface when the next session start rejects the set.
_claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR" || {
  _claudex_error "canonical auth directory holds a malformed entry; remove it explicitly before logging in"
  exit 1
}
existing_rc=0
existing_path=""
existing_fingerprint=""
existing_set_fingerprint=""
existing_path="$(_claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type")" || existing_rc=$?
case "$existing_rc" in
  0)
    if ! _claudex_credential_json_valid "$existing_path" "$cred_type"; then
      _claudex_error "canonical $cred_type credential is invalid; remove it explicitly before logging in again"
      exit 1
    fi
    if [ "$replace" = false ]; then
      echo "claudex-login: canonical $cred_type credential is present and schema-valid; live validity was not checked"
      exit 0
    fi
    existing_fingerprint="$(_claudex_credential_fingerprint "$existing_path")" || exit 1
    existing_set_fingerprint="$(_claudex_credential_set_fingerprint "$CLAUDEX_AUTH_DIR")" || exit 1
    ;;
  1)
    if [ "$replace" = true ]; then
      _claudex_error "canonical $cred_type credential is absent; run claudex-login without --replace first"
      exit 1
    fi
    ;;
  *)
    _claudex_error "canonical auth directory holds duplicate $cred_type entries; refusing to choose or delete one"
    exit 1
    ;;
esac

staging="$($CLAUDEX_MKTEMP -d "$CLAUDEX_STATE_DIR/auth.login.XXXXXX")"
_claudex_quiet_chmod 700 -- "$staging" || {
  _claudex_error "failed to secure the private login staging directory"
  exit 1
}
staging_auth="$staging/auth"
staging_config="$staging/config.yaml"
cleanup_staging() {
  _claudex_quiet_rm -rf -- "$staging"
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

_claudex_rollback_replacement() {
  local backup="$1" destination="$2"
  _claudex_quiet_mv -f -- "$backup" "$destination" || {
    _claudex_error "credential replacement failed and automatic rollback could not restore the private backup"
    return 1
  }
  _claudex_credential_json_valid "$destination" "$cred_type" \
    && _claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR"
}

_claudex_promote_staged_credential() {
  local staged destination current_path current_fingerprint current_set_fingerprint backup_dir backup_path backup_fingerprint existing_rc
  # Validate the final state BEFORE moving anything: the canonical set must be well-formed
  # (a malformed sibling means the move would only produce another invalid state). The full
  # default/mixed set contract is deliberately NOT asserted here — codex-only and
  # claude-only are legitimate mid-login states (either login order is allowed); the
  # per-mode contract is asserted at session start instead.
  _claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR" || {
    _claudex_error "canonical auth directory holds a malformed entry; staged credential was not promoted"
    return 1
  }
  staged="$(_claudex_single_credential_path "$staging_auth")" || return 1
  _claudex_credential_json_valid "$staged" "$cred_type" || return 1

  if [ "$replace" = false ]; then
    existing_rc=0
    _claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type" >/dev/null || existing_rc=$?
    if [ "$existing_rc" -ne 1 ]; then
      _claudex_error "another login changed the canonical $cred_type credential; staged credential was not promoted"
      return 1
    fi
    destination="$CLAUDEX_AUTH_DIR/${staged##*/}"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
      _claudex_error "refusing to overwrite an existing canonical credential"
      return 1
    fi
    _claudex_quiet_mv -n -- "$staged" "$destination" || {
      _claudex_error "atomic credential promotion failed"
      return 1
    }
    if [ -e "$staged" ] || [ -L "$staged" ]; then
      _claudex_error "atomic credential promotion did not complete"
      return 1
    fi
    _claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type" >/dev/null \
      && _claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR"
    return
  fi

  existing_rc=0
  current_path="$(_claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type")" || existing_rc=$?
  if [ "$existing_rc" -ne 0 ] || [ "$current_path" != "$existing_path" ]; then
    _claudex_error "canonical $cred_type credential changed during OAuth; staged credential was not promoted"
    return 1
  fi
  current_fingerprint="$(_claudex_credential_fingerprint "$current_path")" || return 1
  current_set_fingerprint="$(_claudex_credential_set_fingerprint "$CLAUDEX_AUTH_DIR")" || return 1
  if [ "$current_fingerprint" != "$existing_fingerprint" ] \
    || [ "$current_set_fingerprint" != "$existing_set_fingerprint" ]; then
    _claudex_error "canonical $cred_type credential changed during OAuth; staged credential was not promoted"
    return 1
  fi

  backup_dir="$CLAUDEX_STATE_DIR/credential-backups"
  _claudex_ensure_private_dir "$backup_dir" || return 1
  backup_path="$($CLAUDEX_MKTEMP --suffix=.json "$backup_dir/$cred_type.XXXXXX")" || return 1
  _claudex_quiet_chmod 600 -- "$backup_path" || {
    _claudex_quiet_rm -f -- "$backup_path"
    _claudex_error "failed to secure the private credential backup"
    return 1
  }
  if ! _claudex_quiet_cp -- "$current_path" "$backup_path"; then
    _claudex_quiet_rm -f -- "$backup_path"
    _claudex_error "failed to create the private credential backup"
    return 1
  fi
  _claudex_quiet_chmod 600 -- "$backup_path" || {
    _claudex_quiet_rm -f -- "$backup_path"
    _claudex_error "failed to secure the private credential backup"
    return 1
  }
  backup_fingerprint="$(_claudex_credential_fingerprint "$backup_path")" || {
    _claudex_quiet_rm -f -- "$backup_path"
    return 1
  }
  if [ "$backup_fingerprint" != "$existing_fingerprint" ] \
    || ! _claudex_credential_json_valid "$backup_path" "$cred_type"; then
    _claudex_quiet_rm -f -- "$backup_path"
    _claudex_error "private credential backup verification failed"
    return 1
  fi

  # The backup copy itself is outside CLIProxyAPI's lock protocol. Re-read the whole
  # canonical set after the backup is verified and immediately before promotion so a
  # writer that changed either provider during that window cannot be overwritten.
  existing_rc=0
  current_path="$(_claudex_credential_path_of_type "$CLAUDEX_AUTH_DIR" "$cred_type")" || existing_rc=$?
  current_fingerprint="$(_claudex_credential_fingerprint "$current_path")" || existing_rc=$?
  current_set_fingerprint="$(_claudex_credential_set_fingerprint "$CLAUDEX_AUTH_DIR")" || existing_rc=$?
  if [ "$existing_rc" -ne 0 ] || [ "$current_path" != "$existing_path" ] \
    || [ "$current_fingerprint" != "$existing_fingerprint" ] \
    || [ "$current_set_fingerprint" != "$existing_set_fingerprint" ]; then
    _claudex_quiet_rm -f -- "$backup_path"
    _claudex_error "canonical credential set changed before replacement; staged credential was not promoted"
    return 1
  fi

  # CIR: pinned CLIProxyAPI 7.2.73 keys auth watcher state by path and explicitly
  # treats a same-path rename as an atomic update. Preserve the canonical basename and
  # replace it from staging on the same filesystem so a running watcher never sees a
  # provider disappear between two renames. The verified private backup remains available.
  destination="$current_path"
  if ! _claudex_quiet_mv -f -- "$staged" "$destination"; then
    _claudex_quiet_rm -f -- "$backup_path"
    _claudex_error "atomic credential replacement failed; canonical credential was preserved"
    return 1
  fi
  if [ -e "$staged" ] || [ -L "$staged" ]; then
    _claudex_rollback_replacement "$backup_path" "$destination" || return 1
    _claudex_error "atomic credential replacement did not complete; canonical credential was restored"
    return 1
  fi
  if ! _claudex_credential_json_valid "$destination" "$cred_type" \
    || ! _claudex_assert_entries_wellformed "$CLAUDEX_AUTH_DIR"; then
    _claudex_rollback_replacement "$backup_path" "$destination" || return 1
    _claudex_error "replacement validation failed; canonical credential was restored"
    return 1
  fi
}

with_state_lock _claudex_promote_staged_credential
if [ "$replace" = true ]; then
  echo "claudex-login: canonical $cred_type credential was replaced and is schema-valid; live validity was not checked"
else
  echo "claudex-login: canonical $cred_type credential is ready"
fi
