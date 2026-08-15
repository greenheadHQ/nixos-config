# tests/suites/headless-ssh-dispatcher.sh — hermetic headless SSH dispatcher groups
# shellcheck shell=bash

_run_headless_ssh_dispatcher_group() {
  local group="$1"
  python3 "$REPO_ROOT/tests/headless-ssh-dispatcher-tests.py" "$group"
}

test_headless_ssh_dispatcher_group_coverage() {
  python3 - "$REPO_ROOT/tests/headless-ssh-dispatcher-tests.py" <<'PY'
import ast
import pathlib
import sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
actual = sorted(
    node.name
    for node in tree.body
    if isinstance(node, ast.ClassDef)
    and any(isinstance(base, ast.Name) and base.id == "DispatcherFixture" for base in node.bases)
)
expected = sorted("CoreContractTests ScopeTests LifecycleTests DependencyTests".split())
if actual != expected:
    raise SystemExit(f"dispatcher suite class coverage drift: actual={actual} expected={expected}")
PY
}

test_headless_ssh_dispatcher_core_contract() {
  _run_headless_ssh_dispatcher_group CoreContractTests
}

test_headless_ssh_dispatcher_scope_parser() {
  _run_headless_ssh_dispatcher_group ScopeTests
}

test_headless_ssh_dispatcher_supervisor() {
  _run_headless_ssh_dispatcher_group LifecycleTests
}

test_headless_ssh_dispatcher_identity_compat() {
  _run_headless_ssh_dispatcher_group DependencyTests
}

test_claude_snapshot_preserves_headless_ssh_path() {
  local sandbox personal_env personal_init work_env finalizer
  local stable_bin fixture_env fixture_finalizer zsh_bin
  local raw_bin dispatcher_bin competitor_bin tools_bin initial_path snapshot_path actual
  sandbox="$(new_sandbox)"
  raw_bin="$sandbox/raw/bin"
  dispatcher_bin="$sandbox/dispatcher/bin"
  competitor_bin="$sandbox/competitor/bin"
  tools_bin="$sandbox/tools/bin"
  zsh_bin="$(command -v zsh)"
  mkdir -p "$raw_bin" "$dispatcher_bin" "$competitor_bin" "$tools_bin" "$sandbox/home"

  # Claude creates the login-shell snapshot with CLAUDECODE=1 and explicitly
  # sources .zshrc before recording it. Evaluate both Home Manager outputs and
  # replay the full production order in the production shell parser.
  personal_env="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"greenhead-MacBookPro\".config.home-manager.users.greenhead.programs.zsh.envExtra"
  )"
  personal_init="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"greenhead-MacBookPro\".config.home-manager.users.greenhead.programs.zsh.initContent"
  )"
  work_env="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"work-MacBookPro\".config.home-manager.users.glen.programs.zsh.envExtra"
  )"
  finalizer="$(
    awk '
      /BEGIN nixos-config headless SSH snapshot PATH finalizer/ { emit = 1 }
      emit { print }
      /END nixos-config headless SSH snapshot PATH finalizer/ { exit }
    ' <<<"$personal_init"
  )"
  stable_bin="$(
    sed -n 's@.*path=("\([^"]*/headless-ssh/bin\)".*@\1@p' <<<"$personal_env" | head -1
  )"
  [[ -n "$stable_bin" ]] || fail "personal envExtra did not expose the stable headless SSH path"
  [[ -n "$finalizer" ]] || fail "personal initContent did not expose the snapshot PATH finalizer"
  [[ "$work_env" != *"$stable_bin"* ]] || fail "work host unexpectedly exposed the headless SSH path"

  # Replace only the evaluated deployment path. Predicates, zsh path-array
  # behavior, and finalizer control flow remain exactly as rendered.
  fixture_env="${personal_env//"$stable_bin"/"$dispatcher_bin"}"
  fixture_finalizer="${finalizer//"$stable_bin"/"$dispatcher_bin"}"
  initial_path="$raw_bin:$tools_bin:/usr/bin:/bin"
  printf '#!/bin/sh\nprintf "raw\\n"\n' > "$raw_bin/ssh"
  printf '#!/bin/sh\nprintf "headless\\n"\n' > "$dispatcher_bin/ssh"
  printf '#!/bin/sh\nprintf "competitor\\n"\n' > "$competitor_bin/ssh"
  # Keep timeout explicit so the fixture varies only the child ssh lookup.
  printf '#!/bin/sh\nexec "$@"\n' > "$tools_bin/timeout"
  chmod +x \
    "$raw_bin/ssh" "$dispatcher_bin/ssh" "$competitor_bin/ssh" \
    "$tools_bin/timeout"

  mkdir -p "$sandbox/snapshot-zdot" "$sandbox/tool-zdot" "$sandbox/work-zdot"
  printf 'export PATH="%s"\n%s\n' "$initial_path" "$fixture_env" > "$sandbox/snapshot-zdot/.zshenv"
  printf 'export PATH="%s:$PATH"\n%s\n' \
    "$competitor_bin" "$fixture_finalizer" > "$sandbox/snapshot-zdot/.zshrc"
  printf 'export PATH="%s"\n%s\n' "$initial_path" "$fixture_env" > "$sandbox/tool-zdot/.zshenv"
  printf 'export PATH="%s"\n%s\n' "$initial_path" "$work_env" > "$sandbox/work-zdot/.zshenv"

  snapshot_path="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/snapshot-zdot" \
      PATH="$initial_path" CLAUDECODE=1 \
      "$zsh_bin" -d -c -l 'source "$ZDOTDIR/.zshrc" < /dev/null; print -r -- "$PATH"'
  )"
  [[ "$snapshot_path" == "$dispatcher_bin:"* ]] \
    || fail "Claude zsh snapshot did not finalize dispatcher PATH: $snapshot_path"
  [[ "$snapshot_path" == *":$competitor_bin:"* ]] \
    || fail "snapshot fixture did not retain the competing PATH entry"

  printf 'export PATH="%s"\n' "$snapshot_path" > "$sandbox/fresh-snapshot.sh"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/tool-zdot" PATH="$initial_path" \
      CLAUDE_CODE_SESSION_KIND=bg SNAPSHOT_FILE="$sandbox/fresh-snapshot.sh" \
      TIMEOUT_BIN="$tools_bin/timeout" \
      "$zsh_bin" -d -c 'source "$SNAPSHOT_FILE"; "$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "headless" ]] \
    || fail "snapshot-restored external timeout ssh bypassed dispatcher: $actual"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/tool-zdot" PATH="$initial_path" \
      NIXOS_CONFIG_HEADLESS_SSH=1 TIMEOUT_BIN="$tools_bin/timeout" \
      "$zsh_bin" -d -c '"$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "headless" ]] || fail "launcher marker did not resolve dispatcher SSH: $actual"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/tool-zdot" PATH="$initial_path" \
      TIMEOUT_BIN="$tools_bin/timeout" "$zsh_bin" -d -c '"$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "raw" ]] || fail "ordinary shell no longer resolves raw SSH: $actual"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/work-zdot" PATH="$initial_path" \
      CLAUDECODE=1 TIMEOUT_BIN="$tools_bin/timeout" "$zsh_bin" -d -c '"$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "raw" ]] || fail "work-host Claude shell no longer resolves raw SSH: $actual"
}

