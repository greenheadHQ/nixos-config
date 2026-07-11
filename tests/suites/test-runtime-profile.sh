# tests/suites/test-runtime-profile.sh — pre-push runtime profile 계약 테스트 (sourced)
# shellcheck shell=bash
# shellcheck disable=SC2154  # REPO_ROOT는 aggregator가 제공한다.

# production command contract를 fake runtime fixture도 그대로 사용한다.
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/ai/test-runtime-profile.sh"

_test_runtime_profile_script() {
  printf '%s/scripts/ai/test-runtime-profile.sh' "$REPO_ROOT"
}

_test_runtime_profile_make_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test User"
  mkdir -p "$dir/libraries"
  printf '{"version": 7}\n' > "$dir/flake.lock"
  printf '{ outputs = _: { }; }\n' > "$dir/flake.nix"
  printf '{ pkgs }: { pythonWithTomlkit = pkgs.python3; }\n' > "$dir/libraries/python-runtimes.nix"
}

_test_runtime_profile_make_runtime() {
  local runtime="$1"
  local command_name
  mkdir -p "$runtime/bin"
  while IFS= read -r command_name; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$runtime/bin/$command_name"
    chmod +x "$runtime/bin/$command_name"
  done < <(test_runtime_profile_required_commands)
}

_test_runtime_profile_make_fake_nix() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action="${1:-}"
shift || true
case "$action" in
  build)
    out_link=""
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --out-link)
          out_link="$2"
          shift 2
          ;;
        *) shift ;;
      esac
    done
    [ -n "$out_link" ] || exit 91
    [ -z "${FAKE_NIX_FAIL:-}" ] || exit 92
    [ -z "${FAKE_NIX_SLEEP:-}" ] || sleep "$FAKE_NIX_SLEEP"
    printf 'build\n' >> "$FAKE_NIX_LOG"
    rm -f "$out_link"
    ln -s "$FAKE_RUNTIME" "$out_link"
    ;;
  shell)
    printf 'shell\n' >> "$FAKE_NIX_LOG"
    while [ "$#" -gt 0 ] && [ "$1" != "--command" ]; do shift; done
    [ "${1:-}" = "--command" ] || exit 93
    shift
    exec "$@"
    ;;
  *) exit 94 ;;
esac
EOF
  chmod +x "$bin_dir/nix"
}

_test_runtime_profile_expect_prepare_failure() {
  local dir="$1" runtime="$2" fake_bin="$3" log="$4" expected="$5"
  local output status
  set +e
  output="$(PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" \
    timeout 5 bash "$(_test_runtime_profile_script)" prepare "$dir" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "unsafe profile path unexpectedly succeeded"
  [ "$status" -ne 124 ] || fail "unsafe profile path blocked instead of failing fast"
  assert_contains "$output" "$expected"
}

test_runtime_profile_build_cache_and_content_invalidation() (
  local dir runtime fake_bin log script
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-runtime-profile.XXXXXX")"
  trap 'rm -rf "$dir"' EXIT
  runtime="$dir/runtime"
  fake_bin="$dir/fake-bin"
  log="$dir/nix.log"
  script="$(_test_runtime_profile_script)"
  _test_runtime_profile_make_repo "$dir"
  _test_runtime_profile_make_runtime "$runtime"
  _test_runtime_profile_make_fake_nix "$fake_bin"
  : > "$log"

  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  [ "$(wc -l < "$log" | tr -d ' ')" = "1" ] || fail "initial profile build must invoke nix once"
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  [ "$(wc -l < "$log" | tr -d ' ')" = "1" ] || fail "current profile must be a cache hit"

  printf '{"version": 8}\n' > "$dir/flake.lock"
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  [ "$(wc -l < "$log" | tr -d ' ')" = "2" ] || fail "flake.lock content change must rebuild"

  printf '{ pkgs }: { pythonWithTomlkit = pkgs.python311; }\n' > "$dir/libraries/python-runtimes.nix"
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  [ "$(wc -l < "$log" | tr -d ' ')" = "3" ] || fail "runtime definition content change must rebuild"
)

