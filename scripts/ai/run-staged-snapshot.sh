#!/usr/bin/env bash
# Run a command from a materialized copy of the current staged index.
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

tmp_base="/private/tmp"
[ -d "$tmp_base" ] || tmp_base="${TMPDIR:-/tmp}"
tmp_base="$(cd "$tmp_base" && pwd -P)"

tmp_dir="$(mktemp -d "$tmp_base/staged-snapshot.XXXXXX")"
snapshot="$tmp_dir/worktree"
staged_files_file="$tmp_dir/staged-files.nul"
staged_name_status_file="$tmp_dir/staged-name-status.nul"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$snapshot"
git -C "$REPO_ROOT" diff --cached -z --name-only > "$staged_files_file"
git -C "$REPO_ROOT" diff --cached -z --name-status > "$staged_name_status_file"
git -C "$REPO_ROOT" checkout-index --all --prefix="$snapshot/"

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
  cd "$snapshot"
  "$@"
)
