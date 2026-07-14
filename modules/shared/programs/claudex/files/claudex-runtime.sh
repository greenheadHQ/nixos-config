#!@bashBin@
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2050
# Shared runtime contract for the declarative claudex PoC.
#
# This file is sourced by the public commands. Sourcing it is side-effect free: state creation,
# credential validation, loopback probes, and launchctl calls happen only through the eight
# public functions listed at the end of this header.
#
# Public API:
#   with_state_lock prepare_state render_runtime_config credential_count
#   assert_single_codex_credential curl_loopback wait_for_proxy_ready
#   ensure_declared_launch_agent

if [ "@allowTestOverrides@" = "true" ]; then
  CLAUDEX_JQ="${CLAUDEX_JQ:-@jqBin@}"
  CLAUDEX_CURL="${CLAUDEX_CURL:-@curlBin@}"
  CLAUDEX_OPENSSL="${CLAUDEX_OPENSSL:-@opensslBin@}"
  CLAUDEX_STAT="${CLAUDEX_STAT:-@statBin@}"
  CLAUDEX_CHMOD="${CLAUDEX_CHMOD:-@chmodBin@}"
  CLAUDEX_MKDIR="${CLAUDEX_MKDIR:-@mkdirBin@}"
  CLAUDEX_MKTEMP="${CLAUDEX_MKTEMP:-@mktempBin@}"
  CLAUDEX_MV="${CLAUDEX_MV:-@mvBin@}"
  CLAUDEX_RM="${CLAUDEX_RM:-@rmBin@}"
  CLAUDEX_SLEEP="${CLAUDEX_SLEEP:-@sleepBin@}"
  CLAUDEX_ENV="${CLAUDEX_ENV:-@envBin@}"
  CLAUDEX_LOCKF="${CLAUDEX_LOCKF:-@lockfBin@}"
  CLAUDEX_LAUNCHCTL="${CLAUDEX_LAUNCHCTL:-@launchctlBin@}"
  CLAUDEX_ID="${CLAUDEX_ID:-@idBin@}"
else
  CLAUDEX_JQ="@jqBin@"
  CLAUDEX_CURL="@curlBin@"
  CLAUDEX_OPENSSL="@opensslBin@"
  CLAUDEX_STAT="@statBin@"
  CLAUDEX_CHMOD="@chmodBin@"
  CLAUDEX_MKDIR="@mkdirBin@"
  CLAUDEX_MKTEMP="@mktempBin@"
  CLAUDEX_MV="@mvBin@"
  CLAUDEX_RM="@rmBin@"
  CLAUDEX_SLEEP="@sleepBin@"
  CLAUDEX_ENV="@envBin@"
  CLAUDEX_LOCKF="@lockfBin@"
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
  CLAUDEX_DESCRIPTOR="${CLAUDEX_DESCRIPTOR:-$CLAUDEX_HOME/.config/claudex/runtime.json}"
  CLAUDEX_CONFIG_TEMPLATE="${CLAUDEX_CONFIG_TEMPLATE:-@configTemplate@}"
else
  CLAUDEX_HOME="@homeDir@"
  CLAUDEX_STATE_DIR="$CLAUDEX_HOME/Library/Application Support/claudex"
  CLAUDEX_AUTH_DIR="$CLAUDEX_STATE_DIR/auth"
  CLAUDEX_CONFIG_FILE="$CLAUDEX_STATE_DIR/config.yaml"
  CLAUDEX_API_KEY_FILE="$CLAUDEX_STATE_DIR/client-api-key"
  CLAUDEX_STATE_LOCK="$CLAUDEX_STATE_DIR/state.lock"
  CLAUDEX_WORK_DIR="$CLAUDEX_STATE_DIR/work"
  CLAUDEX_DESCRIPTOR="$CLAUDEX_HOME/.config/claudex/runtime.json"
  CLAUDEX_CONFIG_TEMPLATE="@configTemplate@"
fi
CLAUDEX_LOCK_TIMEOUT_SECONDS="${CLAUDEX_LOCK_TIMEOUT_SECONDS:-10}"
CLAUDEX_READY_ATTEMPTS="${CLAUDEX_READY_ATTEMPTS:-20}"
CLAUDEX_READY_DELAY_SECONDS="${CLAUDEX_READY_DELAY_SECONDS:-0.25}"

CLAUDEX_BIND_HOST="127.0.0.1"
CLAUDEX_PORT="8317"
CLAUDEX_MODEL="gpt-5.6-sol"
CLAUDEX_LABEL="org.nix-community.home.claudex-proxy"
CLAUDEX_BASE_URL="http://${CLAUDEX_BIND_HOST}:${CLAUDEX_PORT}"

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

