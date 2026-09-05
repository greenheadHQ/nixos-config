#!/usr/bin/env bash
# scripts/ai/test-runtime-profile.sh
#
# pre-push/통합 테스트가 공유하는 hermetic runtime GC-root 관리 모듈.
#
# `prepare`는 flake.lock + runtime/플랫폼 flock 정의 content hash와 profile 검증이 모두 current일 때
# 재사용하고, stamp/profile 부재·불일치·검증 실패 시 `.#prePushRuntime`을 다시 빌드한다.
# out-link는 worktree의 .direnv 아래에 두어 worktree 수명과 함께 정리하고, Git 공용
# 디렉토리 lock으로 여러 worktree/direnv의 동시 Nix eval을 직렬화한다.
#
# `run`은 current profile을 PATH에 올려 명령을 실행한다. profile이 없거나 stale이면 common-dir
# lock 아래에서 같은 flake package를 prepare한 뒤 검증된 profile만 활성화한다. 검증 실패를
# `_TOMLKIT_BOOTSTRAP_READY`로 덮지 않고 hard-fail해 fresh clone에서도 hermetic 계약을 유지한다.

_TEST_RUNTIME_PROFILE_REQUIRED_COMMANDS=(
  python3
  cc
  touch
  find
  lsof
  flock
  lefthook
  bats
  pytest
  timeout
)

_TEST_RUNTIME_PROFILE_FINGERPRINT_INPUTS=(
  flake.lock
  flake.nix
  libraries/python-runtimes.nix
  libraries/claude-rc-flock.nix
)

test_runtime_profile_required_commands() {
  printf '%s\n' "${_TEST_RUNTIME_PROFILE_REQUIRED_COMMANDS[@]}"
}

test_runtime_profile_fingerprint_inputs() {
  printf '%s\n' "${_TEST_RUNTIME_PROFILE_FINGERPRINT_INPUTS[@]}"
}

test_runtime_profile_path() {
  printf '%s/.direnv/pre-push-runtime' "$1"
}

test_runtime_profile_stamp_path() {
  printf '%s/.direnv/pre-push-runtime.stamp' "$1"
}

test_runtime_profile_fingerprint() {
  local repo_root="$1"
  local path path_hash hashes=""
  while IFS= read -r path; do
    [ -f "$repo_root/$path" ] || {
      echo "test-runtime-profile: stamp input missing: $repo_root/$path" >&2
      return 1
    }
    path_hash="$(git -C "$repo_root" hash-object -- "$path")" || return 1
    hashes="${hashes}${path_hash}"$'\n'
  done < <(test_runtime_profile_fingerprint_inputs)
  printf '%s' "$hashes" | git -C "$repo_root" hash-object --stdin
}

test_runtime_profile_validate() {
  local profile="$1"
  local command_name
  [ -L "$profile" ] && [ -d "$profile/bin" ] || return 1
  # 배열은 접근자 경유로만 읽는다 (test_runtime_profile_fingerprint 와 동일 패턴) —
  # 직접 참조와 접근자가 공존하면 접근자에 필터링이 생겨도 이 검증이 못 받는다.
  while IFS= read -r command_name; do
    [ -x "$profile/bin/$command_name" ] || return 1
  done < <(test_runtime_profile_required_commands)
  # tomlkit 은 배열 밖 계약이라 접근자로 흡수하지 않는다.
  "$profile/bin/python3" -c 'import tomlkit' >/dev/null 2>&1
}

test_runtime_profile_is_current() {
  local repo_root="$1"
  local profile stamp_file expected_stamp actual_stamp
  profile="$(test_runtime_profile_path "$repo_root")"
  stamp_file="$(test_runtime_profile_stamp_path "$repo_root")"
  [ -f "$stamp_file" ] && [ ! -L "$stamp_file" ] || return 1
  expected_stamp="$(test_runtime_profile_fingerprint "$repo_root")" || return 1
  actual_stamp="$(cat "$stamp_file" 2>/dev/null)" || return 1
  [ "$actual_stamp" = "$expected_stamp" ] || return 1
  test_runtime_profile_validate "$profile"
}

_test_runtime_profile_normalize_tmpdir() {
  # macOS launchd의 TMPDIR은 보통 trailing slash를 갖는다. 기존 nix shell은 이를
  # 정규화하므로 current profile과 on-demand prepare 모두 같은 canonical-path 계약을 제공한다.
  case "${TMPDIR:-}" in
    "" | /) ;;
    */)
      TMPDIR="${TMPDIR%/}"
      export TMPDIR
      ;;
  esac
}

test_runtime_profile_activate() {
  local repo_root="$1"
  local profile
  test_runtime_profile_is_current "$repo_root" || return 1
  profile="$(test_runtime_profile_path "$repo_root")"
  export PATH="$profile/bin:$PATH"
  _test_runtime_profile_normalize_tmpdir
  export _TOMLKIT_BOOTSTRAP_READY=1
}

_test_runtime_profile_acquire_lock() {
  local repo_root="$1"
  local git_common_dir lock_path lock_parent timeout_seconds
  git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || {
    echo "test-runtime-profile: git common dir lookup failed: $repo_root" >&2
    return 1
  }
  lock_path="$git_common_dir/info/pre-push-runtime.lock.d"
  lock_parent="$(dirname "$lock_path")"
  [ -L "$lock_parent" ] && {
    echo "test-runtime-profile: refusing symlinked lock parent: $lock_parent" >&2
    return 1
  }
  mkdir -p "$lock_parent"
  if ! mkdir "$lock_path" 2>/dev/null; then
    [ -d "$lock_path" ] && [ ! -L "$lock_path" ] || {
      echo "test-runtime-profile: refusing unsafe lock path: $lock_path" >&2
      return 1
    }
  fi
  timeout_seconds="${TEST_RUNTIME_PROFILE_LOCK_TIMEOUT_SECONDS:-120}"
  # Bash 3.2 호환 때문에 named FD 대신 literal FD 201을 redirection/lock 양쪽에 고정한다.
  # 이 FD는 prepare subshell이 소유하며, subshell 종료까지 열려 있어 build + stamp publish
  # 전체를 직렬화한다.
  # trailing slash forces directory resolution: a raced-in FIFO/regular file fails instead of blocking.
  exec 201<"$lock_path/"
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
  if [ -L "$stamp_file" ] || { [ -e "$stamp_file" ] && [ ! -f "$stamp_file" ]; }; then
    echo "test-runtime-profile: refusing unsafe stamp path: $stamp_file" >&2
    return 1
  fi
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
    echo "test-runtime-profile: runtime validation failed (required commands or tomlkit)" >&2
    return 1
  fi

  stamp_tmp="$(mktemp "$repo_root/.direnv/.pre-push-runtime.stamp.XXXXXX")"
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
  echo "test-runtime-profile: current profile unavailable; preparing validated profile" >&2
  test_runtime_profile_prepare "$repo_root" || {
    echo "test-runtime-profile: failed to prepare validated runtime profile" >&2
    return 1
  }
  test_runtime_profile_activate "$repo_root" || {
    echo "test-runtime-profile: prepared runtime profile failed validation" >&2
    return 1
  }
  exec "$@"
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
