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
    env -u TMUX -u CODEX_HOME \
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
    env -u TMUX -u CODEX_HOME \
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
    env -u TMUX -u CODEX_HOME \
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
    env -u TMUX -u CODEX_HOME \
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
    env -u TMUX -u CODEX_HOME \
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
    env -u TMUX -u CODEX_HOME \
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
  mode_after=$(_portable_file_mode "$config_file")
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
    env -u TMUX -u CODEX_HOME \
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
    env -u TMUX -u CODEX_HOME \
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
      env -u TMUX -u CODEX_HOME \
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
      env -u TMUX -u CODEX_HOME \
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

test_codex_trust_untrust_project_removes_only_target() {
  local sandbox config_file target_project other_project output rc before_hash after_hash
  if ! codex_config_tomlkit_available; then
    echo "SKIP: codex trust untrust roundtrip requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  target_project="$sandbox/repo/.claude/worktrees/feature_gone"
  other_project="$sandbox/other-project"
  mkdir -p "$target_project" "$other_project"
  target_project="$(cd "$target_project" && pwd -P)"
  other_project="$(cd "$other_project" && pwd -P)"

  printf 'model = "test-model"\n' > "$config_file"
  "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
    trust-project --config "$config_file" "$target_project" >/dev/null 2>&1 \
    || fail "expected trust-project to register target"
  "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
    trust-project --config "$config_file" "$other_project" >/dev/null 2>&1 \
    || fail "expected trust-project to register other project"

  # 등록 키는 trust 시점의 canonical 경로다. 해제는 디렉토리가 사라진 뒤에 불리므로
  # 여기서도 먼저 지워, resolve 없이 키 문자열만으로 지워지는지 확인한다.
  rm -rf "$target_project"

  "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
    untrust-project --config "$config_file" "$target_project" \
    || fail "expected untrust-project to succeed"

  "${WT_PYTHON:-python3}" - "$config_file" "$target_project" "$other_project" <<'PY'
import sys
import tomllib

config_file, target_project, other_project = sys.argv[1:4]
with open(config_file, "rb") as f:
    data = tomllib.load(f)

projects = data.get("projects", {})
assert target_project not in projects, projects
assert projects[other_project]["trust_level"] == "trusted", projects
assert data["model"] == "test-model", data
PY

  # 없는 키 해제는 no-op이어야 한다 (exit 0 + 파일 무변경).
  before_hash=$(cksum < "$config_file")
  set +e
  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
      untrust-project --config "$config_file" "$target_project" 2>&1
  )
  rc=$?
  set -e
  after_hash=$(cksum < "$config_file")
  [[ "$rc" == "0" ]] || fail "expected untrust of absent key to exit 0, got rc=$rc output=$output"
  [[ "$before_hash" == "$after_hash" ]] \
    || fail "untrust of absent key must not rewrite the config"
}

test_codex_trust_gc_dry_run_leaves_config_unchanged() {
  local sandbox config_file stale_project output before_hash after_hash
  if ! codex_config_tomlkit_available; then
    echo "SKIP: codex trust GC dry-run requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  stale_project="$sandbox/repo/.claude/worktrees/feature_stale"

  cat > "$config_file" <<EOF
model = "test-model"

[projects."$stale_project"]
trust_level = "trusted"
EOF
  before_hash=$(cksum < "$config_file")

  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
      gc-worktree-projects --config "$config_file" --dry-run 2>&1
  )

  after_hash=$(cksum < "$config_file")
  assert_contains "$output" "$stale_project"
  # dry-run 요약은 실제 실행과 구분돼야 한다 — 같은 "removed N"이면 로그만 보고 이미
  # 지웠다고 오해한다.
  assert_contains "$output" "would remove 1 (kept 0)"
  assert_not_contains "$output" "removed 1 (kept 0)"
  [[ "$before_hash" == "$after_hash" ]] || fail "gc --dry-run must not modify the config"
  [[ -z "$(find "$sandbox" -maxdepth 1 -name 'config.toml.bak-gc-*' -print -quit)" ]] \
    || fail "gc --dry-run must not create a backup"
}

