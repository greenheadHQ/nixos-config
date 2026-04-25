#!/usr/bin/env bash
# write-handoff 입력 파싱 helper — REPO slug + ISSUE_NUM 2줄 출력.
#
# 호출: LLM이 write-handoff/SKILL.md Step 1-B 절차에 따라 런타임별 경로로 직접 실행한다.
#   Claude Code 세션: ~/.claude/scripts/write-handoff-repo-and-issue.sh "$ARGUMENTS"
#   Codex 세션:       ~/.codex/scripts/write-handoff-repo-and-issue.sh "$ARGUMENTS"
# 양 런타임은 Home Manager로 동일 source를 프로비저닝한다.
#
# 출력 (항상 2줄; 둘 중 하나가 빈 줄일 수 있음):
#   1줄 REPO_SLUG (owner/name 또는 빈 줄)
#   2줄 ISSUE_NUM (정수 또는 빈 줄)
#
# 동작:
#   1. 이슈 인자($1)가 있으면 `gh issue view --json url,number`로 두 값 동시 파싱
#      → 실패 시 REPO/ISSUE_NUM 모두 빈 줄 (cwd fallback 하지 않음 — wrong-repo slug 방지)
#   2. 이슈 인자가 없으면 cwd repo의 `gh repo view --json nameWithOwner` 사용 (REPO만, ISSUE_NUM은 빈 줄)
#   3. 최종 실패 시 해당 줄만 빈 줄 (SKILL.md Step 1-D 실패 처리가 사용자 확답 요구)
#
# exit code는 언제나 0이다 — 호출 LLM이 결과 문자열로 성공/실패를 판단한다.

set -o pipefail

slug=""
issue_num=""

issue_arg="${1:-}"

if [ -n "$issue_arg" ]; then
  # Explicit issue arg 경로: URL/number/가변 입력을 gh가 해석. 실패 시 cwd fallback 금지 (fail-closed).
  json=$(gh issue view "$issue_arg" --json url,number 2>/dev/null || true)
  url=$(printf '%s\n' "$json" | jq -r '.url // empty' 2>/dev/null)
  number=$(printf '%s\n' "$json" | jq -r '.number // empty' 2>/dev/null)
  parsed_slug=$(printf '%s\n' "$url" | sed -nE 's|^https?://[^/]+/([^/]+/[^/]+)/.*$|\1|p')
  case "$parsed_slug" in
    null|'') ;;
    *) slug="$parsed_slug" ;;
  esac
  case "$number" in
    null|'') ;;
    *) issue_num="$number" ;;
  esac
else
  # No issue arg: cwd repo fallback (REPO만)
  fallback=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  case "$fallback" in
    null|'') ;;
    *) slug="$fallback" ;;
  esac
fi

# 최종 출력 (항상 2줄; 빈 값일 수도 있음)
printf '%s\n%s\n' "$slug" "$issue_num"
exit 0
