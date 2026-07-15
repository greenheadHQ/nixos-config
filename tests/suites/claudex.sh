# tests/suites/claudex.sh — Stage 1 fake-only coverage for the declarative claudex PoC
# shellcheck shell=bash

_claudex_assert_no_placeholders() {
  local path="$1"
  if grep -Eq '@[A-Za-z_][A-Za-z0-9_-]*@' "$path"; then
    fail "claudex fixture retained an unsubstituted placeholder: $path"
  fi
}

_claudex_render_config_template() {
  local source="$1" destination="$2"
  local bind_host="${CLAUDEX_FIXTURE_BIND_HOST:-127.0.0.1}"
  local port="${CLAUDEX_FIXTURE_PORT:-8317}"
  local pprof_port="${CLAUDEX_FIXTURE_PPROF_PORT:-$((port - 1))}"

  jq \
    --arg bindHost "$bind_host" \
    --argjson port "$port" \
    --arg pprofAddr "${bind_host}:${pprof_port}" \
    '.host = $bindHost | .port = $port | .pprof.addr = $pprofAddr' \
    "$source" > "$destination"
}

_claudex_materialize_runtime() {
  local destination="$1" template="$2"
  local source="$REPO_ROOT/modules/shared/programs/claudex/files/claudex-runtime.sh"
  local allow_test_overrides="${CLAUDEX_FIXTURE_ALLOW_TEST_OVERRIDES:-true}"
  local declared_home="${CLAUDEX_FIXTURE_DECLARED_HOME:-$destination-home}"
  local curl_bin="${CLAUDEX_FIXTURE_CURL_BIN:-$(command -v curl)}"
  local lockf_bin="${CLAUDEX_FIXTURE_LOCKF_BIN:-/usr/bin/lockf}"
  local launchctl_bin="${CLAUDEX_FIXTURE_LAUNCHCTL_BIN:-/bin/launchctl}"
  local bind_host="${CLAUDEX_FIXTURE_BIND_HOST:-127.0.0.1}"
  local port="${CLAUDEX_FIXTURE_PORT:-8317}"
  local model="${CLAUDEX_FIXTURE_MODEL:-gpt-5.6-sol}"
  local label="${CLAUDEX_FIXTURE_LABEL:-org.nix-community.home.claudex-proxy}"
  local pprof_port="${CLAUDEX_FIXTURE_PPROF_PORT:-$((port - 1))}"
  local state_dir="${CLAUDEX_FIXTURE_STATE_DIR:-$declared_home/Library/Application Support/claudex}"
  local auth_dir="${CLAUDEX_FIXTURE_AUTH_DIR:-$state_dir/auth}"
  local config_file="${CLAUDEX_FIXTURE_CONFIG_FILE:-$state_dir/config.yaml}"
  local api_key_file="${CLAUDEX_FIXTURE_API_KEY_FILE:-$state_dir/client-api-key}"
  local state_lock="${CLAUDEX_FIXTURE_STATE_LOCK:-$state_dir/state.lock}"
  local work_dir="${CLAUDEX_FIXTURE_WORK_DIR:-$state_dir/work}"

  sed \
    -e "s|@allowTestOverrides@|$allow_test_overrides|g" \
    -e "s|@bashBin@|$(command -v bash)|g" \
    -e "s|@homeDir@|$declared_home|g" \
    -e "s|@stateDir@|$state_dir|g" \
    -e "s|@authDir@|$auth_dir|g" \
    -e "s|@configFile@|$config_file|g" \
    -e "s|@apiKeyFile@|$api_key_file|g" \
    -e "s|@stateLock@|$state_lock|g" \
    -e "s|@workDir@|$work_dir|g" \
    -e "s|@configTemplate@|$template|g" \
    -e "s|@jqBin@|$(command -v jq)|g" \
    -e "s|@curlBin@|$curl_bin|g" \
    -e "s|@opensslBin@|$(command -v openssl)|g" \
    -e "s|@cmpBin@|$(command -v cmp)|g" \
    -e "s|@statBin@|$(command -v stat)|g" \
    -e "s|@chmodBin@|$(command -v chmod)|g" \
    -e "s|@mkdirBin@|$(command -v mkdir)|g" \
    -e "s|@mktempBin@|$(command -v mktemp)|g" \
    -e "s|@mvBin@|$(command -v mv)|g" \
    -e "s|@rmBin@|$(command -v rm)|g" \
    -e "s|@sleepBin@|$(command -v sleep)|g" \
    -e "s|@envBin@|$(command -v env)|g" \
    -e "s|@idBin@|$(command -v id)|g" \
    -e "s|@lockfBin@|$lockf_bin|g" \
    -e "s|@launchctlBin@|$launchctl_bin|g" \
    -e "s|@bindHost@|$bind_host|g" \
    -e "s|@port@|$port|g" \
    -e "s|@model@|$model|g" \
    -e "s|@label@|$label|g" \
    -e "s|@pprofPort@|$pprof_port|g" \
    "$source" > "$destination"
  _claudex_assert_no_placeholders "$destination"
}

_claudex_materialize_command() {
  local source="$1" destination="$2" runtime="$3" proxy="$4" template="$5"
  local wrapper_settings="${6:-$template}"
  local wrapper_settings_fast="${7:-$wrapper_settings}"

  sed \
    -e "s|@bashBin@|$(command -v bash)|g" \
    -e "s|@runtimeLibrary@|$runtime|g" \
    -e "s|@proxyBin@|$proxy|g" \
    -e "s|@configTemplate@|$template|g" \
    -e "s|@wrapperSettings@|$wrapper_settings|g" \
    -e "s|@wrapperSettingsFast@|$wrapper_settings_fast|g" \
    -e "s|@maxContextTokens@|258000|g" \
    "$source" > "$destination"
  _claudex_assert_no_placeholders "$destination"
}

_claudex_write_wrapper_settings() {
  local destination="$1"
  jq -n '{env: {CLAUDE_CODE_EXTRA_BODY: "{}"}}' > "$destination"
}

_claudex_write_wrapper_settings_fast() {
  local destination="$1"
  jq -n '{env: {CLAUDE_CODE_EXTRA_BODY: ({service_tier: "priority"} | tostring)}}' \
    > "$destination"
}

_claudex_file_inode() {
  stat -c '%i' "$1" 2>/dev/null || /usr/bin/stat -f '%i' "$1" 2>/dev/null
}

