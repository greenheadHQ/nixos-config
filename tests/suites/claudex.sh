# tests/suites/claudex.sh — fixture coverage for the declarative Claudex runtime
# shellcheck shell=bash

# Single expected raw Codex catalog window for the wrapper-owned context override. The production
# source of truth is `maxContextTokens` in modules/shared/programs/claudex/default.nix, so
# the fixture substitution, fake-claude assert, and Nix-generated grep below all read this
# one constant to keep future catalog re-tunes atomic.
_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS=272000

# Role-split model expectations (production source of truth: runtimeContract in
# modules/shared/programs/claudex/default.nix). The default main and subagent models are
# currently the same id; keeping separate constants makes the role of each assertion
# explicit and future re-tunes atomic.
_CLAUDEX_EXPECTED_DEFAULT_MAIN_MODEL=gpt-5.6-sol
_CLAUDEX_EXPECTED_SUBAGENT_MODEL=gpt-5.6-sol
_CLAUDEX_EXPECTED_MIXED_MAIN_MODEL=claude-opus-4-8

# claudex-login과 claudex-proxy-launcher는 프록시를 `env -i ... PATH=/usr/bin:/bin:/usr/sbin:/sbin`
# 으로 실행해 상속 환경을 격리한다. NixOS에는 그 PATH에 bash가 없어 `#!/usr/bin/env bash` shebang이
# 해석되지 않으므로, 그 경계 아래서 실행되는 fake 프록시의 shebang만 절대 경로로 고정한다.
# production 프록시는 절대 store 경로의 바이너리라 PATH에 의존하지 않으며, 격리 계약(env -i와
# 제한된 PATH) 자체는 손대지 않으므로 테스트가 검증하는 경계는 그대로다.
# 함수 이름대로 shebang만 바꾼다: 조립은 임시 파일에서 하되 대상에는 truncate 후 덮어쓰기로
# 되돌려, 대상의 inode와 mode/권한을 보존한다. `mv`로 교체하면 임시 파일의 속성이 대상을
# 덮어써서, 이미 실행 비트가 설정된 파일에 적용할 경우 그 비트를 조용히 잃는다.
_claudex_pin_proxy_shebang() {
  local target="$1" tmp bash_bin
  bash_bin="$(command -v bash)"
  tmp="$(mktemp)"
  {
    printf '#!%s\n' "$bash_bin"
    tail -n +2 "$target"
  } > "$tmp"
  cat "$tmp" > "$target"
  rm -f "$tmp"
}

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
  local flock_bin="${CLAUDEX_FIXTURE_FLOCK_BIN:-/usr/bin/flock}"
  local launchctl_bin="${CLAUDEX_FIXTURE_LAUNCHCTL_BIN:-/bin/launchctl}"
  local bind_host="${CLAUDEX_FIXTURE_BIND_HOST:-127.0.0.1}"
  local port="${CLAUDEX_FIXTURE_PORT:-8317}"
  local default_main_model="${CLAUDEX_FIXTURE_DEFAULT_MAIN_MODEL:-$_CLAUDEX_EXPECTED_DEFAULT_MAIN_MODEL}"
  local subagent_model="${CLAUDEX_FIXTURE_SUBAGENT_MODEL:-$_CLAUDEX_EXPECTED_SUBAGENT_MODEL}"
  local mixed_main_model="${CLAUDEX_FIXTURE_MIXED_MAIN_MODEL:-$_CLAUDEX_EXPECTED_MIXED_MAIN_MODEL}"
  local label="${CLAUDEX_FIXTURE_LABEL:-org.nix-community.home.claudex-proxy}"
  local pprof_port="${CLAUDEX_FIXTURE_PPROF_PORT:-$((port - 1))}"
  local state_dir="${CLAUDEX_FIXTURE_STATE_DIR:-$declared_home/Library/Application Support/claudex}"
  local auth_dir="${CLAUDEX_FIXTURE_AUTH_DIR:-$state_dir/auth}"
  local config_file="${CLAUDEX_FIXTURE_CONFIG_FILE:-$state_dir/config.yaml}"
  local api_key_file="${CLAUDEX_FIXTURE_API_KEY_FILE:-$state_dir/client-api-key}"
  local state_lock="${CLAUDEX_FIXTURE_STATE_LOCK:-$state_dir/state.lock}"
  local lifecycle_lock="${CLAUDEX_FIXTURE_LIFECYCLE_LOCK:-$state_dir/lifecycle.lock}"
  local control_socket="${CLAUDEX_FIXTURE_CONTROL_SOCKET:-$state_dir/control.sock}"
  local log_file="${CLAUDEX_FIXTURE_LOG_FILE:-$state_dir/proxy.log}"
  local work_dir="${CLAUDEX_FIXTURE_WORK_DIR:-$state_dir/work}"
  local gate_bin="${CLAUDEX_FIXTURE_GATE_BIN:-$destination-gate}"
  local generation="${CLAUDEX_FIXTURE_GENERATION:-fixture-generation}"
  local platform="${CLAUDEX_FIXTURE_PLATFORM:-darwin}"
  local systemctl_bin="${CLAUDEX_FIXTURE_SYSTEMCTL_BIN:-$destination-systemctl}"

  sed \
    -e "s|@allowTestOverrides@|$allow_test_overrides|g" \
    -e "s|@bashBin@|$(command -v bash)|g" \
    -e "s|@homeDir@|$declared_home|g" \
    -e "s|@stateDir@|$state_dir|g" \
    -e "s|@authDir@|$auth_dir|g" \
    -e "s|@configFile@|$config_file|g" \
    -e "s|@apiKeyFile@|$api_key_file|g" \
    -e "s|@stateLock@|$state_lock|g" \
    -e "s|@lifecycleLock@|$lifecycle_lock|g" \
    -e "s|@controlSocket@|$control_socket|g" \
    -e "s|@logFile@|$log_file|g" \
    -e "s|@workDir@|$work_dir|g" \
    -e "s|@configTemplate@|$template|g" \
    -e "s|@jqBin@|$(command -v jq)|g" \
    -e "s|@curlBin@|$curl_bin|g" \
    -e "s|@opensslBin@|$(command -v openssl)|g" \
    -e "s|@cmpBin@|$(command -v cmp)|g" \
    -e "s|@cpBin@|$(command -v cp)|g" \
    -e "s|@statBin@|$(command -v stat)|g" \
    -e "s|@chmodBin@|$(command -v chmod)|g" \
    -e "s|@mkdirBin@|$(command -v mkdir)|g" \
    -e "s|@mktempBin@|$(command -v mktemp)|g" \
    -e "s|@mvBin@|$(command -v mv)|g" \
    -e "s|@rmBin@|$(command -v rm)|g" \
    -e "s|@sleepBin@|$(command -v sleep)|g" \
    -e "s|@envBin@|$(command -v env)|g" \
    -e "s|@idBin@|$(command -v id)|g" \
    -e "s|@flockBin@|$flock_bin|g" \
    -e "s|@launchctlBin@|$launchctl_bin|g" \
    -e "s|@systemctlBin@|$systemctl_bin|g" \
    -e "s|@gateBin@|$gate_bin|g" \
    -e "s|@generation@|$generation|g" \
    -e "s|@platform@|$platform|g" \
    -e "s|@bindHost@|$bind_host|g" \
    -e "s|@port@|$port|g" \
    -e "s|@defaultMainModel@|$default_main_model|g" \
    -e "s|@subagentModel@|$subagent_model|g" \
    -e "s|@mixedMainModel@|$mixed_main_model|g" \
    -e "s|@label@|$label|g" \
    -e "s|@pprofPort@|$pprof_port|g" \
    "$source" > "$destination"
  _claudex_assert_no_placeholders "$destination"
}

