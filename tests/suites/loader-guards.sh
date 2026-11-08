# tests/suites/loader-guards.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
read_bash_array_from_script() {
  local script_path="$1"
  local array_name="$2"
  awk -v array_name="$array_name" '
    $0 ~ "^" array_name "=\\(" { in_array=1; next }
    in_array && $0 ~ "^\\)" { exit }
    in_array {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
      if ($0 != "") print
    }
  ' "$script_path"
}
test_shadow_paths_do_not_override_managed_helpers() {
  local sandbox home_dir repo_root worktree_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$home_dir/.local/lib/lib/rebuild"
  while IFS= read -r helper; do
    cat > "$home_dir/.local/lib/lib/rebuild/$helper.sh" <<'EOF'
echo "SHADOW_REBUILD_HELPER" >&2
EOF
  done < <(read_bash_array_from_script "$REPO_ROOT/modules/shared/scripts/rebuild-common.sh" "REBUILD_HELPERS")
  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
    ' 2>&1
  )

  assert_not_contains "$output" "SHADOW_REBUILD_HELPER"
}

test_rebuild_common_symlink_alias_does_not_load_adjacent_helpers() {
  local sandbox home_dir alias_dir alias_path output generated_dir
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  alias_dir="$sandbox/alias/lib"
  alias_path="$alias_dir/rebuild-common.sh"
  generated_dir="$sandbox/generated"

  install_deployed_layout "$sandbox"

  mkdir -p "$sandbox/alias/lib/rebuild" "$alias_dir" "$generated_dir"
  sed "s|@flakePath@|$REPO_ROOT|g" \
    "$REPO_ROOT/modules/shared/scripts/rebuild-common.sh" > "$generated_dir/rebuild-common.sh"
  ln -sf "$generated_dir/rebuild-common.sh" "$alias_path"
  cat > "$sandbox/alias/lib/rebuild/common.sh" <<'EOF'
echo "MALICIOUS_REBUILD" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$alias_path"'"
      printf "loaded\n"
    ' 2>&1 || true
  )

  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "MALICIOUS_REBUILD"
}
test_missing_managed_helpers_fail_closed() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  rm -rf "$home_dir/.local/lib/rebuild"
  mkdir -p "$home_dir/.local/lib/lib/rebuild"
  cat > "$home_dir/.local/lib/lib/rebuild/common.sh" <<'EOF'
echo "SHADOW_REBUILD_LOADED" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
    ' 2>&1 || true
  )
  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "SHADOW_REBUILD_LOADED"
}
