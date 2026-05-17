#!/usr/bin/env bash
# Install Lefthook (worktree-local in worktrees, default in main) and inject the staged-config guard.
#
# Design split — main repo vs. worktree (preserves PR #750's worktree-local design):
#
# * Main repo (git-common-dir == git-dir): the previous version of this script wrote
#   `extensions.worktreeConfig=true` + `--worktree core.hooksPath=<git-dir>/hooks` on every
#   direnv reload. In the main repo this points to the same `.git/hooks` git already
#   resolves by default, so it was redundant — but it tripped lefthook 2.1+'s
#   "core.hooksPath is set locally" guard, forcing `--force` and two warning lines on
#   every reload. We now unset that redundant value (only when it matches the default,
#   preserving any deliberate user override) and call `lefthook install` without --force.
#
# * Worktree (git-common-dir != git-dir): PR #750 deliberately installs hooks under
#   the worktree-local `.git/worktrees/<name>/hooks/` directory via
#   `--worktree core.hooksPath`. That is *not* git's default resolution — git would
#   otherwise route every worktree through the shared `.git/hooks/` and let any
#   nearby worktree's `lefthook install` silently overwrite the staged-config guard
#   we inject below. We preserve that worktree-local design here and keep `--force`
#   because lefthook's guard fires on the (intentional) core.hooksPath override.
#
# Source-of-truth scope: this script governs lefthook install + guard injection for
# the main repo and every worktree whose flake.nix shellHook calls
# `bash ./scripts/ai/install-lefthook-hooks.sh`. Worktrees with inline shellHook
# implementations (`.claude/worktrees/issue_587/flake.nix` 등 8개) are outside this
# scope and tracked as NG-1 (follow-up consolidation candidate). The lefthook.yml
# `lefthook-guard-self-check` job is a second-layer regression defense that catches
# silent guard removal by any worktree at commit-time.
set -euo pipefail

# Marker constants — kept on dedicated lines so tests/shell-script-tests.sh can
# sed-extract them and avoid hard-coding the literal in a second place.
BEGIN_MARKER="# BEGIN nixos-config lefthook staged-config guard"
END_MARKER="# END nixos-config lefthook staged-config guard"

# 30 minutes — install itself runs in ~150ms; this guards against hung child
# processes (NFS lock issues, OS bugs) rather than normal contention. Matches the
# convention from modules/shared/scripts/lib/rebuild/locks.sh:198.
LOCK_TIMEOUT_SECONDS=1800

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
git_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-dir)"
git_common_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir)"
hooks_dir="$git_dir/hooks"
mkdir -p "$hooks_dir"

is_main_repo() {
  # In the main repo, git-dir and git-common-dir are the same path. In a worktree
  # they diverge (git-dir = .git/worktrees/<name>, git-common-dir = .git).
  [ "$git_dir" = "$git_common_dir" ]
}

cleanup_main_redundant_hooks_path() {
  # Main repo only. Unset core.hooksPath if (and only if) it points to git's
  # default resolution location — i.e., it was set by a prior version of this
  # script and is now redundant. If a user (or another tool) pointed it
  # elsewhere, leave it alone and surface a warning so the user can decide.
  #
  # We deliberately do not use `lefthook install --reset-hooks-path` here:
  # that flag unsets the value unconditionally, which would wipe user-intended
  # overrides too. Our scope-aware comparison preserves them.
  local default_hooks current scope
  default_hooks="$git_common_dir/hooks"

  for scope in local worktree; do
    if [ "$scope" = "worktree" ] && \
       [ "$(git -C "$repo_root" config --get extensions.worktreeConfig 2>/dev/null || echo false)" != "true" ]; then
      continue
    fi
    current="$(git -C "$repo_root" config "--$scope" --get core.hooksPath 2>/dev/null || true)"
    [ -n "$current" ] || continue
    if [ "$current" = "$default_hooks" ]; then
      # `|| true`: cleanup runs outside the install lock (it must precede the lock so
      # lefthook install sees the cleaned-up state). On the rare main-vs-main concurrent
      # install where another process unsets the same key first, the second --unset-all
      # returns exit 5; idempotency keeps the script from failing.
      git -C "$repo_root" config "--$scope" --unset-all core.hooksPath 2>/dev/null || true
      echo "install-lefthook-hooks: removed redundant core.hooksPath ($scope). Hooks resolve to ${default_hooks}." >&2
    else
      echo "install-lefthook-hooks: non-default core.hooksPath ($scope) detected: ${current}." >&2
      echo "  Preserved. lefthook install will fail in main mode (--force is intentionally not added);" >&2
      echo "  unset the override or set LEFTHOOK=0 to skip install for the current shell." >&2
    fi
  done
}

