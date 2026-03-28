#!/usr/bin/env bash
# Claude Code PreToolUse hook: worktree path guard
# worktree에서 실행 중일 때 main repo 파일을 Edit/Write하면 차단하고 worktree 경로를 안내

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Edit, Write만 감시
case "$TOOL_NAME" in
  Edit|Write) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[[ -z "$FILE_PATH" ]] && exit 0

# worktree 감지: git-dir ≠ git-common-dir
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null) || exit 0
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null) || exit 0
[[ "$GIT_DIR" == "$COMMON_DIR" ]] && exit 0  # main repo → 통과

WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
MAIN_REPO=$(cd "$COMMON_DIR/.." 2>/dev/null && pwd) || exit 0

# 대상 파일의 실제 경로 확인 (심링크 해석)
RESOLVED=$(readlink -f "$FILE_PATH" 2>/dev/null || echo "$FILE_PATH")

# main repo guard 예외: Claude plan 파일 허용
# claude --worktree의 main session에서 plan write가 $MAIN_REPO/.claude/plans/로 나가는
# 사례가 관측되어 예외 허용 (Claude Code 2.x, plansDirectory를 main repo 기준으로 해석)
_is_main_repo_plan_path() {
  local p="$1"
  [[ "$p" == *".."* ]] && return 1  # path traversal 방어
  local dir base
  dir=$(dirname "$p")
  base=$(basename "$p")
  [[ "$dir" == "$MAIN_REPO/.claude/plans" ]] && [[ "$base" == *.md ]] && return 0
  return 1
}

if _is_main_repo_plan_path "$RESOLVED"; then
  exit 0
fi

# main repo 경로이면서 현재 worktree 하위가 아닌 경우 차단
_is_main_repo_path() {
  local p="$1"
  [[ "$p" != "$MAIN_REPO"/* ]] && return 1
  [[ "$p" == "$WORKTREE_ROOT"/* ]] && return 1
  return 0
}

if _is_main_repo_path "$FILE_PATH" || _is_main_repo_path "$RESOLVED"; then
  local_resolved="${RESOLVED:-$FILE_PATH}"
  REL="${local_resolved#"$MAIN_REPO"/}"
  SUGGESTED="$WORKTREE_ROOT/$REL"
  jq -n --arg reason "main repo 파일을 직접 수정할 수 없습니다 (worktree에서 실행 중). worktree 경로를 사용하세요: $SUGGESTED" \
    '{decision: "block", reason: $reason}'
  exit 0
fi

exit 0
