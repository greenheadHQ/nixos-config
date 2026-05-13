#!/usr/bin/env bash
# Install Lefthook using a worktree-local hooks path and inject the staged config guard.
set -euo pipefail

BEGIN_MARKER="# BEGIN nixos-config lefthook staged-config guard"
END_MARKER="# END nixos-config lefthook staged-config guard"

fail() {
  echo "install-lefthook-hooks: $*" >&2
  exit 1
}

if [ "${LEFTHOOK:-}" = "0" ] || [ "${LEFTHOOK:-}" = "false" ]; then
  exit 0
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
  exit 0
fi

command -v lefthook >/dev/null 2>&1 || fail "lefthook not found"
command -v python3 >/dev/null 2>&1 || fail "python3 not found"

repo_root="$(git rev-parse --show-toplevel)"
worktree_git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-dir)"
hooks_dir="$worktree_git_dir/hooks"
mkdir -p "$hooks_dir"

git -C "$repo_root" config extensions.worktreeConfig true
git -C "$repo_root" config --worktree core.hooksPath "$hooks_dir"

lefthook install --force

hook_path="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks/pre-commit)"
[ -f "$hook_path" ] || fail "generated pre-commit hook not found: $hook_path"

python3 - "$hook_path" "$BEGIN_MARKER" "$END_MARKER" <<'PY'
from __future__ import annotations

from pathlib import Path
import sys

hook_path = Path(sys.argv[1])
begin = sys.argv[2]
end = sys.argv[3]

lines = hook_path.read_text(encoding="utf-8").splitlines()

regions: list[tuple[int, int]] = []
active: int | None = None
for idx, line in enumerate(lines):
    if line == begin:
        if active is not None:
            raise SystemExit("install-lefthook-hooks: nested guard marker")
        active = idx
    elif line == end:
        if active is None:
            raise SystemExit("install-lefthook-hooks: unmatched end guard marker")
        regions.append((active, idx))
        active = None
if active is not None:
    raise SystemExit("install-lefthook-hooks: unmatched begin guard marker")

remove = set()
for start, finish in regions:
    remove.update(range(start, finish + 1))
stripped = [line for idx, line in enumerate(lines) if idx not in remove]

call_indexes = [
    idx
    for idx, line in enumerate(stripped)
    if 'call_lefthook run "pre-commit" "$@"' in line
]
if not call_indexes:
    raise SystemExit("install-lefthook-hooks: final Lefthook pre-commit call not found")
insert_at = call_indexes[-1]

guard = [
    begin,
    'repo_root="$(git rev-parse --show-toplevel)" || exit 1',
    'expected_lefthook_config="$(cd "$repo_root" && pwd -P)/lefthook.yml"',
    'if [ -n "${LEFTHOOK_CONFIG:-}" ]; then',
    '  config_dir="$(dirname "$LEFTHOOK_CONFIG")"',
    '  config_base="$(basename "$LEFTHOOK_CONFIG")"',
    '  config_abs="$(cd "$config_dir" 2>/dev/null && pwd -P)/$config_base" || { echo "lefthook staged guard: invalid LEFTHOOK_CONFIG" >&2; exit 1; }',
    '  if [ "$config_abs" != "$expected_lefthook_config" ]; then',
    '    echo "lefthook staged guard: LEFTHOOK_CONFIG must point to repo lefthook.yml" >&2',
    '    exit 1',
    '  fi',
    'fi',
    'if [ -n "${LEFTHOOK_BIN:-}" ]; then',
    '  echo "lefthook staged guard: LEFTHOOK_BIN is not allowed for guarded commits" >&2',
    '  exit 1',
    'fi',
    'if [ -n "${LEFTHOOK_EXCLUDE:-}" ]; then',
    '  echo "lefthook staged guard: LEFTHOOK_EXCLUDE is not allowed for guarded commits" >&2',
    '  exit 1',
    'fi',
    'guard_path="scripts/ai/check-lefthook-staged-config.sh"',
    'if git -C "$repo_root" cat-file -e ":$guard_path" 2>/dev/null; then',
    '  guard_entry="$(git -C "$repo_root" ls-files -s -- "$guard_path")"',
    '  guard_count="$(printf "%s\\n" "$guard_entry" | sed "/^$/d" | wc -l | tr -d " ")"',
    '  guard_mode="$(printf "%s\\n" "$guard_entry" | awk \'{ print $1 }\')"',
    '  guard_stage="$(printf "%s\\n" "$guard_entry" | awk \'{ print $3 }\')"',
    '  if [ "$guard_count" != "1" ] || [ "$guard_stage" != "0" ] || { [ "$guard_mode" != "100644" ] && [ "$guard_mode" != "100755" ]; }; then',
    '    echo "lefthook staged guard: invalid staged guard script index entry" >&2',
    '    exit 1',
    '  fi',
    '  guard_tmp="$(mktemp "${TMPDIR:-/tmp}/lefthook-staged-guard.XXXXXX")" || exit 1',
    '  if ! git -C "$repo_root" show ":$guard_path" > "$guard_tmp"; then',
    '    rm -f "$guard_tmp"',
    '    echo "lefthook staged guard: failed to materialize staged guard script" >&2',
    '    exit 1',
    '  fi',
    '  guard_status=0',
    '  bash "$guard_tmp" "$repo_root" || guard_status="$?"',
    '  rm -f "$guard_tmp"',
    '  if [ "$guard_status" != "0" ]; then',
    '    exit "$guard_status"',
    '  fi',
    'else',
    '  if git -C "$repo_root" cat-file -e "HEAD:$guard_path" 2>/dev/null; then',
    '    echo "lefthook staged guard: guard script missing from index" >&2',
    '    exit 1',
    '  fi',
    '  if git -C "$repo_root" show :lefthook.yml 2>/dev/null | grep -Eq "scripts/ai/run-staged-snapshot.sh|scripts/ai/run-gitleaks-staged-policy.sh"; then',
    '    echo "lefthook staged guard: staged-snapshot hook surface requires staged guard script" >&2',
    '    exit 1',
    '  fi',
    'fi',
    end,
]

updated = stripped[:insert_at] + guard + stripped[insert_at:]
hook_path.write_text("\n".join(updated) + "\n", encoding="utf-8")
PY

chmod +x "$hook_path"
bash -n "$hook_path"