_claudex_fixture() {
  local sandbox="$1"
  local root="$REPO_ROOT/modules/shared/programs/claudex"
  local generated="$sandbox/generated"
  local fake_proxy="$sandbox/fake-cli-proxy-api"
  local wrapper_settings="$generated/wrapper-settings.json"
  local wrapper_settings_fast="$generated/wrapper-settings-fast.json"

  mkdir -p "$sandbox/home/.local/bin" "$generated"
  _claudex_render_config_template \
    "$root/files/config-template.json" "$generated/config-template.json"
  _claudex_write_wrapper_settings "$wrapper_settings"
  _claudex_write_wrapper_settings_fast "$wrapper_settings_fast"
  cat > "$sandbox/fake-lockf" <<'EOF'
#!/usr/bin/env bash
[ -z "${CLAUDEX_FAKE_LOCK_LOG:-}" ] || printf '%s\n' "$@" >> "$CLAUDEX_FAKE_LOCK_LOG"
[ "${CLAUDEX_FAKE_LOCK_FAIL:-0}" != 1 ] || exit 1
exit 0
EOF
  cat > "$fake_proxy" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
  chmod +x "$sandbox/fake-lockf" "$fake_proxy"

  _claudex_materialize_runtime \
    "$generated/claudex-runtime.sh" "$generated/config-template.json"
  local script
  for script in claudex claudex-login claudex-status claudex-proxy-launcher; do
    _claudex_materialize_command \
      "$root/files/$script.sh" "$generated/$script" \
      "$generated/claudex-runtime.sh" "$fake_proxy" "$generated/config-template.json" \
      "$wrapper_settings" "$wrapper_settings_fast"
    chmod +x "$generated/$script"
  done
}

_claudex_production_fixture() {
  local sandbox="$1" declared_home="$2"
  local root="$REPO_ROOT/modules/shared/programs/claudex"
  local generated="$sandbox/production"
  local runtime="$generated/claudex-runtime.sh"
  local proxy="$sandbox/production-cli-proxy-api"
  local curl_bin="$sandbox/production-curl"
  local launchctl_bin="$sandbox/production-launchctl"
  local wrapper_settings="$generated/wrapper-settings.json"
  local wrapper_settings_fast="$generated/wrapper-settings-fast.json"
  local jq_bin
  jq_bin="$(command -v jq)"
  mkdir -p "$generated" "$declared_home/.local/bin"
  _claudex_write_wrapper_settings "$wrapper_settings"
  _claudex_write_wrapper_settings_fast "$wrapper_settings_fast"

  cat > "$curl_bin" <<'EOF'
#!/usr/bin/env bash
IFS= read -r _header || true
printf '%s' '{"data":[{"id":"gpt-5.6-sol"}]}'
EOF
  cat > "$launchctl_bin" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat > "$proxy" <<EOF
#!/usr/bin/env bash
set -euo pipefail
device=false
config=''
args=("\$@")
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --codex-device-login) device=true; shift ;;
    --config) config="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ "\$device" = true ]; then
  env | sort > "$sandbox/production-login.env"
  printf 'home=%s\n' "\$HOME" > "$sandbox/production-login.log"
  printf 'arg=%s\n' "\${args[@]}" >> "$sandbox/production-login.log"
  auth_dir="\$("$jq_bin" -r '.["auth-dir"]' "\$config")"
  mkdir -p "\$auth_dir"
  chmod 700 "\$auth_dir"
  printf '%s' '{"type":"codex","access_token":"prod-access","refresh_token":"prod-refresh"}' > "\$auth_dir/codex-production.json"
  chmod 600 "\$auth_dir/codex-production.json"
  exit 0
fi
env | sort > "$sandbox/production-launcher.env"
printf 'home=%s\n' "\$HOME" > "$sandbox/production-launcher.log"
printf 'cwd=%s\n' "\$PWD" >> "$sandbox/production-launcher.log"
printf 'arg=%s\n' "\${args[@]}" >> "$sandbox/production-launcher.log"
exit 17
EOF
  chmod +x "$curl_bin" "$launchctl_bin" "$proxy"

  CLAUDEX_FIXTURE_ALLOW_TEST_OVERRIDES=false \
    CLAUDEX_FIXTURE_DECLARED_HOME="$declared_home" \
    CLAUDEX_FIXTURE_CURL_BIN="$curl_bin" \
    CLAUDEX_FIXTURE_LOCKF_BIN="$sandbox/fake-lockf" \
    CLAUDEX_FIXTURE_LAUNCHCTL_BIN="$launchctl_bin" \
    _claudex_materialize_runtime "$runtime" "$sandbox/generated/config-template.json"
  local script
  for script in claudex claudex-login claudex-status claudex-proxy-launcher; do
    _claudex_materialize_command \
      "$root/files/$script.sh" "$generated/$script" "$runtime" "$proxy" \
      "$sandbox/generated/config-template.json" "$wrapper_settings" "$wrapper_settings_fast"
    chmod +x "$generated/$script"
  done
}

_claudex_prepare_fixture_state() {
  local sandbox="$1"
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$sandbox/state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    bash -c 'source "$1"; prepare_state' _ "$sandbox/generated/claudex-runtime.sh"
}

_claudex_add_valid_credential() {
  local state="$1"
  printf '%s' '{"type":"codex","access_token":"test-access","refresh_token":"test-refresh"}' \
    > "$state/auth/codex-test.json"
  chmod 600 "$state/auth/codex-test.json"
}

_claudex_make_ready_curl() {
  local sandbox="$1"
  cat > "$sandbox/fake-curl" <<EOF
#!/usr/bin/env bash
IFS= read -r _header || true
printf '%s\n' "\$@" >> "$sandbox/curl.argv"
printf '%s' '{"data":[{"id":"gpt-5.6-sol"}]}'
EOF
  chmod +x "$sandbox/fake-curl"
}

