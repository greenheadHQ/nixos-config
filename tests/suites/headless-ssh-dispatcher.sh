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
  local sandbox personal_env work_env stable_bin fixture_env bash_bin
  local raw_bin dispatcher_bin tools_bin initial_path snapshot_path actual
  sandbox="$(new_sandbox)"
  raw_bin="$sandbox/raw/bin"
  dispatcher_bin="$sandbox/dispatcher/bin"
  tools_bin="$sandbox/tools/bin"
  bash_bin="$(command -v bash)"
  mkdir -p "$raw_bin" "$dispatcher_bin" "$tools_bin" "$sandbox/home"

  # Claude creates the login-shell snapshot with CLAUDECODE=1. Evaluate the
  # Home Manager result, then replay the production order that regressed:
  # .zshenv -> source snapshot(export PATH) -> external `timeout ssh`.
  personal_env="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"greenhead-MacBookPro\".config.home-manager.users.greenhead.programs.zsh.envExtra"
  )"
  work_env="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"work-MacBookPro\".config.home-manager.users.glen.programs.zsh.envExtra"
  )"
  stable_bin="$(
    sed -n 's@.*export PATH="\([^"]*/headless-ssh/bin\):\$PATH".*@\1@p' <<<"$personal_env" | head -1
  )"
  [[ -n "$stable_bin" ]] || fail "personal envExtra did not expose the stable headless SSH path"
  [[ "$work_env" != *"$stable_bin"* ]] || fail "work host unexpectedly exposed the headless SSH path"

  # Replace only the evaluated absolute deployment path with a hermetic fixture;
  # predicates and shell control flow remain exactly as Home Manager rendered them.
  fixture_env="${personal_env//"$stable_bin"/"$dispatcher_bin"}"
  initial_path="$raw_bin:$tools_bin:/usr/bin:/bin"
  printf '#!/bin/sh\nprintf "raw\\n"\n' > "$raw_bin/ssh"
  printf '#!/bin/sh\nprintf "headless\\n"\n' > "$dispatcher_bin/ssh"
  printf '#!/bin/sh\nexec "$@"\n' > "$tools_bin/timeout"
  chmod +x "$raw_bin/ssh" "$dispatcher_bin/ssh" "$tools_bin/timeout"

  snapshot_path="$(
    env -i HOME="$sandbox/home" PATH="$initial_path" CLAUDECODE=1 \
      "$bash_bin" --noprofile --norc -c "$fixture_env"$'\nprintf "%s" "$PATH"\n'
  )"
  [[ "$snapshot_path" == "$dispatcher_bin:"* ]] \
    || fail "Claude snapshot did not capture dispatcher PATH: $snapshot_path"

  actual="$(
    env -i HOME="$sandbox/home" PATH="$initial_path" \
      CLAUDE_CODE_SESSION_KIND=bg SNAPSHOT_PATH="$snapshot_path" \
      "$bash_bin" --noprofile --norc -c \
      "$fixture_env"$'\nexport PATH="$SNAPSHOT_PATH"\ntimeout ssh\n'
  )"
  [[ "$actual" == "headless" ]] \
    || fail "snapshot-restored external timeout ssh bypassed dispatcher: $actual"

  actual="$(
    env -i HOME="$sandbox/home" PATH="$initial_path" \
      "$bash_bin" --noprofile --norc -c "$fixture_env"$'\ntimeout ssh\n'
  )"
  [[ "$actual" == "raw" ]] || fail "ordinary shell no longer resolves raw SSH: $actual"
}
