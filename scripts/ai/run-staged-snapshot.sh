#!/usr/bin/env bash
# Run a command from a materialized copy of the current staged index.
#
# staged 트리(~752파일)는 scripts/ai/lib/staged-snapshot-cache.sh 가 git write-tree
# 해시를 키로 1회만 materialize 하여 공유한다(parallel pre-commit 의 checkout-index
# 중복 제거). 공유 worktree 는 read-only 이므로 consumer 는 읽기 전용으로 다룬다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "run-staged-snapshot: $*" >&2
  exit 1
}

if [ "${1:-}" != "--" ]; then
  fail "usage: bash ./scripts/ai/run-staged-snapshot.sh -- <command> [args...]"
fi
shift
[ "$#" -gt 0 ] || fail "missing command"

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "not inside a git repository"
fi

# shellcheck disable=SC1091  # repo 내부 고정 경로
. "$SCRIPT_DIR/lib/staged-snapshot-cache.sh"

# staged 메타데이터는 매번 생성한다. `git diff --cached` 는 HEAD↔index diff 라 tree
# hash(=index 내용)만으로 캐시하면 HEAD 변동 시 stale 위험이 있다. 생성 비용은
# checkout-index 에 비해 작아 공유 이득을 해치지 않는다.
meta_dir="$(mktemp -d "${TMPDIR:-/tmp}/staged-snapshot-meta.XXXXXX")"
staged_files_file="$meta_dir/staged-files.nul"
staged_name_status_file="$meta_dir/staged-name-status.nul"

cleanup() {
  staged_snapshot_cache_release
  rm -rf "$meta_dir"
}
trap cleanup EXIT

# metadata(diff)와 snapshot 이 같은 index 시점을 보도록, 현재 index 를 먼저 private copy 로 pin 하고
# diff 와 provider 모두 그 동일 pinned index 로 실행한다. 둘을 각각 현재 index 에서 읽으면 두 시점
# 사이 index 가 바뀔 때 STAGED_SNAPSHOT_*(metadata)와 STAGED_SNAPSHOT_ROOT(worktree)가 갈라질 수 있다.
intended_index="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path index)"
pinned_index="$meta_dir/index"
cp "$intended_index" "$pinned_index"
GIT_INDEX_FILE="$pinned_index" git -C "$REPO_ROOT" diff --cached -z --name-only > "$staged_files_file"
GIT_INDEX_FILE="$pinned_index" git -C "$REPO_ROOT" diff --cached -z --name-status > "$staged_name_status_file"

# 공유 캐시에서 staged 트리를 확보한다 (없으면 1회 build, 있으면 재사용). 위 pinned index 를 넘겨
# metadata 와 동일한 staged tree 를 materialize 한다.
staged_snapshot_cache_provide "$REPO_ROOT" "$pinned_index" || fail "failed to provide staged snapshot cache"
snapshot="$STAGED_SNAPSHOT_CACHE_WORKTREE"
[ -d "$snapshot" ] || fail "staged snapshot worktree missing: $snapshot"

unset_repo_git_env() {
  local var
  while IFS= read -r var; do
    [ -n "$var" ] && unset "$var"
  done < <(git -C "$REPO_ROOT" rev-parse --local-env-vars)
}

(
  unset_repo_git_env
  export STAGED_SNAPSHOT_ROOT="$snapshot"
  export STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE="$staged_files_file"
  export STAGED_SNAPSHOT_STAGED_NAME_STATUS_NUL_FILE="$staged_name_status_file"
  # 실제 repo source root(snapshot 임시 경로가 아닌)를 generic context 로 노출한다. cwd 가
  # snapshot 이라 nix self-wrap 시 repo_root 가 snapshot 으로 잡혀 트리 전체가 store 로 복사되는
  # 것을, 소비자(tomlkit-bootstrap 등)가 이 값을 읽어 실제 repo flake 를 쓰게 함으로써 막는다.
  # runner 는 소비자별 전용 변수를 두지 않고 generic source root 만 노출한다.
  export STAGED_SNAPSHOT_SOURCE_ROOT="$REPO_ROOT"
  cd "$snapshot"
  "$@"
)
