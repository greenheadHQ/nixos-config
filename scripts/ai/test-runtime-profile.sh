#!/usr/bin/env bash
# scripts/ai/test-runtime-profile.sh
#
# pre-push/통합 테스트가 공유하는 hermetic runtime GC-root 관리 모듈.
#
# `prepare`는 flake.lock + runtime 정의 content hash가 바뀔 때만 `.#prePushRuntime`을
# 다시 빌드한다. out-link는 worktree의 .direnv 아래에 두어 worktree 수명과 함께 정리하고,
# Git 공용 디렉토리 lock으로 여러 worktree/direnv의 동시 Nix eval을 직렬화한다.
#
# `run`은 current profile을 PATH에 올려 명령을 실행한다. profile이 없거나 stale이면 같은
# flake package를 `nix shell`로 실행해, 최적화가 준비되지 않은 fresh clone에서도 기존의
# hermetic fail-safe를 유지한다.

_TEST_RUNTIME_PROFILE_REQUIRED_COMMANDS=(
  python3
  touch
  find
  lsof
  lefthook
  bats
  pytest
)

test_runtime_profile_path() {
  printf '%s/.direnv/pre-push-runtime' "$1"
}

test_runtime_profile_stamp_path() {
  printf '%s/.direnv/pre-push-runtime.stamp' "$1"
}

test_runtime_profile_fingerprint() {
  local repo_root="$1"
  local path path_hash hashes=""
  for path in flake.lock flake.nix libraries/python-runtimes.nix; do
    [ -f "$repo_root/$path" ] || {
      echo "test-runtime-profile: stamp input missing: $repo_root/$path" >&2
      return 1
    }
    path_hash="$(git -C "$repo_root" hash-object -- "$path")" || return 1
    hashes="${hashes}${path_hash}"$'\n'
  done
  printf '%s' "$hashes" | git -C "$repo_root" hash-object --stdin
}

test_runtime_profile_validate() {
  local profile="$1"
  local command_name
  [ -L "$profile" ] && [ -d "$profile/bin" ] || return 1
  for command_name in "${_TEST_RUNTIME_PROFILE_REQUIRED_COMMANDS[@]}"; do
    [ -x "$profile/bin/$command_name" ] || return 1
  done
  "$profile/bin/python3" -c 'import tomlkit' >/dev/null 2>&1
}

test_runtime_profile_is_current() {
  local repo_root="$1"
  local profile stamp_file expected_stamp actual_stamp
  profile="$(test_runtime_profile_path "$repo_root")"
  stamp_file="$(test_runtime_profile_stamp_path "$repo_root")"
  [ -f "$stamp_file" ] || return 1
  expected_stamp="$(test_runtime_profile_fingerprint "$repo_root")" || return 1
  actual_stamp="$(cat "$stamp_file" 2>/dev/null)" || return 1
  [ "$actual_stamp" = "$expected_stamp" ] || return 1
  test_runtime_profile_validate "$profile"
}

test_runtime_profile_activate() {
  local repo_root="$1"
  local profile
  test_runtime_profile_is_current "$repo_root" || return 1
  profile="$(test_runtime_profile_path "$repo_root")"
  export PATH="$profile/bin:$PATH"
  export _TOMLKIT_BOOTSTRAP_READY=1
}

_test_runtime_profile_acquire_lock() {
  local repo_root="$1"
  local git_common_dir lock_file lock_dir timeout_seconds
  git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "test-runtime-profile: git common dir lookup failed: $repo_root" >&2
    return 1
  }
  lock_file="$git_common_dir/info/pre-push-runtime.lock"
  lock_dir="$(dirname "$lock_file")"
  [ -L "$lock_dir" ] && {
    echo "test-runtime-profile: refusing symlinked lock directory: $lock_dir" >&2
    return 1
  }
  mkdir -p "$lock_dir"
  timeout_seconds="${TEST_RUNTIME_PROFILE_LOCK_TIMEOUT_SECONDS:-120}"
  exec 201>"$lock_file"
  if command -v flock >/dev/null 2>&1; then
    flock --timeout "$timeout_seconds" 201 \
      || { echo "test-runtime-profile: lock timed out after ${timeout_seconds}s (flock)" >&2; return 1; }
  elif command -v lockf >/dev/null 2>&1; then
    lockf -s -t "$timeout_seconds" 201 \
      || { echo "test-runtime-profile: lock timed out after ${timeout_seconds}s (lockf)" >&2; return 1; }
  else
    echo "test-runtime-profile: neither flock nor lockf is available" >&2
    return 1
  fi
}

