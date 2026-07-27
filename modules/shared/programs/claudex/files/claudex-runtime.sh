#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2050
# Shared runtime contract for the declarative claudex PoC.
#
# This file is sourced by the version-locked commands in the same runtime package. Sourcing it
# is side-effect free: state creation, credential validation, loopback probes, and launchctl
# calls happen only when a command invokes a function.
#
# Package-internal command API:
#   with_state_lock prepare_state credential_count
#   assert_credential_set curl_loopback wait_for_proxy_ready
#
# Package-internal cross-file API (not stable for external callers):
#   _claudex_error _claudex_read_api_key _claudex_render_runtime_config_unlocked
#   _claudex_ensure_private_dir _claudex_single_credential_path
#   _claudex_credential_json_valid _claudex_credential_fingerprint
#   _claudex_credential_set_fingerprint _claudex_credential_type_of
#   _claudex_credential_path_of_type _claudex_assert_entries_wellformed
#   _claudex_assert_safe_work_dir

if [ "@allowTestOverrides@" = "true" ]; then
  CLAUDEX_JQ="${CLAUDEX_JQ:-@jqBin@}"
  CLAUDEX_CURL="${CLAUDEX_CURL:-@curlBin@}"
  CLAUDEX_OPENSSL="${CLAUDEX_OPENSSL:-@opensslBin@}"
  CLAUDEX_CMP="${CLAUDEX_CMP:-@cmpBin@}"
  CLAUDEX_CP="${CLAUDEX_CP:-@cpBin@}"
  CLAUDEX_STAT="${CLAUDEX_STAT:-@statBin@}"
  CLAUDEX_CHMOD="${CLAUDEX_CHMOD:-@chmodBin@}"
  CLAUDEX_MKDIR="${CLAUDEX_MKDIR:-@mkdirBin@}"
  CLAUDEX_MKTEMP="${CLAUDEX_MKTEMP:-@mktempBin@}"
  CLAUDEX_MV="${CLAUDEX_MV:-@mvBin@}"
  CLAUDEX_RM="${CLAUDEX_RM:-@rmBin@}"
  CLAUDEX_SLEEP="${CLAUDEX_SLEEP:-@sleepBin@}"
  CLAUDEX_ENV="${CLAUDEX_ENV:-@envBin@}"
  CLAUDEX_FLOCK="${CLAUDEX_FLOCK:-@flockBin@}"
  CLAUDEX_LAUNCHCTL="${CLAUDEX_LAUNCHCTL:-@launchctlBin@}"
  CLAUDEX_ID="${CLAUDEX_ID:-@idBin@}"
else
  CLAUDEX_JQ="@jqBin@"
  CLAUDEX_CURL="@curlBin@"
  CLAUDEX_OPENSSL="@opensslBin@"
  CLAUDEX_CMP="@cmpBin@"
  CLAUDEX_CP="@cpBin@"
  CLAUDEX_STAT="@statBin@"
  CLAUDEX_CHMOD="@chmodBin@"
  CLAUDEX_MKDIR="@mkdirBin@"
  CLAUDEX_MKTEMP="@mktempBin@"
  CLAUDEX_MV="@mvBin@"
  CLAUDEX_RM="@rmBin@"
  CLAUDEX_SLEEP="@sleepBin@"
  CLAUDEX_ENV="@envBin@"
  CLAUDEX_FLOCK="@flockBin@"
  CLAUDEX_LAUNCHCTL="@launchctlBin@"
  CLAUDEX_ID="@idBin@"
fi

if [ "@allowTestOverrides@" = "true" ]; then
  : "${HOME:?claudex: HOME must be set}"
  CLAUDEX_HOME="${CLAUDEX_HOME:-$HOME}"
  CLAUDEX_STATE_DIR="${CLAUDEX_STATE_DIR:-$CLAUDEX_HOME/Library/Application Support/claudex}"
  CLAUDEX_AUTH_DIR="${CLAUDEX_AUTH_DIR:-$CLAUDEX_STATE_DIR/auth}"
  CLAUDEX_CONFIG_FILE="${CLAUDEX_CONFIG_FILE:-$CLAUDEX_STATE_DIR/config.yaml}"
  CLAUDEX_API_KEY_FILE="${CLAUDEX_API_KEY_FILE:-$CLAUDEX_STATE_DIR/client-api-key}"
  CLAUDEX_STATE_LOCK="${CLAUDEX_STATE_LOCK:-$CLAUDEX_STATE_DIR/state.lock}"
  CLAUDEX_WORK_DIR="${CLAUDEX_WORK_DIR:-$CLAUDEX_STATE_DIR/work}"
  CLAUDEX_CONFIG_TEMPLATE="${CLAUDEX_CONFIG_TEMPLATE:-@configTemplate@}"
