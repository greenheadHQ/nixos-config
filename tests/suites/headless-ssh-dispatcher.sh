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
