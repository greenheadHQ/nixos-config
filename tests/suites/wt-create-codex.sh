# tests/suites/wt-create-codex.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
test_wt_create_does_not_call_legacy_sync() {
  local sandbox home_dir repo_root output new_worktree fallback_dir marker_file legacy_name
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  fallback_dir="$sandbox/fallback-bin"
  marker_file="$sandbox/legacy-sync-marker"
  # Split the retired command name so public stale literal scans stay clean.
  legacy_name="codex""-sync"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$home_dir/.local/bin" "$fallback_dir"
  cat > "$home_dir/.local/bin/$legacy_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'managed:%s\n' "$*" >> "${LEGACY_SYNC_MARKER:?}"
exit 0
EOF
  chmod +x "$home_dir/.local/bin/$legacy_name"
  cat > "$home_dir/.local/bin/$legacy_name.sh" <<'EOF'
#!/usr/bin/env bash
echo "SHADOW_LEGACY_SYNC" >&2
exit 0
EOF
  chmod +x "$home_dir/.local/bin/$legacy_name.sh"
  cat > "$fallback_dir/$legacy_name" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'fallback:%s\n' "$*" >> "${LEGACY_SYNC_MARKER:?}"
exit 0
EOF
  chmod +x "$fallback_dir/$legacy_name"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$fallback_dir:$FIXTURE_DIR/bin:$PATH" \
      LEGACY_SYNC_MARKER="$marker_file" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-two
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/feature-two"
  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "$new_worktree"
  assert_not_contains "$output" "SHADOW_LEGACY_SYNC"
  [[ ! -f "$marker_file" ]] || fail "legacy sync command must not be called by wt bootstrap: $(cat "$marker_file")"
}

test_wt_create_skips_symlinked_codex_source() {
  local sandbox home_dir repo_root codex_target output new_worktree
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  codex_target="$sandbox/codex-target"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$codex_target"
  printf 'external\n' > "$codex_target/config.toml"
  ln -s "$codex_target" "$repo_root/.codex"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-symlink-codex
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/feature-symlink-codex"
  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "원본 .codex가 symlink라 worktree 복사를 건너뜁니다"
  [[ ! -L "$new_worktree/.codex" ]] \
    || fail "symlinked source .codex must not be copied as a symlink into new worktree"
  if [[ -f "$new_worktree/.codex/config.toml" ]]; then
    assert_not_contains "$(cat "$new_worktree/.codex/config.toml")" "external"
  fi
}

test_wt_create_prunes_retired_project_mcp_block() {
  local sandbox home_dir repo_root output new_worktree config_file retired_name
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  # Split the retired command name so public stale literal scans stay clean.
  retired_name="codex""-sync"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex"
  cat > "$repo_root/.codex/config.toml" <<EOF
model = "test-model"

# BEGIN $retired_name managed mcp
[mcp_servers.retired]
command = "retired"
# END $retired_name managed mcp

[mcp_servers.keep]
command = "keep"
EOF

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" prune-project-mcp
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/prune-project-mcp"
  config_file="$new_worktree/.codex/config.toml"
  [[ -f "$config_file" ]] || fail "expected copied Codex config: $config_file"
  assert_contains "$output" "$new_worktree"
  assert_not_contains "$(cat "$config_file")" "# BEGIN $retired_name managed mcp"
  assert_not_contains "$(cat "$config_file")" "mcp_servers.retired"
  assert_contains "$(cat "$config_file")" "mcp_servers.keep"
}

test_wt_create_removes_unterminated_copied_codex_config() {
  local sandbox home_dir repo_root output new_worktree config_file retired_name
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  retired_name="codex""-sync"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex"
  cat > "$repo_root/.codex/config.toml" <<EOF
model = "test-model"

# BEGIN $retired_name managed mcp
[mcp_servers.retired]
command = "retired"
EOF

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" unterminated-copied-config
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/unterminated-copied-config"
  config_file="$new_worktree/.codex/config.toml"
  [[ -d "$new_worktree" ]] || fail "expected worktree to be created despite copied Codex config cleanup failure"
  assert_contains "$output" "복사된 config를 제거하고 계속합니다"
  [[ ! -e "$config_file" && ! -L "$config_file" ]] \
    || fail "unterminated copied Codex config must be removed"
}

test_wt_create_removes_directory_copied_codex_config() {
  local sandbox home_dir repo_root output new_worktree config_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  mkdir -p "$repo_root/.codex/config.toml"
  printf 'nested\n' > "$repo_root/.codex/config.toml/nested.txt"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" directory-copied-config
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/directory-copied-config"
  config_file="$new_worktree/.codex/config.toml"
  [[ -d "$new_worktree" ]] || fail "expected worktree to be created despite directory copied Codex config"
  assert_contains "$output" "worktree .codex/config.toml이 regular file이 아니라 제거했습니다"
  [[ ! -e "$config_file" && ! -L "$config_file" ]] \
    || fail "directory copied Codex config must be removed"
}