else
  CLAUDEX_HOME="@homeDir@"
  CLAUDEX_STATE_DIR="@stateDir@"
  CLAUDEX_AUTH_DIR="@authDir@"
  CLAUDEX_CONFIG_FILE="@configFile@"
  CLAUDEX_API_KEY_FILE="@apiKeyFile@"
  CLAUDEX_STATE_LOCK="@stateLock@"
  CLAUDEX_WORK_DIR="@workDir@"
  CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"
fi
CLAUDEX_LOCK_TIMEOUT_SECONDS="${CLAUDEX_LOCK_TIMEOUT_SECONDS:-10}"
CLAUDEX_READY_ATTEMPTS="${CLAUDEX_READY_ATTEMPTS:-20}"
CLAUDEX_READY_DELAY_SECONDS="${CLAUDEX_READY_DELAY_SECONDS:-0.25}"

CLAUDEX_BIND_HOST="@bindHost@"
CLAUDEX_PORT="@port@"
# Role-split model contract (single CLAUDEX_MODEL previously carried catalog check,
# subagent env, and CLI --model at once; the mixed mode forks main vs subagent roles).
CLAUDEX_DEFAULT_MAIN_MODEL="@defaultMainModel@"
CLAUDEX_SUBAGENT_MODEL="@subagentModel@"
CLAUDEX_MIXED_MAIN_MODEL="@mixedMainModel@"
CLAUDEX_LABEL="@label@"
CLAUDEX_PPROF_ADDR="${CLAUDEX_BIND_HOST}:@pprofPort@"
CLAUDEX_BASE_URL="http://${CLAUDEX_BIND_HOST}:${CLAUDEX_PORT}"
CLAUDEX_NO_PROXY="${CLAUDEX_BIND_HOST},localhost"

_claudex_error() {
  printf 'claudex: %s\n' "$*" >&2
}

_claudex_reject_newline() {
  case "$1" in
    *$'\n'* | *$'\r'*)
      _claudex_error "path contains a newline"
      return 1
      ;;
  esac
}