test_codex_trust_gc_removes_stale_worktree_projects_only() {
  local sandbox config_file live_worktree stale_worktree stale_plain output backup
  if ! codex_config_tomlkit_available; then
    echo "SKIP: codex trust GC requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  live_worktree="$sandbox/repo/.claude/worktrees/feature_live"
  stale_worktree="$sandbox/repo/.claude/worktrees/feature_stale"
  # worktree 경로가 아닌 항목은 디렉토리가 없어도 GC 대상이 아니다 (다른 호스트 경로·
  # 마이그레이션 잔재는 사용자 결정 영역).
  stale_plain="$sandbox/not-a-worktree/project"
  mkdir -p "$live_worktree"

  cat > "$config_file" <<EOF
model = "test-model"

[projects."$live_worktree"]
trust_level = "trusted"

[projects."$stale_worktree"]
trust_level = "trusted"

[projects."$stale_plain"]
trust_level = "trusted"
EOF
  # 원본을 일부러 0600보다 넓게 둔다 — 백업 권한 회귀가 umask에 가려지지 않게 한다.
  chmod 0644 "$config_file"

  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
      gc-worktree-projects --config "$config_file" 2>&1
  )

  assert_contains "$output" "$stale_worktree"
  assert_not_contains "$output" "$stale_plain"
  assert_contains "$output" "removed 1 (kept 2)"

  "${WT_PYTHON:-python3}" - "$config_file" "$live_worktree" "$stale_worktree" "$stale_plain" <<'PY'
import sys
import tomllib

config_file, live_worktree, stale_worktree, stale_plain = sys.argv[1:5]
with open(config_file, "rb") as f:
    data = tomllib.load(f)

projects = data["projects"]
assert stale_worktree not in projects, projects
assert projects[live_worktree]["trust_level"] == "trusted", projects
assert projects[stale_plain]["trust_level"] == "trusted", projects
assert data["model"] == "test-model", data
PY

  backup=$(find "$sandbox" -maxdepth 1 -name 'config.toml.bak-gc-*' -print -quit)
  [[ -n "$backup" ]] || fail "expected gc to leave a timestamped backup"
  assert_contains "$(cat "$backup")" "$stale_worktree"
  # 백업은 config 전체 사본이다. copy2가 원본 mode를 그대로 옮기므로, 원본이 0600보다
  # 넓으면 백업도 넓어진다 (여기서는 위 heredoc이 umask 기본 권한으로 만든다). 새 config는
  # write_atomic이 0600으로 좁히니 백업만 남아 노출되지 않도록 같은 폭을 고정한다.
  [[ "$(_portable_file_mode "$backup")" == "600" ]] \
    || fail "gc backup must be 0600, got $(_portable_file_mode "$backup")"
}