_claudex_materialize_command() {
  local source="$1" destination="$2" runtime="$3" proxy="$4" template="$5"
  local wrapper_settings="${6:-$template}"
  local wrapper_settings_fast="${7:-$wrapper_settings}"
  local command_dir
  command_dir="$(dirname "$destination")"

  sed \
    -e "s|@bashBin@|$(command -v bash)|g" \
    -e "s|@runtimeLibrary@|$runtime|g" \
    -e "s|@proxyBin@|$proxy|g" \
    -e "s|@configTemplate@|$template|g" \
    -e "s|@wrapperSettings@|$wrapper_settings|g" \
    -e "s|@wrapperSettingsFast@|$wrapper_settings_fast|g" \
    -e "s|@maxContextTokens@|$_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS|g" \
    -e "s|@loginHandler@|$command_dir/claudex-login|g" \
    -e "s|@statusHandler@|$command_dir/claudex-status|g" \
    -e "s|@proxyHandler@|$command_dir/claudex-proxy|g" \
    -e "s|@gateBin@|$command_dir/claudex-gate|g" \
    -e "s|@generation@|fixture-generation|g" \
    -e "s|@backendPort@|8318|g" \
    -e "s|@gracefulDrainSeconds@|30|g" \
    -e "s|@childStopSeconds@|10|g" \
    -e "s|@proxyLauncher@|$command_dir/claudex-proxy-launcher|g" \
    -e "s|@launchdPlist@|$command_dir/claudex-proxy.plist|g" \
    -e "s|@serviceName@|claudex-proxy.service|g" \
    -e "s|@tailBin@|$(command -v tail)|g" \
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
  cat > "$sandbox/fake-flock" <<'EOF'
#!/usr/bin/env bash
[ -z "${CLAUDEX_FAKE_LOCK_LOG:-}" ] || printf '%s\n' "$@" >> "$CLAUDEX_FAKE_LOCK_LOG"
[ "${CLAUDEX_FAKE_LOCK_FAIL:-0}" != 1 ] || exit 1
exit 0
EOF
  cat > "$fake_proxy" <<'EOF'
#!/usr/bin/env bash
exit 99
EOF
  cat > "$generated/claudex-gate" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
  : > "$generated/claudex-proxy.plist"
  _claudex_pin_proxy_shebang "$fake_proxy"
  chmod +x "$sandbox/fake-flock" "$fake_proxy" "$generated/claudex-gate"

  CLAUDEX_FIXTURE_GATE_BIN="$generated/claudex-gate" \
    _claudex_materialize_runtime \
      "$generated/claudex-runtime.sh" "$generated/config-template.json"
  local script
  for script in claudex-login claudex-status claudex-proxy-launcher claudex-proxy claudex; do
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
  local jq_bin sort_bin mkdir_bin chmod_bin
  jq_bin="$(command -v jq)"
  # 이 fake는 launcher/login이 `env -i ... PATH=/usr/bin:/bin:/usr/sbin:/sbin`으로 실행하므로
  # 본문이 PATH로 도구를 찾을 수 없다(NixOS에는 그 경로에 coreutils가 없다). jq와 같은 방식으로
  # 생성 시점에 절대 경로를 박아 넣어, 격리 계약을 완화하지 않고도 fake가 어디서든 동작하게 한다.
  # fake 안에서 PATH를 넓히지 않는 이유: 이 fake는 자신이 받은 env 스냅샷을 기록해 격리를
  # 증명하는데, PATH를 손대면 그 스냅샷이 오염되어 검증 대상 자체가 흐려진다.
  sort_bin="$(command -v sort)"
  mkdir_bin="$(command -v mkdir)"
  chmod_bin="$(command -v chmod)"
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
  env | "$sort_bin" > "$sandbox/production-login.env"
  printf 'home=%s\n' "\$HOME" > "$sandbox/production-login.log"
  printf 'arg=%s\n' "\${args[@]}" >> "$sandbox/production-login.log"
  auth_dir="\$("$jq_bin" -r '.["auth-dir"]' "\$config")"
  "$mkdir_bin" -p "\$auth_dir"
  "$chmod_bin" 700 "\$auth_dir"
  printf '%s' '{"type":"codex","access_token":"prod-access","refresh_token":"prod-refresh"}' > "\$auth_dir/codex-production.json"
  "$chmod_bin" 600 "\$auth_dir/codex-production.json"
  exit 0
fi
env | "$sort_bin" > "$sandbox/production-launcher.env"
printf 'home=%s\n' "\$HOME" > "$sandbox/production-launcher.log"
printf 'cwd=%s\n' "\$PWD" >> "$sandbox/production-launcher.log"
printf 'arg=%s\n' "\${args[@]}" >> "$sandbox/production-launcher.log"
exit 17
EOF
  _claudex_pin_proxy_shebang "$proxy"
  chmod +x "$curl_bin" "$launchctl_bin" "$proxy"
  ln -s "$proxy" "$generated/claudex-gate"

  CLAUDEX_FIXTURE_ALLOW_TEST_OVERRIDES=false \
    CLAUDEX_FIXTURE_DECLARED_HOME="$declared_home" \
    CLAUDEX_FIXTURE_CURL_BIN="$curl_bin" \
    CLAUDEX_FIXTURE_FLOCK_BIN="$sandbox/fake-flock" \
    CLAUDEX_FIXTURE_LAUNCHCTL_BIN="$launchctl_bin" \
    CLAUDEX_FIXTURE_GATE_BIN="$proxy" \
    _claudex_materialize_runtime "$runtime" "$sandbox/generated/config-template.json"
  local script
  for script in claudex-login claudex-status claudex-proxy-launcher claudex-proxy claudex; do
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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
  expected=$'assert_credential_set\ncredential_count\ncurl_loopback\nprepare_state\nwait_for_proxy_ready\nwith_lifecycle_lock\nwith_state_lock'
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
  if HOME="$symlink_home" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    bash -c 'source "$1"; prepare_state' _ "$runtime" >/dev/null 2>&1; then
    fail "prepare_state accepted a symlinked default-state ancestor"
  fi
  [[ ! -e "$sandbox/external-library/Application Support/claudex" ]] \
    || fail "symlinked state ancestor was followed"

  rm -rf "$sandbox/lock-failure"
  if HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$sandbox/lock-failure" \
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_FAKE_LOCK_LOG="$sandbox/flock.argv" \
    CLAUDEX_FAKE_LOCK_FAIL=1 \
    bash -c 'source "$1"; prepare_state' _ "$runtime" >/dev/null 2>&1; then
    fail "prepare_state continued after lock acquisition failed"
  fi
  grep -Fqx -- "-x" "$sandbox/flock.argv" || fail "flock must receive -x (exclusive lock)"
  grep -Fqx -- "-w" "$sandbox/flock.argv" || fail "flock must receive -w (lock timeout)"
  # -s is a *shared* lock in flock (it meant "silent" in the macOS lockf this replaced), so
  # passing it would silently downgrade the exclusive state-lock contract to a shared one.
  if grep -Fqx -- "-s" "$sandbox/flock.argv"; then
    fail "flock must never receive -s: that acquires a shared lock, not an exclusive one"
  fi
  assert_file_contains "$sandbox/flock.argv" "10"
  assert_file_contains "$sandbox/flock.argv" "9"
  [[ ! -e "$sandbox/lock-failure/client-api-key" ]] \
    || fail "lock failure still entered the state mutation callback"

  _claudex_prepare_fixture_state "$sandbox"
  [[ "$(_portable_file_mode "$state")" == "700" ]] || fail "claudex state mode must be 0700"
  [[ "$(_portable_file_mode "$state/auth")" == "700" ]] || fail "claudex auth mode must be 0700"
  [[ "$(_portable_file_mode "$state/work")" == "700" ]] || fail "claudex work mode must be 0700"
  [[ "$(_portable_file_mode "$state/client-api-key")" == "600" ]] || fail "claudex key mode must be 0600"
  [[ "$(_portable_file_mode "$state/config.yaml")" == "600" ]] || fail "claudex config mode must be 0600"
  [[ "$(_portable_file_mode "$state/state.lock")" == "600" ]] || fail "claudex lock mode must be 0600"
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

  # GNU stat %a prefixes a special-bit digit (setgid 0700 -> "2700") and GNU chmod 700
  # does not clear a directory's setgid bit, so the runtime cannot self-heal from one:
  # the mode check must accept special bits over a private triplet while still rejecting
  # any group/other access.
  chmod g+s "$state/auth"
  _claudex_prepare_fixture_state "$sandbox" \
    || fail "prepare_state rejected a setgid auth dir with a 700 triplet"
  chmod g-s "$state/auth"
  chmod 750 "$state/work"
  if _claudex_prepare_fixture_state "$sandbox" >/dev/null 2>&1; then
    fail "prepare_state accepted a group-readable work dir"
  fi
  chmod 700 "$state/work"

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
  [[ "$(_portable_file_mode "$state/config.yaml")" == "600" ]] \
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
    CLAUDEX_FIXTURE_DEFAULT_MAIN_MODEL=sentinel-default-main \
    CLAUDEX_FIXTURE_SUBAGENT_MODEL=sentinel-subagent \
    CLAUDEX_FIXTURE_MIXED_MAIN_MODEL=sentinel-mixed-main \
    CLAUDEX_FIXTURE_LABEL=org.example.claudex-sentinel \
    _claudex_materialize_runtime "$runtime" "$template"

  output="$(HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"
    printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n" \
      "$CLAUDEX_BIND_HOST" "$CLAUDEX_PORT" \
      "$CLAUDEX_DEFAULT_MAIN_MODEL" "$CLAUDEX_SUBAGENT_MODEL" "$CLAUDEX_MIXED_MAIN_MODEL" \
      "$CLAUDEX_LABEL" "$CLAUDEX_PPROF_ADDR" "$CLAUDEX_BASE_URL" "$CLAUDEX_NO_PROXY"
  ' _ "$runtime")"
  expected=$'127.0.0.42\n18317\nsentinel-default-main\nsentinel-subagent\nsentinel-mixed-main\norg.example.claudex-sentinel\n127.0.0.42:18316\nhttp://127.0.0.42:18317\n127.0.0.42,localhost'
  [[ "$output" == "$expected" ]] || fail "derived runtime contract drifted: $output"

  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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
    source "$1"; assert_credential_set "$CLAUDEX_AUTH_DIR" default
  ' _ "$runtime" || fail "valid Codex credential was rejected"

  # Set fingerprints are a fail-closed concurrency boundary. A non-private entry or
  # an individual credential digest failure must not be hidden by a successful final
  # set digest on the right side of the pipeline.
  chmod 644 "$state/auth/codex-test.json"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; _claudex_credential_set_fingerprint "$CLAUDEX_AUTH_DIR"
  ' _ "$runtime" >/dev/null 2>&1; then
    fail "credential set fingerprint accepted a non-private entry"
  fi
  chmod 600 "$state/auth/codex-test.json"

  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"
    _claudex_credential_fingerprint() { return 91; }
    _claudex_credential_set_fingerprint "$CLAUDEX_AUTH_DIR"
  ' _ "$runtime" >/dev/null 2>&1; then
    fail "credential set fingerprint hid an individual digest failure"
  fi

  printf '%s' '{"type":"claude","access_token":"secret","refresh_token":"secret"}' \
    > "$state/auth/codex-test.json"
  chmod 600 "$state/auth/codex-test.json"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_credential_set "$CLAUDEX_AUTH_DIR" default
  ' _ "$runtime" >/dev/null 2>&1; then
    fail "claude-only credential set was accepted without a codex credential"
  fi
  _claudex_add_valid_credential "$state"

  # Mixed-set contract: codex + claude coexistence is a valid default set, required for
  # mixed; a second claude entry or an unknown provider breaks both modes.
  printf '%s' '{"type":"claude","access_token":"claude-access","refresh_token":"claude-refresh"}' \
    > "$state/auth/claude-test.json"
  chmod 600 "$state/auth/claude-test.json"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_credential_set "$CLAUDEX_AUTH_DIR" default
  ' _ "$runtime" || fail "codex+claude coexistence was rejected in default mode"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_credential_set "$CLAUDEX_AUTH_DIR" mixed
  ' _ "$runtime" || fail "codex+claude coexistence was rejected in mixed mode"
  rm "$state/auth/claude-test.json"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_credential_set "$CLAUDEX_AUTH_DIR" mixed
  ' _ "$runtime" >/dev/null 2>&1; then
    fail "mixed mode accepted a set without a claude credential"
  fi
  printf '%s' '{"type":"gemini","access_token":"x","refresh_token":"y"}' \
    > "$state/auth/gemini-test.json"
  chmod 600 "$state/auth/gemini-test.json"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" bash -c '
    source "$1"; assert_credential_set "$CLAUDEX_AUTH_DIR" default
  ' _ "$runtime" >/dev/null 2>&1; then
    fail "unknown-provider credential was accepted"
  fi
  rm "$state/auth/gemini-test.json"

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
  printf 'compact_pct_override=%s\n' "\${CLAUDE_AUTOCOMPACT_PCT_OVERRIDE-unset}"
  printf 'blocking_limit_override=%s\n' "\${CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE-unset}"
  printf 'auto_compact_window=%s\n' "\${CLAUDE_CODE_AUTO_COMPACT_WINDOW-unset}"
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    ANTHROPIC_BASE_URL="https://hostile.invalid" \
    ANTHROPIC_API_KEY="hostile" \
    ANTHROPIC_AUTH_TOKEN="hostile" \
    ANTHROPIC_MODEL="hostile" \
    ANTHROPIC_UNIX_SOCKET="$sandbox/hostile.sock" \
    CLAUDE_CODE_EFFORT_LEVEL=low \
    CLAUDE_CODE_EXTRA_BODY='{"model":"hostile-model","max_tokens":7}' \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS=1 \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW=1 \
    CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=1 \
    CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE=1 \
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
  assert_file_contains "$sandbox/claude.log" "max_context=$_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS"
  assert_file_contains "$sandbox/claude.log" "compact_pct_override=unset"
  assert_file_contains "$sandbox/claude.log" "blocking_limit_override=unset"
  assert_file_contains "$sandbox/claude.log" "auto_compact_window=$_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS"
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
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

test_claudex_unified_cli_help_is_side_effect_free() {
  local sandbox wrapper output
  sandbox="$(new_sandbox)"
  wrapper="$sandbox/generated/claudex"
  _claudex_fixture "$sandbox"

  output="$(HOME="$sandbox/home" CLAUDEX_STATE_DIR="$sandbox/state" "$wrapper" --help)"
  assert_contains "$output" "claudex login [codex|claude] [--replace]"
  assert_contains "$output" "claudex status [--json]"
  assert_contains "$output" "claudex proxy start|foreground"
  [[ ! -e "$sandbox/state" ]] || fail "claudex --help mutated runtime state"

  output="$(HOME="$sandbox/home" CLAUDEX_STATE_DIR="$sandbox/state" "$wrapper" help)"
  assert_contains "$output" "claudex [세션 인자...]"
  [[ ! -e "$sandbox/state" ]] || fail "claudex help mutated runtime state"
}

test_claudex_unified_cli_routes_subcommands() {
  local sandbox wrapper handler rc
  sandbox="$(new_sandbox)"
  wrapper="$sandbox/generated/claudex"
  _claudex_fixture "$sandbox"

  for handler in claudex-login claudex-status claudex-proxy; do
    cat > "$sandbox/generated/$handler" <<EOF
#!/usr/bin/env bash
printf '%s\\n' '$handler '"\$*" >> "$sandbox/dispatch.log"
exit "\${CLAUDEX_HANDLER_EXIT:-0}"
EOF
    chmod +x "$sandbox/generated/$handler"
  done

  HOME="$sandbox/home" "$wrapper" login claude --replace
  HOME="$sandbox/home" "$wrapper" status --json
  HOME="$sandbox/home" "$wrapper" proxy stop --force

  assert_file_contains "$sandbox/dispatch.log" "claudex-login --claude --replace"
  assert_file_contains "$sandbox/dispatch.log" "claudex-status --json"
  assert_file_contains "$sandbox/dispatch.log" "claudex-proxy stop --force"

  set +e
  CLAUDEX_HANDLER_EXIT=37 HOME="$sandbox/home" "$wrapper" status >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" == "37" ]] || fail "claudex did not preserve a subcommand handler failure"
}

test_claudex_proxy_stop_reports_busy_requests() {
  local sandbox proxy output snapshot rc
  sandbox="$(new_sandbox)"
  proxy="$sandbox/generated/claudex-proxy"
  _claudex_fixture "$sandbox"

  cat > "$sandbox/busy-gate" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"ok":false,"code":"BUSY_REOPENED","message":"active requests remain; admission reopened"}'
exit 1
EOF
  cat > "$sandbox/fake-launchctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = print ]; then
  printf 'pid = 10\n'
fi
exit 0
EOF
  chmod +x "$sandbox/busy-gate" "$sandbox/fake-launchctl"
  snapshot="$(
    jq -cn \
      --arg gate "$sandbox/busy-gate" \
      --arg backend "$sandbox/fake-cli-proxy-api" \
      '{schema: 1, instance: "fixture", generation: "fixture-generation",
        mode: "managed", state: "open", accepting: true, active: 1,
        gate_pid: 10, gate_executable: $gate, backend_pid: 11,
        backend_executable: $backend}'
  )"

  set +e
  output="$(
    HOME="$sandbox/home" \
      CLAUDEX_STATE_DIR="$sandbox/state" \
      CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_GATE_BIN="$sandbox/busy-gate" \
      CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
      CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
      "$proxy" stop 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" != 0 ]] || fail "busy proxy stop unexpectedly succeeded"
  assert_contains "$output" "활성 요청이 있어 proxy를 중지하지 않았습니다"
  assert_contains "$output" "claudex proxy stop --force"
}

