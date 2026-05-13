#!/usr/bin/env bash
# Run gitleaks against staged content while pinning policy files to staged material.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATOR_PATH="scripts/ai/validate-gitleaks-staged-policy.py"

fail() {
  echo "run-gitleaks-staged-policy: $*" >&2
  exit 1
}

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  fail "not inside a git repository"
fi

abs_git_dir="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-dir)"
if [ -n "${GIT_INDEX_FILE:-}" ]; then
  case "$GIT_INDEX_FILE" in
    /*) intended_index="$GIT_INDEX_FILE" ;;
    *) intended_index="$(cd "$REPO_ROOT" && cd "$(dirname "$GIT_INDEX_FILE")" && pwd -P)/$(basename "$GIT_INDEX_FILE")" ;;
  esac
else
  intended_index="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-path index)"
fi
[ -f "$intended_index" ] || fail "index not found: $intended_index"

tmp_base="/private/tmp"
[ -d "$tmp_base" ] || tmp_base="${TMPDIR:-/tmp}"
tmp_base="$(cd "$tmp_base" && pwd -P)"

tmp_dir="$(mktemp -d "$tmp_base/gitleaks-staged.XXXXXX")"
snapshot="$tmp_dir/worktree"
temp_index="$tmp_dir/index"
validator_tmp="$tmp_dir/validate-gitleaks-staged-policy.py"

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

mkdir -p "$snapshot"
cp "$intended_index" "$temp_index"

local_git_env_vars=()
while IFS= read -r var; do
  [ -n "$var" ] && local_git_env_vars+=("$var")
done < <(git -C "$REPO_ROOT" rev-parse --local-env-vars)

with_staged_git_env() (
  local var
  for var in "${local_git_env_vars[@]}"; do
    unset "$var"
  done
  while IFS='=' read -r var _; do
    case "$var" in
      GIT_CONFIG | GIT_CONFIG_*) unset "$var" ;;
    esac
  done < <(env)
  export GIT_DIR="$abs_git_dir"
  export GIT_WORK_TREE="$snapshot"
  export GIT_INDEX_FILE="$temp_index"
  "$@"
)

index_entry() {
  with_staged_git_env git ls-files -s -- "$1"
}

require_index_mode() {
  local path="$1"
  local expected_mode="$2"
  local entry count mode stage
  entry="$(index_entry "$path")"
  count="$(printf '%s\n' "$entry" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = "1" ] || fail "$path must have exactly one stage-0 index entry"
  mode="$(printf '%s\n' "$entry" | awk '{print $1}')"
  stage="$(printf '%s\n' "$entry" | awk '{print $3}')"
  [ "$stage" = "0" ] || fail "$path must be a stage-0 index entry"
  [ "$mode" = "$expected_mode" ] || fail "$path must have index mode $expected_mode, got $mode"
}

require_executable_materialized_helper() {
  local path="$1"
  local output="$2"
  local entry count mode stage
  entry="$(index_entry "$path")"
  count="$(printf '%s\n' "$entry" | sed '/^$/d' | wc -l | tr -d ' ')"
  [ "$count" = "1" ] || fail "$path must have exactly one stage-0 index entry"
  mode="$(printf '%s\n' "$entry" | awk '{print $1}')"
  stage="$(printf '%s\n' "$entry" | awk '{print $3}')"
  [ "$stage" = "0" ] || fail "$path must be a stage-0 index entry"
  if [ "$mode" != "100644" ] && [ "$mode" != "100755" ]; then
    fail "$path must be a regular blob, got mode $mode"
  fi
  with_staged_git_env git show ":$path" > "$output"
}

with_staged_git_env git checkout-index --all --prefix="$snapshot/"

require_index_mode ".gitleaks.toml" "100644"
if index_entry ".gitleaksignore" >/dev/null && [ -n "$(index_entry ".gitleaksignore")" ]; then
  require_index_mode ".gitleaksignore" "100644"
else
  : > "$snapshot/.gitleaksignore"
fi

require_executable_materialized_helper "$VALIDATOR_PATH" "$validator_tmp"
python3 "$validator_tmp" --snapshot "$snapshot" --git-dir "$abs_git_dir" --index "$temp_index"

(
  cd "$snapshot"
  with_staged_git_env gitleaks protect --staged --source . --no-banner --redact \
    --config ./.gitleaks.toml \
    --gitleaks-ignore-path ./.gitleaksignore
)
