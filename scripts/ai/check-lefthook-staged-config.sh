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
# 이 heredoc 블록은 lefthook.yml 의 pre-commit 섹션을 위 awk normalize(빈 줄·주석 제거)한 결과와
# 1바이트 일치해야 한다. lefthook.yml 의 glob 을 변경하면 아래 블록도 동시에 갱신한다.
# 의도/동기화 설명 주석은 awk 가 제거하므로 이 heredoc 안이 아니라 lefthook.yml 쪽에 둔다.
cat > "$expected_precommit" <<'EOF'
pre-commit:
  parallel: true
  commands:
    lefthook-guard-self-check:
      run: |
        hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
        pre_commit="$hooks_dir/pre-commit"
        problem=""
        if [ ! -f "$pre_commit" ] || ! grep -Fq "# BEGIN nixos-config lefthook staged-config guard" "$pre_commit"; then
          problem="staged-config guard block missing from $pre_commit"
        else
          for hook_name in pre-commit commit-msg pre-push; do
            hook_path="$hooks_dir/$hook_name"
            if [ ! -f "$hook_path" ]; then
              problem="hook file missing: $hook_path (auto-install is disabled, so lefthook will not recreate it)"
              break
            fi
            expected_call='call_lefthook run "'"$hook_name"'" --no-auto-install "$@"'
            if ! grep -Fxq -- "$expected_call" "$hook_path"; then
              problem="expected exact lefthook call [$expected_call] in $hook_path (lefthook's next auto-sync would silently drop the staged-config guard)"
              break
            fi
          done
        fi
        if [ -n "$problem" ]; then
          echo "lefthook-guard-self-check: $problem" >&2
          echo "  Cause: lefthook's implicit auto-sync regenerated the hooks (happens on the first run after lefthook.yml changes)," >&2
          echo "         or another worktree's raw 'lefthook install' overwrote the shared hook." >&2
          echo "  Fix:   bash scripts/ai/install-lefthook-hooks.sh   (or 'direnv reload') in the current worktree, then retry." >&2
          exit 1
        fi
    ai-skills-consistency:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/warn-skill-consistency.sh
    ai-skill-stale-identifiers:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/warn-skill-stale-identifiers.sh
    ai-skill-version-stamps:
      glob:
        - "modules/shared/programs/claude/files/skills/using-codex-exec/**"
        - "modules/shared/programs/claude/files/skills/using-claude-p/**"
        - ".claude/skills/configuring-codex/**"
        - "modules/shared/programs/codex/codex-pin.json"
        - "scripts/ai/warn-skill-version-stamps.sh"
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/warn-skill-version-stamps.sh
    gitleaks:
      run: bash ./scripts/ai/run-gitleaks-staged-policy.sh
    nixfmt:
      glob: "*.nix"
      run: nixfmt --check {staged_files}
    shellcheck:
      glob: "*.sh"
      run: shellcheck -S warning {staged_files}
    eval-tests:
      glob:
        - "*.nix"
        - "flake.lock"
        - "tests/run-eval-tests.sh"
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./tests/run-eval-tests.sh
    codex-hook-fixtures:
      glob:
        - "modules/shared/programs/codex/**"
        - "modules/shared/programs/claude/files/hooks/**"
        - "modules/shared/programs/claude/files/lib/**"
        - "tests/fixtures/codex-hooks/**"
        - "tests/test-codex-hook-fixtures.sh"
        - "tests/lib/**"
        - "scripts/ai/commit-msg-pinning.sh"
        - "scripts/ai/lib/tomlkit-bootstrap.sh"
        - "scripts/ai/test-runtime-profile.sh"
        - "modules/shared/scripts/codex-exec-supervised.sh"
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./tests/test-codex-hook-fixtures.sh --no-live
    skill-noise-check:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/check-skill-noise.sh
    local-skill-noise-check:
      run: bash ./scripts/ai/run-staged-snapshot.sh -- bash ./scripts/ai/check-skill-noise.sh .claude/skills
EOF

if ! diff -u "$expected_precommit" "$normalized_precommit" >&2; then
  fail "unsupported pre-commit Lefthook command shape; update guard allowlist with hook changes"
fi