test_claudex_runtime_api_and_private_state() {
  local sandbox state runtime command_functions expected key_before key_after replacement_key config_inode_before config_inode_after external production_runtime production_home output symlink_home
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  runtime="$sandbox/generated/claudex-runtime.sh"
  _claudex_fixture "$sandbox"

  command_functions="$({
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
      source "$1"
      declare -F | sed "s/^declare -f //" | grep -v "^_" | sort
    ' _ "$runtime"
  })"
  expected=$'assert_single_codex_credential\ncredential_count\ncurl_loopback\nprepare_state\nwait_for_proxy_ready\nwith_state_lock'
  [[ "$command_functions" == "$expected" ]] || fail "claudex runtime command API drifted: $command_functions"
  [[ ! -e "$state" ]] || fail "sourcing claudex runtime must be inert"

  production_runtime="$sandbox/generated/claudex-runtime-production.sh"
  production_home="$sandbox/declared-home"
  CLAUDEX_FIXTURE_ALLOW_TEST_OVERRIDES=false \
    CLAUDEX_FIXTURE_DECLARED_HOME="$production_home" \
    _claudex_materialize_runtime "$production_runtime" "$sandbox/generated/config-template.json"
  output="$(
    HOME="$sandbox/hostile-home" \
      CLAUDEX_STATE_DIR="$sandbox/hostile-state" \
      CLAUDEX_JQ=/bin/false \
      bash -c 'source "$1"; printf "%s\n%s\n" "$CLAUDEX_HOME" "$CLAUDEX_STATE_DIR"' \
      _ "$production_runtime"
  )"
  expected="$production_home"$'\n'"$production_home/Library/Application Support/claudex"
  [[ "$output" == "$expected" ]] || fail "production runtime accepted inherited home/state overrides"
  [[ "$(HOME="$sandbox/hostile-home" CLAUDEX_JQ=/bin/false bash -c 'source "$1"; printf "%s" "$CLAUDEX_JQ"' _ "$production_runtime")" == "$(command -v jq)" ]] \
    || fail "production runtime accepted an inherited tool override"

  symlink_home="$sandbox/symlink-home"
  mkdir -p "$symlink_home" "$sandbox/external-library"
  ln -s "$sandbox/external-library" "$symlink_home/Library"
  if HOME="$symlink_home" CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    bash -c 'source "$1"; prepare_state' _ "$runtime" >/dev/null 2>&1; then
    fail "prepare_state accepted a symlinked default-state ancestor"
  fi
  [[ ! -e "$sandbox/external-library/Application Support/claudex" ]] \
    || fail "symlinked state ancestor was followed"

  rm -rf "$sandbox/lock-failure"
  if HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$sandbox/lock-failure" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_FAKE_LOCK_LOG="$sandbox/lockf.argv" \
    CLAUDEX_FAKE_LOCK_FAIL=1 \
    bash -c 'source "$1"; prepare_state' _ "$runtime" >/dev/null 2>&1; then
    fail "prepare_state continued after lock acquisition failed"
  fi
  grep -Fqx -- "-s" "$sandbox/lockf.argv" || fail "lockf must receive -s"
  grep -Fqx -- "-t" "$sandbox/lockf.argv" || fail "lockf must receive -t"
  assert_file_contains "$sandbox/lockf.argv" "10"
  assert_file_contains "$sandbox/lockf.argv" "9"
  [[ ! -e "$sandbox/lock-failure/client-api-key" ]] \
    || fail "lock failure still entered the state mutation callback"

  _claudex_prepare_fixture_state "$sandbox"
  [[ "$(_codex_config_file_mode "$state")" == "700" ]] || fail "claudex state mode must be 0700"
  [[ "$(_codex_config_file_mode "$state/auth")" == "700" ]] || fail "claudex auth mode must be 0700"
  [[ "$(_codex_config_file_mode "$state/work")" == "700" ]] || fail "claudex work mode must be 0700"
  [[ "$(_codex_config_file_mode "$state/client-api-key")" == "600" ]] || fail "claudex key mode must be 0600"
  [[ "$(_codex_config_file_mode "$state/config.yaml")" == "600" ]] || fail "claudex config mode must be 0600"
  [[ "$(_codex_config_file_mode "$state/state.lock")" == "600" ]] || fail "claudex lock mode must be 0600"
  grep -Eq '^[0-9a-f]{64}$' "$state/client-api-key" || fail "claudex key must be 64 lowercase hex bytes"
  jq -e \
    --arg auth "$state/auth" \
    '.host == "127.0.0.1" and .port == 8317 and .["auth-dir"] == $auth
     and (.["api-keys"][0] | test("^[0-9a-f]{64}$"))
     and .["remote-management"]["allow-remote"] == false
     and .["remote-management"]["disable-control-panel"] == true
     and .["remote-management"]["disable-auto-update-panel"] == true
     and .["commercial-mode"] == true
     and .["usage-statistics-enabled"] == false' \
    "$state/config.yaml" >/dev/null || fail "rendered claudex config violates its contract"

  key_before="$(<"$state/client-api-key")"
  config_inode_before="$(_claudex_file_inode "$state/config.yaml")"
  _claudex_prepare_fixture_state "$sandbox"
  key_after="$(<"$state/client-api-key")"
  config_inode_after="$(_claudex_file_inode "$state/config.yaml")"
  [[ "$key_before" == "$key_after" ]] || fail "prepare_state rotated an existing API key"
  [[ "$config_inode_before" == "$config_inode_after" ]] \
    || fail "byte-identical config render replaced its inode"

  replacement_key="$(printf 'b%.0s' {1..64})"
  printf '%s' "$replacement_key" > "$state/client-api-key"
  config_inode_before="$(_claudex_file_inode "$state/config.yaml")"
  _claudex_prepare_fixture_state "$sandbox"
  config_inode_after="$(_claudex_file_inode "$state/config.yaml")"
  [[ "$config_inode_before" != "$config_inode_after" ]] \
    || fail "changed config content did not atomically replace its inode"
  jq -e --arg key "$replacement_key" '.["api-keys"] == [$key]' "$state/config.yaml" >/dev/null \
    || fail "changed config did not contain the replacement API key"
  [[ "$(_codex_config_file_mode "$state/config.yaml")" == "600" ]] \
    || fail "changed config lost mode 0600"
  key_before="$replacement_key"

  printf '%s\n%s' "$key_before" trailing-bytes > "$state/client-api-key"
  if _claudex_prepare_fixture_state "$sandbox" >/dev/null 2>&1; then
    fail "prepare_state accepted trailing bytes in the client API key"
  fi
  printf '%s' "$key_before" > "$state/client-api-key"

  external="$sandbox/external-config"
  printf '%s' sentinel > "$external"
  rm "$state/config.yaml"
  ln -s "$external" "$state/config.yaml"
  if _claudex_prepare_fixture_state "$sandbox" >/dev/null 2>&1; then
    fail "prepare_state accepted a symlinked config"
  fi
  [[ "$(<"$external")" == "sentinel" ]] || fail "symlink rejection modified its external target"
}

