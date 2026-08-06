# tests/suites/codex-user-hooks.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
write_malformed_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex"
  printf '{ not valid json\n' > "$home_dir/.codex/hooks.json"
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}

write_symlinked_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex" "$home_dir/dotfiles/codex"
  cat > "$home_dir/dotfiles/codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/hooks/session-init-icons.sh"
          }
        ]
      }
    ]
  }
}
EOF
  ln -s "$home_dir/dotfiles/codex/hooks.json" "$home_dir/.codex/hooks.json"
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}

write_clean_symlinked_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex" "$home_dir/dotfiles/codex"
  cat > "$home_dir/dotfiles/codex/hooks.json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/custom-user-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  ln -s "$home_dir/dotfiles/codex/hooks.json" "$home_dir/.codex/hooks.json"
}
assert_malformed_user_codex_hooks_preserved() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -f "$hooks_json" ]] || fail "expected malformed user-level hooks.json to remain for manual repair"
  [[ "$(cat "$hooks_json")" == "{ not valid json" ]] || fail "expected malformed user-level hooks.json content to remain unchanged"
}

assert_symlinked_user_codex_hooks_preserved() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -L "$hooks_json" ]] || fail "expected user-level hooks.json symlink to remain intact"
  [[ "$(readlink "$hooks_json")" == "$home_dir/dotfiles/codex/hooks.json" ]] || fail "expected user-level hooks.json symlink target to remain unchanged"
  assert_contains "$(cat "$home_dir/dotfiles/codex/hooks.json")" "session-init-icons.sh"
}

test_verify_ai_compat_codex_artifact_contract_static() {
  local verifier expectations codex_rebuild_helper verifier_content expectations_content
  verifier="$REPO_ROOT/scripts/ai/verify-ai-compat.sh"
  expectations="$REPO_ROOT/tests/lib/codex-hook-expectations.sh"
  codex_rebuild_helper="$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex.sh"
  verifier_content="$(cat "$verifier")"
  expectations_content="$(cat "$expectations")"

  assert_contains "$verifier_content" '_check_hook_executable ".codex/hooks/record-prompt-submit.sh"'
  assert_contains "$verifier_content" '_check_hook_executable ".codex/hooks/_stop-dispatcher.sh"'
  assert_contains "$verifier_content" 'for _sub in "${EXPECTED_DISPATCHER_SUB_SCRIPTS[@]}"; do'
  assert_contains "$expectations_content" 'EXPECTED_DISPATCHER_SUB_SCRIPTS=(record-last-stop.sh nrs-session-cleanup.sh)'
  assert_contains "$verifier_content" '_check_hook_executable ".codex/hooks/pinning-alert.sh"'
  assert_contains "$verifier_content" '_check_hook_executable ".codex/hooks/pinning-guard.sh"'
  assert_contains "$verifier_content" 'codex_evaluated_seed_is_trusted "$_DEPLOYED_TEMPLATE"'
  assert_not_contains "$verifier_content" 'marker verification deferred until post-nrs rerun'
  assert_contains "$(cat "$codex_rebuild_helper")" 'CODEX_EVALUATED_SEED_REL_PATH=".local/share/nixos-config/codex/config-template.toml"'

  assert_contains "$verifier_content" '_check_readable_symlink_suffix ".codex/lib/pinning-patterns.sh" "$_pinning_lib_suffix"'
  assert_contains "$verifier_content" '_check_readable_symlink_suffix ".codex/lib/hook-runtime.sh" "$_hook_runtime_lib_suffix"'
  assert_not_contains "$verifier_content" '_check_hook_executable ".codex/lib/'
  assert_not_contains "$verifier_content" '_check_executable_symlink_suffix ".codex/lib/'

  # shellcheck source=../../tests/lib/codex-hook-expectations.sh
  source "$expectations"
  # shellcheck source=../../modules/shared/scripts/lib/rebuild/codex.sh
  source "$codex_rebuild_helper"

  local expected_hooks actual_hooks rel expected_hooks_text actual_hooks_text
  expected_hooks=("${EXPECTED_CODEX_MANAGED_HOOK_ARTIFACTS[@]}")
  actual_hooks=()
  for rel in "${CODEX_MANAGED_HOOK_ARTIFACTS[@]}"; do
    actual_hooks+=("${rel#hooks/}")
  done
  expected_hooks_text="$(printf '%s\n' "${expected_hooks[@]}" | sort)"
  actual_hooks_text="$(printf '%s\n' "${actual_hooks[@]}" | sort)"
  [[ "$actual_hooks_text" == "$expected_hooks_text" ]] || \
    fail "codex managed hook artifact list drift: actual=[$actual_hooks_text] expected=[$expected_hooks_text]"

  local expected_libs actual_libs expected_libs_text actual_libs_text
  expected_libs=("${EXPECTED_CODEX_MANAGED_LIB_ARTIFACTS[@]}")
  actual_libs=()
  for rel in "${CODEX_MANAGED_LIB_ARTIFACTS[@]}"; do
    actual_libs+=("${rel#lib/}")
  done
  expected_libs_text="$(printf '%s\n' "${expected_libs[@]}" | sort)"
  actual_libs_text="$(printf '%s\n' "${actual_libs[@]}" | sort)"
  [[ "$actual_libs_text" == "$expected_libs_text" ]] || \
    fail "codex managed lib artifact list drift: actual=[$actual_libs_text] expected=[$expected_libs_text]"
}

