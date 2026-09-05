# tests/suites/plugin-manifest.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
managed_plugin_skill_link() {
  local skills_dir="$1"
  local pattern="$2"
  local -a matches=()
  local path
  while IFS= read -r path; do
    matches+=("$path")
  done < <(find "$skills_dir" -maxdepth 1 -type l -name "$pattern" -print)
  (( ${#matches[@]} == 1 )) \
    || fail "expected exactly one managed plugin skill symlink matching: $skills_dir/$pattern (found: ${#matches[@]})"
  printf '%s\n' "${matches[0]}"
}

test_managed_plugin_skill_link_requires_single_match() {
  local sandbox skills_dir output
  sandbox=$(new_sandbox)
  skills_dir="$sandbox/skills"
  mkdir -p "$skills_dir"
  ln -s /tmp/source-one "$skills_dir/wt-plugin--dup-one"
  ln -s /tmp/source-two "$skills_dir/wt-plugin--dup-two"

  if output=$(managed_plugin_skill_link "$skills_dir" 'wt-plugin--dup-*' 2>&1); then
    fail "duplicate managed plugin skill symlinks must fail cardinality assertion"
  fi
  assert_contains "$output" "expected exactly one managed plugin skill symlink"
  assert_contains "$output" "(found: 2)"
}
test_wt_create_inherits_claude_local_plugin_manifest() {
  local sandbox home_dir repo_root manifest settings output new_worktree other_project mode_after plugin_dir alt_plugin_dir manual_plugin_dir projected_skill projected_alt_skill
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  manifest="$home_dir/.claude/plugins/installed_plugins.json"
  settings="$repo_root/.claude/settings.local.json"
  other_project="$sandbox/project-alpha"
  alt_plugin_dir="$sandbox/example-plugin-alt"
  manual_plugin_dir="$sandbox/manual-example-plugin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  plugin_dir="$repo_root/local-plugins/example-plugin"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$manifest")" "$(dirname "$settings")" "$other_project" \
    "$plugin_dir/skills/example-skill" "$alt_plugin_dir/skills/example-skill" "$manual_plugin_dir"
  printf '%s\n' '---' 'name: example-skill' '---' > "$plugin_dir/skills/example-skill/SKILL.md"
  printf '%s\n' '---' 'name: example-skill' '---' > "$alt_plugin_dir/skills/example-skill/SKILL.md"
  HOME="$home_dir" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" -c core.hooksPath=/dev/null -c commit.gpgSign=false \
    add local-plugins/example-plugin
  HOME="$home_dir" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" -c core.hooksPath=/dev/null -c commit.gpgSign=false \
    commit -m "add local plugin fixture" >/dev/null 2>&1

  python3 - "$repo_root" "$settings" "$manifest" "$other_project" "$repo_root/.claude/worktrees/feature-two" "$plugin_dir" "$alt_plugin_dir" "$manual_plugin_dir" <<'PY'
import json
import sys

repo_root, settings, manifest, other_project, target_worktree, plugin_dir, alt_plugin_dir, manual_plugin_dir = sys.argv[1:9]
with open(settings, "w", encoding="utf-8") as f:
    json.dump(
        {
            "enabledPlugins": {
                "example-plugin@demo-marketplace": True,
                "example-plugin@other-marketplace": True,
                "disabled-plugin@demo-marketplace": False,
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": repo_root,
                        "installPath": plugin_dir,
                        "metadata": {"channel": "stable"},
                    },
                    {
                        "scope": "local",
                        "projectPath": target_worktree,
                        "installPath": plugin_dir,
                    },
                    {
                        "scope": "local",
                        "projectPath": target_worktree,
                        "installPath": manual_plugin_dir,
                        "metadata": {"owner": "manual"},
                    },
                    {
                        "scope": "user",
                        "installPath": "/tmp/example-plugin-user",
                    },
                    {
                        "scope": "local",
                        "projectPath": other_project,
                        "installPath": "/tmp/example-plugin-other",
                    },
                ],
                "example-plugin@other-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": repo_root,
                        "installPath": alt_plugin_dir,
                    }
                ],
                "disabled-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": repo_root,
                        "installPath": "/tmp/disabled-plugin",
                    },
                    {
                        "scope": "local",
                        "projectPath": target_worktree,
                        "installPath": "/tmp/stale-disabled-plugin",
                        "metadata": {
                            "wtManaged": {
                                "version": 1,
                                "sourceProjectPath": repo_root,
                                "sourceInstallPath": "/tmp/disabled-plugin"
                            }
                        },
                    }
                ],
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY
  chmod 0644 "$manifest"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-two
        "'"$home_dir/.local/bin/wt"'" --yes --if-exists=recreate feature-two
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/feature-two"
  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "$new_worktree"
  projected_skill=$(managed_plugin_skill_link \
    "$new_worktree/.agents/skills" \
    'wt-plugin--example-plugin_demo-marketplace-*--example-skill-*')
  [[ "$(readlink "$projected_skill")" == "$(cd "$new_worktree/local-plugins/example-plugin/skills/example-skill" && pwd -P)" ]] \
    || fail "projected plugin skill symlink target mismatch"
  projected_alt_skill=$(managed_plugin_skill_link \
    "$new_worktree/.agents/skills" \
    'wt-plugin--example-plugin_other-marketplace-*--example-skill-*')
  [[ "$(readlink "$projected_alt_skill")" == "$(cd "$alt_plugin_dir/skills/example-skill" && pwd -P)" ]] \
    || fail "same plugin name from another source must get a distinct projected skill symlink"
  [[ "$projected_skill" != "$projected_alt_skill" ]] \
    || fail "managed plugin skill symlinks must not collide across plugin keys"
  HOME="$home_dir" XDG_CONFIG_HOME="$home_dir/.config" \
    git -C "$new_worktree" check-ignore -q ".agents/skills/$(basename "$projected_skill")" \
    || fail "managed plugin skill symlink must be ignored from public git artifacts"

  python3 - "$manifest" "$repo_root" "$new_worktree" "$other_project" "$plugin_dir" "$manual_plugin_dir" <<'PY'