apply_worktree_local_hooks_config() {
  # Worktree only. Pin core.hooksPath to this worktree's git-dir so that another
  # worktree's `lefthook install` cannot silently overwrite our staged-config
  # guard. This is the PR #750 worktree-local design (idempotent + isolated).
  # lefthook 2.1+ refuses to install when core.hooksPath is set, so we accept
  # the trade-off and pass --force in run_lefthook_install.
  git -C "$repo_root" config extensions.worktreeConfig true
  git -C "$repo_root" config --worktree core.hooksPath "$hooks_dir"
}

acquire_install_lock() {
  # Critical section: lefthook rewrites the hook file and the Python block
  # below re-reads + re-writes it to inject the staged-config guard. Without
  # serialization a "nested guard marker" SystemExit can fire when two direnv
  # reloads race. The lock pins both operations into one critical section.
  #
  # Lock path lives under the main repo's .git/info — every worktree shares
  # this directory via `git rev-parse --git-common-dir`, so installs from the
  # main repo and any worktree all serialize on the same lock. .git/info
  # already exists in the main repo (lefthook.checksum lives there), so no
  # mkdir is required.
  #
  # fd 200: outside stdin/stdout/stderr (0-2) and shell-builtin reserved range
  # (3-9); matches the convention from locks.sh:202. Closed explicitly in
  # children of run_lefthook_install / inject_staged_guard so they cannot
  # extend the lock's lifetime past this script.
  local lock_file lock_dir
  lock_file="$git_common_dir/info/lefthook-install.lock"
  lock_dir="$(dirname "$lock_file")"
  # .git/info is normally created by git init, but fresh-clone or fixture environments
  # can miss it; create on demand so the lock file open below cannot fail with ENOENT.
  [ -d "$lock_dir" ] || mkdir -p "$lock_dir"

  exec 200>"$lock_file"

  if command -v flock >/dev/null 2>&1; then
    # Linux (NixOS): fd-based, auto-released when the fd closes.
    flock --timeout "$LOCK_TIMEOUT_SECONDS" 200 \
      || fail "lefthook install lock timed out after ${LOCK_TIMEOUT_SECONDS}s (flock)"
  elif command -v lockf >/dev/null 2>&1; then
    # macOS (Darwin): fd-based BSD flock(2) wrapper, auto-released when the fd closes.
    lockf -s -t "$LOCK_TIMEOUT_SECONDS" 200 \
      || fail "lefthook install lock timed out after ${LOCK_TIMEOUT_SECONDS}s (lockf)"
  else
    fail "neither flock nor lockf available; cannot serialize lefthook install"
  fi
}

run_lefthook_install() {
  # lefthook 2.x has no --quiet flag and prints "sync hooks: ✔️ ..." on every
  # install, plus two "core.hooksPath is set locally" + "Installing hooks
  # anyway" lines when --force is used in worktree mode. Suppress that normal
  # output so direnv reloads stay silent (SC-1) but re-emit captured output on
  # failure so the user still sees error context.
  #
  # 200>&-: explicitly close fd 200 in the lefthook child so it cannot extend
  # the lock's lifetime if it ever spawns a background process.
  local install_output rc=0
  if is_main_repo; then
    install_output="$(lefthook install 200>&- 2>&1)" || rc=$?
  else
    install_output="$(lefthook install --force 200>&- 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    if [ -n "$install_output" ]; then
      printf '%s\n' "$install_output" >&2
    fi
    fail "lefthook install failed (exit $rc)"
  fi
}

inject_staged_guard() {
  local hook_path
  hook_path="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks/pre-commit)"
  [ -f "$hook_path" ] || fail "generated pre-commit hook not found: $hook_path"

  # 200>&- closes the lock fd in the python child for the same reason as run_lefthook_install.
  python3 - "$hook_path" "$BEGIN_MARKER" "$END_MARKER" 200>&- <<'PY'
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

  # Defense in depth: confirm the marker pair really landed before returning.
  # Catches any future regression in inject_staged_guard itself (the python
  # block above) before the user attempts to commit and trips the guard.
  if ! grep -Fq "$BEGIN_MARKER" "$hook_path" || ! grep -Fq "$END_MARKER" "$hook_path"; then
    fail "guard injection verification failed: marker pair missing from $hook_path"
  fi
}

if is_main_repo; then
  cleanup_main_redundant_hooks_path
else
  apply_worktree_local_hooks_config
fi
acquire_install_lock
run_lefthook_install
inject_staged_guard