_claudex_assert_default_state_ancestors() {
  local current
  case "$CLAUDEX_STATE_DIR" in
    "$CLAUDEX_HOME"/*) ;;
    *) return 0 ;;
  esac

  current="${CLAUDEX_STATE_DIR%/*}"
  while [ "$current" != "$CLAUDEX_HOME" ]; do
    if [ -L "$current" ]; then
      _claudex_error "refusing a symlinked state ancestor"
      return 1
    fi
    current="${current%/*}"
  done
}

# GNU stat %a prefixes a special-bit digit when setuid/setgid/sticky is set (a setgid 0700
# directory prints 2700), which the exact "700"/"600" comparisons at the call sites would
# wrongly reject. Return only the trailing owner/group/other triplet: with group/other bits
# forced to zero by those comparisons, special bits grant no additional access.
_claudex_permission_triplet() {
  local mode
  mode="$("$CLAUDEX_STAT" -c '%a' "$1" 2>/dev/null)" || return 1
  printf '%s\n' "${mode: -3}"
}

_claudex_file_owner() {
  "$CLAUDEX_STAT" -c '%u' "$1" 2>/dev/null
}

_claudex_assert_private_dir() {
  local path="$1"
  _claudex_reject_newline "$path" || return 1
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    _claudex_error "expected a real private directory: $path"
    return 1
  fi
  if [ "$(_claudex_permission_triplet "$path")" != "700" ]; then
    _claudex_error "directory mode must be 0700: $path"
    return 1
  fi
  if [ "$(_claudex_file_owner "$path")" != "$($CLAUDEX_ID -u)" ]; then
    _claudex_error "directory owner does not match the current user: $path"
    return 1
  fi
}

_claudex_ensure_private_dir() {
  local path="$1"
  _claudex_reject_newline "$path" || return 1
  if [ -e "$path" ] || [ -L "$path" ]; then
    if [ -L "$path" ] || [ ! -d "$path" ]; then
      _claudex_error "refusing non-directory or symlink state path: $path"
      return 1
    fi
    _claudex_assert_private_dir "$path"
    return
  else
    "$CLAUDEX_MKDIR" -p -- "$path" || return 1
  fi
  "$CLAUDEX_CHMOD" 700 -- "$path" || return 1
  _claudex_assert_private_dir "$path"
}

_claudex_assert_private_file() {
  local path="$1"
  _claudex_reject_newline "$path" || return 1
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    _claudex_error "expected a real private file: $path"
    return 1
  fi
  if [ "$(_claudex_permission_triplet "$path")" != "600" ]; then
    _claudex_error "file mode must be 0600: $path"
    return 1
  fi
  if [ "$(_claudex_file_owner "$path")" != "$($CLAUDEX_ID -u)" ]; then
    _claudex_error "file owner does not match the current user: $path"
    return 1
  fi
}

_claudex_assert_safe_work_dir() {
  _claudex_assert_private_dir "$CLAUDEX_WORK_DIR" || return 1
  if [ -e "$CLAUDEX_WORK_DIR/.env" ] || [ -L "$CLAUDEX_WORK_DIR/.env" ]; then
    _claudex_error "refusing to run CLIProxyAPI with .env in its fixed working directory"
    return 1
  fi
}

_claudex_read_api_key() {
  local key
  _claudex_assert_private_file "$CLAUDEX_API_KEY_FILE" || return 1
  if ! "$CLAUDEX_JQ" -Rse 'length == 64 and test("^[0-9a-f]{64}$")' \
    "$CLAUDEX_API_KEY_FILE" >/dev/null 2>&1; then
    _claudex_error "client API key must contain exactly 64 lowercase hex bytes"
    return 1
  fi
  IFS= read -r key < "$CLAUDEX_API_KEY_FILE" || true
  printf '%s' "$key"
}

_claudex_ensure_api_key_unlocked() {
  local key tmp
  if [ -e "$CLAUDEX_API_KEY_FILE" ] || [ -L "$CLAUDEX_API_KEY_FILE" ]; then
    _claudex_read_api_key >/dev/null
    return
  fi

  tmp="$($CLAUDEX_MKTEMP "$CLAUDEX_STATE_DIR/.client-api-key.XXXXXX")" || return 1
  "$CLAUDEX_CHMOD" 600 -- "$tmp" || {
    "$CLAUDEX_RM" -f -- "$tmp"
    return 1
  }
  if ! key="$($CLAUDEX_OPENSSL rand -hex 32)"; then
    "$CLAUDEX_RM" -f -- "$tmp"
    return 1
  fi
  if [ "${#key}" -ne 64 ]; then
    "$CLAUDEX_RM" -f -- "$tmp"
    _claudex_error "generated client API key has an invalid length"
    return 1
  fi
  case "$key" in
    *[!0-9a-f]*)
      "$CLAUDEX_RM" -f -- "$tmp"
      _claudex_error "generated client API key has an invalid format"
      return 1
      ;;
  esac
  printf '%s' "$key" > "$tmp"

  # -n is a final no-overwrite guard even though callers already hold state.lock.
  "$CLAUDEX_MV" -n -- "$tmp" "$CLAUDEX_API_KEY_FILE" || {
    "$CLAUDEX_RM" -f -- "$tmp"
    return 1
  }
  if [ -e "$tmp" ]; then
    "$CLAUDEX_RM" -f -- "$tmp"
  fi
  key="$(_claudex_read_api_key)" || return 1
  [ -n "$key" ]
}

_claudex_render_runtime_config_unlocked() {
  local key tmp cmp_status
  key="$(_claudex_read_api_key)" || return 1
  if [ -L "$CLAUDEX_CONFIG_FILE" ] || { [ -e "$CLAUDEX_CONFIG_FILE" ] && [ ! -f "$CLAUDEX_CONFIG_FILE" ]; }; then
    _claudex_error "refusing non-regular or symlink runtime config: $CLAUDEX_CONFIG_FILE"
    return 1
  fi
  # Preserve the inode on routine wrapper calls so CLIProxyAPI's file watch stays attached.
  # A byte-changing contract update is still atomic and requires restarting the foreground proxy.
  if [ -e "$CLAUDEX_CONFIG_FILE" ]; then
    _claudex_assert_private_file "$CLAUDEX_CONFIG_FILE" || return 1
  fi
  if [ ! -f "$CLAUDEX_CONFIG_TEMPLATE" ] || [ -L "$CLAUDEX_CONFIG_TEMPLATE" ]; then
    _claudex_error "Nix-owned runtime config template is missing or unsafe"
    return 1
  fi

  tmp="$($CLAUDEX_MKTEMP "$CLAUDEX_STATE_DIR/.config.yaml.XXXXXX")" || return 1
  "$CLAUDEX_CHMOD" 600 -- "$tmp" || {
    "$CLAUDEX_RM" -f -- "$tmp"
    return 1
  }
  if ! "$CLAUDEX_JQ" --arg authDir "$CLAUDEX_AUTH_DIR" --rawfile apiKey "$CLAUDEX_API_KEY_FILE" '
      .["auth-dir"] = $authDir
      | .["api-keys"] = [$apiKey]
    ' "$CLAUDEX_CONFIG_TEMPLATE" > "$tmp"; then
    "$CLAUDEX_RM" -f -- "$tmp"
    return 1
  fi
  if ! "$CLAUDEX_JQ" -e \
    --arg bindHost "$CLAUDEX_BIND_HOST" \
    --argjson port "$CLAUDEX_PORT" \
    --arg pprofAddr "$CLAUDEX_PPROF_ADDR" \
    --arg authDir "$CLAUDEX_AUTH_DIR" \
    --rawfile apiKey "$CLAUDEX_API_KEY_FILE" '
      keys == [
        "api-keys", "auth-dir", "commercial-mode", "debug", "error-logs-max-files",
        "host", "logging-to-file", "logs-max-total-size-mb", "max-retry-credentials",
        "max-retry-interval", "passthrough-headers", "plugins", "port", "pprof",
        "proxy-url", "remote-management", "streaming", "tls",
        "transient-error-cooldown-seconds", "usage-statistics-enabled", "ws-auth"
      ]
      and .host == $bindHost
      and .port == $port
      and (.tls | keys == ["cert", "enable", "key"])
      and .tls.enable == false
      and .tls.cert == ""
      and .tls.key == ""
      and (.["remote-management"] | keys == [
        "allow-remote", "disable-auto-update-panel", "disable-control-panel", "secret-key"
      ])
      and .["remote-management"]["allow-remote"] == false
      and .["remote-management"]["secret-key"] == ""
      and .["remote-management"]["disable-control-panel"] == true
      and .["remote-management"]["disable-auto-update-panel"] == true
      and .["auth-dir"] == $authDir
      and .["api-keys"] == [$apiKey]
      and .debug == false
      and (.pprof | keys == ["addr", "enable"])
      and .pprof.enable == false
      and .pprof.addr == $pprofAddr
      and (.plugins | keys == ["configs", "dir", "enabled"])
      and .plugins.enabled == false
      and .plugins.dir == "plugins"
      and .plugins.configs == {}
      and .["commercial-mode"] == true
      and .["logging-to-file"] == false
      and .["logs-max-total-size-mb"] == 0
      and .["error-logs-max-files"] == 0
      and .["usage-statistics-enabled"] == false
      and .["proxy-url"] == ""
      and .["max-retry-credentials"] == 1
      and .["max-retry-interval"] == 30
      and .["passthrough-headers"] == true
      and .["transient-error-cooldown-seconds"] == -1
      and (.streaming | keys == ["bootstrap-retries", "keepalive-seconds"])
      and .streaming["keepalive-seconds"] == 15
      and .streaming["bootstrap-retries"] == 1
      and .["ws-auth"] == true
    ' "$tmp" >/dev/null; then
    "$CLAUDEX_RM" -f -- "$tmp"
    _claudex_error "rendered runtime config violates the declared security contract"
    return 1
  fi
  if [ -e "$CLAUDEX_CONFIG_FILE" ]; then
    if "$CLAUDEX_CMP" -s -- "$tmp" "$CLAUDEX_CONFIG_FILE"; then
      "$CLAUDEX_RM" -f -- "$tmp" || return 1
      _claudex_assert_private_file "$CLAUDEX_CONFIG_FILE"
      return
    else
      cmp_status=$?
      if [ "$cmp_status" -ne 1 ]; then
        "$CLAUDEX_RM" -f -- "$tmp"
        _claudex_error "failed to compare the rendered runtime config"
        return 1
      fi
    fi
  fi
  "$CLAUDEX_MV" -f -- "$tmp" "$CLAUDEX_CONFIG_FILE" || {
    "$CLAUDEX_RM" -f -- "$tmp"
    return 1
  }
  "$CLAUDEX_CHMOD" 600 -- "$CLAUDEX_CONFIG_FILE" || return 1
  _claudex_assert_private_file "$CLAUDEX_CONFIG_FILE"
}

_claudex_prepare_state_unlocked() {
  _claudex_ensure_private_dir "$CLAUDEX_AUTH_DIR" || return 1
  _claudex_ensure_private_dir "$CLAUDEX_WORK_DIR" || return 1
  _claudex_assert_safe_work_dir || return 1
  _claudex_ensure_api_key_unlocked || return 1
  _claudex_render_runtime_config_unlocked
}

_claudex_single_credential_path() (
  local dir="${1:-$CLAUDEX_AUTH_DIR}"
  local entries
  _claudex_assert_private_dir "$dir" || return 1
  shopt -s dotglob nullglob
  entries=("$dir"/*)
  if [ "${#entries[@]}" -ne 1 ]; then
    _claudex_error "expected exactly one credential entry in $dir (found ${#entries[@]})"
    return 1
  fi
  printf '%s' "${entries[0]}"
)

_claudex_credential_json_valid() {
  local path="$1" cred_type="$2"
  case "$cred_type" in
    codex | claude) ;;
    *)
      _claudex_error "unsupported credential type: $cred_type"
      return 1
      ;;
  esac
  case "${path##*/}" in
    *.json) ;;
    *)
      _claudex_error "credential entry must be a JSON file"
      return 1
      ;;
  esac
  _claudex_assert_private_file "$path" || return 1
  "$CLAUDEX_JQ" -e --arg credType "$cred_type" '
    type == "object"
    and .type == $credType
    and (.access_token | type == "string" and length > 0)
    and (.refresh_token | type == "string" and length > 0)
  ' "$path" >/dev/null 2>&1
}