test_runtime_profile_prepare() (
  set -euo pipefail
  local repo_root="$1"
  local profile stamp_file expected_stamp stamp_tmp old_target=""

  repo_root="$(git -C "$repo_root" rev-parse --show-toplevel)"
  if test_runtime_profile_is_current "$repo_root"; then
    return 0
  fi

  _test_runtime_profile_acquire_lock "$repo_root"
  # 다른 direnv가 lock 대기 중 profile을 완성했으면 Nix를 다시 평가하지 않는다.
  if test_runtime_profile_is_current "$repo_root"; then
    return 0
  fi

  profile="$(test_runtime_profile_path "$repo_root")"
  stamp_file="$(test_runtime_profile_stamp_path "$repo_root")"
  [ -L "$repo_root/.direnv" ] && {
    echo "test-runtime-profile: refusing symlinked .direnv: $repo_root/.direnv" >&2
    return 1
  }
  mkdir -p "$repo_root/.direnv"
  expected_stamp="$(test_runtime_profile_fingerprint "$repo_root")"
  if [ -L "$profile" ]; then
    old_target="$(readlink "$profile")"
  fi

  if ! nix build --no-write-lock-file --out-link "$profile" "$repo_root#prePushRuntime"; then
    echo "test-runtime-profile: failed to build .#prePushRuntime" >&2
    return 1
  fi
  if ! test_runtime_profile_validate "$profile"; then
    rm -f "$profile"
    [ -n "$old_target" ] && ln -s "$old_target" "$profile"
    echo "test-runtime-profile: built profile is missing required commands" >&2
    return 1
  fi

  stamp_tmp="${stamp_file}.tmp.${BASHPID:-$$}"
  trap 'rm -f "$stamp_tmp"' EXIT
  printf '%s\n' "$expected_stamp" > "$stamp_tmp"
  mv -f "$stamp_tmp" "$stamp_file"
  trap - EXIT
)

test_runtime_profile_run() {
  local repo_root="$1"
  shift
  [ "${1:-}" = "--" ] || {
    echo "test-runtime-profile: run requires -- before the command" >&2
    return 2
  }
  shift
  [ "$#" -gt 0 ] || {
    echo "test-runtime-profile: run command is required" >&2
    return 2
  }
  repo_root="$(git -C "$repo_root" rev-parse --show-toplevel)" || return 1
  if test_runtime_profile_activate "$repo_root"; then
    exec "$@"
  fi
  command -v nix >/dev/null 2>&1 || {
    echo "test-runtime-profile: current profile and nix are both unavailable" >&2
    return 1
  }
  echo "test-runtime-profile: current profile unavailable; using nix shell fallback" >&2
  export _TOMLKIT_BOOTSTRAP_READY=1
  exec nix shell --no-write-lock-file "$repo_root#prePushRuntime" --command "$@"
}

test_runtime_profile_main() {
  local action="${1:-}"
  case "$action" in
    prepare)
      [ "$#" -le 2 ] || { echo "usage: $0 prepare [repo-root]" >&2; return 2; }
      test_runtime_profile_prepare "${2:-.}"
      ;;
    run)
      [ "$#" -ge 4 ] || { echo "usage: $0 run <repo-root> -- <command> [args...]" >&2; return 2; }
      shift
      test_runtime_profile_run "$@"
      ;;
    *)
      echo "usage: $0 {prepare [repo-root]|run <repo-root> -- <command> [args...]}" >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  test_runtime_profile_main "$@"
fi