test_runtime_profile_failed_rebuild_preserves_last_good() (
  local dir runtime_one runtime_two fake_bin log script old_target old_stamp status
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-runtime-profile-fail.XXXXXX")"
  trap 'rm -rf "$dir"' EXIT
  runtime_one="$dir/runtime-one"
  runtime_two="$dir/runtime-two"
  fake_bin="$dir/fake-bin"
  log="$dir/nix.log"
  script="$(_test_runtime_profile_script)"
  _test_runtime_profile_make_repo "$dir"
  _test_runtime_profile_make_runtime "$runtime_one"
  _test_runtime_profile_make_runtime "$runtime_two"
  _test_runtime_profile_make_fake_nix "$fake_bin"
  : > "$log"

  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime_one" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  old_target="$(readlink "$dir/.direnv/pre-push-runtime")"
  old_stamp="$(cat "$dir/.direnv/pre-push-runtime.stamp")"
  printf '# changed runtime definition\n' >> "$dir/flake.nix"
  set +e
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime_two" FAKE_NIX_LOG="$log" FAKE_NIX_FAIL=1 \
    bash "$script" prepare "$dir" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed nix build must fail prepare"
  [ "$(readlink "$dir/.direnv/pre-push-runtime")" = "$old_target" ] || fail "failed rebuild replaced last-good profile"
  [ "$(cat "$dir/.direnv/pre-push-runtime.stamp")" = "$old_stamp" ] || fail "failed rebuild replaced last-good stamp"

  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime_two" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  [ "$(readlink "$dir/.direnv/pre-push-runtime")" = "$runtime_two" ] || fail "retry did not publish rebuilt profile"
  [ "$(cat "$dir/.direnv/pre-push-runtime.stamp")" != "$old_stamp" ] || fail "retry did not publish new stamp"
)

test_runtime_profile_rejects_unsafe_lock_and_stamp_nodes() (
  local dir runtime fake_bin log common_dir lock_path stamp_path external_stamp
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-runtime-profile-paths.XXXXXX")"
  trap 'rm -rf "$dir"' EXIT
  runtime="$dir/runtime"
  fake_bin="$dir/fake-bin"
  log="$dir/nix.log"
  _test_runtime_profile_make_repo "$dir"
  _test_runtime_profile_make_runtime "$runtime"
  _test_runtime_profile_make_fake_nix "$fake_bin"
  : > "$log"

  common_dir="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir)"
  lock_path="$common_dir/info/pre-push-runtime.lock.d"
  mkdir -p "$common_dir/info" "$dir/external-lock"
  ln -s "$dir/external-lock" "$lock_path"
  _test_runtime_profile_expect_prepare_failure \
    "$dir" "$runtime" "$fake_bin" "$log" "refusing unsafe lock path"
  [ ! -s "$log" ] || fail "unsafe lock symlink invoked nix"

  rm -f "$lock_path"
  mkfifo "$lock_path"
  _test_runtime_profile_expect_prepare_failure \
    "$dir" "$runtime" "$fake_bin" "$log" "refusing unsafe lock path"
  [ ! -s "$log" ] || fail "unsafe lock FIFO invoked nix"

  rm -f "$lock_path"
  stamp_path="$dir/.direnv/pre-push-runtime.stamp"
  external_stamp="$dir/external-stamp"
  mkdir -p "$dir/.direnv"
  printf 'do-not-overwrite\n' > "$external_stamp"
  ln -s "$external_stamp" "$stamp_path"
  _test_runtime_profile_expect_prepare_failure \
    "$dir" "$runtime" "$fake_bin" "$log" "refusing unsafe stamp path"
  [ "$(cat "$external_stamp")" = "do-not-overwrite" ] || fail "unsafe stamp target was modified"
  [ ! -s "$log" ] || fail "unsafe stamp symlink invoked nix"
)

test_runtime_profile_concurrent_prepare_builds_once() (
  local dir runtime fake_bin log script first_pid second_pid
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-runtime-profile-race.XXXXXX")"
  trap 'rm -rf "$dir"' EXIT
  runtime="$dir/runtime"
  fake_bin="$dir/fake-bin"
  log="$dir/nix.log"
  script="$(_test_runtime_profile_script)"
  _test_runtime_profile_make_repo "$dir"
  _test_runtime_profile_make_runtime "$runtime"
  _test_runtime_profile_make_fake_nix "$fake_bin"
  : > "$log"

  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" FAKE_NIX_SLEEP=0.5 \
    bash "$script" prepare "$dir" &
  first_pid=$!
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" FAKE_NIX_SLEEP=0.5 \
    bash "$script" prepare "$dir" &
  second_pid=$!
  wait "$first_pid"
  wait "$second_pid"
  [ "$(wc -l < "$log" | tr -d ' ')" = "1" ] || fail "concurrent prepare must invoke nix exactly once"
)