normalized_prepush="$tmp_dir/pre-push.normalized"
awk '
  /^pre-push:/ { in_block = 1 }
  in_block && /^[^[:space:]#][^:]*:/ && $0 !~ /^pre-push:/ { exit }
  in_block {
    if ($0 ~ /^[[:space:]]*$/) next
    if ($0 ~ /^[[:space:]]*#/) next
    print
  }
' "$index_file" > "$normalized_prepush"

expected_prepush="$tmp_dir/pre-push.expected"
# P2의 push_files glob은 required CI와 함께 로컬 검증 범위를 결정하는 안전 경계다. pre-commit
# expected와 마찬가지로 주석/빈 줄을 제외한 staged pre-push 블록 전체를 exact match한다.
cat > "$expected_prepush" <<'EOF'
pre-push:
  parallel: false
  commands:
    analyzing-da-sessions-tests:
      glob:
        - "modules/shared/programs/claude/files/skills/analyzing-da-sessions/**"
        - "modules/shared/programs/claude/files/skills/run-da/**"
        - "tests/run-analyzing-da-sessions-tests.sh"
      run: bash ./tests/run-analyzing-da-sessions-tests.sh
    fleiss-kappa-tests:
      glob:
        - "modules/shared/programs/claude/files/scripts/fleiss-kappa.py"
        - "modules/shared/programs/claude/files/scripts/tests/test_fleiss_kappa.py"
        - "tests/run-fleiss-kappa-tests.sh"
      run: bash ./tests/run-fleiss-kappa-tests.sh
    skill-doc-sync:
      glob:
        - "modules/shared/programs/claude/files/skills/run-da/**"
        - "modules/shared/programs/claude/files/scripts/fleiss-kappa.py"
        - "tests/skill-doc-sync.py"
      run: bash ./tests/test-skill-doc-sync.sh
    flake-check:
      glob:
        - "*.nix"
        - "flake.lock"
      run: nix flake check --no-build --all-systems
    statusline-bats:
      glob:
        - "modules/shared/programs/claude/files/scripts/statusline.sh"
        - "modules/shared/programs/claude/files/scripts/tests/statusline.bats"
        - "scripts/ai/test-runtime-profile.sh"
      run: bash ./scripts/ai/test-runtime-profile.sh run "$PWD" -- env TERM="${TERM:-xterm-256color}" bats modules/shared/programs/claude/files/scripts/tests/statusline.bats
    ai-skill-version-stamps:
      run: bash ./scripts/ai/warn-skill-version-stamps.sh --from-head
EOF

if ! diff -u "$expected_prepush" "$normalized_prepush" >&2; then
  fail "unsupported pre-push Lefthook command shape; update guard allowlist with hook changes"
fi

allowed_top_level='^(pre-commit|commit-msg|pre-push):$'
while IFS= read -r top_key; do
  if ! [[ "$top_key" =~ $allowed_top_level ]]; then
    fail "unsupported top-level Lefthook key: ${top_key%:}"
  fi
done < <(awk '/^[A-Za-z0-9_.-]+:/ { print $1 }' "$index_file")

repo_scripts=(
  "scripts/ai/run-staged-snapshot.sh"
  "scripts/ai/lib/staged-snapshot-cache.sh"
  "scripts/ai/warn-skill-consistency.sh"
  "scripts/ai/warn-skill-stale-identifiers.sh"
  "scripts/ai/warn-skill-version-stamps.sh"
  "scripts/ai/run-gitleaks-staged-policy.sh"
  "tests/run-eval-tests.sh"
  "tests/test-codex-hook-fixtures.sh"
  "scripts/ai/check-skill-noise.sh"
  "scripts/ai/test-runtime-profile.sh"
  # lefthook-guard-self-check가 검사하는 `--no-auto-install` 주입은 이 installer가 수행한다.
  # hook 설정과 allowlist만 staged되고 installer 변경이 빠지면 그 계약이 조용히 깨지므로,
  # PR #750의 helper script drift 경계를 installer까지 넓힌다.
  "scripts/ai/install-lefthook-hooks.sh"
  # commit-msg hook의 pinning command가 실행하는 스크립트. commit-msg 단계에는 이 guard가
  # 없으므로, pre-commit 시점의 이 drift check가 commit-msg 실행 계약까지 함께 보호한다.
  "scripts/ai/commit-msg-pinning.sh"
)

for path in "${repo_scripts[@]}"; do
  require_regular_index_entry "$path"
  require_worktree_matches_index "$path"
done