test_claudex_proxy_stop_reports_credential_recovery_failure() {
  local sandbox proxy output snapshot rc
  sandbox="$(new_sandbox)"
  proxy="$sandbox/generated/claudex-proxy"
  _claudex_fixture "$sandbox"

  cat > "$sandbox/recovery-failing-gate" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"ok":false,"code":"RECOVERY_FAILED","message":"credential recovery failed; operator action is required"}'
exit 1
EOF
  cat > "$sandbox/fake-launchctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = print ]; then
  printf 'pid = 10\n'
fi
exit 0
EOF
  chmod +x "$sandbox/recovery-failing-gate" "$sandbox/fake-launchctl"
  snapshot="$(
    jq -cn \
      --arg gate "$sandbox/recovery-failing-gate" \
      --arg backend "$sandbox/fake-cli-proxy-api" \
      '{schema: 1, instance: "fixture", generation: "fixture-generation",
        mode: "managed", state: "open", accepting: true, active: 0,
        gate_pid: 10, gate_executable: $gate, backend_pid: 11,
        backend_executable: $backend}'
  )"

  set +e
  output="$(
    HOME="$sandbox/home" \
      CLAUDEX_STATE_DIR="$sandbox/state" \
      CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_GATE_BIN="$sandbox/recovery-failing-gate" \
      CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
      CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
      "$proxy" stop 2>&1
  )"
  rc=$?
  set -e

  [[ "$rc" != 0 ]] || fail "credential recovery failure was reported as success"
  assert_contains "$output" "proxy는 중지됐지만 인증 파일 복구에 실패했습니다"
  assert_contains "$output" "claudex status"
}