test_runtime_profile_run_uses_current_and_falls_back_when_stale() (
  local dir canonical_dir runtime fake_bin log script output
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-runtime-profile-run.XXXXXX")"
  trap 'rm -rf "$dir"' EXIT
  runtime="$dir/runtime"
  fake_bin="$dir/fake-bin"
  log="$dir/nix.log"
  script="$(_test_runtime_profile_script)"
  _test_runtime_profile_make_repo "$dir"
  canonical_dir="$(git -C "$dir" rev-parse --show-toplevel)"
  _test_runtime_profile_make_runtime "$runtime"
  _test_runtime_profile_make_fake_nix "$fake_bin"
  mkdir -p "$dir/tmp"
  : > "$log"
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" bash "$script" prepare "$dir"
  : > "$log"

  output="$(PATH="$fake_bin:$PATH" TMPDIR="$dir/tmp/" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" \
    bash "$script" run "$dir" -- bash -c 'case "$TMPDIR" in */) exit 97;; esac; printf "%s|%s" "${PATH%%:*}" "${_TOMLKIT_BOOTSTRAP_READY:-}"')"
  [ "$output" = "$canonical_dir/.direnv/pre-push-runtime/bin|1" ] || fail "current profile was not activated: $output"
  [ ! -s "$log" ] || fail "current profile unexpectedly invoked nix"

  printf '# stale\n' >> "$dir/flake.nix"
  output="$(PATH="$fake_bin:$PATH" TMPDIR="$dir/tmp/" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" \
    bash "$script" run "$dir" -- bash -c 'printf "%s|%s" "$TMPDIR" "${_TOMLKIT_BOOTSTRAP_READY:-}"')"
  [ "$output" = "$dir/tmp|1" ] || fail "fallback TMPDIR/READY contract drifted: $output"
  [ "$(cat "$log")" = "shell" ] || fail "stale profile must use exactly one nix shell fallback"
)

test_tomlkit_bootstrap_uses_validated_snapshot_source_profile() (
  local dir source snapshot runtime fake_bin log script
  dir="$(mktemp -d "${TMPDIR:-/tmp}/test-runtime-profile-snapshot.XXXXXX")"
  trap 'rm -rf "$dir"' EXIT
  source="$dir/source"
  snapshot="$dir/snapshot"
  runtime="$dir/runtime"
  fake_bin="$dir/fake-bin"
  log="$dir/nix.log"
  script="$(_test_runtime_profile_script)"
  mkdir -p "$source" "$snapshot/scripts/ai/lib"
  _test_runtime_profile_make_repo "$source"
  _test_runtime_profile_make_runtime "$runtime"
  _test_runtime_profile_make_fake_nix "$fake_bin"
  cp "$REPO_ROOT/scripts/ai/test-runtime-profile.sh" "$snapshot/scripts/ai/test-runtime-profile.sh"
  cp "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh" "$snapshot/scripts/ai/lib/tomlkit-bootstrap.sh"
  : > "$snapshot/consumer.sh"
  : > "$log"
  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" bash "$script" prepare "$source"
  : > "$log"

  PATH="$fake_bin:$PATH" FAKE_RUNTIME="$runtime" FAKE_NIX_LOG="$log" \
    STAGED_SNAPSHOT_ROOT="$snapshot" STAGED_SNAPSHOT_SOURCE_ROOT="$source" \
    bash -c 'set -euo pipefail; source "$1/scripts/ai/lib/tomlkit-bootstrap.sh"; tomlkit_bootstrap_require "$1" "$1/consumer.sh"; test "${PATH%%:*}" = "$2/.direnv/pre-push-runtime/bin"' \
    _ "$snapshot" "$source"
  [ ! -s "$log" ] || fail "validated snapshot source profile unexpectedly invoked nix"
)