test_claudex_runtime_derived_contract() {
  local sandbox state runtime template output expected
  sandbox="$(new_sandbox)"
  state="$sandbox/contract-state"
  runtime="$sandbox/generated/claudex-runtime-contract.sh"
  template="$sandbox/generated/config-template-contract.json"
  _claudex_fixture "$sandbox"

  CLAUDEX_FIXTURE_BIND_HOST=127.0.0.42 \
    CLAUDEX_FIXTURE_PORT=18317 \
    CLAUDEX_FIXTURE_PPROF_PORT=18316 \
    _claudex_render_config_template \
      "$REPO_ROOT/modules/shared/programs/claudex/files/config-template.json" "$template"
  CLAUDEX_FIXTURE_BIND_HOST=127.0.0.42 \
    CLAUDEX_FIXTURE_PORT=18317 \
    CLAUDEX_FIXTURE_PPROF_PORT=18316 \
    CLAUDEX_FIXTURE_MODEL=sentinel-model \
    CLAUDEX_FIXTURE_LABEL=org.example.claudex-sentinel \
    _claudex_materialize_runtime "$runtime" "$template"

  output="$(HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"
    printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n" \
      "$CLAUDEX_BIND_HOST" "$CLAUDEX_PORT" "$CLAUDEX_MODEL" "$CLAUDEX_LABEL" \
      "$CLAUDEX_PPROF_ADDR" "$CLAUDEX_BASE_URL" "$CLAUDEX_NO_PROXY"
  ' _ "$runtime")"
  expected=$'127.0.0.42\n18317\nsentinel-model\norg.example.claudex-sentinel\n127.0.0.42:18316\nhttp://127.0.0.42:18317\n127.0.0.42,localhost'
  [[ "$output" == "$expected" ]] || fail "derived runtime contract drifted: $output"

  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    bash -c 'source "$1"; prepare_state' _ "$runtime"
  jq -e \
    '.host == "127.0.0.42" and .port == 18317 and .pprof.addr == "127.0.0.42:18316"' \
    "$state/config.yaml" >/dev/null || fail "rendered config ignored the injected runtime contract"
}

test_claudex_credential_and_loopback_contract() {
  local sandbox state runtime output key
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  runtime="$sandbox/generated/claudex-runtime.sh"
  _claudex_fixture "$sandbox"
  _claudex_prepare_fixture_state "$sandbox"

  output="$(HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; credential_count
  ' _ "$runtime")"
  [[ "$output" == "0" ]] || fail "empty credential directory must count as zero"

  _claudex_add_valid_credential "$state"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_single_codex_credential
  ' _ "$runtime" || fail "valid Codex credential was rejected"

  printf '%s' '{"type":"claude","access_token":"secret","refresh_token":"secret"}' \
    > "$state/auth/codex-test.json"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_single_codex_credential
  ' _ "$runtime" >/dev/null 2>&1; then
    fail "wrong-provider credential was accepted"
  fi
  _claudex_add_valid_credential "$state"

  _claudex_make_ready_curl "$sandbox"

  cat > "$sandbox/hostile-template.json" <<'EOF'
{"host":"127.0.0.1","port":8317,"tls":{"enable":false},"remote-management":{"allow-remote":false,"secret-key":"","disable-control-panel":true,"disable-auto-update-panel":true},"auth-dir":"","api-keys":[],"debug":false,"pprof":{"enable":false},"plugins":{"enabled":false},"commercial-mode":true,"logging-to-file":false,"logs-max-total-size-mb":0,"error-logs-max-files":0,"usage-statistics-enabled":false,"proxy-url":"http://hostile.invalid","max-retry-credentials":1,"ws-auth":true}
EOF
  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_CONFIG_TEMPLATE="$sandbox/hostile-template.json" \
    bash -c 'source "$1"; curl_loopback /v1/models' _ "$runtime")"
  [[ "$output" == '{"data":[{"id":"gpt-5.6-sol"}]}' ]] || fail "loopback curl payload mismatch"
  grep -Fqx -- "-q" "$sandbox/curl.argv" || fail "curl must disable curlrc with -q"
  grep -Fqx -- "--noproxy" "$sandbox/curl.argv" || fail "curl must set --noproxy"
  assert_file_contains "$sandbox/curl.argv" "*"
  grep -Fqx -- "--proto" "$sandbox/curl.argv" || fail "curl must pin the http protocol"
  assert_file_contains "$sandbox/curl.argv" "=http"
  assert_file_contains "$sandbox/curl.argv" "http://127.0.0.1:8317/v1/models"
  key="$(<"$state/client-api-key")"
  if grep -Fq "$key" "$sandbox/curl.argv"; then
    fail "client API key leaked into curl argv"
  fi
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_CURL="$sandbox/fake-curl" \
    bash -c 'source "$1"; curl_loopback "http://example.com"' _ "$runtime" >/dev/null 2>&1; then
    fail "curl_loopback accepted an absolute URL"
  fi
}