import json
import pathlib
import sys

manifest, repo_root, new_worktree, other_project, plugin_dir, manual_plugin_dir = sys.argv[1:7]
repo_root = str(pathlib.Path(repo_root).resolve())
new_worktree = str(pathlib.Path(new_worktree).resolve())
other_project = str(pathlib.Path(other_project).resolve())
target_plugin_dir = str((pathlib.Path(new_worktree) / "local-plugins/example-plugin").resolve())
with open(manifest, encoding="utf-8") as f:
    plugins = json.load(f)["plugins"]

entries = plugins["example-plugin@demo-marketplace"]
target_entries = [
    e for e in entries
    if e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == new_worktree
]
inherited_entries = [e for e in target_entries if e.get("installPath") == target_plugin_dir]
manual_entries = [e for e in target_entries if e.get("installPath") == manual_plugin_dir]
assert len(inherited_entries) == 1, target_entries
assert len(manual_entries) == 1, target_entries
target_entry = inherited_entries[0]
assert target_entry["metadata"]["channel"] == "stable", target_entry
assert target_entry["metadata"]["wtManaged"]["version"] == 1, target_entry
assert target_entry["metadata"]["wtManaged"]["sourceProjectPath"] == repo_root, target_entry
assert target_entry["metadata"]["wtManaged"]["sourceInstallPath"] == plugin_dir, target_entry
assert manual_entries[0]["metadata"] == {"owner": "manual"}, manual_entries

assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == repo_root
    for e in entries
), entries
assert any(e.get("scope") == "user" for e in entries), entries
assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == other_project
    for e in entries
), entries

disabled_entries = plugins["disabled-plugin@demo-marketplace"]
assert not any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == new_worktree
    for e in disabled_entries
), disabled_entries
PY
  mode_after=$(_portable_file_mode "$manifest")
  [[ "$mode_after" == "600" ]] \
    || fail "expected Claude plugin manifest mode 600 after inheritance, got: $mode_after"
}

