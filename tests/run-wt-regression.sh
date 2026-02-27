#!/usr/bin/env bash
# tests/run-wt-regression.sh
# 목적: wt() 실행 시 .claude/.claude, .agents/.agents 중첩 회귀 방지
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WT_LIB="$REPO_ROOT/modules/shared/scripts/git-worktree-functions.sh"
BRANCH_NAME="tmp/wt-regression-$(date +%s)-$$"
WORKTREE_PATH=""
LOG_FILE="/tmp/wt-regression-${$}.log"

resolve_worktree_path() {
  git -C "$REPO_ROOT" worktree list --porcelain | awk -v branch="$BRANCH_NAME" '
    /^worktree / { path = substr($0, 10) }
    /^branch refs\/heads\// {
      b = substr($0, 19)
      if (b == branch) print path
    }
  '
}

cleanup() {
  if [[ -z "$WORKTREE_PATH" ]]; then
    WORKTREE_PATH="$(resolve_worktree_path | head -1)"
  fi

  if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
    git -C "$REPO_ROOT" worktree remove "$WORKTREE_PATH" --force >/dev/null 2>&1 || true
  fi
  git -C "$REPO_ROOT" branch -D "$BRANCH_NAME" >/dev/null 2>&1 || true
  rm -f "$LOG_FILE"
}
trap cleanup EXIT INT TERM

echo "Running wt nested-dir regression test..."

if [[ ! -f "$WT_LIB" ]]; then
  echo "FAIL: wt library not found: $WT_LIB" >&2
  exit 1
fi

if ! zsh -lc "cd '$REPO_ROOT'; source '$WT_LIB'; WT_EDITOR=true wt -s '$BRANCH_NAME'" >"$LOG_FILE" 2>&1; then
  echo "FAIL: wt command failed" >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

WORKTREE_PATH="$(resolve_worktree_path | head -1)"
if [[ -z "$WORKTREE_PATH" ]] || [[ ! -d "$WORKTREE_PATH" ]]; then
  echo "FAIL: created worktree path not found for branch $BRANCH_NAME" >&2
  cat "$LOG_FILE" >&2
  exit 1
fi

# 회귀 핵심 검증: 중첩 디렉토리가 생기면 실패
if [[ -d "$WORKTREE_PATH/.claude/.claude" ]]; then
  echo "FAIL: nested directory detected: $WORKTREE_PATH/.claude/.claude" >&2
  exit 1
fi
if [[ -d "$WORKTREE_PATH/.agents/.agents" ]]; then
  echo "FAIL: nested directory detected: $WORKTREE_PATH/.agents/.agents" >&2
  exit 1
fi
if [[ -d "$WORKTREE_PATH/.codex/.codex" ]]; then
  echo "FAIL: nested directory detected: $WORKTREE_PATH/.codex/.codex" >&2
  exit 1
fi

echo "wt regression test passed."
