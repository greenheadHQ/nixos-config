# shellcheck shell=bash
# shellcheck disable=SC2154  # The aggregator provides REPO_ROOT and assertions.

_cnp_fixture() {
  local sandbox="$1" source="$REPO_ROOT/scripts/ai/verify-ai-compat.sh"
  local target="$sandbox/home/.codex/packages/standalone/releases/test-release/bin/codex"
  assert_line_count "$source" '# BEGIN Codex executable path checks' 1
  assert_line_count "$source" '# END Codex executable path checks' 1
  mkdir -p "$(dirname "$target")" "$sandbox/home/.local/bin" "$sandbox/tools"
  cat > "$target" <<'EXECUTABLE'
#!/bin/sh
printf 'executed\n' > "$CNP_EXEC_MARKER"
exit 97
EXECUTABLE
  chmod +x "$target"
  ln -s releases/test-release "$sandbox/home/.codex/packages/standalone/current"
  ln -s "$target" "$sandbox/home/.local/bin/codex"
  cat > "$sandbox/tools/readlink" <<'READLINK'
#!/bin/sh
if [ "${CNP_LEGACY_NIX:-0}" = 1 ] && [ "$2" = "$HOME/.local/bin/codex" ]; then
  printf '/nix/store/00000000000000000000000000000000-codex-test/bin/codex\n'
else
  exec "$CNP_READLINK_BINARY" "$@"
fi
READLINK
  chmod +x "$sandbox/tools/readlink"
  {
    cat <<'PRELUDE'
set -euo pipefail
passes=0
warnings=0
errors=0
pass() { passes=$((passes + 1)); printf 'PASS %s\n' "$1"; }
warn() { warnings=$((warnings + 1)); printf 'WARN %s\n' "$1"; }
fail() { errors=$((errors + 1)); printf 'FAIL %s\n' "$1"; }
PRELUDE
    awk '/^# BEGIN Codex executable path checks$/ { copying = 1 }
      copying { print }
      /^# END Codex executable path checks$/ { exit }' "$source"
    printf 'printf "COUNTS %%s %%s %%s\\n" "$passes" "$warnings" "$errors"\n'
  } > "$sandbox/check.sh"
}

_cnp_run() {
  local sandbox="$1" test_shell="$2" lookup_dir="$3" readlink_binary
  readlink_binary="$(command -v readlink)"
  HOME="$sandbox/home" PATH="$lookup_dir:$sandbox/tools" \
    CNP_EXEC_MARKER="$sandbox/executed" CNP_READLINK_BINARY="$readlink_binary" \
    CNP_LEGACY_NIX="${cnp_legacy_nix:-0}" \
    "$test_shell" "$sandbox/check.sh"
}

_cnp_check_valid() {
  local test_shell="$1" sandbox mode output lookup_dir
  for mode in native relative direct app missing-path; do
    sandbox="$(new_sandbox)"
    _cnp_fixture "$sandbox"
    lookup_dir="$sandbox/home/.local/bin"
    case "$mode" in
      relative)
        rm "$lookup_dir/codex"
        ln -s ../../.codex/packages/standalone/current/bin/codex "$lookup_dir/codex"
        ;;
      direct) lookup_dir="$sandbox/home/.codex/packages/standalone/releases/test-release/bin" ;;
      app)
        lookup_dir="$sandbox/app/injectedCLI"
        mkdir -p "$lookup_dir"
        cp "$sandbox/home/.local/bin/codex" "$lookup_dir/codex"
        ;;
      missing-path) lookup_dir="$sandbox/absent" ;;
    esac
    output="$(_cnp_run "$sandbox" "$test_shell" "$lookup_dir")"
    assert_contains "$output" 'PASS Codex native installation is ready'
    case "$mode" in
      app)
        assert_contains "$output" "application's injectedCLI"
        assert_contains "$output" 'COUNTS 2 1 0'
        ;;
      missing-path)
        assert_contains "$output" 'not available on PATH'
        assert_contains "$output" 'COUNTS 2 1 0'
        ;;
      *) assert_contains "$output" 'COUNTS 3 0 0' ;;
    esac
    [[ ! -e "$sandbox/executed" ]] || fail 'path inspection executed the CLI'
    assert_not_contains "$output" "$sandbox"
  done
}

