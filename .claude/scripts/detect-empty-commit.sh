#!/bin/bash
# PostToolUse hook: git commit 후 빈 커밋 감지
# tree hash 비교로 staging area 초기화 버그 감지 (Issue #125)
set -euo pipefail

# settings.local.json의 matcher: "Bash"가 이미 tool_name 필터링
command=$(cat | jq -r '.tool_input.command // empty')
[[ -n "$command" ]] || exit 0

# git commit 감지 (직접 또는 nix develop 래핑)
is_commit=false
if [[ "$command" =~ git[[:space:]]+commit ]]; then
  is_commit=true
elif [[ "$command" =~ echo[[:space:]]+([A-Za-z0-9+/=]+)[[:space:]].*nix[[:space:]]+develop ]]; then
  decoded=$(echo "${BASH_REMATCH[1]}" | base64 -d 2>/dev/null || true)
  [[ "$decoded" =~ git[[:space:]]+commit ]] && is_commit=true
fi
[[ "$is_commit" == "true" ]] || exit 0

# --amend는 tree 변경 없이 메시지만 수정할 수 있으므로 제외
[[ "$command" =~ --amend ]] && exit 0

# merge commit은 parent와 tree가 같아도 정상
git rev-parse HEAD^2 &>/dev/null && exit 0

head_tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null) || exit 0
parent_tree=$(git rev-parse "HEAD~1^{tree}" 2>/dev/null) || exit 0

if [[ "$head_tree" == "$parent_tree" ]]; then
  head_sha=$(git rev-parse --short HEAD)
  jq -n \
    --arg reason "EMPTY COMMIT DETECTED: commit $head_sha has identical tree as parent. Staging area was likely corrupted by lefthook. Run 'git reset HEAD~1' to undo, re-stage files, and retry." \
    --arg ctx "This is GitHub Issue #125. Current HEAD tree: $head_tree, Parent tree: $parent_tree (identical). Recovery: git reset HEAD~1 && git add <files> && git commit -m 'message'" \
    '{
      decision: "block",
      reason: $reason,
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext: $ctx
      }
    }'
fi

exit 0