_claudex_credential_fingerprint() {
  local path="$1" digest
  _claudex_assert_private_file "$path" || return 1
  digest="$("$CLAUDEX_OPENSSL" dgst -sha256 < "$path")" || return 1
  digest="${digest##*= }"
  if [ "${#digest}" -ne 64 ]; then
    _claudex_error "credential fingerprint has an invalid length"
    return 1
  fi
  case "$digest" in
    *[!0-9a-fA-F]*)
      _claudex_error "credential fingerprint has an invalid format"
      return 1
      ;;
  esac
  printf '%s' "$digest"
}

_claudex_credential_set_fingerprint() {
  local dir="$1" digest
  _claudex_assert_private_dir "$dir" || return 1
  digest="$(
    shopt -s dotglob nullglob
    for entry in "$dir"/*; do
      _claudex_assert_private_file "$entry" || exit 1
      printf '%s\0%s\0' "${entry##*/}" "$(_claudex_credential_fingerprint "$entry")" || exit 1
    done | "$CLAUDEX_OPENSSL" dgst -sha256
  )" || return 1
  digest="${digest##*= }"
  if [ "${#digest}" -ne 64 ]; then
    _claudex_error "credential set fingerprint has an invalid length"
    return 1
  fi
  case "$digest" in
    *[!0-9a-fA-F]*)
      _claudex_error "credential set fingerprint has an invalid format"
      return 1
      ;;
  esac
  printf '%s' "$digest"
}