_cnp_check_shadowing() {
  local test_shell="$1" sandbox mode output lookup_dir cnp_legacy_nix
  for mode in shim node unknown legacy missing app-without-native; do
    sandbox="$(new_sandbox)"
    _cnp_fixture "$sandbox"
    cnp_legacy_nix=0
    case "$mode" in
      shim) lookup_dir="$sandbox/mise/shims" ;;
      node) lookup_dir="$sandbox/mise/installs/node/test/bin" ;;
      unknown) lookup_dir="$sandbox/unrecognized" ;;
      legacy)
        lookup_dir="$sandbox/home/.local/bin"
        cnp_legacy_nix=1
        ;;
      missing)
        rm "$sandbox/home/.local/bin/codex"
        lookup_dir="$sandbox/absent"
        ;;
      app-without-native)
        lookup_dir="$sandbox/app/injectedCLI"
        mkdir -p "$lookup_dir"
        cp "$sandbox/home/.local/bin/codex" "$lookup_dir/codex"
        rm "$sandbox/home/.local/bin/codex"
        ;;
    esac
    case "$mode" in
      shim|node)
        mkdir -p "$lookup_dir"
        ln -s "$sandbox/home/.local/bin/codex" "$lookup_dir/codex"
        ;;
      unknown)
        mkdir -p "$lookup_dir"
        cp "$sandbox/home/.local/bin/codex" "$lookup_dir/codex"
        ;;
    esac
    output="$(_cnp_run "$sandbox" "$test_shell" "$lookup_dir")"
    case "$mode" in
      shim) assert_contains "$output" 'FAIL Codex PATH selects a mise shim'; assert_contains "$output" 'COUNTS 2 0 1' ;;
      node) assert_contains "$output" 'FAIL Codex PATH selects a Node global'; assert_contains "$output" 'COUNTS 2 0 1' ;;
      unknown) assert_contains "$output" 'unrecognized installation'; assert_contains "$output" 'COUNTS 2 1 0' ;;
      legacy) assert_contains "$output" 'native migration is needed'; assert_contains "$output" 'COUNTS 1 2 0' ;;
      missing|app-without-native)
        assert_contains "$output" 'Codex native installation is missing'
        assert_contains "$output" 'COUNTS 1 2 0'
        assert_not_contains "$output" 'PASS Codex native installation'
        ;;
    esac
    [[ ! -e "$sandbox/executed" ]] || fail 'shadow inspection executed the CLI or shim'
    assert_not_contains "$output" "$sandbox"
  done
}

_cnp_check_invalid() {
  local test_shell="$1" sandbox mode output native target
  for mode in outside nonexecutable nested dangling regular current-outside; do
    sandbox="$(new_sandbox)"
    _cnp_fixture "$sandbox"
    native="$sandbox/home/.local/bin/codex"
    target="$sandbox/home/.codex/packages/standalone/releases/test-release/bin/codex"
    case "$mode" in
      outside)
        mkdir "$sandbox/outside"
        cp "$target" "$sandbox/outside/codex"
        rm "$native"
        ln -s "$sandbox/outside/codex" "$native"
        ;;
      nonexecutable) chmod -x "$target" ;;
      nested)
        mkdir -p "$sandbox/home/.codex/packages/standalone/releases/nested/extra/bin"
        cp "$target" "$sandbox/home/.codex/packages/standalone/releases/nested/extra/bin/codex"
        rm "$native"
        ln -s "$sandbox/home/.codex/packages/standalone/releases/nested/extra/bin/codex" "$native"
        ;;
      dangling) rm "$target" ;;
      regular) rm "$native"; cp "$target" "$native" ;;
      current-outside)
        mkdir -p "$sandbox/outside/bin"
        cp "$target" "$sandbox/outside/bin/codex"
        rm "$sandbox/home/.codex/packages/standalone/current"
        ln -s "$sandbox/outside" "$sandbox/home/.codex/packages/standalone/current"
        ;;
    esac
    output="$(_cnp_run "$sandbox" "$test_shell" "$sandbox/home/.local/bin")"
    assert_contains "$output" 'FAIL '
    if [[ "$mode" != current-outside ]]; then
      assert_not_contains "$output" 'PASS Codex native installation'
      assert_not_contains "$output" 'PASS Codex PATH selects an executable native release'
    else
      assert_contains "$output" 'FAIL Codex standalone current'
    fi
    [[ ! -e "$sandbox/executed" ]] || fail 'invalid-install inspection executed the CLI'
    assert_not_contains "$output" "$sandbox"
  done
}

test_codex_native_path_accepts_native_installation() {
  _cnp_check_valid "$BASH"
}

test_codex_native_path_reports_shadowing_without_execution() {
  _cnp_check_shadowing "$BASH"
}

test_codex_native_path_rejects_invalid_installations() {
  _cnp_check_invalid "$BASH"
}

test_codex_native_path_supports_system_bash32() {
  if [[ ! -x /bin/bash ]] || ! /bin/bash -c '[[ ${BASH_VERSINFO[0]} == 3 && ${BASH_VERSINFO[1]} == 2 ]]'; then
    echo 'N/A: system Bash 3.2 is unavailable' >&2
    return 0
  fi
  _cnp_check_valid /bin/bash
  _cnp_check_shadowing /bin/bash
  _cnp_check_invalid /bin/bash
}