test_claudex_wrapper_pins_provider_model_and_argv() {
  local sandbox state wrapper wrapper_settings wrapper_settings_fast settings_arg rc flag
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  wrapper="$sandbox/generated/claudex"
  wrapper_settings="$sandbox/generated/wrapper-settings.json"
  wrapper_settings_fast="$sandbox/generated/wrapper-settings-fast.json"
  _claudex_fixture "$sandbox"
  _claudex_prepare_fixture_state "$sandbox"
  _claudex_add_valid_credential "$state"
  _claudex_make_ready_curl "$sandbox"

  cat > "$sandbox/home/.local/bin/claude" <<EOF
#!/usr/bin/env bash
{
  printf 'base=%s\n' "\${ANTHROPIC_BASE_URL-unset}"
  printf 'api_key=%s\n' "\${ANTHROPIC_API_KEY-unset}"
  printf 'provider_bedrock=%s\n' "\${CLAUDE_CODE_USE_BEDROCK-unset}"
  printf 'http_proxy=%s\n' "\${HTTP_PROXY-unset}"
  printf 'managed=%s\n' "\${CLAUDE_CODE_PROVIDER_MANAGED_BY_HOST-unset}"
  printf 'scrub=%s\n' "\${CLAUDE_CODE_SUBPROCESS_ENV_SCRUB-unset}"
  printf 'subagent=%s\n' "\${CLAUDE_CODE_SUBAGENT_MODEL-unset}"
  printf 'effort_enabled=%s\n' "\${CLAUDE_CODE_ALWAYS_ENABLE_EFFORT-unset}"
  printf 'concurrency=%s\n' "\${CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY-unset}"
  printf 'tool_search=%s\n' "\${ENABLE_TOOL_SEARCH-unset}"
  printf 'extra_body=%s\n' "\${CLAUDE_CODE_EXTRA_BODY-unset}"
  printf 'max_context=%s\n' "\${CLAUDE_CODE_MAX_CONTEXT_TOKENS-unset}"
  printf 'effort_level=%s\n' "\${CLAUDE_CODE_EFFORT_LEVEL-unset}"
  printf 'host_creds=%s\n' "\${CLAUDE_CODE_HOST_CREDS_FILE-unset}"
  printf 'host_auth_env=%s\n' "\${CLAUDE_CODE_HOST_AUTH_ENV_VAR-unset}"
  printf 'host_auth_refresh=%s\n' "\${CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH-unset}"
  printf 'host_auth_timeout=%s\n' "\${CLAUDE_CODE_HOST_AUTH_REFRESH_TIMEOUT_MS-unset}"
  printf 'host_http_proxy=%s\n' "\${CLAUDE_CODE_HOST_HTTP_PROXY_PORT-unset}"
  printf 'host_hfi_bearer=%s\n' "\${CLAUDE_CODE_HFI_BEARER_TOKEN-unset}"
  printf 'unix_socket=%s\n' "\${ANTHROPIC_UNIX_SOCKET-unset}"
  printf 'no_proxy=%s\n' "\${NO_PROXY-unset}"
  if [ "\${ANTHROPIC_AUTH_TOKEN-unset}" = "\$(<"$state/client-api-key")" ]; then
    echo 'auth_token=match'
  else
    echo 'auth_token=mismatch'
  fi
  printf 'arg=%s\n' "\$@"
} > "$sandbox/claude.log"
exit 23
EOF
  chmod +x "$sandbox/home/.local/bin/claude"

  set +e
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    ANTHROPIC_BASE_URL="https://hostile.invalid" \
    ANTHROPIC_API_KEY="hostile" \
    ANTHROPIC_AUTH_TOKEN="hostile" \
    ANTHROPIC_MODEL="hostile" \
    ANTHROPIC_UNIX_SOCKET="$sandbox/hostile.sock" \
    CLAUDE_CODE_EFFORT_LEVEL=low \
    CLAUDE_CODE_EXTRA_BODY='{"model":"hostile-model","max_tokens":7}' \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=1 \
    CLAUDE_CODE_HOST_CREDS_FILE="$sandbox/host-creds.json" \
    CLAUDE_CODE_HOST_AUTH_ENV_VAR=HOSTILE_AUTH \
    CLAUDE_CODE_SDK_HAS_HOST_AUTH_REFRESH=1 \
    CLAUDE_CODE_HOST_AUTH_REFRESH_TIMEOUT_MS=1 \
    CLAUDE_CODE_HOST_HTTP_PROXY_PORT=65000 \
    CLAUDE_CODE_HFI_BEARER_TOKEN=hostile-hfi \
    CLAUDE_CODE_USE_BEDROCK=1 \
    HTTP_PROXY="http://hostile.invalid" \
    "$wrapper" -- --model literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex did not preserve Claude's exit status"
  assert_file_contains "$sandbox/claude.log" "base=http://127.0.0.1:8317"
  assert_file_contains "$sandbox/claude.log" "api_key=unset"
  assert_file_contains "$sandbox/claude.log" "provider_bedrock=unset"
  assert_file_contains "$sandbox/claude.log" "http_proxy=unset"
  assert_file_contains "$sandbox/claude.log" "managed=1"
  assert_file_contains "$sandbox/claude.log" "scrub=0"
  assert_file_contains "$sandbox/claude.log" "subagent=gpt-5.6-sol"
  assert_file_contains "$sandbox/claude.log" "effort_enabled=1"
  assert_file_contains "$sandbox/claude.log" "concurrency=3"
  assert_file_contains "$sandbox/claude.log" "tool_search=false"
  assert_file_contains "$sandbox/claude.log" "extra_body=unset"
  assert_file_contains "$sandbox/claude.log" "max_context=258000"
  assert_file_contains "$sandbox/claude.log" "effort_level=high"
  assert_file_contains "$sandbox/claude.log" "host_creds=unset"
  assert_file_contains "$sandbox/claude.log" "host_auth_env=unset"
  assert_file_contains "$sandbox/claude.log" "host_auth_refresh=unset"
  assert_file_contains "$sandbox/claude.log" "host_auth_timeout=unset"
  assert_file_contains "$sandbox/claude.log" "host_http_proxy=unset"
  assert_file_contains "$sandbox/claude.log" "host_hfi_bearer=unset"
  assert_file_contains "$sandbox/claude.log" "unix_socket=unset"
  assert_file_contains "$sandbox/claude.log" "no_proxy=127.0.0.1,localhost"
  assert_file_contains "$sandbox/claude.log" "auth_token=match"
  jq -e '.["proxy-url"] == ""' "$state/config.yaml" >/dev/null \
    || fail "claudex accepted an inherited runtime config template"
  assert_file_contains "$sandbox/claude.log" "arg=--settings"
  settings_arg="$(awk '/^arg=--settings$/ { getline; sub(/^arg=/, ""); print; exit }' "$sandbox/claude.log")"
  [[ "$settings_arg" == "$wrapper_settings" ]] \
    || fail "claudex did not pass the wrapper-owned settings file"
  jq -e '.env.CLAUDE_CODE_EXTRA_BODY == "{}" and (.env | keys == ["CLAUDE_CODE_EXTRA_BODY"])' \
    "$settings_arg" >/dev/null || fail "wrapper-owned settings did not neutralize extra body"
  assert_file_contains "$sandbox/claude.log" "arg=--model"
  assert_file_contains "$sandbox/claude.log" "arg=gpt-5.6-sol"
  assert_file_contains "$sandbox/claude.log" "arg=--fallback-model"
  [[ "$(awk '/^arg=--fallback-model$/ { getline; print; exit }' "$sandbox/claude.log")" == "arg=" ]] \
    || fail "claudex did not mask settings fallbackModel with an empty CLI fallback list"
  assert_file_contains "$sandbox/claude.log" "arg=--effort"
  assert_file_contains "$sandbox/claude.log" "arg=high"
  assert_file_contains "$sandbox/claude.log" "arg=--dangerously-skip-permissions"
  assert_file_contains "$sandbox/claude.log" "arg=--"
  assert_file_contains "$sandbox/claude.log" "arg=literal-prompt"

  for flag in --model --fallback-model --settings --setting-sources --permission-mode; do
    rm -f "$sandbox/claude.log"
    if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" "$flag" hostile \
      >/dev/null 2>&1; then
      fail "claudex accepted managed split option: $flag"
    fi
    [[ ! -e "$sandbox/claude.log" ]] || fail "rejected option still invoked Claude"
    if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" "$flag=hostile" \
      >/dev/null 2>&1; then
      fail "claudex accepted managed attached option: $flag"
    fi
  done

  # --effort is user-adjustable within the validated whitelist; the wrapper consumes the
  # argument and re-owns both the environment value and the single CLI occurrence.
  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDE_CODE_EFFORT_LEVEL=low \
    "$wrapper" --effort xhigh -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex --effort xhigh did not reach Claude"
  assert_file_contains "$sandbox/claude.log" "effort_level=xhigh"
  assert_file_contains "$sandbox/claude.log" "arg=xhigh"

  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    "$wrapper" --effort=medium -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex --effort=medium did not reach Claude"
  assert_file_contains "$sandbox/claude.log" "effort_level=medium"

  # ultra is argv-invalid on the pinned CLI (warn-then-ignore), so the wrapper must ship it
  # via the environment value only and omit the --effort argv pair entirely.
  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    "$wrapper" --effort ultra -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex --effort ultra did not reach Claude"
  assert_file_contains "$sandbox/claude.log" "effort_level=ultra"
  if grep -q '^arg=--effort$' "$sandbox/claude.log"; then
    fail "claudex passed argv --effort for ultra despite the pinned CLI rejecting it"
  fi

  for bad_effort in "--effort" "--effort=hostile"; do
    rm -f "$sandbox/claude.log"
    if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" $bad_effort \
      >/dev/null 2>&1; then
      fail "claudex accepted invalid effort usage: $bad_effort"
    fi
    [[ ! -e "$sandbox/claude.log" ]] || fail "invalid effort still invoked Claude"
  done
  rm -f "$sandbox/claude.log"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" --effort hostile \
    >/dev/null 2>&1; then
    fail "claudex accepted an invalid split effort level"
  fi
  [[ ! -e "$sandbox/claude.log" ]] || fail "invalid split effort still invoked Claude"

  # --fast selects the pinned fast wrapper-settings variant (service_tier=priority in the
  # wrapper-owned request body) while the inherited CLAUDE_CODE_EXTRA_BODY stays scrubbed.
  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDE_CODE_EXTRA_BODY='{"service_tier":"hostile"}' \
    "$wrapper" --fast -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex --fast did not reach Claude"
  assert_file_contains "$sandbox/claude.log" "extra_body=unset"
  assert_file_contains "$sandbox/claude.log" "effort_level=high"
  settings_arg="$(awk '/^arg=--settings$/ { getline; sub(/^arg=/, ""); print; exit }' "$sandbox/claude.log")"
  [[ "$settings_arg" == "$wrapper_settings_fast" ]] \
    || fail "claudex --fast did not pass the fast wrapper-owned settings file"
  jq -e '(.env.CLAUDE_CODE_EXTRA_BODY | fromjson) == {service_tier: "priority"}
    and (.env | keys == ["CLAUDE_CODE_EXTRA_BODY"])' \
    "$settings_arg" >/dev/null \
    || fail "fast wrapper-owned settings did not pin service_tier=priority"

  # --fast composes with --effort; both wrapper-owned values are re-issued together.
  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    "$wrapper" --fast --effort low -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex --fast --effort low did not reach Claude"
  assert_file_contains "$sandbox/claude.log" "effort_level=low"
  settings_arg="$(awk '/^arg=--settings$/ { getline; sub(/^arg=/, ""); print; exit }' "$sandbox/claude.log")"
  [[ "$settings_arg" == "$wrapper_settings_fast" ]] \
    || fail "claudex --fast --effort low did not keep the fast settings variant"

  # --fast is a boolean session flag; attached values are rejected with the wrapper's
  # managed-option contract exit code 2 before Claude runs.
  for flag in "--fast=true" "--fast=priority"; do
    rm -f "$sandbox/claude.log"
    set +e
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" "$flag" \
      >/dev/null 2>&1
    rc=$?
    set -e
    [[ "$rc" == "2" ]] \
      || fail "claudex returned $rc instead of exit 2 for: $flag"
    [[ ! -e "$sandbox/claude.log" ]] || fail "rejected fast flag still invoked Claude"
  done
}