test_wt_create_ignores_branch_tracked_plugin_settings() {
  local sandbox home_dir repo_root manifest output new_worktree branch_name
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  manifest="$home_dir/.claude/plugins/installed_plugins.json"
  branch_name="branch-tracked-settings"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$manifest")"

  fixture_git_cmd() {
    HOME="$home_dir" \
      XDG_CONFIG_HOME="$home_dir/.config" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      git -C "$repo_root" \
      -c core.hooksPath=/dev/null \
      -c commit.gpgSign=false \
      -c init.templateDir= \
      "$@"
  }

  fixture_git_cmd checkout -b "$branch_name" >/dev/null 2>&1
  mkdir -p "$repo_root/.claude"
  python3 - "$repo_root/.claude/settings.local.json" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"enabledPlugins": {"example-plugin@demo-marketplace": True}}, f, indent=2)
    f.write("\n")
PY
  fixture_git_cmd add -f .claude/settings.local.json
  fixture_git_cmd commit -m "track local settings fixture" >/dev/null 2>&1
  fixture_git_cmd checkout main >/dev/null 2>&1
  [[ ! -f "$repo_root/.claude/settings.local.json" ]] \
    || fail "source local settings fixture should be absent on main"

  python3 - "$repo_root" "$manifest" <<'PY'
import json
import sys

repo_root, manifest = sys.argv[1:3]
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": repo_root,
                        "installPath": "/tmp/example-plugin",
                    }
                ]
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" --if-exists=reuse "'"$branch_name"'"
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/$branch_name"
  [[ ! -e "$new_worktree/.claude/settings.local.json" ]] \
    || fail "branch-tracked target settings must be removed when source settings is absent"
  assert_contains "$output" "$new_worktree"

  python3 - "$manifest" "$new_worktree" <<'PY'
import json
import pathlib
import sys

manifest, new_worktree = sys.argv[1:3]
new_worktree = str(pathlib.Path(new_worktree).resolve())
with open(manifest, encoding="utf-8") as f:
    entries = json.load(f)["plugins"]["example-plugin@demo-marketplace"]
assert not any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == new_worktree
    for e in entries
), entries
PY
}

test_wt_plugin_manifest_ignores_noncanonical_adjacent_lock_directory() {
  local sandbox home_dir repo_root manifest settings new_worktree output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  manifest="$home_dir/.claude/plugins/installed_plugins.json"
  settings="$repo_root/.claude/settings.local.json"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  mkdir -p "$(dirname "$manifest")" "$(dirname "$settings")" "$manifest.lock"

  python3 - "$settings" "$repo_root" "$manifest" <<'PY'
import json
import sys

settings, repo_root, manifest = sys.argv[1:4]
with open(settings, "w", encoding="utf-8") as f:
    json.dump({"enabledPlugins": {"example-plugin@demo-marketplace": True}}, f, indent=2)
    f.write("\n")
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": repo_root,
                        "installPath": "/tmp/example-plugin",
                    }
                ]
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" stale-legacy-lock
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/stale-legacy-lock"
  assert_contains "$output" "$new_worktree"
  [[ -d "$manifest.lock" ]] || fail "noncanonical adjacent lock directory fixture should remain untouched"

  python3 - "$manifest" "$new_worktree" <<'PY'
import json
import pathlib
import sys

manifest, new_worktree = sys.argv[1:3]
new_worktree = str(pathlib.Path(new_worktree).resolve())
with open(manifest, encoding="utf-8") as f:
    entries = json.load(f)["plugins"]["example-plugin@demo-marketplace"]
assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == new_worktree
    for e in entries
), entries
PY
}