# Prints the declared .type of a credential file, or nothing when the file is not a
# readable JSON object with a string type. Never fails the caller; type routing decisions
# stay with the caller. Symlinks and non-regular entries (FIFO, directory) yield no type
# without opening them — jq would follow a symlink or block forever on a FIFO.
_claudex_credential_type_of() {
  local path="$1"
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    return 0
  fi
  "$CLAUDEX_JQ" -r 'if type == "object" and (.type | type == "string") then .type else empty end' \
    "$path" 2>/dev/null || true
}

# Asserts every entry in the directory is a well-formed codex/claude credential without
# constraining counts. Partial sets (codex-only or claude-only) are legitimate mid-login
# states, so login-time checks use this instead of the full assert_credential_set contract.
_claudex_assert_entries_wellformed() (
  local dir="$1"
  local entry cred_entry_type
  _claudex_assert_private_dir "$dir" || return 1
  shopt -s dotglob nullglob
  for entry in "$dir"/*; do
    cred_entry_type="$(_claudex_credential_type_of "$entry")"
    case "$cred_entry_type" in
      codex | claude) ;;
      *)
        _claudex_error "canonical auth directory holds an unexpected credential entry"
        return 1
        ;;
    esac
    _claudex_credential_json_valid "$entry" "$cred_entry_type" || return 1
  done
)

# Prints the path of the unique credential of the given type. Return codes: 0 = exactly
# one entry of that type exists (path printed), 1 = none exist (silent — callers use this
# as an existence probe), 2 = more than one entry of that type (error printed).
_claudex_credential_path_of_type() (
  local dir="$1" cred_type="$2"
  local entry cred_entry_type found=""
  _claudex_assert_private_dir "$dir" || return 2
  shopt -s dotglob nullglob
  for entry in "$dir"/*; do
    cred_entry_type="$(_claudex_credential_type_of "$entry")"
    if [ "$cred_entry_type" = "$cred_type" ]; then
      if [ -n "$found" ]; then
        _claudex_error "expected at most one $cred_type credential in $dir"
        return 2
      fi
      found="$entry"
    fi
  done
  [ -n "$found" ] || return 1
  printf '%s' "$found"
)

# Run a command or shell function under the canonical state lock. The descriptor and state
# live on a local filesystem; flock's fd mode gives us kernel-backed exclusion without a
# stale-lock cleanup protocol, identically on macOS (discoteq flock) and NixOS (util-linux
# flock). -x is stated explicitly so the exclusive contract does not rest on flock's default.
# Tests may inject CLAUDEX_FLOCK.
with_state_lock() (
  local lock_triplet
  umask 077
  _claudex_assert_default_state_ancestors || exit 1
  _claudex_ensure_private_dir "$CLAUDEX_STATE_DIR" || exit 1
  if [ -L "$CLAUDEX_STATE_LOCK" ] || { [ -e "$CLAUDEX_STATE_LOCK" ] && [ ! -f "$CLAUDEX_STATE_LOCK" ]; }; then
    _claudex_error "refusing non-regular or symlink state lock"
    exit 1
  fi
  : >> "$CLAUDEX_STATE_LOCK" || exit 1
  "$CLAUDEX_CHMOD" 600 -- "$CLAUDEX_STATE_LOCK" || exit 1
  lock_triplet="$(_claudex_permission_triplet "$CLAUDEX_STATE_LOCK")"
  if [ "$lock_triplet" != "600" ]; then
    _claudex_error "state lock mode must be 0600"
    exit 1
  fi
  exec 9>"$CLAUDEX_STATE_LOCK" || exit 1
  if ! "$CLAUDEX_FLOCK" -x -w "$CLAUDEX_LOCK_TIMEOUT_SECONDS" 9; then
    _claudex_error "timed out waiting for the state lock"
    exit 1
  fi
  "$@"
)

prepare_state() {
  with_state_lock _claudex_prepare_state_unlocked
}

credential_count() (
  local dir="${1:-$CLAUDEX_AUTH_DIR}"
  local entries
  _claudex_assert_private_dir "$dir" || return 1
  shopt -s dotglob nullglob
  entries=("$dir"/*)
  printf '%s\n' "${#entries[@]}"
)

# Validates the canonical credential set for a session mode.
#   default: exactly one codex credential (required) + at most one claude credential.
#   mixed:   exactly one codex credential + exactly one claude credential.
# Any entry that is not a valid codex/claude credential JSON is rejected in both modes.
# CIR: mixed Stage 1.5 keeps a single proxy and a single canonical auth dir. Once a claude
# credential is present, a default (non-mixed) session can technically reach it through the
# same loopback API key — the user explicitly accepted this residual exposure (issue #1127
# decision; same trust domain as the Stage 1 "loopback key visible to in-session
# subprocesses" acceptance in claudex.sh). Splitting per-provider auth dirs/proxies was
# rejected because credential auto-refresh rewrites files and copies would drift; the
# follow-up boundary review is tracked on the Stage 2 gate issue #1108.
assert_credential_set() (
  local dir="$1" mode="$2"
  local entry cred_entry_type codex_count=0 claude_count=0
  case "$mode" in
    default | mixed) ;;
    *)
      _claudex_error "assert_credential_set mode must be default or mixed"
      return 1
      ;;
  esac
  _claudex_assert_private_dir "$dir" || return 1
  shopt -s dotglob nullglob
  for entry in "$dir"/*; do
    cred_entry_type="$(_claudex_credential_type_of "$entry")"
    case "$cred_entry_type" in
      codex) codex_count=$((codex_count + 1)) ;;
      claude) claude_count=$((claude_count + 1)) ;;
      *)
        _claudex_error "unexpected credential entry in $dir: ${entry##*/}"
        return 1
        ;;
    esac
    _claudex_credential_json_valid "$entry" "$cred_entry_type" || return 1
  done
  if [ "$codex_count" -ne 1 ]; then
    _claudex_error "expected exactly one codex credential in $dir (found $codex_count)"
    return 1
  fi
  case "$mode" in
    default)
      if [ "$claude_count" -gt 1 ]; then
        _claudex_error "expected at most one claude credential in $dir (found $claude_count)"
        return 1
      fi
      ;;
    mixed)
      if [ "$claude_count" -ne 1 ]; then
        _claudex_error "mixed mode requires exactly one claude credential in $dir (found $claude_count; run claudex-login --claude)"
        return 1
      fi
      ;;
  esac
)