test_claude_stale_snapshot_path_recovery() {
  local sandbox snapshot_dir stale_snapshot dispatcher_bin raw_bin tools_bin initial_path zsh_bin actual
  local recovery="$REPO_ROOT/modules/shared/programs/shell/files/refresh-claude-snapshot-paths.sh"
  sandbox="$(new_sandbox)"
  snapshot_dir="$sandbox/shell-snapshots"
  stale_snapshot="$snapshot_dir/snapshot-zsh-stale.sh"
  dispatcher_bin="$sandbox/dispatcher/bin"
  raw_bin="$sandbox/raw/bin"
  tools_bin="$sandbox/tools/bin"
  initial_path="$raw_bin:$tools_bin:/usr/bin:/bin"
  zsh_bin="$(command -v zsh)"
  mkdir -p "$snapshot_dir" "$dispatcher_bin" "$raw_bin" "$tools_bin" "$sandbox/home" "$sandbox/zdot"

  printf '#!/bin/sh\nprintf "raw\\n"\n' > "$raw_bin/ssh"
  printf '#!/bin/sh\nprintf "headless\\n"\n' > "$dispatcher_bin/ssh"
  printf '#!/bin/sh\nexec "$@"\n' > "$tools_bin/timeout"
  chmod +x "$raw_bin/ssh" "$dispatcher_bin/ssh" "$tools_bin/timeout"
  printf 'export PATH="%s"\n' "$initial_path" > "$stale_snapshot"
  printf 'sentinel\n' > "$sandbox/symlink-target"
  ln -s "$sandbox/symlink-target" "$snapshot_dir/snapshot-zsh-symlink.sh"

  bash "$recovery" "$snapshot_dir" "$dispatcher_bin"
  bash "$recovery" "$snapshot_dir" "$dispatcher_bin"

  [[ "$(grep -Fc '# nixos-config headless SSH PATH recovery v1' "$stale_snapshot")" == "1" ]] \
    || fail "stale snapshot recovery was not idempotent"
  [[ "$(cat "$sandbox/symlink-target")" == "sentinel" ]] \
    || fail "snapshot recovery followed a symlink"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/zdot" PATH="$initial_path" \
      CLAUDE_CODE_SESSION_KIND=bg SNAPSHOT_FILE="$stale_snapshot" \
      TIMEOUT_BIN="$tools_bin/timeout" \
      "$zsh_bin" -d -c 'source "$SNAPSHOT_FILE"; "$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "headless" ]] \
    || fail "pre-deployment stale snapshot still resolved raw SSH: $actual"
}