test_wt_plugin_manifest_skill_projection_skips_os_errors() {
  local sandbox output
  sandbox=$(new_sandbox)

  output=$(
    python3 - "$REPO_ROOT" "$sandbox" <<'PY' 2>&1
import importlib.util
import os
from pathlib import Path
import sys

repo_root, sandbox = sys.argv[1:3]
module_path = Path(repo_root) / "modules/shared/scripts/lib/wt/plugin-manifest.py"
spec = importlib.util.spec_from_file_location("plugin_manifest", module_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

target_root = Path(sandbox) / "target"
skills_dir = target_root / ".agents/skills"
skills_dir.mkdir(parents=True)
(skills_dir / "wt-plugin--stale").symlink_to("/tmp/stale-source")

original_remove = module.remove_managed_plugin_skill_path

def flaky_remove(path):
    if Path(path).name == "wt-plugin--stale":
        raise OSError("synthetic remove failure")
    return original_remove(path)

original_symlink = module.os.symlink

def flaky_symlink(source, target):
    if Path(target).name == "wt-plugin--bad":
        raise OSError("synthetic symlink failure")
    return original_symlink(source, target)

module.remove_managed_plugin_skill_path = flaky_remove
module.os.symlink = flaky_symlink
module.reconcile_plugin_skill_links(
    str(target_root),
    {
        "wt-plugin--bad": "/tmp/bad-source",
        "wt-plugin--ok": "/tmp/ok-source",
    },
)

ok_link = skills_dir / "wt-plugin--ok"
assert ok_link.is_symlink(), "unrelated valid managed plugin skill link should still be created"
assert os.readlink(ok_link) == "/tmp/ok-source"
assert (skills_dir / "wt-plugin--stale").is_symlink()
assert not (skills_dir / "wt-plugin--bad").exists()
PY
  )
  assert_contains "$output" "cannot remove stale managed plugin skill path"
  assert_contains "$output" "cannot create managed plugin skill symlink"
}

test_wt_plugin_manifest_cleanup_uses_stable_canonical_target() {
  local sandbox manifest target_path other_project
  sandbox=$(new_sandbox)
  manifest="$sandbox/home/.claude/plugins/installed_plugins.json"
  target_path="$sandbox/worktree"
  other_project="$sandbox/project-alpha"

  mkdir -p "$(dirname "$manifest")" "$target_path" "$other_project"
  target_path="$(cd "$target_path" && pwd -P)"
  other_project="$(cd "$other_project" && pwd -P)"

  python3 - "$manifest" "$target_path" "$other_project" <<'PY'
import json
import sys

manifest, target_path, other_project = sys.argv[1:4]
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": target_path,
                        "installPath": "/tmp/target",
                        "metadata": {"wtManaged": {"version": 1}},
                    },
                    {"scope": "local", "projectPath": other_project, "installPath": "/tmp/other"},
                ]
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY

  rm -rf "$target_path"
  ln -s "$other_project" "$target_path"

  "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/plugin-manifest.py" remove-local \
    --manifest "$manifest" \
    --target-root "$target_path" \
    --target-root-before-removal "$target_path"

  python3 - "$manifest" "$target_path" "$other_project" <<'PY'
import json
import pathlib
import sys

manifest, target_path, other_project = sys.argv[1:4]
target_path = str(pathlib.Path(target_path))
other_project = str(pathlib.Path(other_project).resolve())
with open(manifest, encoding="utf-8") as f:
    entries = json.load(f)["plugins"]["example-plugin@demo-marketplace"]
assert not any(e.get("projectPath") == target_path for e in entries), entries
assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == other_project
    for e in entries
), entries
PY
}