test_claudex_managed_proxy_requires_manager_ownership() {
  local sandbox state proxy snapshot wrong_snapshot output rc
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  proxy="$sandbox/generated/claudex-proxy"
  _claudex_fixture "$sandbox"
  _claudex_prepare_fixture_state "$sandbox"
  _claudex_add_valid_credential "$state"
  _claudex_make_ready_curl "$sandbox"

  cat > "$sandbox/fake-launchctl" <<EOF
#!/usr/bin/env bash
if [ "\$1" = print ]; then
  printf 'path = %s\n' "$sandbox/generated/claudex-proxy.plist"
  printf 'pid = %s\n' "\${CLAUDEX_FAKE_MANAGER_PID:-0}"
fi
exit 0
EOF
  cat > "$sandbox/fake-systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"MainPID"*) printf '%s\n' "${CLAUDEX_FAKE_MANAGER_PID:-0}" ;;
  *"LoadState"*) printf 'loaded\n' ;;
esac
exit 0
EOF
  chmod +x "$sandbox/fake-launchctl" "$sandbox/fake-systemctl"
  snapshot="$(
    jq -cn \
      --arg gate "$sandbox/generated/claudex-gate" \
      --arg backend "$sandbox/fake-cli-proxy-api" \
      '{schema: 1, instance: "fixture", generation: "fixture-generation",
        mode: "managed", state: "open", accepting: true, active: 0,
        gate_pid: 10, gate_executable: $gate, backend_pid: 11,
        backend_executable: $backend}'
  )"

  set +e
  output="$(
    HOME="$sandbox/home" \
      CLAUDEX_STATE_DIR="$state" \
      CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/fake-curl" \
      CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
      CLAUDEX_FAKE_MANAGER_PID=99 \
      CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
      "$proxy" start 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "Darwin accepted a managed gate not owned by launchd"
  assert_contains "$output" "service identity를 확인할 수 없습니다"

  wrong_snapshot="$(
    jq -c '.gate_executable = "/nix/store/wrong/bin/claudex-gate"' <<< "$snapshot"
  )"
  set +e
  output="$(
    HOME="$sandbox/home" \
      CLAUDEX_STATE_DIR="$state" \
      CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/fake-curl" \
      CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
      CLAUDEX_FAKE_MANAGER_PID=10 \
      CLAUDEX_TEST_GATE_SNAPSHOT="$wrong_snapshot" \
      "$proxy" start 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "Darwin accepted a managed gate with an unexpected executable"
  assert_contains "$output" "service identity를 확인할 수 없습니다"

  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_FAKE_MANAGER_PID=10 \
    CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
    "$proxy" start

  set +e
  output="$(
    HOME="$sandbox/home" \
      CLAUDEX_STATE_DIR="$state" \
      CLAUDEX_PLATFORM=linux \
      CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/fake-curl" \
      CLAUDEX_SYSTEMCTL="$sandbox/fake-systemctl" \
      CLAUDEX_FAKE_MANAGER_PID=99 \
      CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
      "$proxy" start 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "Linux accepted a managed gate not owned by systemd"
  assert_contains "$output" "service identity를 확인할 수 없습니다"

  HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_PLATFORM=linux \
    CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_SYSTEMCTL="$sandbox/fake-systemctl" \
    CLAUDEX_FAKE_MANAGER_PID=10 \
    CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
    "$proxy" start
}

test_claudex_launchd_start_preserves_current_inactive_definition() {
  local sandbox runtime proxy log
  sandbox="$(new_sandbox)"
  runtime="$sandbox/generated/claudex-runtime.sh"
  proxy="$sandbox/generated/claudex-proxy"
  log="$sandbox/launchctl.log"
  _claudex_fixture "$sandbox"

  cat > "$sandbox/fake-launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDEX_FAKE_LAUNCHCTL_LOG"
if [ "$1" = print ]; then
  printf 'path = %s\n' "$CLAUDEX_FAKE_DEFINITION_PATH"
fi
exit 0
EOF
  chmod +x "$sandbox/fake-launchctl"

  : > "$log"
  HOME="$sandbox/home" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_FAKE_LAUNCHCTL_LOG="$log" \
    CLAUDEX_FAKE_DEFINITION_PATH="$sandbox/generated/claudex-proxy.plist" \
    bash -c '
      source "$1"
      source <(sed "/^command=/,\$d" "$2")
      _claudex_manager_start
    ' _ "$runtime" "$proxy"
  grep -Fq "kickstart " "$log" || fail "current launchd definition was not kickstarted"
  if grep -Eq '(^| )(bootout|bootstrap)( |$)' "$log"; then
    fail "current inactive launchd definition was unnecessarily replaced"
  fi

  : > "$log"
  HOME="$sandbox/home" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_FAKE_LAUNCHCTL_LOG="$log" \
    CLAUDEX_FAKE_DEFINITION_PATH="$sandbox/stale-claudex-proxy.plist" \
    bash -c '
      source "$1"
      source <(sed "/^command=/,\$d" "$2")
      _claudex_manager_start
    ' _ "$runtime" "$proxy"
  grep -Fq "bootout " "$log" || fail "stale launchd definition was not booted out"
  grep -Fq "bootstrap " "$log" || fail "current launchd definition was not bootstrapped"
  grep -Fq "kickstart " "$log" || fail "replacement launchd definition was not kickstarted"
}

test_claudex_mixed_mode_contract() {
  local sandbox state wrapper rc
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  wrapper="$sandbox/generated/claudex"
  _claudex_fixture "$sandbox"
  _claudex_prepare_fixture_state "$sandbox"
  _claudex_add_valid_credential "$state"

  # Mixed catalog fake: the mixed main model and the subagent model are both served.
  cat > "$sandbox/fake-curl" <<EOF
#!/usr/bin/env bash
IFS= read -r _header || true
printf '%s' '{"data":[{"id":"$_CLAUDEX_EXPECTED_SUBAGENT_MODEL"},{"id":"$_CLAUDEX_EXPECTED_MIXED_MAIN_MODEL"}]}'
EOF
  chmod +x "$sandbox/fake-curl"

  cat > "$sandbox/home/.local/bin/claude" <<EOF
#!/usr/bin/env bash
{
  printf 'subagent=%s\n' "\${CLAUDE_CODE_SUBAGENT_MODEL-unset}"
  printf 'max_context=%s\n' "\${CLAUDE_CODE_MAX_CONTEXT_TOKENS-unset}"
  printf 'auto_compact_window=%s\n' "\${CLAUDE_CODE_AUTO_COMPACT_WINDOW-unset}"
  printf 'arg=%s\n' "\$@"
} > "$sandbox/claude.log"
exit 23
EOF
  chmod +x "$sandbox/home/.local/bin/claude"

  # --mixed refuses to start without a claude credential (fail-closed, before exec).
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" "$wrapper" --mixed -- literal-prompt >/dev/null 2>&1; then
    fail "--mixed started without a claude credential"
  fi
  [[ ! -e "$sandbox/claude.log" ]] || fail "--mixed invoked Claude without a claude credential"

  printf '%s' '{"type":"claude","access_token":"claude-access","refresh_token":"claude-refresh"}' \
    > "$state/auth/claude-test.json"
  chmod 600 "$state/auth/claude-test.json"

  # Mixed happy path: Claude main model on argv, gpt subagent env, no auto-compact window.
  set +e
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" "$wrapper" --mixed -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "claudex --mixed did not reach Claude"
  assert_file_contains "$sandbox/claude.log" "subagent=$_CLAUDEX_EXPECTED_SUBAGENT_MODEL"
  assert_file_contains "$sandbox/claude.log" "max_context=$_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS"
  assert_file_contains "$sandbox/claude.log" "auto_compact_window=unset"
  assert_file_contains "$sandbox/claude.log" "arg=--model"
  assert_file_contains "$sandbox/claude.log" "arg=$_CLAUDEX_EXPECTED_MIXED_MAIN_MODEL"

  # Default mode keeps working with the coexisting claude credential and keeps its
  # auto-compact window export.
  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" "$wrapper" -- literal-prompt
  rc=$?
  set -e
  [[ "$rc" == "23" ]] || fail "default claudex did not run with a coexisting claude credential"
  assert_file_contains "$sandbox/claude.log" "arg=$_CLAUDEX_EXPECTED_DEFAULT_MAIN_MODEL"
  assert_file_contains "$sandbox/claude.log" "auto_compact_window=$_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS"

  # Managed-flag hygiene: --mixed is a boolean and combines with neither a value nor --fast.
  rm -f "$sandbox/claude.log"
  set +e
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" --mixed=1 >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" == "2" ]] || fail "--mixed=1 was not rejected with exit 2"
  set +e
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$wrapper" --mixed --fast >/dev/null 2>&1
  rc=$?
  set -e
  [[ "$rc" == "2" ]] || fail "--mixed --fast was not rejected with exit 2"
  [[ ! -e "$sandbox/claude.log" ]] || fail "rejected mixed combination still invoked Claude"

  # Mixed fails when the catalog lacks the mixed main model (subagent-only catalog).
  _claudex_make_ready_curl "$sandbox"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    CLAUDEX_CURL="$sandbox/fake-curl" "$wrapper" --mixed -- literal-prompt >/dev/null 2>&1; then
    fail "--mixed accepted a catalog without the mixed main model"
  fi
}

