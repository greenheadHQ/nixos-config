#!/usr/bin/env bash
# Install Lefthook (worktree-local in worktrees, default in main), refuse symlinked hooks before
# `lefthook install` can write through them, inject the staged-config guard, and suppress
# lefthook's implicit auto-install on every configured hook.
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
# `bash ./scripts/ai/install-lefthook-hooks.sh`. Worktrees whose shellHook still calls
# `lefthook install` inline are outside this scope and tracked as NG-1 (issue #789).
# Enumerate the current ones instead of trusting a hard-coded count — that number went
# stale before:
#   rg -l 'git config --unset-all --local core\.hooksPath' .claude/worktrees/*/flake.nix
# The lefthook.yml `lefthook-guard-self-check` job is a second-layer regression defense
# that catches silent guard removal by any worktree at commit-time.
set -euo pipefail

# Marker constants — kept on dedicated lines so tests/shell-script-tests.sh can
# sed-extract them and avoid hard-coding the literal in a second place.
BEGIN_MARKER="# BEGIN nixos-config lefthook staged-config guard"
END_MARKER="# END nixos-config lefthook staged-config guard"

# `lefthook run`은 lefthook.checksum(해시 + config mtime)이 현재 lefthook.yml과
# 어긋나면 hook 파일 전체를 암묵적으로 재설치한다 ("sync hooks: ✔️ (...)"). 그 재설치는
# 순수 lefthook 템플릿을 쓰므로 inject_staged_guard가 넣은 guard 블록이 조용히 사라지고,
# 바로 그 실행의 lefthook-guard-self-check가 자기가 방금 잃은 guard를 발견해 commit을
# 차단한다 (= lefthook.yml이 바뀐 뒤 첫 commit은 항상 실패). hook 하나에서 sync가 나면
# pre-commit/commit-msg/pre-push가 한꺼번에 재생성되므로 세 hook 모두 차단해야 한다.
# LEFTHOOK_* env로는 끌 수 없고 `lefthook run --no-auto-install`이 유일한 차단 수단이라,
# 설치된 모든 hook의 lefthook 호출부에 이 플래그를 주입한다. checksum 최신화는 아래
# run_lefthook_install이 전담하므로 자동 재설치를 잃어도 손해가 없다.
# 플래그 존재 재확인: `lefthook run --help | grep -- --no-auto-install` (lefthook 2.1.5 기준).
NO_AUTO_INSTALL_FLAG="--no-auto-install"

# git이 인정하는 hook 이름. configured_hooks가 lefthook.yml의 top-level 키에서 hook만 골라낼 때
# 쓴다 (전역 옵션 키를 hook으로 오인하지 않도록). 목록 출처: `man githooks` (git 2.x).
# 한 줄로 유지한다 — tests/suites/lefthook.sh가 sed로 추출해 실제 hook 이름 판별에 재사용한다.
GIT_HOOK_NAMES="applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update reference-transaction push-to-checkout pre-auto-gc post-rewrite sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change"