test_user_hooks_stale_filter_supports_clean_symlink_target() {
  local sandbox home_dir count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  write_clean_symlinked_user_codex_hooks "$home_dir"

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$home_dir/.codex/hooks.json")"
  [[ "$count" == "0" ]] || fail "expected clean symlinked user hooks.json stale count 0, got: $count"
}

test_user_hooks_stale_filter_detects_symlink_target_stale_entries() {
  local sandbox home_dir count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  write_symlinked_user_codex_hooks "$home_dir"

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$home_dir/.codex/hooks.json")"
  [[ "$count" == "1" ]] || fail "expected symlinked user hooks.json stale count 1, got: $count"
}

test_user_hooks_stale_filter_ignores_stale_path_mentions() {
  local sandbox home_dir hooks_json count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  hooks_json="$home_dir/.codex/hooks.json"
  mkdir -p "$home_dir/.codex"
  cat > "$hooks_json" <<'EOF'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/foo/.codex/hooks/session-init-icons.sh.backup"
          },
          {
            "type": "command",
            "command": "bash -lc 'test -e ~/.codex/hooks/session-init-icons.sh'"
          }
        ]
      }
    ]
  }
}
EOF

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(HOME="$home_dir" jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$hooks_json")"
  [[ "$count" == "0" ]] || fail "expected stale path mentions to be ignored, got stale count: $count"
}

test_user_hooks_stale_filter_detects_exact_home_path() {
  local sandbox home_dir hooks_json count
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  hooks_json="$home_dir/.codex/hooks.json"
  mkdir -p "$home_dir/.codex"
  cat > "$hooks_json" <<EOF
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$home_dir/.codex/hooks/worktree-path-guard.sh"
          }
        ]
      }
    ]
  }
}
EOF

  source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  count="$(HOME="$home_dir" jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$hooks_json")"
  [[ "$count" == "1" ]] || fail "expected exact HOME path stale count 1, got: $count"
}
test_clear_retired_codex_hook_artifacts_preserves_malformed_user_hooks() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_malformed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      _clear_retired_codex_hook_artifacts
    ' 2>&1
  )

  assert_contains "$output" "Removed retired Codex hook artifacts."
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Could not parse $home_dir/.codex/hooks.json; leaving user-owned hook file unchanged."
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected repo-local hooks.json to be removed"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected repo-local hooks.compatibility.json to be removed"
  assert_malformed_user_codex_hooks_preserved "$home_dir"
}

test_clear_retired_codex_hook_artifacts_preserves_symlinked_user_hooks() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_symlinked_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      _clear_retired_codex_hook_artifacts
    ' 2>&1
  )

  assert_contains "$output" "Removed retired Codex hook artifacts."
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "$home_dir/.codex/hooks.json is a symlink; leaving user-owned hook file unchanged"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected repo-local hooks.json to be removed"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected repo-local hooks.compatibility.json to be removed"
  assert_symlinked_user_codex_hooks_preserved "$home_dir"
}

test_clear_retired_codex_hook_artifacts_removes_dangling_artifact_symlinks() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex" "$home_dir/.codex"
  rm -f "$repo_root/.codex/hooks.json" "$repo_root/.codex/hooks.compatibility.json" "$home_dir/.codex/hooks.compatibility.json"
  ln -s "$repo_root/.codex/missing-hooks.json" "$repo_root/.codex/hooks.json"
  ln -s "$repo_root/.codex/missing-hooks.compatibility.json" "$repo_root/.codex/hooks.compatibility.json"
  ln -s "$home_dir/.codex/missing-hooks.compatibility.json" "$home_dir/.codex/hooks.compatibility.json"

  output=$(
    HOME="$home_dir" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      _clear_retired_codex_hook_artifacts
    ' 2>&1
  )

  assert_contains "$output" "Removed retired Codex hook artifacts."
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  [[ ! -L "$repo_root/.codex/hooks.json" ]] || fail "expected dangling repo-local hooks.json symlink to be removed"
  [[ ! -L "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected dangling repo-local hooks.compatibility.json symlink to be removed"
  [[ ! -L "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected dangling user-level hooks.compatibility.json symlink to be removed"
}