test_claudex_launcher_and_login_use_fake_boundaries() {
  local sandbox state launcher login proxy_log jq_bin output rc
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  launcher="$sandbox/generated/claudex-proxy-launcher"
  login="$sandbox/generated/claudex-login"
  proxy_log="$sandbox/proxy.log"
  jq_bin="$(command -v jq)"
  _claudex_fixture "$sandbox"

  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    "$launcher" --prepare-only
  [[ ! -e "$proxy_log" ]] || fail "--prepare-only invoked the proxy"
  _claudex_add_valid_credential "$state"

  cat > "$sandbox/generated/claudex-gate" <<EOF
#!/usr/bin/env bash
printf 'arg=%s\n' "\$@" >> "$proxy_log"
exit 17
EOF
  _claudex_pin_proxy_shebang "$sandbox/generated/claudex-gate"
  chmod +x "$sandbox/generated/claudex-gate"
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
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      HOME_JWT=hostile PGSTORE_DSN=hostile DEPLOY=hostile "$launcher" --managed
  )
  rc=$?
  set -e
  [[ "$rc" == "17" ]] || fail "proxy launcher did not preserve fake proxy exit status"
  assert_file_contains "$proxy_log" "arg=serve"
  assert_file_contains "$proxy_log" "arg=--mode"
  assert_file_contains "$proxy_log" "arg=managed"
  assert_file_contains "$proxy_log" "arg=--config"
  assert_file_contains "$proxy_log" "arg=$state/config.yaml"
  assert_file_contains "$proxy_log" "arg=--backend-bin"
  assert_file_contains "$proxy_log" "arg=$sandbox/fake-cli-proxy-api"

  rm -f "$proxy_log"
  : > "$state/work/.env"
  set +e
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" "$launcher" \
    --managed >/dev/null 2>&1
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
  _claudex_pin_proxy_shebang "$sandbox/fake-cli-proxy-api"
  chmod +x "$sandbox/fake-cli-proxy-api"
  _claudex_materialize_command \
    "$REPO_ROOT/modules/shared/programs/claudex/files/claudex-login.sh" \
    "$login" "$sandbox/generated/claudex-runtime.sh" \
    "$sandbox/fake-cli-proxy-api" "$sandbox/generated/config-template.json" \
    "$sandbox/generated/wrapper-settings.json"
  chmod +x "$login"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" "$login" \
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
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" "$login"
  )"
  [[ "$output" == "claudex login: canonical codex credential is present and schema-valid; live validity was not checked" ]] \
    || fail "existing codex credential was reported as live-ready: $output"
  [[ ! -e "$proxy_log" ]] || fail "existing canonical credential triggered another device login"

  # --claude adds the second provider credential next to the codex entry (mixed set).
  cat > "$sandbox/fake-cli-proxy-api" <<EOF
#!/usr/bin/env bash
printf 'arg=%s\n' "\$@" > "$proxy_log"
claude=false
config=''
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --claude-login) claude=true; shift ;;
    --config) config="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "\$claude" = true ] || exit 1
auth_dir="\$("$jq_bin" -r '.["auth-dir"]' "\$config")"
mkdir -p "\$auth_dir"
chmod 700 "\$auth_dir"
printf '%s' '{"type":"claude","access_token":"claude-access","refresh_token":"claude-refresh"}' > "\$auth_dir/claude-stage.json"
chmod 600 "\$auth_dir/claude-stage.json"
exit 0
EOF
  _claudex_pin_proxy_shebang "$sandbox/fake-cli-proxy-api"
  chmod +x "$sandbox/fake-cli-proxy-api"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    "$login" --claude >/dev/null
  assert_file_contains "$proxy_log" "arg=--claude-login"
  [[ "$(find "$state/auth" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == "2" ]] \
    || fail "claude login did not add the second credential next to the codex entry"
  jq -e '.type == "claude" and .access_token == "claude-access"' \
    "$state/auth/claude-stage.json" >/dev/null || fail "promoted claude credential is invalid"
  jq -e '.type == "codex"' "$state/auth/codex-stage.json" >/dev/null \
    || fail "claude login touched the canonical codex credential"

  # Both login paths are idempotent per credential type once their entry exists.
  rm -f "$proxy_log"
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      "$login" --claude
  )"
  [[ "$output" == "claudex login: canonical claude credential is present and schema-valid; live validity was not checked" ]] \
    || fail "existing claude credential was reported as live-ready: $output"
  [[ ! -e "$proxy_log" ]] || fail "existing claude credential triggered another claude login"
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" "$login"
  )"
  [[ "$output" == "claudex login: canonical codex credential is present and schema-valid; live validity was not checked" ]] \
    || fail "coexisting codex credential was reported as live-ready: $output"
  [[ ! -e "$proxy_log" ]] || fail "coexisting claude credential broke the no-arg login no-op"

  # Usage hygiene: unknown or extra arguments are rejected.
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$login" --claude extra >/dev/null 2>&1; then
    fail "claudex-login accepted extra arguments"
  fi
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$login" --hostile >/dev/null 2>&1; then
    fail "claudex-login accepted an unknown flag"
  fi

  # Claude-first login order: --claude into an EMPTY auth dir must promote cleanly
  # (codex-only and claude-only are legitimate mid-login states; the old full-set assert
  # made this path fail after the move).
  rm -rf "$state/auth"
  HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    "$login" --claude >/dev/null || fail "claude-first login into an empty auth dir failed"
  [[ "$(find "$state/auth" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == "1" ]] \
    || fail "claude-first login did not leave exactly one credential"
  jq -e '.type == "claude"' "$state/auth/claude-stage.json" >/dev/null \
    || fail "claude-first promoted credential is invalid"

  # A malformed sibling blocks both the ready short-circuit and promotion (no partial
  # promotion next to a poisoned set; no false ready that the session gate would reject).
  printf '%s' '{"type":"gemini","access_token":"x","refresh_token":"y"}' \
    > "$state/auth/gemini-bad.json"
  chmod 600 "$state/auth/gemini-bad.json"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    "$login" --claude >/dev/null 2>&1; then
    fail "login reported ready despite a malformed sibling entry"
  fi
  rm -f "$proxy_log"
  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
    "$login" >/dev/null 2>&1; then
    fail "codex login proceeded despite a malformed sibling entry"
  fi
  rm "$state/auth/gemini-bad.json"
}

test_claudex_login_replaces_one_provider_safely() {
  local sandbox state login proxy_log jq_bin output sibling_before codex_before backup_path
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  login="$sandbox/generated/claudex-login"
  proxy_log="$sandbox/proxy.log"
  jq_bin="$(command -v jq)"
  _claudex_fixture "$sandbox"
  cat > "$sandbox/no-proxy-curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$sandbox/no-proxy-curl"
  mkdir -p "$state/auth"
  chmod 700 "$state" "$state/auth"
  _claudex_add_valid_credential "$state"
  printf '%s' '{"type":"claude","access_token":"sibling-access","refresh_token":"sibling-refresh"}' \
    > "$state/auth/claude-sibling.json"
  chmod 600 "$state/auth/claude-sibling.json"
  sibling_before="$(sha256sum "$state/auth/claude-sibling.json")"

  cat > "$sandbox/fake-cli-proxy-api" <<EOF
#!/usr/bin/env bash
printf 'arg=%s\n' "\$@" > "$proxy_log"
config=''
cred_type=codex
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --config) config="\$2"; shift 2 ;;
    --claude-login) cred_type=claude; shift ;;
    *) shift ;;
  esac
done
auth_dir="\$("$jq_bin" -r '.["auth-dir"]' "\$config")"
mkdir -p "\$auth_dir"
chmod 700 "\$auth_dir"
if [ "\$cred_type" = codex ]; then
  printf '%s' '{"type":"codex","access_token":"replacement-access","refresh_token":"replacement-refresh"}'
else
  printf '%s' '{"type":"claude","access_token":"replacement-claude-access","refresh_token":"replacement-claude-refresh"}'
fi > "\$auth_dir/upstream-generated-name.json"
chmod 600 "\$auth_dir/upstream-generated-name.json"
printf '%s' 'Paste the callback URL if manual fallback is required: '
printf 'Saving credentials to %s\n' "\$auth_dir/upstream-generated-name.json"
printf 'Authentication saved to %s\n' "\$auth_dir/upstream-generated-name.json"
if [ "\$cred_type" = codex ]; then
  printf '%s\n' 'Codex device authentication successful!'