test_claudex_launcher_and_login_use_fake_boundaries() {
  local sandbox state launcher login proxy_log jq_bin expected_work rc
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  launcher="$sandbox/generated/claudex-proxy-launcher"
  login="$sandbox/generated/claudex-login"
  proxy_log="$sandbox/proxy.log"
  jq_bin="$(command -v jq)"
  _claudex_fixture "$sandbox"

  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_LOCKF="$sandbox/fake-lockf" \
    "$launcher" --prepare-only
  [[ ! -e "$proxy_log" ]] || fail "--prepare-only invoked the proxy"
  _claudex_add_valid_credential "$state"

  cat > "$sandbox/fake-cli-proxy-api" <<EOF
#!/usr/bin/env bash
printf 'cwd=%s\n' "\$PWD" > "$proxy_log"
printf 'home_jwt=%s\n' "\${HOME_JWT-unset}" >> "$proxy_log"
printf 'pgstore_dsn=%s\n' "\${PGSTORE_DSN-unset}" >> "$proxy_log"
printf 'deploy=%s\n' "\${DEPLOY-unset}" >> "$proxy_log"
printf 'arg=%s\n' "\$@" >> "$proxy_log"
exit 17
EOF
  chmod +x "$sandbox/fake-cli-proxy-api"
  _claudex_materialize_command \
    "$REPO_ROOT/modules/shared/programs/claudex/files/claudex-proxy-launcher.sh" \
    "$launcher" "$sandbox/generated/claudex-runtime.sh" \
    "$sandbox/fake-cli-proxy-api" "$sandbox/generated/config-template.json" \
    "$sandbox/generated/wrapper-settings.json"
  chmod +x "$launcher"

  mkdir -p "$sandbox/caller"
  printf '%s' 'PGSTORE_DSN=from-dotenv' > "$sandbox/caller/.env"
  set +e
  (
    cd "$sandbox/caller"
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_LOCKF="$sandbox/fake-lockf" \
      HOME_JWT=hostile PGSTORE_DSN=hostile DEPLOY=hostile "$launcher"
  )
  rc=$?
  set -e
  [[ "$rc" == "17" ]] || fail "proxy launcher did not preserve fake proxy exit status"
  expected_work="$(cd "$state/work" && pwd -P)"
  assert_file_contains "$proxy_log" "cwd=$expected_work"
  assert_file_contains "$proxy_log" "home_jwt=unset"
  assert_file_contains "$proxy_log" "pgstore_dsn=unset"
  assert_file_contains "$proxy_log" "deploy=unset"
  assert_file_contains "$proxy_log" "arg=--config"
  assert_file_contains "$proxy_log" "arg=$state/config.yaml"
  assert_file_contains "$proxy_log" "arg=--local-model"

  rm -f "$proxy_log"
  : > "$state/work/.env"
  set +e
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_LOCKF="$sandbox/fake-lockf" "$launcher" \
    >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "proxy launcher accepted .env in its fixed work directory"
  [[ ! -e "$proxy_log" ]] || fail "work-dir .env rejection still invoked the proxy"
  rm "$state/work/.env"

  # Re-materialize login against a fake device flow that writes only to the staged auth-dir.
  rm -rf "$state"
  cat > "$sandbox/fake-cli-proxy-api" <<EOF
#!/usr/bin/env bash
printf 'arg=%s\n' "\$@" > "$proxy_log"
config=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--config' ]; then config="\$2"; shift 2; else shift; fi
done
auth_dir="\$("$jq_bin" -r '.["auth-dir"]' "\$config")"
mkdir -p "\$auth_dir"
chmod 700 "\$auth_dir"
printf '%s' '{"type":"codex","access_token":"stage-access","refresh_token":"stage-refresh"}' > "\$auth_dir/codex-stage.json"
chmod 600 "\$auth_dir/codex-stage.json"
exit 0
EOF
  chmod +x "$sandbox/fake-cli-proxy-api"
  _claudex_materialize_command \
    "$REPO_ROOT/modules/shared/programs/claudex/files/claudex-login.sh" \
    "$login" "$sandbox/generated/claudex-runtime.sh" \
    "$sandbox/fake-cli-proxy-api" "$sandbox/generated/config-template.json" \
    "$sandbox/generated/wrapper-settings.json"
  chmod +x "$login"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_LOCKF="$sandbox/fake-lockf" "$login" \
    >/dev/null
  [[ "$(find "$state/auth" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == "1" ]] \
    || fail "device login did not promote exactly one credential"
  jq -e '.type == "codex" and .access_token == "stage-access" and .refresh_token == "stage-refresh"' \
    "$state/auth/codex-stage.json" >/dev/null || fail "promoted credential is invalid"
  assert_file_contains "$proxy_log" "arg=--codex-device-login"
  assert_file_contains "$proxy_log" "arg=--no-browser"
  assert_file_contains "$proxy_log" "arg=--local-model"
  if find "$state" -maxdepth 1 -name 'auth.login.*' | grep -q .; then
    fail "login staging directory leaked after promotion"
  fi
  rm -f "$proxy_log"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_LOCKF="$sandbox/fake-lockf" "$login" \
    >/dev/null
  [[ ! -e "$proxy_log" ]] || fail "existing canonical credential triggered another device login"
}

test_claudex_production_execution_boundaries() {
  local sandbox declared_home hostile_home state expected_work rc
  sandbox="$(new_sandbox)"
  declared_home="$sandbox/declared-home"
  hostile_home="$sandbox/hostile-home"
  state="$declared_home/Library/Application Support/claudex"
  _claudex_fixture "$sandbox"
  _claudex_production_fixture "$sandbox" "$declared_home"
  mkdir -p "$hostile_home/.local/bin"

  cat > "$declared_home/.local/bin/claude" <<EOF
#!/usr/bin/env bash
printf 'home=%s\n' "\$HOME" > "$sandbox/production-claude.log"
printf 'arg=%s\n' "\$@" >> "$sandbox/production-claude.log"
exit 0
EOF
  cat > "$hostile_home/.local/bin/claude" <<EOF
#!/usr/bin/env bash
: > "$sandbox/hostile-claude-ran"
exit 0
EOF
  chmod +x "$declared_home/.local/bin/claude" "$hostile_home/.local/bin/claude"

  HOME="$hostile_home" CLAUDEX_STATE_DIR="$sandbox/hostile-state" \
    "$sandbox/production/claudex-proxy-launcher" --prepare-only
  [[ -f "$state/client-api-key" ]] || fail "production launcher did not use the declared state path"
  [[ ! -e "$sandbox/hostile-state" ]] || fail "production launcher accepted inherited state path"
  _claudex_add_valid_credential "$state"

  HOME="$hostile_home" "$sandbox/production/claudex" -- harmless-prompt
  [[ ! -e "$sandbox/hostile-claude-ran" ]] || fail "production claudex executed hostile HOME's Claude"
  assert_file_contains "$sandbox/production-claude.log" "home=$declared_home"

  set +e
  HOME="$hostile_home" \
    HOME_JWT=hostile home_jwt=hostile \
    PGSTORE_DSN=hostile pgstore_dsn=hostile \
    GITSTORE_GIT_URL=hostile gitstore_git_url=hostile \
    OBJECTSTORE_SECRET_KEY=hostile objectstore_secret_key=hostile \
    DEPLOY=hostile deploy=hostile \
    "$sandbox/production/claudex-proxy-launcher"
  rc=$?
  set -e
  [[ "$rc" == 17 ]] || fail "production launcher did not preserve proxy status"
  expected_work="$(cd "$state/work" && pwd -P)"
  assert_file_contains "$sandbox/production-launcher.log" "home=$declared_home"
  assert_file_contains "$sandbox/production-launcher.log" "cwd=$expected_work"
  if grep -Eiq '^(HOME_JWT|home_jwt|PGSTORE_|pgstore_|GITSTORE_|gitstore_|OBJECTSTORE_|objectstore_|DEPLOY=|deploy=)' \
    "$sandbox/production-launcher.env"; then
    fail "production launcher leaked backend environment"
  fi

  rm -f "$state/auth/codex-test.json"
  HOME="$hostile_home" \
    HOME_JWT=hostile home_jwt=hostile \
    PGSTORE_DSN=hostile pgstore_dsn=hostile \
    GITSTORE_GIT_URL=hostile gitstore_git_url=hostile \
    OBJECTSTORE_SECRET_KEY=hostile objectstore_secret_key=hostile \
    DEPLOY=hostile deploy=hostile \
    "$sandbox/production/claudex-login" >/dev/null
  assert_file_contains "$sandbox/production-login.log" "home=$declared_home"
  [[ -f "$state/auth/codex-production.json" ]] || fail "production login did not use declared auth path"
  if grep -Eiq '^(HOME_JWT|home_jwt|PGSTORE_|pgstore_|GITSTORE_|gitstore_|OBJECTSTORE_|objectstore_|DEPLOY=|deploy=)' \
    "$sandbox/production-login.env"; then
    fail "production login leaked backend environment"
  fi
}

test_claudex_status_is_sanitized() {
  local sandbox state status output expected rc
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  status="$sandbox/generated/claudex-status"
  _claudex_fixture "$sandbox"
  _claudex_prepare_fixture_state "$sandbox"
  _claudex_add_valid_credential "$state"
  _claudex_make_ready_curl "$sandbox"

  cat > "$sandbox/fake-launchctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$sandbox/launchctl.argv"
if [ "\$1" = print ]; then
  exit "\${CLAUDEX_FAKE_PRINT_RC:-0}"
fi
exit 0
EOF
  chmod +x "$sandbox/fake-launchctl"
  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    "$status")"
  expected=$'service=present\nauth=ready\nproxy=ready\ncatalog=ready'
  [[ "$output" == "$expected" ]] || fail "ready status output drifted: $output"

  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_FAKE_PRINT_RC=1 \
    "$status")"
  expected=$'service=missing\nauth=ready\nproxy=ready\ncatalog=ready'
  [[ "$output" == "$expected" ]] || fail "foreground-ready status output drifted: $output"

  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$status" --strict >/dev/null 2>&1; then
    fail "Stage 1 status accepted the removed --strict option"
  fi

  rm -rf "$state"
  set +e
  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_FAKE_PRINT_RC=1 \
    "$status" 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "missing status unexpectedly succeeded"
  [[ ! -e "$state" ]] || fail "status mutated missing state"
  assert_contains "$output" "auth=missing"
  assert_not_contains "$output" "test-access"
  assert_not_contains "$output" "test-refresh"

}