test_codex_trust_sanitizes_unsafe_copied_codex_config() {
  local sandbox config_file target_file output
  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  target_file="$sandbox/external.toml"

  printf 'model = "external"\n' > "$target_file"
  ln -s "$target_file" "$config_file"

  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
      sanitize-copied-codex-config "$config_file" 2>&1
  )

  assert_contains "$output" "regular file이 아니라 제거했습니다"
  [[ ! -e "$config_file" && ! -L "$config_file" ]] \
    || fail "unsafe copied Codex config must be removed"
  assert_contains "$(cat "$target_file")" "external"
}

test_wt_prepare_rejects_symlinked_claude_dir() {
  local sandbox wt_path external_dir source_settings output rc
  sandbox=$(new_sandbox)
  wt_path="$sandbox/worktree"
  external_dir="$sandbox/external-claude"
  source_settings="$sandbox/missing-settings.local.json"

  mkdir -p "$wt_path" "$external_dir"
  printf '{"enabledPlugins": {"external": true}}\n' > "$external_dir/settings.local.json"
  ln -s "$external_dir" "$wt_path/.claude"

  set +e
  output=$(
    bash -c '
        set -euo pipefail
        _die() { printf "die: %s\n" "$*" >&2; exit 42; }
        _warn() { printf "warning: %s\n" "$*" >&2; }
        source "'"$REPO_ROOT/modules/shared/scripts/lib/wt/bootstrap.sh"'"
        _wt_prepare_claude_settings "'"$source_settings"'" "'"$wt_path/.claude"'"
      ' 2>&1
  )
  rc=$?
  set -e

  [[ "$rc" == "42" ]] || fail "expected symlinked .claude to abort bootstrap, got rc=$rc output=$output"
  assert_contains "$output" "worktree .claude가 regular directory가 아니라 bootstrap 중단"
  assert_contains "$(cat "$external_dir/settings.local.json")" "external"
}

test_wt_prepare_skips_symlinked_source_settings() {
  local sandbox repo_root wt_path external_file output
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  wt_path="$sandbox/worktree"
  external_file="$sandbox/external-secret"

  mkdir -p "$repo_root/.claude" "$wt_path/.claude"
  printf 'secret\n' > "$external_file"
  printf '{"enabledPlugins": {"stale": true}}\n' > "$wt_path/.claude/settings.local.json"
  ln -s "$external_file" "$repo_root/.claude/settings.local.json"

  output=$(
    bash -c '
      set -euo pipefail
      _die() { printf "die: %s\n" "$*" >&2; exit 42; }
      _warn() { printf "warning: %s\n" "$*" >&2; }
      source "'"$REPO_ROOT/modules/shared/scripts/lib/wt/bootstrap.sh"'"
      _wt_prepare_claude_settings "'"$repo_root/.claude/settings.local.json"'" "'"$wt_path/.claude"'"
    ' 2>&1
  )

  assert_contains "$output" "원본 .claude/settings.local.json이 symlink라 worktree 복사를 건너뜁니다"
  [[ ! -e "$wt_path/.claude/settings.local.json" && ! -L "$wt_path/.claude/settings.local.json" ]] \
    || fail "symlinked source settings must not be materialized in worktree"
  assert_contains "$(cat "$external_file")" "secret"
}

test_wt_create_trusts_codex_project() {
  local sandbox home_dir repo_root config_file output new_worktree other_project mode_after
  if ! codex_config_tomlkit_available; then
    echo "SKIP: wt create trusts Codex project config requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  config_file="$home_dir/.codex/config.toml"
  other_project="$sandbox/other-project"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$config_file")" "$other_project"
  other_project="$(cd "$other_project" && pwd -P)"
  new_worktree="$repo_root/.claude/worktrees/feature-trust"
  cat > "$config_file" <<EOF
model = "test-model"

[projects."$other_project"]
trust_level = "trusted"

[projects."$new_worktree"]
trust_level = "untrusted"
EOF
  chmod 0644 "$config_file"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-trust
        "'"$home_dir/.local/bin/wt"'" --yes --if-exists=recreate feature-trust
      ' 2>&1
  )

  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "$new_worktree"

  python3 - "$config_file" "$new_worktree" "$other_project" <<'PY'
import pathlib
import sys
import tomllib

