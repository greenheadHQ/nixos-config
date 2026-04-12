#!/usr/bin/env bash
# write-handoff 동적 context 주입 helper.
#
# 호출:
#   ~/.claude/scripts/write-handoff-repo-slug.sh "$ARGUMENTS"
#
# SKILL.md 의 `` !`<command>` `` 문법이 zsh eval 로 실행되며
# nested single quotes + redirect 를 안전하게 처리하지 못한다
# (Claude Code known bug: anthropics/claude-code#14315, #13655).
# 그래서 sed/grep 패턴이 담긴 복잡 파이프를 SKILL.md inline 이 아니라
# 이 standalone script 로 분리한다.
#
# 동작:
#   1. 이슈 인자($1)가 있으면 `gh issue view --json url` 로 owner/name 파싱
#   2. 1에서 빈 값이면 cwd repo 의 `gh repo view --json nameWithOwner` 사용
#   3. 둘 다 실패하면 빈 줄을 출력 (SKILL.md placeholder 검증이 이후 처리)
#
# exit code 는 언제나 0 이다 — preprocessing 이 skill 로드를 중단하지 않도록.

set -o pipefail

slug=""

issue_arg="${1:-}"

if [ -n "$issue_arg" ]; then
  url=$(gh issue view "$issue_arg" --json url -q .url 2>/dev/null || true)
  parsed=$(printf '%s\n' "$url" | sed -nE 's|^https?://[^/]+/([^/]+/[^/]+)/.*$|\1|p')
  case "$parsed" in
    null|'') ;;
    *) slug="$parsed" ;;
  esac
fi

if [ -z "$slug" ]; then
  fallback=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  case "$fallback" in
    null|'') ;;
    *) slug="$fallback" ;;
  esac
fi

# 최종 출력 (빈 값일 수도 있음)
printf '%s\n' "$slug"
exit 0
