#!/usr/bin/env bash
# write-handoff repo slug 확보 helper.
#
# 호출: LLM이 write-handoff/SKILL.md Step 1-B 절차에 따라 런타임별 경로로 직접 실행한다.
#   Claude Code 세션: ~/.claude/scripts/write-handoff-repo-slug.sh "$ARGUMENTS"
#   Codex 세션:       ~/.codex/scripts/write-handoff-repo-slug.sh "$ARGUMENTS"
# 양 런타임은 Home Manager로 동일 source를 프로비저닝한다 (#486).
#
# 동작:
#   1. 이슈 인자($1)가 있으면 `gh issue view --json url`로 owner/name 파싱
#      → 실패 시 빈 줄 반환 (cwd fallback 하지 않음 — wrong-repo slug 방지, #486 H2)
#   2. 이슈 인자가 없으면 cwd repo 의 `gh repo view --json nameWithOwner` 사용
#   3. 최종 실패 시 빈 줄 반환 (SKILL.md Step 1-D 실패 처리가 사용자 확답 요구)
#
# exit code 는 언제나 0 이다 — 호출 LLM이 결과 문자열로 성공/실패를 판단한다.

set -o pipefail

slug=""

issue_arg="${1:-}"

if [ -n "$issue_arg" ]; then
  # Explicit issue arg 경로: URL 파싱만 사용. 실패 시 cwd fallback 금지 (fail-closed).
  url=$(gh issue view "$issue_arg" --json url -q .url 2>/dev/null || true)
  parsed=$(printf '%s\n' "$url" | sed -nE 's|^https?://[^/]+/([^/]+/[^/]+)/.*$|\1|p')
  case "$parsed" in
    null|'') ;;
    *) slug="$parsed" ;;
  esac
else
  # No issue arg: cwd repo fallback
  fallback=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  case "$fallback" in
    null|'') ;;
    *) slug="$fallback" ;;
  esac
fi

# 최종 출력 (빈 값일 수도 있음)
printf '%s\n' "$slug"
exit 0