test_wt_cleanup_removes_exact_claude_local_plugin_manifest_entries() {
  local sandbox home_dir repo_root manifest target_path other_worktree output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  manifest="$home_dir/.claude/plugins/installed_plugins.json"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"
  other_worktree="$repo_root/.claude/worktrees/feature_two"
  mkdir -p "$(dirname "$manifest")" "$other_worktree"

  python3 - "$manifest" "$repo_root" "$target_path" "$other_worktree" <<'PY'
import json
import sys

manifest, repo_root, target_path, other_worktree = sys.argv[1:5]
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {"scope": "local", "projectPath": repo_root, "installPath": "/tmp/source"},
                    {
                        "scope": "local",
                        "projectPath": target_path,
                        "installPath": "/tmp/target",
                        "metadata": {"wtManaged": {"version": 1}},
                    },
                    {
                        "scope": "local",
                        "projectPath": target_path,
                        "installPath": "/tmp/manual",
                        "metadata": {"owner": "manual"},
                    },
                    {"scope": "local", "projectPath": other_worktree, "installPath": "/tmp/other"},
                    {"scope": "user", "projectPath": target_path, "installPath": "/tmp/user"},
                ],
                "sample-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": target_path,
                        "installPath": "/tmp/remove-only",
                        "metadata": {"wtManaged": {"version": 1}},
                    }
                ],
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY

  output=$(
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
  [[ ! -d "$target_path" ]] || fail "expected worktree to be removed: $target_path"

  python3 - "$manifest" "$repo_root" "$target_path" "$other_worktree" <<'PY'
import json
import pathlib
import sys

manifest, repo_root, target_path, other_worktree = sys.argv[1:5]
repo_root = str(pathlib.Path(repo_root).resolve())
target_path = str(pathlib.Path(target_path).resolve())
other_worktree = str(pathlib.Path(other_worktree).resolve())
with open(manifest, encoding="utf-8") as f:
    plugins = json.load(f)["plugins"]

entries = plugins["example-plugin@demo-marketplace"]
assert not any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == target_path
    and e.get("metadata", {}).get("wtManaged", {}).get("version") == 1
    for e in entries
), entries
assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == target_path
    and e.get("installPath") == "/tmp/manual"
    for e in entries
), entries
assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == repo_root
    for e in entries
), entries
assert any(
    e.get("scope") == "local"
    and str(pathlib.Path(e.get("projectPath", "")).resolve()) == other_worktree
    for e in entries
), entries
assert any(e.get("scope") == "user" for e in entries), entries
assert "sample-plugin@demo-marketplace" not in plugins, plugins
PY
}

test_wt_cleanup_stops_when_plugin_manifest_cleanup_fails() {
  local sandbox home_dir repo_root manifest lock_path target_path output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  manifest="$home_dir/.claude/plugins/installed_plugins.json"
  lock_path="$home_dir/.claude/plugins/.installed_plugins.json.lock"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  target_path="$repo_root/.claude/worktrees/feature_one"
  mkdir -p "$(dirname "$manifest")" "$lock_path"
  printf '{"plugins": {}}\n' > "$manifest"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cleanup feature_one --yes
    ' 2>&1
  )

  assert_contains "$output" "Claude local plugin cleanup 실패"
  assert_contains "$output" "정리 완료: 0개 삭제"
  [[ -d "$target_path" ]] || fail "worktree must remain when plugin manifest cleanup fails"
}

test_wt_plugin_manifest_missing_and_invalid_are_safe() {
  local sandbox home_dir repo_root manifest settings before output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  manifest="$home_dir/.claude/plugins/installed_plugins.json"
  settings="$repo_root/.claude/settings.local.json"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" no-settings
      ' 2>&1
  )
  assert_contains "$output" "$repo_root/.claude/worktrees/no-settings"

  mkdir -p "$(dirname "$settings")"
  python3 - "$settings" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"enabledPlugins": {"example-plugin@demo-marketplace": True}}, f, indent=2)
    f.write("\n")
PY

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" missing-manifest
      ' 2>&1
  )
  assert_contains "$output" "$repo_root/.claude/worktrees/missing-manifest"
  assert_contains "$output" "Claude plugin manifest missing"

  mkdir -p "$(dirname "$manifest")"
  python3 - "$manifest" "$repo_root/.claude/worktrees/invalid-settings" <<'PY'
import json
import sys

manifest, target_worktree = sys.argv[1:3]
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": target_worktree,
                        "installPath": "/tmp/stale-managed",
                        "metadata": {"wtManaged": {"version": 1}},
                    }
                ]
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY
  printf '{not-json\n' > "$settings"
  before="$(cat "$manifest")"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" invalid-settings
      ' 2>&1
  )
  assert_contains "$output" "$repo_root/.claude/worktrees/invalid-settings"
  assert_contains "$output" "settings.local.json JSON is invalid"
  [[ "$(cat "$manifest")" == "$before" ]] || fail "invalid settings must not remove existing managed manifest entries"

  python3 - "$settings" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump({"enabledPlugins": {"example-plugin@demo-marketplace": True}}, f, indent=2)
    f.write("\n")