test_claudex_nix_generated_command_outputs_are_pinned() {
  local runtime_drv runtime_out path settings_path fast_settings_path
  runtime_drv="$(
    cd "$REPO_ROOT"
    nix eval --impure --raw --expr '
      let
        f = builtins.getFlake (toString ./.);
        fixture = import ./tests/fixtures/claudex-home.nix {
          flake = f;
          hostname = "greenhead-MacBookPro";
        };
      in
      builtins.head (builtins.attrNames (
        builtins.getContext (toString fixture.config.home.file.".local/bin/claudex".source)
      ))
    '
  )"
  runtime_out="$(nix build --no-link --print-out-paths "$runtime_drv^out")"

  for path in \
    "$runtime_out/bin/claudex" \
    "$runtime_out/bin/claudex-login" \
    "$runtime_out/bin/claudex-status" \
    "$runtime_out/libexec/claudex/claudex-proxy-launcher"; do
    [[ -x "$path" ]] || fail "Nix-generated command is not executable: $path"
    _claudex_assert_no_placeholders "$path"
    grep -Fq 'source "/nix/store/' "$path" \
      || fail "Nix-generated command does not source a store runtime: $path"
  done

  grep -Fq 'CLAUDEX_WRAPPER_SETTINGS="/nix/store/' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not reference store wrapper settings"
  grep -Fq -- '--settings "$CLAUDEX_WRAPPER_SETTINGS"' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not pass wrapper settings"
  settings_path="$(sed -n 's/^CLAUDEX_WRAPPER_SETTINGS="\(.*\)"$/\1/p' "$runtime_out/bin/claudex")"
  jq -e '.env.CLAUDE_CODE_EXTRA_BODY == "{}" and (.env | keys == ["CLAUDE_CODE_EXTRA_BODY"])' \
    "$settings_path" >/dev/null || fail "Nix-generated wrapper settings drifted"
  grep -Fq 'CLAUDEX_WRAPPER_SETTINGS_FAST="/nix/store/' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not reference store fast wrapper settings"
  fast_settings_path="$(sed -n 's/^CLAUDEX_WRAPPER_SETTINGS_FAST="\(.*\)"$/\1/p' "$runtime_out/bin/claudex")"
  jq -e '(.env.CLAUDE_CODE_EXTRA_BODY | fromjson) == {service_tier: "priority"}
    and (.env | keys == ["CLAUDE_CODE_EXTRA_BODY"])' \
    "$fast_settings_path" >/dev/null || fail "Nix-generated fast wrapper settings drifted"
  grep -Fq 'CLAUDEX_MAX_CONTEXT_TOKENS="258000"' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not pin the 258k context-window override"
  grep -Fq -- '--local-model' "$runtime_out/libexec/claudex/claudex-proxy-launcher" \
    || fail "Nix-generated proxy launcher does not pass --local-model"
  grep -Fq -- '--codex-device-login' "$runtime_out/bin/claudex-login" \
    || fail "Nix-generated login does not pass --codex-device-login"
}