else
  printf '%s\n' 'Claude authentication successful!'
fi
EOF
  _claudex_pin_proxy_shebang "$sandbox/fake-cli-proxy-api"
  chmod +x "$sandbox/fake-cli-proxy-api"
  _claudex_materialize_command \
    "$REPO_ROOT/modules/shared/programs/claudex/files/claudex-login.sh" \
    "$login" "$sandbox/generated/claudex-runtime.sh" \
    "$sandbox/fake-cli-proxy-api" "$sandbox/generated/config-template.json" \
    "$sandbox/generated/wrapper-settings.json"
  chmod +x "$login"

  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/no-proxy-curl" \
      "$login" --replace 2>&1
  )"
  [[ "$output" == "claudex login: follow the codex OAuth instructions printed by CLIProxyAPI"$'\n'"Paste the callback URL if manual fallback is required: Saving credentials to [private login staging]"$'\n'"Authentication saved to [private login staging]"$'\n'"Codex device authentication successful!"$'\n'"claudex login: canonical codex credential was replaced and is schema-valid; live validity was not checked" ]] \
    || fail "Codex replacement output drifted or exposed private data: $output"
  assert_file_contains "$proxy_log" "arg=--codex-device-login"
  [[ -f "$state/auth/codex-test.json" ]] \
    || fail "Codex replacement did not preserve the canonical credential path"
  [[ ! -e "$state/auth/upstream-generated-name.json" ]] \
    || fail "Codex replacement adopted the staging filename and changed watcher identity"
  jq -e '.type == "codex" and .access_token == "replacement-access"' \
    "$state/auth/codex-test.json" >/dev/null || fail "Codex replacement was not promoted"
  [[ "$(sha256sum "$state/auth/claude-sibling.json")" == "$sibling_before" ]] \
    || fail "Codex replacement changed the Claude sibling"
  [[ "$(stat -c '%a' "$state/credential-backups")" == "700" ]] \
    || fail "credential backup directory is not private"
  backup_path="$(find "$state/credential-backups" -mindepth 1 -maxdepth 1 -type f -print -quit)"
  [[ -n "$backup_path" && "$(stat -c '%a' "$backup_path")" == "600" ]] \
    || fail "replaced Codex credential did not leave one private backup"
  jq -e '.type == "codex" and .access_token == "test-access"' "$backup_path" >/dev/null \
    || fail "Codex backup does not hold the pre-replacement credential"

  # The symmetric Claude path preserves the already-replaced Codex credential.
  codex_before="$(sha256sum "$state/auth/codex-test.json")"
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/no-proxy-curl" \
      "$login" --replace --claude 2>&1
  )"
  [[ "$output" == "claudex login: follow the claude OAuth instructions printed by CLIProxyAPI"$'\n'"Paste the callback URL if manual fallback is required: Saving credentials to [private login staging]"$'\n'"Authentication saved to [private login staging]"$'\n'"Claude authentication successful!"$'\n'"claudex login: canonical claude credential was replaced and is schema-valid; live validity was not checked" ]] \
    || fail "Claude replacement output drifted or exposed private data: $output"
  assert_file_contains "$proxy_log" "arg=--claude-login"
  [[ -f "$state/auth/claude-sibling.json" ]] \
    || fail "Claude replacement did not preserve the canonical credential path"
  jq -e '.type == "claude" and .access_token == "replacement-claude-access"' \
    "$state/auth/claude-sibling.json" >/dev/null || fail "Claude replacement was not promoted"
  [[ "$(sha256sum "$state/auth/codex-test.json")" == "$codex_before" ]] \
    || fail "Claude replacement changed the Codex sibling"
  [[ "$(find "$state/credential-backups" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == "2" ]] \
    || fail "provider replacements did not retain one backup per operation"
  find "$state/credential-backups" -mindepth 1 -maxdepth 1 -type f -exec \
    "$jq_bin" -e 'select(.type == "claude" and .access_token == "sibling-access")' {} + \
    >/dev/null || fail "Claude backup does not hold the pre-replacement credential"
  if find "$state" -maxdepth 1 -name 'auth.login.*' | grep -q .; then
    fail "replacement staging directory leaked after promotion"
  fi
}

test_claudex_login_replacement_fails_closed() {
  local sandbox state login jq_bin scenario output before after rc real_cp real_mv real_rm CLAUDEX_CURL
  sandbox="$(new_sandbox)"
  state="$sandbox/state"
  login="$sandbox/generated/claudex-login"
  jq_bin="$(command -v jq)"
  scenario="$sandbox/scenario"
  real_cp="$(command -v cp)"
  real_mv="$(command -v mv)"
  real_rm="$(command -v rm)"
  _claudex_fixture "$sandbox"
  cat > "$sandbox/no-proxy-curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$sandbox/no-proxy-curl"
  CLAUDEX_CURL="$sandbox/no-proxy-curl"
  export CLAUDEX_CURL
  mkdir -p "$state/auth"
  chmod 700 "$state" "$state/auth"

  _reset_replacement_credentials() {
    rm -rf "$state/auth" "$state/credential-backups"
    mkdir -p "$state/auth"
    chmod 700 "$state/auth"
    printf '%s' '{"type":"codex","access_token":"original-secret-access","refresh_token":"original-secret-refresh"}' \
      > "$state/auth/private-codex-account.json"
    printf '%s' '{"type":"claude","access_token":"sibling-secret-access","refresh_token":"sibling-secret-refresh"}' \
      > "$state/auth/private-claude-account.json"
    chmod 600 "$state/auth/"*.json
  }

  _canonical_digest() {
    find "$state/auth" -mindepth 1 -maxdepth 1 -type f -exec sha256sum {} + | sort
  }

  _assert_login_args_rejected() {
    if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$login" "$@" >/dev/null 2>&1; then
      fail "claudex-login accepted hostile argv: $*"
    fi
  }

  cat > "$sandbox/fake-cli-proxy-api" <<EOF
#!/usr/bin/env bash
config=''
while [ "\$#" -gt 0 ]; do
  if [ "\$1" = '--config' ]; then config="\$2"; shift 2; else shift; fi
done
case "\$(<"$scenario")" in
  oauth-fail) exit 19 ;;
esac
auth_dir="\$("$jq_bin" -r '.["auth-dir"]' "\$config")"
mkdir -p "\$auth_dir"
chmod 700 "\$auth_dir"
if [ "\$(<"$scenario")" = save-error ]; then
  printf 'failed to save credential: open %s: permission denied\n' \
    "\$auth_dir/private-staged-account.json" >&2
  exit 18
fi
case "\$(<"$scenario")" in
  invalid-stage | invalid-stage-mode)
    printf '%s' '{"type":"codex","access_token":"","refresh_token":"staged-secret-refresh"}' \
      > "\$auth_dir/private-staged-account.json"
    ;;
  *)
    printf '%s' '{"type":"codex","access_token":"staged-secret-access","refresh_token":"staged-secret-refresh"}' \
      > "\$auth_dir/private-staged-account.json"
    ;;
esac
chmod 600 "\$auth_dir/private-staged-account.json"
if [ "\$(<"$scenario")" = invalid-stage-mode ]; then
  printf '%s' '{"type":"codex","access_token":"staged-secret-access","refresh_token":"staged-secret-refresh"}' \
    > "\$auth_dir/private-staged-account.json"
  chmod 644 "\$auth_dir/private-staged-account.json"
fi
printf 'Authentication saved to %s\n' "\$auth_dir/private-staged-account.json"
case "\$(<"$scenario")" in
  concurrent-target)
    printf '%s' '{"type":"codex","access_token":"concurrent-secret-access","refresh_token":"concurrent-secret-refresh"}' \
      > "$state/auth/private-codex-account.json"
    chmod 600 "$state/auth/private-codex-account.json"
    ;;
  concurrent-sibling)
    printf '%s' '{"type":"claude","access_token":"concurrent-sibling-access","refresh_token":"concurrent-sibling-refresh"}' \
      > "$state/auth/private-claude-account.json"
    chmod 600 "$state/auth/private-claude-account.json"
    ;;
