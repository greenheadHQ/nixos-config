#!/usr/bin/env bash
# Run gitleaks against staged content while pinning policy files to staged material.
#
# staged 트리는 scripts/ai/lib/staged-snapshot-cache.sh 의 공유 캐시(read-only)를
# 재사용한다(pre-commit 의 checkout-index 중복 제거). 정책 파일(.gitleaks.toml 등)을
# staged index 에 고정하는 temp_index / GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE 핀은
# 그대로 유지한다. 공유 worktree 는 read-only 라 그 안에 임시 파일을 쓰지 않는다.
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

# shellcheck disable=SC1091  # repo 내부 고정 경로
. "$SCRIPT_DIR/lib/staged-snapshot-cache.sh"

tmp_base="/private/tmp"
[ -d "$tmp_base" ] || tmp_base="${TMPDIR:-/tmp}"
tmp_base="$(cd "$tmp_base" && pwd -P)"

tmp_dir="$(mktemp -d "$tmp_base/gitleaks-staged.XXXXXX")"
temp_index="$tmp_dir/index"
validator_tmp="$tmp_dir/validate-gitleaks-staged-policy.py"
empty_gitleaksignore="$tmp_dir/empty-gitleaksignore"

cleanup() {
  staged_snapshot_cache_release
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

# 단일 source index: temp_index 를 먼저 만들고 그것을 provider 에 넘긴다. provider 는 temp_index 를
# 자기 private copy 로 떠서 snapshot 을 빌드하고, gitleaks/validator 는 GIT_INDEX_FILE=temp_index 를
# 쓴다 — 둘 다 같은 temp_index 내용에서 비롯되므로 snapshot 과 검증 입력이 동일 staged tree 를
# 가리킨다. provider 를 호출한 뒤 index 를 따로 복사하면 두 복사 시점 사이 index 변경 시 갈라질 수
# 있어, 복사를 provider 호출보다 앞에 둔다. checkout-index 는 provider 가 1회만 수행하고, 표준
# 케이스에서는 run-staged-snapshot 소비자들과 동일한 캐시 키를 공유한다.
cp "$intended_index" "$temp_index"
staged_snapshot_cache_provide "$REPO_ROOT" "$temp_index" \
  || fail "failed to provide staged snapshot cache"
snapshot="$STAGED_SNAPSHOT_CACHE_WORKTREE"
[ -d "$snapshot" ] || fail "staged snapshot worktree missing: $snapshot"

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

# checkout-index 는 공유 캐시 provider 가 이미 1회 수행했다(중복 제거). snapshot 은 read-only.
require_index_mode ".gitleaks.toml" "100644"

# .gitleaksignore: staged 면 공유 snapshot 의 것을 검증해 쓰고, 없으면 per-command 빈 파일을
# 쓴다. 공유 snapshot 은 read-only 계약이라 그 안에 빈 파일을 만들지 않는다(캐시 오염 방지).
: > "$empty_gitleaksignore"
gitleaksignore_path="$empty_gitleaksignore"
if index_entry ".gitleaksignore" >/dev/null && [ -n "$(index_entry ".gitleaksignore")" ]; then
  require_index_mode ".gitleaksignore" "100644"
  gitleaksignore_path="$snapshot/.gitleaksignore"
fi

require_executable_materialized_helper "$VALIDATOR_PATH" "$validator_tmp"
python3 "$validator_tmp" --snapshot "$snapshot" --git-dir "$abs_git_dir" --index "$temp_index"

# gitleaks 런처 결정: PATH 우선(direnv 활성 인터랙티브 셸), 없으면 nix 경유(direnv
# 미활성 비대화형 AI 에이전트/CI 셸). gitleaks는 flake devShell에만 있어, 비대화형
# 셸에서는 PATH에 없어 이 hook이 exit 127로 커밋을 차단했다(#826). statusline-bats
# (lefthook.yml)와 동일하게 --inputs-from으로 repo flake.lock의 nixpkgs를 재사용해
# 임시 registry fetch와 프로젝트 pin 우회를 피한다. PATH에 있으면 nix 평가 없이 직접 실행.
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks_cmd=(gitleaks)
else
  command -v nix >/dev/null 2>&1 \
    || fail "gitleaks not on PATH and nix unavailable to bootstrap it (enter devShell or install gitleaks)"
  gitleaks_cmd=(nix shell --inputs-from "$REPO_ROOT" nixpkgs#gitleaks --command gitleaks)
fi

(
  cd "$snapshot"
  with_staged_git_env "${gitleaks_cmd[@]}" protect --staged --source . --no-banner --redact \
    --config ./.gitleaks.toml \
    --gitleaks-ignore-path "$gitleaksignore_path"
)