test_claudex_release_layout_verifier() {
  local sandbox verifier exact entry
  sandbox="$(new_sandbox)"
  verifier="$REPO_ROOT/modules/shared/programs/claudex/files/verify-release-layout.sh"
  exact="$sandbox/exact"
  mkdir -p "$exact"
  for entry in LICENSE README.md README_CN.md cli-proxy-api config.example.yaml; do
    : > "$exact/$entry"
  done
  bash "$verifier" "$exact" || fail "exact CLIProxyAPI release layout was rejected"

  for entry in missing extra symlink directory; do
    rm -rf "$sandbox/candidate"
    cp -R "$exact" "$sandbox/candidate"
    case "$entry" in
      missing) rm "$sandbox/candidate/LICENSE" ;;
      extra) : > "$sandbox/candidate/EXTRA" ;;
      symlink)
        rm "$sandbox/candidate/LICENSE"
        ln -s README.md "$sandbox/candidate/LICENSE"
        ;;
      directory)
        rm "$sandbox/candidate/LICENSE"
        mkdir "$sandbox/candidate/LICENSE"
        ;;
    esac
    if bash "$verifier" "$sandbox/candidate" >/dev/null 2>&1; then
      fail "CLIProxyAPI release verifier accepted $entry layout drift"
    fi
  done
}

test_claudex_disabled_home_excludes_enabled_closure() {
  local activation_drv closure
  activation_drv="$(
    cd "$REPO_ROOT"
    nix eval --impure --raw --expr '
      let
        f = builtins.getFlake (toString ./.);
        fixture = import ./tests/fixtures/claudex-home.nix {
          flake = f;
          hostname = "claudex-disabled-fixture";
        };
      in
      fixture.activationPackage.drvPath
    '
  )"
  closure="$(nix-store -qR "$activation_drv")"
  grep -Fq 'claudex-runtime.sh' <<< "$closure" \
    || fail "disabled Claudex Home Manager closure omitted the shared runtime library"
  if grep -Eiq 'cli-?proxy-?api|claudex-runtime-stage1' <<< "$closure"; then
    fail "disabled Claudex Home Manager closure contains enabled-only artifacts"
  fi
}