PY

  printf '{not-json\n' > "$manifest"
  before="$(cat "$manifest")"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" invalid-manifest
      ' 2>&1
  )
  assert_contains "$output" "$repo_root/.claude/worktrees/invalid-manifest"
  assert_contains "$output" "installed_plugins.json JSON is invalid"
  [[ "$(cat "$manifest")" == "$before" ]] || fail "invalid manifest must not be overwritten"

  rm -f "$manifest"
  mkdir -p "$sandbox/manifest-target"
  printf '{"plugins": {}}\n' > "$sandbox/manifest-target/installed_plugins.json"
  ln -s "$sandbox/manifest-target/installed_plugins.json" "$manifest"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" symlink-manifest
      ' 2>&1
  )
  assert_contains "$output" "$repo_root/.claude/worktrees/symlink-manifest"
  assert_contains "$output" "installed_plugins.json is not a regular file"
  [[ -L "$manifest" ]] || fail "unsafe plugin manifest symlink must not be replaced"

  rm -f "$manifest"
  mkfifo "$manifest"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" fifo-manifest
      ' 2>&1
  )
  assert_contains "$output" "$repo_root/.claude/worktrees/fifo-manifest"
  assert_contains "$output" "installed_plugins.json is not a regular file"
  [[ -p "$manifest" ]] || fail "unsafe plugin manifest FIFO must not be replaced"
}

test_wt_plugin_manifest_gc_removes_unmarked_orphan_worktree_entries() {
  local sandbox manifest manifest_dir wt_base target output backup
  sandbox=$(new_sandbox)
  mkdir -p "$sandbox/home/.claude/plugins" "$sandbox/repo/.claude/worktrees" "$sandbox/project-alpha"
  sandbox="$(cd "$sandbox" && pwd -P)"
  manifest_dir="$sandbox/home/.claude/plugins"
  manifest="$manifest_dir/installed_plugins.json"
  wt_base="$sandbox/repo/.claude/worktrees"
  target="$wt_base/target"
  mkdir -p "$wt_base/live-manual"
  # 깨진 symlink는 "무언가 남아 있는" 경로라 orphan으로 보지 않는다 (판정이 lstat 기준임을 고정).
  ln -s "$wt_base/never-existed" "$wt_base/broken-link"

  python3 - "$sandbox" <<'PY'
import json
import os
import sys

sandbox = sys.argv[1]
wt_base = os.path.join(sandbox, "repo", ".claude", "worktrees")
manifest = os.path.join(sandbox, "home", ".claude", "plugins", "installed_plugins.json")


def local(project_path, install_path, managed=False):
    entry = {"scope": "local", "projectPath": project_path, "installPath": install_path}
    if managed:
        entry["metadata"] = {"wtManaged": {"version": 1}}
    return entry


payload = {
    "plugins": {
        "example-plugin@demo-marketplace": [
            local(os.path.join(wt_base, "target"), "/tmp/target", managed=True),
            local(os.path.join(wt_base, "target"), "/tmp/manual"),
            local(os.path.join(wt_base, "orphan-legacy"), "/tmp/legacy"),
            local(os.path.join(wt_base, "feat", "gone-deep"), "/tmp/deep"),
            local(os.path.join(wt_base, "live-manual"), "/tmp/live"),
            local(os.path.join(wt_base, "broken-link"), "/tmp/broken"),
            local(os.path.join(sandbox, "project-alpha"), "/tmp/other"),
            local(os.path.join(sandbox, "gone-project"), "/tmp/gone"),
            {
                "scope": "user",
                "projectPath": os.path.join(wt_base, "orphan-user"),
                "installPath": "/tmp/user",
            },
        ],
        "legacy-only@demo-marketplace": [
            local(os.path.join(wt_base, "orphan-legacy-two"), "/tmp/legacy-two")
        ],
    }
}
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/plugin-manifest.py" remove-local \
      --manifest "$manifest" \
      --target-root "$target" \
      --target-root-before-removal "$target" 2>&1
  )
  assert_contains "$output" "removed 3 orphan worktree entries"
  assert_contains "$output" "plugin manifest orphan: $wt_base/orphan-legacy"
  assert_contains "$output" "plugin manifest orphan: $wt_base/feat/gone-deep"
  assert_contains "$output" "plugin manifest orphan: $wt_base/orphan-legacy-two"

  # pipefail 셸에서 매치 0건이 조용한 abort가 되지 않도록, 판정은 아래 -n 검사로 몰아준다.
  backup=$(command ls "$manifest_dir" | grep '^installed_plugins\.json\.bak-gc-' | head -1 || true)
  [[ -n "$backup" ]] || fail "orphan GC must leave a manifest backup before deleting entries"

  python3 - "$manifest" "$manifest_dir/$backup" "$sandbox" <<'PY'
