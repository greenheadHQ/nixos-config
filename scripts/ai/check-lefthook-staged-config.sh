#!/usr/bin/env bash
# Guard Lefthook pre-commit execution against unstaged hook config/script drift.
set -euo pipefail

REPO_ROOT="${1:-}"

fail() {
  echo "check-lefthook-staged-config: $*" >&2
  exit 1
}

[ -n "$REPO_ROOT" ] || fail "repo root argument is required"
cd "$REPO_ROOT"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lefthook-staged-config.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

index_file="$tmp_dir/lefthook.yml"

index_entry() {
  git ls-files -s -- "$1"
}

require_regular_index_entry() {
  local path="$1"
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
}

require_worktree_matches_index() {
  local path="$1"
  [ -f "$path" ] || fail "$path is missing from the working tree"
  git show ":$path" | cmp -s - "$path" || fail "$path differs between index and working tree; stage or revert it"
}

require_regular_index_entry "lefthook.yml"
git show ":lefthook.yml" > "$index_file"
[ -f "lefthook.yml" ] || fail "lefthook.yml is missing from the working tree"
cmp -s "$index_file" "lefthook.yml" || fail "lefthook.yml differs between index and working tree; stage or revert it"

alternate_configs=(
  "lefthook.yaml" ".lefthook.yml" ".lefthook.yaml"
  ".config/lefthook.yml" ".config/lefthook.yaml"
  "lefthook.toml" ".lefthook.toml" ".config/lefthook.toml"
  "lefthook.json" "lefthook.jsonc" ".lefthook.json" ".lefthook.jsonc"
  ".config/lefthook.json" ".config/lefthook.jsonc"
  "lefthook-local.yml" "lefthook-local.yaml" "lefthook-local.toml" "lefthook-local.json" "lefthook-local.jsonc"
  ".lefthook-local.yml" ".lefthook-local.yaml" ".lefthook-local.toml" ".lefthook-local.json" ".lefthook-local.jsonc"
  ".config/lefthook-local.yml" ".config/lefthook-local.yaml" ".config/lefthook-local.toml" ".config/lefthook-local.json" ".config/lefthook-local.jsonc"
)

for path in "${alternate_configs[@]}"; do
  if [ -e "$path" ] || [ -n "$(index_entry "$path")" ]; then
    fail "unsupported Lefthook config surface present: $path"
  fi
done

normalized_precommit="$tmp_dir/pre-commit.normalized"
awk '
  /^pre-commit:/ { in_block = 1 }
  in_block && /^[^[:space:]#][^:]*:/ && $0 !~ /^pre-commit:/ { exit }
  in_block {
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^[[:space:]]*#/) next
    print
  }
' "$index_file" > "$normalized_precommit"

expected_precommit="$tmp_dir/pre-commit.expected"
cat > "$expected_precommit" <<'EOF'
pre-commit:
  parallel: true
  commands:
    ai-skills-consistency:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/warn-skill-consistency.sh
    gitleaks:
      run: bash ./scripts/ai/run-gitleaks-staged-policy.sh
    nixfmt:
      glob: "*.nix"
      run: nixfmt --check {staged_files}
    shellcheck:
      glob: "*.sh"
      run: shellcheck -S warning {staged_files}
    eval-tests:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./tests/run-eval-tests.sh
    codex-hook-fixtures:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./tests/test-codex-hook-fixtures.sh --no-live
    skill-noise-check:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/check-skill-noise.sh
    local-skill-noise-check:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/check-skill-noise.sh .claude/skills
EOF

if ! diff -u "$expected_precommit" "$normalized_precommit" >&2; then
  fail "unsupported pre-commit Lefthook command shape; update guard allowlist with hook changes"
fi

allowed_top_level='^(pre-commit|commit-msg|pre-push):$'
while IFS= read -r top_key; do
  if ! [[ "$top_key" =~ $allowed_top_level ]]; then
    fail "unsupported top-level Lefthook key: ${top_key%:}"
  fi
done < <(awk '/^[A-Za-z0-9_.-]+:/ { print $1 }' "$index_file")

repo_scripts=(
  "scripts/ai/run-staged-snapshot.sh"
  "scripts/ai/warn-skill-consistency.sh"
  "scripts/ai/run-gitleaks-staged-policy.sh"
  "tests/run-eval-tests.sh"
  "tests/test-codex-hook-fixtures.sh"
  "scripts/ai/check-skill-noise.sh"
)

for path in "${repo_scripts[@]}"; do
  require_regular_index_entry "$path"
  require_worktree_matches_index "$path"
done