_claudex_file_mode() {
  "$CLAUDEX_STAT" -c '%a' "$1" 2>/dev/null
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
  if [ "$(_claudex_file_mode "$path")" != "700" ]; then
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
  if [ "$(_claudex_file_mode "$path")" != "600" ]; then
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
  local key tmp
  key="$(_claudex_read_api_key)" || return 1
  if [ -L "$CLAUDEX_CONFIG_FILE" ] || { [ -e "$CLAUDEX_CONFIG_FILE" ] && [ ! -f "$CLAUDEX_CONFIG_FILE" ]; }; then
    _claudex_error "refusing non-regular or symlink runtime config: $CLAUDEX_CONFIG_FILE"
    return 1
  fi
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
    --arg authDir "$CLAUDEX_AUTH_DIR" \
    --rawfile apiKey "$CLAUDEX_API_KEY_FILE" '
      keys == [
        "api-keys", "auth-dir", "commercial-mode", "debug", "error-logs-max-files",
        "host", "logging-to-file", "logs-max-total-size-mb", "max-retry-credentials",
        "plugins", "port", "pprof", "proxy-url", "remote-management", "tls",
        "usage-statistics-enabled", "ws-auth"
      ]
      and .host == "127.0.0.1"
      and .port == 8317
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
      and .pprof.addr == "127.0.0.1:8316"
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
      and .["ws-auth"] == true
    ' "$tmp" >/dev/null; then
    "$CLAUDEX_RM" -f -- "$tmp"
    _claudex_error "rendered runtime config violates the declared security contract"
    return 1
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
  local path="$1"
  case "${path##*/}" in
    *.json) ;;
    *)
      _claudex_error "credential entry must be a JSON file"
      return 1
      ;;
  esac
  _claudex_assert_private_file "$path" || return 1
  "$CLAUDEX_JQ" -e '
    type == "object"
    and .type == "codex"
    and (.access_token | type == "string" and length > 0)
    and (.refresh_token | type == "string" and length > 0)
  ' "$path" >/dev/null 2>&1
}

_claudex_ensure_declared_launch_agent_unlocked() {
  local enabled label plist domain
  if [ ! -f "$CLAUDEX_DESCRIPTOR" ]; then
    _claudex_error "runtime descriptor is missing or unsafe: $CLAUDEX_DESCRIPTOR"
    return 1
  fi
  if ! "$CLAUDEX_JQ" -e '.schema == 1 and (.enabled | type == "boolean")' "$CLAUDEX_DESCRIPTOR" >/dev/null; then
    _claudex_error "runtime descriptor schema is invalid"
    return 1
  fi
  enabled="$($CLAUDEX_JQ -r '.enabled' "$CLAUDEX_DESCRIPTOR")" || return 1
  label="$($CLAUDEX_JQ -r '.label' "$CLAUDEX_DESCRIPTOR")" || return 1
  if [ "$label" != "$CLAUDEX_LABEL" ]; then
    _claudex_error "runtime descriptor label drift"
    return 1
  fi
  domain="gui/$($CLAUDEX_ID -u)"

  if [ "$enabled" = "false" ]; then
    if "$CLAUDEX_LAUNCHCTL" print "$domain/$label" >/dev/null 2>&1; then
      _claudex_error "disabled claudex host still has a loaded launch agent"
      return 1
    fi
    return 0
  fi

  plist="$($CLAUDEX_JQ -r '.launchAgentPlist // empty' "$CLAUDEX_DESCRIPTOR")" || return 1
  if [ -z "$plist" ] || [ ! -f "$plist" ]; then
    _claudex_error "enabled claudex descriptor has no declared launch-agent plist"
    return 1
  fi
  if "$CLAUDEX_LAUNCHCTL" print "$domain/$label" >/dev/null 2>&1; then
    return 0
  fi
  "$CLAUDEX_LAUNCHCTL" bootstrap "$domain" "$plist" >/dev/null 2>&1 || true
  if ! "$CLAUDEX_LAUNCHCTL" print "$domain/$label" >/dev/null 2>&1; then
    _claudex_error "declared launch agent did not load after bootstrap"
    return 1
  fi
}

# Run a command or shell function under the canonical state lock. The descriptor and state
# live on local APFS; /usr/bin/lockf's fd mode gives us kernel-backed exclusion without a
# stale-lock cleanup protocol. Tests may inject CLAUDEX_LOCKF.
with_state_lock() (
  local lock_mode
  umask 077
  _claudex_assert_default_state_ancestors || exit 1
  _claudex_ensure_private_dir "$CLAUDEX_STATE_DIR" || exit 1
  if [ -L "$CLAUDEX_STATE_LOCK" ] || { [ -e "$CLAUDEX_STATE_LOCK" ] && [ ! -f "$CLAUDEX_STATE_LOCK" ]; }; then
    _claudex_error "refusing non-regular or symlink state lock"
    exit 1
  fi
  : >> "$CLAUDEX_STATE_LOCK" || exit 1
  "$CLAUDEX_CHMOD" 600 -- "$CLAUDEX_STATE_LOCK" || exit 1
  lock_mode="$(_claudex_file_mode "$CLAUDEX_STATE_LOCK")"
  if [ "$lock_mode" != "600" ]; then
    _claudex_error "state lock mode must be 0600"
    exit 1
  fi
  exec 9>"$CLAUDEX_STATE_LOCK" || exit 1
  if ! "$CLAUDEX_LOCKF" -s -t "$CLAUDEX_LOCK_TIMEOUT_SECONDS" 9; then
    _claudex_error "timed out waiting for the state lock"
    exit 1
  fi
  "$@"
)

prepare_state() {
  with_state_lock _claudex_prepare_state_unlocked
}

render_runtime_config() {
  with_state_lock _claudex_render_runtime_config_unlocked
}

credential_count() (
  local dir="${1:-$CLAUDEX_AUTH_DIR}"
  local entries
  _claudex_assert_private_dir "$dir" || return 1
  shopt -s dotglob nullglob
  entries=("$dir"/*)
  printf '%s\n' "${#entries[@]}"
)

assert_single_codex_credential() {
  local path
  path="$(_claudex_single_credential_path "${1:-$CLAUDEX_AUTH_DIR}")" || return 1
  _claudex_credential_json_valid "$path"
}

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
      NO_PROXY="127.0.0.1,localhost" \
      no_proxy="127.0.0.1,localhost" \
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

ensure_declared_launch_agent() {
  with_state_lock _claudex_ensure_declared_launch_agent_unlocked
}