import json
import os
import stat
import sys

manifest, backup, sandbox = sys.argv[1:4]
wt_base = os.path.join(sandbox, "repo", ".claude", "worktrees")
target = os.path.join(wt_base, "target")

with open(backup, encoding="utf-8") as f:
    backup_paths = [
        entry.get("projectPath")
        for entry in json.load(f)["plugins"]["example-plugin@demo-marketplace"]
    ]
assert os.path.join(wt_base, "orphan-legacy") in backup_paths, backup_paths
backup_mode = stat.S_IMODE(os.stat(backup).st_mode)
assert backup_mode == 0o600, oct(backup_mode)

with open(manifest, encoding="utf-8") as f:
    plugins = json.load(f)["plugins"]
entries = plugins["example-plugin@demo-marketplace"]
kept = [(e.get("scope"), e.get("projectPath"), e.get("installPath")) for e in entries]

# 대상 자신: 표식 있는 등록만 제거되고, 사용자가 직접 만든 등록은 GC에서 빠진다.
assert ("local", target, "/tmp/target") not in kept, kept
assert ("local", target, "/tmp/manual") in kept, kept
# 표식 없는 orphan은 깊이와 무관하게 회수된다.
assert ("local", os.path.join(wt_base, "orphan-legacy"), "/tmp/legacy") not in kept, kept
assert ("local", os.path.join(wt_base, "feat", "gone-deep"), "/tmp/deep") not in kept, kept
assert "legacy-only@demo-marketplace" not in plugins, plugins
# 살아 있는 경로·base 밖 경로·user scope는 그대로 둔다.
assert ("local", os.path.join(wt_base, "live-manual"), "/tmp/live") in kept, kept
assert ("local", os.path.join(wt_base, "broken-link"), "/tmp/broken") in kept, kept
assert ("local", os.path.join(sandbox, "project-alpha"), "/tmp/other") in kept, kept
assert ("local", os.path.join(sandbox, "gone-project"), "/tmp/gone") in kept, kept
assert ("user", os.path.join(wt_base, "orphan-user"), "/tmp/user") in kept, kept
PY
}

test_wt_plugin_manifest_gc_skips_targets_outside_worktree_base() {
  local sandbox manifest target orphan_sibling output
  sandbox=$(new_sandbox)
  manifest="$sandbox/home/.claude/plugins/installed_plugins.json"

  mkdir -p "$(dirname "$manifest")" "$sandbox/projects/target"
  target="$(cd "$sandbox/projects/target" && pwd -P)"
  orphan_sibling="$(dirname "$target")/gone"

  python3 - "$manifest" "$target" "$orphan_sibling" <<'PY'
import json
import sys

manifest, target, orphan_sibling = sys.argv[1:4]
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(
        {
            "plugins": {
                "example-plugin@demo-marketplace": [
                    {
                        "scope": "local",
                        "projectPath": target,
                        "installPath": "/tmp/target",
                        "metadata": {"wtManaged": {"version": 1}},
                    },
                    {"scope": "local", "projectPath": orphan_sibling, "installPath": "/tmp/sibling"},
                ]
            }
        },
        f,
        indent=2,
    )
    f.write("\n")
PY

  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/plugin-manifest.py" remove-local \
      --manifest "$manifest" \
      --target-root "$target" \
      --target-root-before-removal "$target" 2>&1
  )
  assert_not_contains "$output" "orphan worktree entries"

  python3 - "$manifest" "$target" "$orphan_sibling" <<'PY'
