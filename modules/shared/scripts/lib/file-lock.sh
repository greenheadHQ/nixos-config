#!/usr/bin/env bash
set -euo pipefail

# Run a command while holding an advisory file lock.
#
# Contract:
#   with_file_lock <lock_path> <timeout_seconds> <command...>
#
# Uses util-linux flock when available, otherwise macOS lockf. The lock fd is
# scoped to the subshell that executes the command, so callers do not inherit a
# fixed global descriptor.
with_file_lock() {
  if [ "$#" -lt 3 ]; then
    echo "usage: with_file_lock <lock_path> <timeout_seconds> <command...>" >&2
    return 2
  fi

  local lock_path="$1"
  local timeout_seconds="$2"
  shift 2

  local lock_dir
  lock_dir="$(dirname "$lock_path")"
  mkdir -p "$lock_dir"

  (
    if command -v flock >/dev/null 2>&1; then
      if ! flock -w "$timeout_seconds" 9; then
        echo "error: timed out waiting for lock: $lock_path" >&2
        exit 75
      fi
    elif command -v lockf >/dev/null 2>&1; then
      # 이 환경 lockf는 fd 기반(flock(2) wrapper) — locks.sh와 동일 패턴. FreeBSD의 `lockf file command`와 다름.
      if ! lockf -s -t "$timeout_seconds" 9; then
        echo "error: timed out waiting for lock: $lock_path" >&2
        exit 75
      fi
    else
      echo "warning: neither flock nor lockf is available; running without a lock" >&2
    fi

    "$@"
  ) 9>"$lock_path"
}