esac
EOF
  _claudex_pin_proxy_shebang "$sandbox/fake-cli-proxy-api"
  chmod +x "$sandbox/fake-cli-proxy-api"
  _claudex_materialize_command \
    "$REPO_ROOT/modules/shared/programs/claudex/files/claudex-login.sh" \
    "$login" "$sandbox/generated/claudex-runtime.sh" \
    "$sandbox/fake-cli-proxy-api" "$sandbox/generated/config-template.json" \
    "$sandbox/generated/wrapper-settings.json"
  chmod +x "$login"

  # Replacement refuses to start OAuth while a loopback proxy responds, because a
  # refresh already in flight could persist the old credential lineage afterward.
  cat > "$sandbox/responding-proxy-curl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$sandbox/responding-proxy-curl"
  _reset_replacement_credentials
  printf '%s' success > "$scenario"
  before="$(_canonical_digest)"
  if output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/responding-proxy-curl" "$login" --replace 2>&1
  )"; then
    fail "replacement started while the local proxy was responding"
  fi
  [[ "$(_canonical_digest)" == "$before" ]] \
    || fail "running-proxy rejection changed the canonical credential set"
  assert_contains "$output" "stop the local claudex proxy before replacing credentials"
  [[ -z "$(find "$state" -maxdepth 1 -name 'auth.login.*' -print -quit)" ]] \
    || fail "running-proxy rejection created a login staging directory"

  # A proxy that starts during OAuth is caught by the second probe under the
  # promotion state lock, before backup or canonical mutation.
  cat > "$sandbox/proxy-starts-during-oauth-curl" <<EOF
#!/usr/bin/env bash
count=0
if [ -f "$sandbox/curl-count" ]; then read -r count < "$sandbox/curl-count"; fi
count=\$((count + 1))
printf '%s' "\$count" > "$sandbox/curl-count"
if [ "\$count" -ge 2 ]; then exit 0; fi
exit 7
EOF
  chmod +x "$sandbox/proxy-starts-during-oauth-curl"
  _reset_replacement_credentials
  printf '%s' success > "$scenario"
  before="$(_canonical_digest)"
  if output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CURL="$sandbox/proxy-starts-during-oauth-curl" "$login" --replace 2>&1
  )"; then
    fail "replacement continued after the proxy started during OAuth"
  fi
  [[ "$(_canonical_digest)" == "$before" ]] \
    || fail "late proxy rejection changed the canonical credential set"
  [[ ! -d "$state/credential-backups" ]] \
    || fail "late proxy rejection created a credential backup"
  assert_contains "$output" "stop the local claudex proxy before replacing credentials"

  for scenario_name in oauth-fail save-error invalid-stage invalid-stage-mode; do
    _reset_replacement_credentials
    printf '%s' "$scenario_name" > "$scenario"
    before="$(_canonical_digest)"
    set +e
    output="$(
      HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
        "$login" --replace 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" != 0 ]] || fail "$scenario_name replacement unexpectedly succeeded"
    [[ "$(_canonical_digest)" == "$before" ]] \
      || fail "$scenario_name replacement changed the canonical credential set"
    assert_not_contains "$output" "secret-"
    assert_not_contains "$output" "private-"
  done

  # A canonical credential permission failure is generic and does not expose its
  # account-derived filename before OAuth starts.
  _reset_replacement_credentials
  chmod 644 "$state/auth/private-codex-account.json"
  if output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      "$login" --replace 2>&1
  )"; then
    fail "replacement accepted a non-private canonical credential"
  fi
  assert_not_contains "$output" "private-"

  # A valid concurrent mutation anywhere in the canonical set invalidates the snapshot.
  for scenario_name in concurrent-target concurrent-sibling; do
    _reset_replacement_credentials
    printf '%s' "$scenario_name" > "$scenario"
    set +e
    output="$(
      HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
        "$login" --replace 2>&1
    )"
    rc=$?
    set -e
    [[ "$rc" != 0 ]] || fail "$scenario_name mutation did not stop replacement"
    jq -e '.access_token != "staged-secret-access"' \
      "$state/auth/private-codex-account.json" >/dev/null \
      || fail "$scenario_name mutation was overwritten by the staged credential"
    assert_not_contains "$output" "secret-"
    assert_not_contains "$output" "private-"
  done

  # A non-cooperating writer that changes the target while the private backup is copied
  # is detected by the final pre-promotion snapshot check.
  _reset_replacement_credentials
  printf '%s' success > "$scenario"
  cat > "$sandbox/mutate-after-backup-cp" <<EOF
#!/usr/bin/env bash
"$real_cp" "\$@" || exit
printf '%s' '{"type":"codex","access_token":"post-backup-concurrent-access","refresh_token":"post-backup-concurrent-refresh"}' \
  > "$state/auth/private-codex-account.json"
chmod 600 "$state/auth/private-codex-account.json"
EOF
  chmod +x "$sandbox/mutate-after-backup-cp"
  set +e
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CP="$sandbox/mutate-after-backup-cp" "$login" --replace 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "post-backup canonical mutation did not stop replacement"
  jq -e '.access_token == "post-backup-concurrent-access"' \
    "$state/auth/private-codex-account.json" >/dev/null \
    || fail "post-backup concurrent credential was overwritten"
  [[ -z "$(find "$state/credential-backups" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]] \
    || fail "post-backup mutation retained a stale backup"
  assert_not_contains "$output" "private-"

  # Operand-bearing coreutils diagnostics are suppressed before a generic error is printed.
  _reset_replacement_credentials
  cat > "$sandbox/noisy-fail-cp" <<'EOF'
#!/usr/bin/env bash
printf 'cp operand=%s\n' "$@" >&2
exit 92
EOF
  chmod +x "$sandbox/noisy-fail-cp"
  set +e
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_CP="$sandbox/noisy-fail-cp" "$login" --replace 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "failed backup copy unexpectedly allowed replacement"
  assert_contains "$output" "failed to create the private credential backup"
  assert_not_contains "$output" "private-"

  # A failed atomic move leaves the canonical set byte-identical and no redundant backup.
  _reset_replacement_credentials
  printf '%s' success > "$scenario"
  cat > "$sandbox/fail-replacement-mv" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = "-f" ] && [[ "\${3-}" == *"/auth.login."*"/auth/"* ]]; then
  printf 'mv operand=%s\n' "\$@" >&2
  exit 91
fi
exec "$real_mv" "\$@"
EOF
  chmod +x "$sandbox/fail-replacement-mv"
  before="$(_canonical_digest)"
  set +e
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_MV="$sandbox/fail-replacement-mv" "$login" --replace 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 && "$(_canonical_digest)" == "$before" ]] \
    || fail "failed atomic replacement changed the canonical credential set"
  [[ -z "$(find "$state/credential-backups" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]] \
    || fail "failed atomic replacement retained a redundant backup"
  assert_not_contains "$output" "secret-"
  assert_not_contains "$output" "private-"

  # Corruption after the rename triggers automatic rollback from the verified backup.
  _reset_replacement_credentials
  cat > "$sandbox/corrupt-replacement-mv" <<EOF
#!/usr/bin/env bash
"$real_mv" "\$@" || exit
if [ "\${1-}" = "-f" ] && [[ "\${3-}" == *"/auth.login."*"/auth/"* ]]; then
  printf '%s' '{"type":"codex","access_token":"","refresh_token":""}' > "\${4}"
  chmod 600 "\${4}"
fi
EOF
  chmod +x "$sandbox/corrupt-replacement-mv"
  before="$(_canonical_digest)"
  set +e
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_MV="$sandbox/corrupt-replacement-mv" "$login" --replace 2>&1
  )"
  rc=$?
  set -e
  after="$(_canonical_digest)"
  [[ "$rc" != 0 && "$after" == "$before" ]] \
    || fail "post-rename validation failure did not restore the canonical credential set"
  assert_not_contains "$output" "secret-"
  assert_not_contains "$output" "private-"

  # Success is not reported until the private staging directory has been removed. A
  # path-bearing rm diagnostic is suppressed and replaced with a generic failure.
  _reset_replacement_credentials
  printf '%s' success > "$scenario"
  cat > "$sandbox/fail-staging-cleanup-rm" <<EOF
#!/usr/bin/env bash
if [ "\${1-}" = "-rf" ] && [[ "\${3-}" == *"/auth.login."* ]]; then
  printf 'rm operand=%s\n' "\$@" >&2
  exit 93
fi
exec "$real_rm" "\$@"
EOF
  chmod +x "$sandbox/fail-staging-cleanup-rm"
  set +e
  output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      CLAUDEX_RM="$sandbox/fail-staging-cleanup-rm" "$login" --replace 2>&1
  )"
  rc=$?
  set -e
  [[ "$rc" != 0 ]] || fail "replacement reported success after staging cleanup failed"
  jq -e '.access_token == "staged-secret-access"' \
    "$state/auth/private-codex-account.json" >/dev/null \
    || fail "staging cleanup failure obscured the completed replacement state"
  assert_contains "$output" "failed to remove the private login staging directory"
  assert_not_contains "$output" "auth.login."
  assert_not_contains "$output" "private-staged-account"

  # Missing providers, malformed/duplicate state, and hostile argv fail without OAuth or deletion.
  _reset_replacement_credentials
  rm "$state/auth/private-claude-account.json"
  if output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      "$login" --claude --replace 2>&1
  )"; then
    fail "replacement accepted a missing Claude credential"
  fi
  assert_contains "$output" "run claudex login claude first"
  assert_not_contains "$output" "private-"

  _assert_login_args_rejected --replace --replace
  _assert_login_args_rejected --claude --claude
  _assert_login_args_rejected --hostile
  _assert_login_args_rejected positional

  printf '%s' '{"type":"gemini","access_token":"malformed-secret-access","refresh_token":"malformed-secret-refresh"}' \
    > "$state/auth/private-malformed-account.json"
  chmod 600 "$state/auth/private-malformed-account.json"
  if output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      "$login" --replace 2>&1
  )"; then
    fail "replacement accepted a malformed canonical entry"
  fi
  assert_not_contains "$output" "secret-"
  assert_not_contains "$output" "private-"
  rm "$state/auth/private-malformed-account.json"

  cp "$state/auth/private-codex-account.json" "$state/auth/private-codex-duplicate.json"
  chmod 600 "$state/auth/private-codex-duplicate.json"
  if output="$(
    HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" CLAUDEX_FLOCK="$sandbox/fake-flock" \
      "$login" --replace 2>&1
  )"; then
    fail "replacement accepted duplicate Codex credentials"
  fi
  [[ "$(find "$state/auth" -mindepth 1 -maxdepth 1 -type f | wc -l | tr -d ' ')" == "2" ]] \
    || fail "duplicate rejection deleted a canonical credential"
  assert_not_contains "$output" "secret-"
  assert_not_contains "$output" "private-"
}