import json
import sys

manifest, target, orphan_sibling = sys.argv[1:4]
with open(manifest, encoding="utf-8") as f:
    entries = json.load(f)["plugins"]["example-plugin@demo-marketplace"]
paths = [e.get("projectPath") for e in entries]
assert target not in paths, paths
assert orphan_sibling in paths, paths
PY
}

# 경로 존재 여부를 확인하지 못하면(EACCES 등) 지우지 않는다 — root는 권한 검사를 우회하므로 skip.
test_wt_plugin_manifest_gc_keeps_entries_when_path_check_fails() {
  local sandbox manifest wt_base target output
  if [ "$(id -u)" = 0 ]; then
    echo "    (skip: root bypasses directory permission checks)" >&2
    return 0
  fi
  sandbox=$(new_sandbox)
  mkdir -p "$sandbox/home/.claude/plugins" "$sandbox/repo/.claude/worktrees"
  sandbox="$(cd "$sandbox" && pwd -P)"
  manifest="$sandbox/home/.claude/plugins/installed_plugins.json"
  wt_base="$sandbox/repo/.claude/worktrees"
  target="$wt_base/target"
  mkdir -p "$wt_base/live-unmarked"

  python3 - "$sandbox" <<'PY'
import json
import os
import sys

sandbox = sys.argv[1]
wt_base = os.path.join(sandbox, "repo", ".claude", "worktrees")
manifest = os.path.join(sandbox, "home", ".claude", "plugins", "installed_plugins.json")
payload = {
    "plugins": {
        "example-plugin@demo-marketplace": [
            {
                "scope": "local",
                "projectPath": os.path.join(wt_base, "target"),
                "installPath": "/tmp/target",
                "metadata": {"wtManaged": {"version": 1}},
            },
            {
                "scope": "local",
                "projectPath": os.path.join(wt_base, "live-unmarked"),
                "installPath": "/tmp/live",
            },
            {
                "scope": "local",
                "projectPath": os.path.join(wt_base, "gone-sibling"),
                "installPath": "/tmp/gone",
            },
        ]
    }
}
with open(manifest, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
PY

  chmod 000 "$wt_base"
  output=$(
    "${WT_PYTHON:-python3}" "$REPO_ROOT/modules/shared/scripts/lib/wt/plugin-manifest.py" remove-local \
      --manifest "$manifest" \
      --target-root "$target" \
      --target-root-before-removal "$target" 2>&1
  ) || {
    chmod 755 "$wt_base"
    fail "remove-local must not fail when worktree paths cannot be checked"
  }
  chmod 755 "$wt_base"  # sandbox 자동 cleanup이 rm -rf 할 수 있도록 권한 복구.

  assert_not_contains "$output" "orphan worktree entries"
  assert_contains "$output" "cannot check worktree path"

  python3 - "$manifest" "$sandbox" <<'PY'
import json
import os
import sys

manifest, sandbox = sys.argv[1:3]
wt_base = os.path.join(sandbox, "repo", ".claude", "worktrees")
with open(manifest, encoding="utf-8") as f:
    entries = json.load(f)["plugins"]["example-plugin@demo-marketplace"]
paths = [entry.get("projectPath") for entry in entries]
# 표식 있는 대상은 문자열 대조로 제거되지만, 확인하지 못한 형제 등록은 남는다.
assert os.path.join(wt_base, "target") not in paths, paths
assert os.path.join(wt_base, "live-unmarked") in paths, paths
assert os.path.join(wt_base, "gone-sibling") in paths, paths
PY
}