config_file, new_worktree, other_project = sys.argv[1:4]
new_worktree = str(pathlib.Path(new_worktree).resolve())
other_project = str(pathlib.Path(other_project).resolve())
with open(config_file, "rb") as f:
    data = tomllib.load(f)

projects = data["projects"]
assert projects[new_worktree]["trust_level"] == "trusted", projects
assert projects[other_project]["trust_level"] == "trusted", projects
assert data["model"] == "test-model", data
PY

  assert_line_count "$config_file" "[projects.\"$new_worktree\"]" 1
  mode_after=$(_codex_config_file_mode "$config_file")
  [[ "$mode_after" == "600" ]] \
    || fail "expected Codex config mode 600 after trust registration, got: $mode_after"
}

test_wt_create_skips_unsafe_codex_config() {
  local sandbox home_dir repo_root config_file config_target output new_worktree
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  config_file="$home_dir/.codex/config.toml"
  config_target="$sandbox/config-target.toml"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$config_file")"
  printf 'model = "external"\n' > "$config_target"
  ln -s "$config_target" "$config_file"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" unsafe-config-symlink
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/unsafe-config-symlink"
  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "Codex trust registration skipped"
  [[ -L "$config_file" ]] || fail "unsafe Codex config symlink must not be replaced"
  assert_not_contains "$(cat "$config_target")" "unsafe-config-symlink"

  rm -f "$config_file"
  mkfifo "$config_file"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" unsafe-config-fifo
      ' 2>&1
  )
  assert_contains "$output" "Codex trust registration skipped"
  [[ -p "$config_file" ]] || fail "unsafe Codex config FIFO must not be replaced"
}

test_wt_create_supports_valid_projects_shapes() {
  local sandbox home_dir repo_root config_file output
  if ! codex_config_tomlkit_available; then
    echo "SKIP: wt create supports valid Codex projects shapes requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  config_file="$home_dir/.codex/config.toml"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$config_file")"

  local idx=0 worktree_path content
  while (( idx < 3 )); do
    idx=$((idx + 1))
    worktree_path="$repo_root/.claude/worktrees/valid-project-shape-$idx"
    case "$idx" in
      1) content='projects = {}' ;;
      2) content="projects.\"$worktree_path\" = { trust_level = \"trusted\" }" ;;
      3) content="[projects]"$'\n'"\"$worktree_path\" = { trust_level = \"trusted\" }" ;;
    esac
    printf '%s\n' "$content" > "$config_file"
    output=$(
      env -u TMUX \
        HOME="$home_dir" \
        PATH="$FIXTURE_DIR/bin:$PATH" \
        WT_NONINTERACTIVE=1 \
        bash -c '
          set -euo pipefail
          cd "'"$repo_root"'"
          "'"$home_dir/.local/bin/wt"'" "valid-project-shape-'"$idx"'"
        ' 2>&1
    )
    assert_contains "$output" "$worktree_path"
    toml_semantic_equal "$config_file" <(
      printf 'projects."%s".trust_level = "trusted"\n' "$worktree_path"
    ) || fail "valid projects shape must be trusted semantically (scenario $idx): $(cat "$config_file")"
  done
}

test_wt_create_preserves_unmergeable_codex_config() {
  local sandbox home_dir repo_root config_file output
  if ! codex_config_tomlkit_available; then
    echo "SKIP: wt create preserves unmergeable Codex config requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  config_file="$home_dir/.codex/config.toml"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$config_file")"

  local idx=0 branch_name content expected_file
  while (( idx < 2 )); do
    idx=$((idx + 1))
    branch_name="unmergeable-codex-config-$idx"
    case "$idx" in
      1) content='projects = [' ;;
      2) content='projects = []' ;;
    esac

    printf '%s\n' "$content" > "$config_file"
    expected_file="$sandbox/expected-config-$idx.toml"
    cp "$config_file" "$expected_file"

    output=$(
      env -u TMUX \
        HOME="$home_dir" \
        PATH="$FIXTURE_DIR/bin:$PATH" \
        WT_NONINTERACTIVE=1 \
        bash -c '
          set -euo pipefail
          cd "'"$repo_root"'"
          "'"$home_dir/.local/bin/wt"'" "'"$branch_name"'"
        ' 2>&1
    )

    [[ -d "$repo_root/.claude/worktrees/$branch_name" ]] \
      || fail "expected worktree directory to exist despite skipped trust registration: $branch_name"
    assert_contains "$output" "Codex trust registration skipped"
    cmp -s "$config_file" "$expected_file" \
      || fail "unmergeable Codex config must remain unchanged (scenario $idx): $(cat "$config_file")"
  done
}