# 위 목록 중 git이 exit status를 무시하는 hook. 이 hook이 깨져 exit 127로 죽어도 그 명령은 그대로
# 성공하므로, installer는 실패 대신 경고만 낸다 — 아무것도 막지 못하는 파일 하나 때문에 direnv
# 진입까지 막을 이유가 없다.
#
# 편입 기준 (`man githooks`, git 2.54): 그 항목이 "cannot affect the outcome of ..." 또는 "does not
# affect the outcome" 서술을 갖고, **그 문장에 exit status 예외절이 붙지 않을 것.** 예외절이 붙는
# 대표가 `post-checkout`이다 — "cannot affect the outcome of git switch or git checkout, *other than
# that the hook's exit status becomes the exit status of these two commands*". 그래서 제외한다
# (실측: 깨진 post-checkout에서 `git worktree add`가 exit 127을 낸다 — `wt`가 반쯤 만들어진 워크트리를
# 남기고 죽는다). 아래 목록은 이 기준을 문서 전문에 기계적으로 적용한 결과다.
#
# 문서에 exit status 서술이 아예 없으면 넣지 않는다 (fail-closed). `post-rewrite`와 `post-index-change`가
# 그렇다 — 실측으로는 무시되지만 문서 근거가 없어 단정하지 않는다.
#
# 기준은 "문서 근거가 있는가"이지 "이 저장소가 쓰는가"가 아니다. 이 집합은 git의 계약을 그대로 옮긴
# 것이어야 하므로, 서버측 hook(post-update, post-receive)과 git-p4 hook(p4-post-changelist)도 포함한다.
GIT_HOOK_NAMES_IGNORING_EXIT_STATUS="post-applypatch post-commit post-merge post-update post-receive p4-post-changelist"

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
  # `--git-path hooks/pre-commit`은 마지막 구성요소의 symlink까지 해석해 target 경로를 돌려준다
  # (실측). 그 경로로는 아래 `-L` 검사가 무력해지고 python도 target을 직접 연다. 디렉토리만
  # 해석시키고 파일명을 직접 붙여 symlink를 보존한다 — disable_lefthook_auto_install과 같은 방식.
  hook_path="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks)/pre-commit"
  [ -f "$hook_path" ] || fail "generated pre-commit hook not found: $hook_path"
  # 아래 python은 write_text로 제자리 갱신하므로 symlink를 만나면 그 target을 따라 쓴다.
  # disable_lefthook_auto_install이 같은 이유로 symlink를 거부하는데, 이쪽이 먼저 실행되므로
  # 여기서도 막지 않으면 방어가 반쪽이 된다.
  if [ -L "$hook_path" ]; then
    fail "refusing to patch symlinked hook (write would follow the link): $hook_path"
  fi

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