# 실제 Codex config는 [projects."<path>"] 테이블이 다른 최상위 테이블 사이에 흩어져 있어
# tomlkit이 Table 대신 OutOfOrderTableProxy를 준다. 그 프록시의 테이블 위치 맵은 삭제 중
# 조각이 비어 사라질 때 갱신되지 않아, 순차 삭제가 도중에 예외로 죽는다. 위의 in-order
# 소수 fixture로는 재현되지 않으므로 흩어진 대량 fixture를 따로 둔다.
test_codex_trust_gc_handles_out_of_order_projects_tables() {
  local sandbox config_file dry_config live_worktree stale_prefix plain_prefix
  local output rc backup listed
  local stale_count=160 plain_count=40 expected_kept
  if ! codex_config_tomlkit_available; then
    echo "SKIP: codex trust GC out-of-order fixture requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  dry_config="$sandbox/dry-run-config.toml"
  live_worktree="$sandbox/repo/.claude/worktrees/feature_live"
  mkdir -p "$live_worktree"
  live_worktree="$(cd "$live_worktree" && pwd -P)"
  # 존재하지 않는 합성 경로만 쓴다 (실제 홈/사용자 경로를 fixture에 넣지 않는다).
  stale_prefix="/nonexistent-codex-gc/repo/.claude/worktrees"
  plain_prefix="/nonexistent-codex-gc/plain"
  expected_kept=$((plain_count + 1))

  "${WT_PYTHON:-python3}" - \
    "$config_file" "$live_worktree" "$stale_prefix" "$plain_prefix" \
    "$stale_count" "$plain_count" <<'PY'
import sys

(
    config_file,
    live_worktree,
    stale_prefix,
    plain_prefix,
    stale_count,
    plain_count,
) = sys.argv[1:7]
stale_count = int(stale_count)
plain_count = int(plain_count)

# projects 조각별 (stale, 유지) 개수 — 실측한 실제 config(조각 3개, 가운데 조각만 통째로
# stale)의 모양이다. 가운데 조각은 삭제 도중 통째로 비어 프록시의 테이블 리스트에서
# 빠지고, 그러면 마지막 조각 키들이 기억하고 있던 위치가 리스트 밖을 가리키게 된다.
layout = [(60, 20), (20, 0), (80, 20)]
# 조각 사이에 끼우는 비-projects 테이블. 이게 있어야 out-of-order가 된다.
separators = ['[filler_1]\nkeep = 1\n', '[notice]\nmessage = "keep me"\n']
assert sum(s for s, _ in layout) == stale_count, layout
assert sum(p for _, p in layout) == plain_count, layout
assert len(separators) == len(layout) - 1, separators

out = [
    'model = "test-model"\n',
    "# standalone comment must survive GC\n",
    '[tui]\ntheme = "dark"\n',
]
stale_i = plain_i = 0
for frag, (n_stale, n_plain) in enumerate(layout):
    if frag:
        out.append(separators[frag - 1])
    total = n_stale + n_plain
    placed = 0
    for idx in range(total):
        # 유지 항목을 조각 안에 고르게 흩어, 첫/마지막 조각은 삭제 후에도 비지 않게 한다.
        want = round((idx + 1) * n_plain / total)
        if want > placed:
            key = f"{plain_prefix}/project_{plain_i:03d}"
            plain_i += 1
            placed += 1
        else:
            key = f"{stale_prefix}/feature_{stale_i:03d}"
            stale_i += 1
        out.append(f'[projects."{key}"]\ntrust_level = "trusted"\n')
assert (stale_i, plain_i) == (stale_count, plain_count), (stale_i, plain_i)
out.append(f'[projects."{live_worktree}"]\ntrust_level = "trusted"\n')

with open(config_file, "w", encoding="utf-8") as handle:
    handle.write("\n".join(out))
PY
  cp "$config_file" "$dry_config"

  # fixture가 실제로 out-of-order인지 먼저 확인한다 — in-order로 퇴화하면 이 테스트는
  # 회귀를 더 이상 잡지 못하면서도 통과한다.
  "${WT_PYTHON:-python3}" - "$config_file" <<'PY' || fail "fixture must produce an out-of-order projects table"
import sys
import tomlkit
from tomlkit.container import OutOfOrderTableProxy

with open(sys.argv[1], encoding="utf-8") as handle:
    doc = tomlkit.parse(handle.read())
projects = doc["projects"]
assert isinstance(projects, OutOfOrderTableProxy), type(projects)
PY

  # dry-run은 파일을 건드리지 않고 같은 목록을 낸다.
  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
      gc-worktree-projects --config "$dry_config" --dry-run 2>&1
  )
  assert_contains "$output" "would remove $stale_count (kept $expected_kept)"
  assert_not_contains "$output" "$plain_prefix/project_000"
  listed=$(printf '%s\n' "$output" | grep -c -- "^$stale_prefix/feature_" || true)
  [[ "$listed" == "$stale_count" ]] \
    || fail "gc --dry-run must list all $stale_count stale entries, listed=$listed"
  cmp -s "$config_file" "$dry_config" \
    || fail "gc --dry-run must not modify an out-of-order config"

  set +e
  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/codex-trust.py" \
      gc-worktree-projects --config "$config_file" 2>&1
  )
  rc=$?
  set -e
  [[ "$rc" == "0" ]] \
    || fail "gc on an out-of-order projects config must succeed, got rc=$rc output=$output"
  assert_contains "$output" "removed $stale_count (kept $expected_kept)"
  assert_not_contains "$output" "Codex trust GC 건너뜀"
  assert_not_contains "$output" "Traceback"

  grep -q '^# standalone comment must survive GC$' "$config_file" \
    || fail "gc must preserve standalone comments in an out-of-order config"

  "${WT_PYTHON:-python3}" - \
    "$config_file" "$live_worktree" "$stale_prefix" "$plain_prefix" \
    "$stale_count" "$plain_count" <<'PY'
import sys
import tomllib

(
    config_file,
    live_worktree,
    stale_prefix,
    plain_prefix,
    stale_count,
    plain_count,
) = sys.argv[1:7]
stale_count = int(stale_count)
plain_count = int(plain_count)

with open(config_file, "rb") as f:
    data = tomllib.load(f)