test_claudex_production_execution_boundaries() {
  local sandbox declared_home hostile_home state rc
  sandbox="$(new_sandbox)"
  declared_home="$sandbox/declared-home"
  hostile_home="$sandbox/hostile-home"
  state="$declared_home/Library/Application Support/claudex"
  _claudex_fixture "$sandbox"
  _claudex_production_fixture "$sandbox" "$declared_home"
  mkdir -p "$hostile_home/.local/bin"

  HOME="$hostile_home" CLAUDEX_STATE_DIR="$sandbox/hostile-state" \
    "$sandbox/production/claudex-proxy-launcher" --prepare-only
  [[ -f "$state/client-api-key" ]] || fail "production launcher did not use the declared state path"
  [[ ! -e "$sandbox/hostile-state" ]] || fail "production launcher accepted inherited state path"
  _claudex_add_valid_credential "$state"

  set +e
  HOME="$hostile_home" \
    HOME_JWT=hostile home_jwt=hostile \
    PGSTORE_DSN=hostile pgstore_dsn=hostile \
    GITSTORE_GIT_URL=hostile gitstore_git_url=hostile \
    OBJECTSTORE_SECRET_KEY=hostile objectstore_secret_key=hostile \
    DEPLOY=hostile deploy=hostile \
    "$sandbox/production/claudex-proxy-launcher" --managed
  rc=$?
  set -e
  [[ "$rc" == 17 ]] || fail "production launcher did not preserve proxy status"
  assert_file_contains "$sandbox/production-launcher.log" "arg=serve"
  assert_file_contains "$sandbox/production-launcher.log" "arg=--home"
  assert_file_contains "$sandbox/production-launcher.log" "arg=$declared_home"

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
  local sandbox state status output snapshot rc
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
  printf 'path = %s\n' "$sandbox/generated/claudex-proxy.plist"
  printf 'pid = 10\n'
  exit "\${CLAUDEX_FAKE_PRINT_RC:-0}"
fi
exit 0
EOF
  chmod +x "$sandbox/fake-launchctl"
  snapshot="$(
    jq -cn \
      --arg gate "$sandbox/generated/claudex-gate" \
      --arg backend "$sandbox/fake-cli-proxy-api" \
      '{schema: 1, instance: "fixture", generation: "fixture-generation",
        mode: "managed", state: "open", accepting: true, active: 0,
        gate_pid: 10, gate_executable: $gate, backend_pid: 11,
        backend_executable: $backend}'
  )"
  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
    "$status")"
  assert_contains "$output" "전체 상태: 준비됨"
  assert_contains "$output" "인증 파일: ready (upstream 실제 유효성은 확인하지 않음)"
  assert_contains "$output" "proxy: ready"
  assert_contains "$output" "서비스: registered"
  assert_not_contains "$output" "$state"
  assert_not_contains "$output" "test-access"
  assert_not_contains "$output" "test-refresh"

  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_CURL="$sandbox/fake-curl" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_TEST_GATE_SNAPSHOT="$snapshot" \
    "$status" --json)"
  jq -e '
    .schema == 1
    and .overall == "ready"
    and .auth == "ready"
    and .auth_live_validity == "unchecked"
    and .proxy == "ready"
    and .service == "registered"
    and .generation == "current"
  ' <<< "$output" >/dev/null || fail "status JSON contract drifted: $output"

  if HOME="$sandbox/home" CLAUDEX_STATE_DIR="$state" "$status" --strict >/dev/null 2>&1; then
    fail "status accepted the unsupported --strict option"
  fi

  cat > "$sandbox/failing-curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
  chmod +x "$sandbox/failing-curl"
  rm -rf "$state"
  set +e
  output="$(HOME="$sandbox/home" \
    CLAUDEX_STATE_DIR="$state" \
    CLAUDEX_CURL="$sandbox/failing-curl" \
    CLAUDEX_LAUNCHCTL="$sandbox/fake-launchctl" \
    CLAUDEX_FAKE_PRINT_RC=1 \
    "$status" 2>/dev/null)"
  rc=$?
  set -e
  [[ "$rc" != "0" ]] || fail "missing status unexpectedly succeeded"
  [[ ! -e "$state" ]] || fail "status mutated missing state"
  assert_contains "$output" "인증 파일: missing"
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
    "$runtime_out/libexec/claudex/claudex-login" \
    "$runtime_out/libexec/claudex/claudex-status" \
    "$runtime_out/libexec/claudex/claudex-proxy" \
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
  grep -Fq "CLAUDEX_MAX_CONTEXT_TOKENS=\"$_CLAUDEX_EXPECTED_MAX_CONTEXT_TOKENS\"" "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not pin the expected context-window override"
  grep -Fq 'CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CLAUDEX_MAX_CONTEXT_TOKENS"' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not re-enable auto-compact via the env window channel"
  [[ ! -e "$runtime_out/bin/claudex-login" && ! -e "$runtime_out/bin/claudex-status" ]] \
    || fail "Nix-generated runtime retained legacy public Claudex commands"
  grep -Fq -- '--backend-bin' "$runtime_out/libexec/claudex/claudex-proxy-launcher" \
    || fail "Nix-generated proxy launcher does not pass the pinned backend to the gate"
  grep -Fq -- '--codex-device-login' "$runtime_out/libexec/claudex/claudex-login" \
    || fail "Nix-generated login does not pass --codex-device-login"
  grep -Fq -- '--claude-login' "$runtime_out/libexec/claudex/claudex-login" \
    || fail "Nix-generated login does not support --claude-login"
  grep -Fq 'CLAUDEX_LOGIN_HANDLER="/nix/store/' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not route to the internal login handler"
  grep -Fq 'CLAUDEX_PROXY_HANDLER="/nix/store/' "$runtime_out/bin/claudex" \
    || fail "Nix-generated claudex does not route to the internal proxy handler"
}

test_claudex_release_layout_verifier() {
  local sandbox verifier exact entry output
  sandbox="$(new_sandbox)"
  verifier="$REPO_ROOT/modules/shared/programs/claudex/files/verify-release-layout.sh"
  exact="$sandbox/exact"
  mkdir -p "$exact"
  for entry in LICENSE README.md README_CN.md cli-proxy-api config.example.yaml; do
    : > "$exact/$entry"
  done
  bash "$verifier" "$exact" || fail "exact CLIProxyAPI release layout was rejected"

  # extra(초과 항목) 케이스는 아래 진단 출력 테스트가 거부·메시지 계약을 함께 검증한다.
  for entry in missing symlink directory; do
    rm -rf "$sandbox/candidate"
    cp -R "$exact" "$sandbox/candidate"
    case "$entry" in
      missing) rm "$sandbox/candidate/LICENSE" ;;
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

  # A count mismatch must dump the actual entries so an upstream version bump is
  # diagnosable from the failure output alone.
  rm -rf "$sandbox/candidate"
  cp -R "$exact" "$sandbox/candidate"
  : > "$sandbox/candidate/EXTRA"
  if output="$(bash "$verifier" "$sandbox/candidate" 2>&1)"; then
    fail "CLIProxyAPI release verifier accepted an extra release entry"
  fi
  assert_contains "$output" "expected 5 entries, found 6"
  assert_contains "$output" "EXTRA"

  # Upstream 유래 파일명의 제어문자(개행·ESC)는 %q로 중화되어 로그를 위조할 수 없어야 한다.
  rm -rf "$sandbox/candidate"
  cp -R "$exact" "$sandbox/candidate"
  : > "$sandbox/candidate/$(printf 'EVIL\nFORGED')"
  if output="$(bash "$verifier" "$sandbox/candidate" 2>&1)"; then
    fail "CLIProxyAPI release verifier accepted a control-character entry"
  fi
  assert_contains "$output" "EVIL"
  if printf '%s\n' "$output" | grep -q '^FORGED'; then
    fail "control-character entry forged an independent log line"
  fi
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