curl_loopback() (
  local path="${1:-}"
  local key
  case "$path" in
    /*) ;;
    *)
      _claudex_error "curl_loopback accepts only an absolute URL path"
      exit 1
      ;;
  esac
  case "$path" in
    *$'\n'* | *$'\r'* | *..*)
      _claudex_error "unsafe loopback URL path"
      exit 1
      ;;
  esac
  key="$(_claudex_read_api_key)" || exit 1

  # Feed the Authorization header through stdin rather than argv so the stable local API key
  # is not exposed in the process list. Both proxy variable casings are removed, and curl's
  # own --noproxy guard independently pins the request to loopback.
  printf 'header = "Authorization: Bearer %s"\n' "$key" |
    "$CLAUDEX_ENV" \
      -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u NO_PROXY \
      -u http_proxy -u https_proxy -u all_proxy -u no_proxy \
      NO_PROXY="$CLAUDEX_NO_PROXY" \
      no_proxy="$CLAUDEX_NO_PROXY" \
      "$CLAUDEX_CURL" \
        -q \
        --config - \
        --fail \
        --silent \
        --show-error \
        --noproxy '*' \
        --proto '=http' \
        --connect-timeout 2 \
        --max-time 5 \
        --request GET \
        --url "$CLAUDEX_BASE_URL$path"
)

wait_for_proxy_ready() {
  local attempts="${1:-$CLAUDEX_READY_ATTEMPTS}"
  local i=0 payload
  case "$attempts" in
    "" | *[!0-9]*)
      _claudex_error "readiness attempt count must be an integer"
      return 1
      ;;
  esac
  while [ "$i" -lt "$attempts" ]; do
    if payload="$(curl_loopback /v1/models 2>/dev/null)" \
      && "$CLAUDEX_JQ" -e '.data | type == "array"' <<< "$payload" >/dev/null 2>&1; then
      return 0
    fi
    i=$((i + 1))
    if [ "$i" -lt "$attempts" ]; then
      "$CLAUDEX_SLEEP" "$CLAUDEX_READY_DELAY_SECONDS"
    fi
  done
  _claudex_error "proxy did not become ready on $CLAUDEX_BASE_URL"
  return 1
}