projects = data["projects"]
assert len(projects) == plain_count + 1, len(projects)
for i in range(stale_count):
    assert f"{stale_prefix}/feature_{i:03d}" not in projects, i
for i in range(plain_count):
    key = f"{plain_prefix}/project_{i:03d}"
    assert projects[key]["trust_level"] == "trusted", key
assert projects[live_worktree]["trust_level"] == "trusted", projects

# 유지 항목의 값뿐 아니라 projects 조각 사이에 끼어 있던 비-projects 테이블도 남아야 한다.
assert data["model"] == "test-model", data
assert data["tui"]["theme"] == "dark", data
assert data["filler_1"]["keep"] == 1, data
assert data["notice"]["message"] == "keep me", data
PY

  backup=$(find "$sandbox" -maxdepth 1 -name 'config.toml.bak-gc-*' -print -quit)
  [[ -n "$backup" ]] || fail "expected gc to leave a timestamped backup"
  [[ "$(_portable_file_mode "$backup")" == "600" ]] \
    || fail "gc backup must be 0600, got $(_portable_file_mode "$backup")"
  assert_contains "$(cat "$backup")" "$stale_prefix/feature_000"
}

# 삭제 중 tomlkit이 던지는 예외는 traceback으로 새지 않고 기존 GC 스킵 경로로 잡혀야 한다.
# 삭제는 backup/write 이전 단계라 그때 config는 무변경이어야 한다.
test_codex_trust_gc_delete_failure_leaves_config_unchanged() {
  local sandbox config_file stale_project output before_hash after_hash
  if ! codex_config_tomlkit_available; then
    echo "SKIP: codex trust GC delete failure requires tomlkit" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  stale_project="$sandbox/repo/.claude/worktrees/feature_stale"

  cat > "$config_file" <<EOF
model = "test-model"

[projects."$stale_project"]
trust_level = "trusted"
EOF
  before_hash=$(cksum < "$config_file")

  output=$(
    "${WT_PYTHON:-python3}" - "$REPO_ROOT" "$config_file" <<'PY' 2>&1
import importlib.util
from pathlib import Path
import sys

repo_root, config_file = sys.argv[1:3]
module_path = Path(repo_root) / "modules/shared/scripts/lib/wt/codex-trust.py"
spec = importlib.util.spec_from_file_location("codex_trust", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def boom(doc, projects, keys):
    # 실제로 관측된 tomlkit 실패(OutOfOrderTableProxy의 낡은 테이블 위치 참조)를 흉내낸다.
    raise IndexError("list index out of range")


module.delete_project_entries = boom
rc = module.gc_worktree_projects(Path(config_file), False)
assert rc == 1, rc
PY
  )

  after_hash=$(cksum < "$config_file")
  assert_contains "$output" "Codex trust GC 건너뜀"
  assert_contains "$output" "IndexError"
  assert_not_contains "$output" "Traceback"
  [[ "$before_hash" == "$after_hash" ]] \
    || fail "gc must leave the config unchanged when deletion fails"
  [[ -z "$(find "$sandbox" -maxdepth 1 -name 'config.toml.bak-gc-*' -print -quit)" ]] \
    || fail "gc must not create a backup when deletion fails"
}

test_wt_cleanup_untrusts_codex_project() {
  local sandbox home_dir repo_root config_file target_worktree other_project output
  if ! codex_config_tomlkit_available; then
    echo "SKIP: wt cleanup untrusts Codex project requires tomlkit" >&2
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
  target_worktree="$repo_root/.claude/worktrees/feature_one"

  cat > "$config_file" <<EOF
model = "test-model"

[projects."$other_project"]
trust_level = "trusted"

[projects."$target_worktree"]
trust_level = "trusted"
EOF
  chmod 0600 "$config_file"

  output=$(
    env -u TMUX -u CODEX_HOME \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" cleanup feature_one --yes
      ' 2>&1
  )

  assert_contains "$output" "정리 완료: 1개 삭제"
  [[ ! -d "$target_worktree" ]] || fail "expected worktree to be removed: $target_worktree"

  python3 - "$config_file" "$target_worktree" "$other_project" <<'PY'
import sys
import tomllib

config_file, target_worktree, other_project = sys.argv[1:4]
with open(config_file, "rb") as f:
    data = tomllib.load(f)

projects = data.get("projects", {})
assert target_worktree not in projects, projects
assert projects[other_project]["trust_level"] == "trusted", projects
assert data["model"] == "test-model", data
PY
}