disable_lefthook_auto_install() {
  # 설치된 모든 lefthook hook의 `call_lefthook run "<hook>" "$@"` 호출부에
  # NO_AUTO_INSTALL_FLAG를 주입한다 (배경은 상수 정의부 주석 참조).
  #
  # `--git-path hooks`는 core.hooksPath를 반영하므로 lefthook이 실제로 hook을 쓴 위치와
  # 일치한다 ($git_dir/hooks와 다를 수 있다 — 사용자가 core.hooksPath를 재정의한 경우).
  # inject_staged_guard가 hook을 찾는 방식과 같은 해석 경로를 쓴다.
  #
  # 패치 대상은 "lefthook이 만든 모든 hook"이지 "지금 lefthook.yml에 있는 hook"이 아니다.
  # `lefthook install`은 설정에서 빠진 hook 파일을 지우지 않으므로, 과거에 설정돼 있던 hook이
  # 플래그 없이 남는다. git은 그 hook도 실행하고(예: pre-commit 다음의 prepare-commit-msg),
  # 그 안의 `call_lefthook run`이 auto-install을 발동시켜 guard와 플래그를 통째로 지운다.
  # 실측: `.git/hooks/prepare-commit-msg`(현 lefthook.yml에 없음) 하나로 재현된다.
  # 반대로 설치 여부 검증(아래)은 configured_hooks에만 적용한다 — 설정 밖 hook의 부재는 정상이다.
  local hook_file hook_name resolved_hooks_dir
  resolved_hooks_dir="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks)"
  local -a hook_files=()
  for hook_file in "$resolved_hooks_dir"/*; do
    [ -f "$hook_file" ] || continue
    # lefthook이 기존 hook을 밀어낼 때 남기는 백업본은 git이 실행하지 않으므로 건드리지 않는다.
    case "$hook_file" in *.old) continue ;; esac
    # lefthook이 생성한 hook만 고른다. 남이 만든 hook에는 이 호출부가 없다.
    grep -Fq 'call_lefthook run ' "$hook_file" || continue
    # 아래 python 블록은 rename으로 교체하므로 symlink였다면 링크 자체가 일반 파일로 바뀐다
    # (다른 레이어가 hook을 symlink로 관리한다면 그 경계가 조용히 끊긴다). install 전 preflight가
    # 이미 걸렀어야 하지만, 그 사이의 TOCTOU를 여기서 한 번 더 막는다.
    if [ -L "$hook_file" ]; then
      fail "refusing to patch symlinked hook (rename would replace the link): $hook_file"
    fi
    hook_files+=("$hook_file")
  done

  # lefthook.yml이 정의한 hook이 하나라도 설치되지 않았다면, auto-install을 끈 지금은 아무도
  # 되살려 주지 않는다. commit-time self-check가 같은 목록을 fail-fast로 확인하므로, 그 실패를
  # install 시점으로 당겨 원인을 분명히 남긴다.
  for hook_name in $(configured_hooks); do
    if [ ! -f "$resolved_hooks_dir/$hook_name" ]; then
      fail "expected hook not installed: $resolved_hooks_dir/$hook_name (lefthook.yml defines it; check 'lefthook install' output)"
    fi
  done

  if [ "${#hook_files[@]}" -eq 0 ]; then
    fail "no lefthook-generated hooks found under $resolved_hooks_dir"
  fi

  # 200>&- closes the lock fd in the python child (same reason as run_lefthook_install).
  python3 - "$NO_AUTO_INSTALL_FLAG" "${hook_files[@]}" 200>&- <<'PY'
from __future__ import annotations

from pathlib import Path
import os
import sys
import tempfile

flag = sys.argv[1]
call_prefix = 'call_lefthook run "'
call_suffix = '"$@"'

for raw_path in sys.argv[2:]:
    hook_path = Path(raw_path)
    # 호출부의 symlink 검사와 여기 사이의 TOCTOU를 좁힌다. rename은 링크를 따라가지 않고
    # directory entry를 갈아끼우므로, symlink를 만나면 교체하지 않고 세운다.
    st = hook_path.lstat()
    if os.path.islink(hook_path):
        raise SystemExit(f"install-lefthook-hooks: refusing to patch symlinked hook: {hook_path}")

    lines = hook_path.read_text(encoding="utf-8").splitlines()

    changed = False
    patched: list[str] = []
    for line in lines:
        if line.startswith(call_prefix) and line.endswith(call_suffix) and flag not in line:
            line = f"{line[: -len(call_suffix)]}{flag} {call_suffix}"
            changed = True
        patched.append(line)

    if not changed:
        continue

    # Atomic replace: a hook process already executing this file keeps reading the
    # old inode. An in-place truncate+write would corrupt a running `sh` mid-read.
    # mkstemp는 0600 + 현재 uid/gid로 만들므로 원본의 mode와 owner를 명시적으로 옮긴다.
    # 소유자가 달라 chown할 권한이 없으면 조용히 owner를 바꾸지 말고 실패한다.
    fd, tmp_name = tempfile.mkstemp(dir=str(hook_path.parent), prefix=f"{hook_path.name}.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write("\n".join(patched) + "\n")
        os.chmod(tmp_name, st.st_mode)
        os.chown(tmp_name, st.st_uid, st.st_gid)
        os.replace(tmp_name, hook_path)
    except BaseException:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)
        raise
PY

  # Defense in depth: lefthook이 hook 템플릿의 호출부 형태를 바꾸면 위 치환이 조용히
  # no-op가 되고, 다음 auto-sync가 guard를 다시 지운다. 그 실패를 install 시점으로 당긴다.
  #
  # 두 가지를 함께 본다. (1) `call_lefthook run` 호출부가 정확히 하나여야 한다 — 기대 라인의
  # 존재만 확인하면, 같은 hook에 패치되지 않은 두 번째 호출(들여쓰기·후행 구문 등)이 남아 있어도
  # 통과해 그 경로에서 auto-install이 계속 살아 있다. (2) 그 한 줄이 기대값과 완전히 같아야 한다 —
  # "플래그가 파일 어딘가에 있다"는 느슨한 검사는 주석 한 줄만으로 통과한다.
  # 패턴 안의 `"$@"`가 확장되지 않도록 작은따옴표로 감싼다.
  local expected_call call_count
  for hook_file in "${hook_files[@]}"; do
    bash -n "$hook_file"
    hook_name="$(basename "$hook_file")"
    call_count="$(grep -Fc 'call_lefthook run ' "$hook_file" || true)"
    if [ "$call_count" != "1" ]; then
      fail "auto-install suppression failed: expected exactly one 'call_lefthook run' line in $hook_file, found $call_count"
    fi
    expected_call='call_lefthook run "'"$hook_name"'" '"$NO_AUTO_INSTALL_FLAG"' "$@"'
    if ! grep -Fxq -- "$expected_call" "$hook_file"; then
      fail "auto-install suppression failed: expected exact call line [$expected_call] in $hook_file"
    fi
    # (3) `call_lefthook()` 정의가 있어야 한다. 위 검사 셋 중 어느 것도 이것을 보지 않는다 —
    # 정의되지 않은 함수를 부르는 문장은 셸 문법상 합법이라 `bash -n`을 통과하고(실측: exit 0),
    # 호출부 형태만 맞으면 call_count·expected_call도 통과한다. 그런 hook은 git이 실행하는 순간
    # `call_lefthook: command not found`로 exit 127을 내며 죽는다. 이 검사가 없으면 installer는
    # 커밋을 막는 hook을 남겨 둔 채 성공을 보고한다 (#1073).
    #
    # 이 검사를 여기(python 패치 이후)에 두는 것이 중요하다. 앞으로 옮기는 두 대안은 서로 다른
    # 이유로 더 나쁘다.
    #   - 수집 루프(패치 이전, install 이후): 그 시점엔 run_lefthook_install이 configured hook을
    #     순정 템플릿으로 다시 써서 `--no-auto-install`이 없는 상태다. 거기서 죽으면 플래그가 없는
    #     채로 남고, lefthook.yml의 lefthook-guard-self-check가 그것을 커밋 차단으로 판정한다.
    #   - run_lefthook_install 이전 preflight: `fail`이 즉시 exit하므로 install이 아예 돌지 않는다.
    #     그러면 깨진 configured hook을 install이 다시 써서 고칠 기회를 빼앗는다 (실측: lefthook은
    #     그 파일을 <name>.old로 밀고 새로 써서 preamble을 복구한다 — 단 <name>.old가 이미 있으면
    #     rename에 실패해 그 복구도 죽는다). 그 hook은 깨진 채 남고 커밋이 계속 막힌다.
    # 여기서는 패치가 끝나 플래그가 살아 있고, configured hook은 install이 이미 고친 뒤다.
    #
    # 이 배치를 지키는 것은 이 주석뿐이다. 아래 테스트는 검사를 preflight로 옮겨도 통과한다 —
    # 1회차 install이 심은 플래그가 그대로 남아 "실패 후에도 플래그가 살아 있다"는 단언이 성립한다.
    #
    # expected_call 뒤에 두는 것도 의도다. 주석에서 `call_lefthook run `을 언급할 뿐인 남의 hook은
    # 그 검사에서 먼저 걸려, "정의가 없다"는 엉뚱한 진단을 받지 않는다.
    if ! grep -Eq '^[[:space:]]*call_lefthook[[:space:]]*\(\)' "$hook_file"; then
      case " $GIT_HOOK_NAMES_IGNORING_EXIT_STATUS " in
        *" $hook_name "*)
          # git이 이 hook의 exit status를 무시하므로 커밋·push는 막히지 않는다. 알리되 멈추지 않는다.
          echo "install-lefthook-hooks: warning: $hook_file has no call_lefthook() definition and dies with exit 127 when git runs it." >&2
          echo "  git ignores this hook's exit status, so commits still work. Delete the file if lefthook.yml no longer defines this hook." >&2
          ;;
        *)
          fail "broken hook: no call_lefthook() definition (git would fail it with exit 127; delete the file if lefthook.yml no longer defines this hook): $hook_file"
          ;;
      esac
    fi
  done
}

require_canonical_lefthook_config() {
  # `lefthook install`은 LEFTHOOK_CONFIG가 가리키는 설정을 쓴다. 반면 아래 configured_hooks와
  # symlink preflight는 저장소의 lefthook.yml만 읽는다. 둘이 갈라지면 대체 설정에만 있는 hook이
  # 사전 검사를 통과하지 못한 채 install 대상이 되어, 그 hook이 symlink일 때 외부 target을
  # 덮어쓴다. 상태를 바꾸기 전에 두 경로가 같은 설정을 보게 강제한다.
  # (hook 실행 시점의 동일한 차단은 inject_staged_guard가 주입하는 guard 블록이 담당한다.)
  [ -n "${LEFTHOOK_CONFIG:-}" ] || return 0
  local expected config_dir config_base config_abs
  expected="$(cd "$repo_root" && pwd -P)/lefthook.yml"
  config_dir="$(dirname "$LEFTHOOK_CONFIG")"
  config_base="$(basename "$LEFTHOOK_CONFIG")"
  config_abs="$(cd "$config_dir" 2>/dev/null && pwd -P)/$config_base" \
    || fail "invalid LEFTHOOK_CONFIG: $LEFTHOOK_CONFIG"
  if [ "$config_abs" != "$expected" ]; then
    fail "LEFTHOOK_CONFIG must point to $expected (got $config_abs); the installer's preflight only knows the canonical config"
  fi
}

configured_hooks() {
  # lefthook.yml이 정의한 top-level 키 중 실제 git hook 이름만 고른다. lefthook config의
  # top-level에는 hook 외에 전역 옵션(`colors`, `skip_output`, `min_version`, `remotes` 등)도
  # 올 수 있는데, 그것을 hook으로 오인하면 아래 호출부가 `.git/hooks/colors`를 찾다가
  # "expected hook not installed"로 install을 막아 버린다 (실측: `colors: false` 한 줄로 재현).
  # 현재 저장소는 세 hook만 쓰지만, 전역 옵션을 추가하는 순간 direnv 진입이 깨지는 잠복 결함이었다.
  # require_canonical_lefthook_config가 LEFTHOOK_CONFIG를 이 파일로 고정해 둔다.
  [ -f "$repo_root/lefthook.yml" ] || return 0
  awk -v known=" $GIT_HOOK_NAMES " '
    /^[A-Za-z0-9_.-]+:/ {
      name = $1
      sub(/:$/, "", name)
      if (index(known, " " name " ") > 0) print name
    }
  ' "$repo_root/lefthook.yml"
}

refuse_symlinked_hooks() {
  # `lefthook install`은 configured hook을 `>` 리다이렉션처럼 제자리에 쓰므로 symlink를 만나면
  # 링크를 따라가 외부 target을 덮어쓴다. 그 뒤의 inject_staged_guard / disable_lefthook_auto_install
  # 거부는 이미 늦다. install 전에 세워서 남의 파일을 건드리지 않는다.
  # (install 이후의 거부는 TOCTOU 방어로 그대로 유지한다.)
  local hooks_dir_now hook_name
  hooks_dir_now="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path hooks)"
  [ -d "$hooks_dir_now" ] || return 0
  for hook_name in $(configured_hooks); do
    if [ -L "$hooks_dir_now/$hook_name" ]; then
      fail "refusing to install over a symlinked hook (lefthook install would write through the link): $hooks_dir_now/$hook_name"
    fi
  done
}

if is_main_repo; then
  cleanup_main_redundant_hooks_path
else
  apply_worktree_local_hooks_config
fi
acquire_install_lock
require_canonical_lefthook_config
refuse_symlinked_hooks
run_lefthook_install
inject_staged_guard
disable_lefthook_auto_install
