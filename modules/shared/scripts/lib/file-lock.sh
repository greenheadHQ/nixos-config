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
      # fail-closed: lock 없이 callback을 실행하면(fail-open) 이 helper의 계약(lock 보유 중
      # 실행)이 깨진다. Toss는 이 helper로 client당 유효 token 1개 제약의 발급/401 CAS와
      # append-only 원장을 보호하므로, backend 부재 시 lock 없이 진행하면 동시 refresh가
      # 서로의 token을 무효화할 수 있다. 배포 wrapper는 PATH에 flock/lockf를 pin하며,
      # 둘 다 없으면 실행하지 않고 실패한다.
      echo "error: no file-lock backend (flock/lockf) available; refusing to run without a lock: $lock_path" >&2
      exit 75
    fi

    "$@"
  ) 9>"$lock_path"
}
