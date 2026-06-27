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

  mkdir -p "$home_dir/.local/bin/lib/wt" "$home_dir/.local/lib/lib/rebuild"
  cat > "$home_dir/.local/bin/lib/wt/ui.sh" <<'EOF'
echo "SHADOW_WT_HELPER" >&2
EOF
  while IFS= read -r helper; do
    [[ "$helper" == "ui" ]] && continue
    cat > "$home_dir/.local/bin/lib/wt/$helper.sh" <<'EOF'
:
EOF
  done < <(read_bash_array_from_script "$REPO_ROOT/modules/shared/scripts/wt.sh" "WT_HELPERS")
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
      "'"$home_dir/.local/bin/wt"'" --help
    ' 2>&1
  )

  assert_not_contains "$output" "SHADOW_WT_HELPER"
  assert_not_contains "$output" "SHADOW_REBUILD_HELPER"
}

test_wt_symlink_alias_does_not_load_adjacent_helpers() {
  local sandbox home_dir alias_dir alias_path output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  alias_dir="$sandbox/alias/bin"
  alias_path="$alias_dir/wt"

  install_deployed_layout "$sandbox"

  mkdir -p "$sandbox/alias/lib/wt" "$alias_dir"
  ln -sf "$REPO_ROOT/modules/shared/scripts/wt.sh" "$alias_path"
  cat > "$sandbox/alias/lib/wt/ui.sh" <<'EOF'
echo "MALICIOUS_WT" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$alias_path" --help 2>&1 || true
  )

  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "MALICIOUS_WT"
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

  rm -rf "$home_dir/.local/lib/wt" "$home_dir/.local/lib/rebuild"
  mkdir -p "$home_dir/.local/bin/lib/wt" "$home_dir/.local/lib/lib/rebuild"
  cat > "$home_dir/.local/bin/lib/wt/ui.sh" <<'EOF'
echo "SHADOW_WT_LOADED" >&2
EOF
  cat > "$home_dir/.local/lib/lib/rebuild/common.sh" <<'EOF'
echo "SHADOW_REBUILD_LOADED" >&2
EOF

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$home_dir/.local/bin/wt" --help 2>&1 || true
  )
  assert_contains "$output" "helper directory not found"
  assert_not_contains "$output" "SHADOW_WT_LOADED"

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

test_missing_wt_python_helpers_fail_state_changes() {
  local sandbox home_dir repo_root output rc new_worktree
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  new_worktree="$repo_root/.claude/worktrees/missing-python-helper"
  rm -f "$home_dir/.local/lib/wt/codex-trust.py"

  rc=0
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" missing-python-helper
      ' 2>&1
  ) || rc=$?

  [[ "$rc" -ne 0 ]] || fail "missing wt Python helper must fail state-changing create"
  assert_contains "$output" "Codex trust helper를 찾지 못해 wt 상태 변경 불가"
  [[ ! -d "$new_worktree" ]] || fail "missing wt Python helper must fail before creating worktree"
}

test_missing_wt_python_helpers_fail_cleanup_state_changes() {
  local sandbox home_dir repo_root output rc target_name new_worktree
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  target_name="cleanup-missing-helper"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  new_worktree="$repo_root/.claude/worktrees/$target_name"

  env -u TMUX \
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" "'"$target_name"'"
    ' >/dev/null 2>&1

  [[ -d "$new_worktree" ]] || fail "expected worktree fixture to exist before cleanup"
  rm -f "$home_dir/.local/lib/wt/plugin-manifest.py"

  rc=0
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" cleanup --yes "'"$target_name"'"
      ' 2>&1
  ) || rc=$?

  [[ "$rc" -ne 0 ]] || fail "missing wt Python helper must fail state-changing cleanup"
  assert_contains "$output" "Claude plugin manifest helper를 찾지 못해 wt 상태 변경 불가"
  [[ -d "$new_worktree" ]] || fail "missing wt Python helper must fail before removing worktree"
}

test_codex_trust_write_failure_returns_warning() {
  local sandbox config_file project_root output
  sandbox=$(new_sandbox)
  config_file="$sandbox/config.toml"
  project_root="$sandbox/project"
  mkdir -p "$project_root"

  output=$(
    "${WT_PYTHON:-python3}" - "$REPO_ROOT" "$config_file" "$project_root" <<'PY' 2>&1
import importlib.util
from pathlib import Path
import sys

repo_root, config_file, project_root = sys.argv[1:4]
module_path = Path(repo_root) / "modules/shared/scripts/lib/wt/codex-trust.py"
spec = importlib.util.spec_from_file_location("codex_trust", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

def fail_write(config_path, content):
    raise OSError("synthetic write failure")

module.render_trusted_project = lambda content, project_path, doc=None: 'trusted = true\n'
module.load_toml_doc = lambda content, label: {}
module.write_atomic = fail_write
rc = module.ensure_project_trusted(Path(config_file), Path(project_root))
assert rc == 1, rc
PY
  )
  assert_contains "$output" "Codex trust registration skipped: cannot write config"
}
