#!/usr/bin/env bash
# Legacy slug-only helper path. Output is exactly one REPO_SLUG line.
# Callers that need ISSUE_NUM should use write-handoff-repo-and-issue.sh (2-line).
#
# 동작: 새 sibling helper가 provisioning 되어 있으면 그 첫 줄만 반환하고,
# 없으면 아래 inline fallback으로 slug-only 로직을 직접 수행한다.

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
NEW_HELPER="$SCRIPT_DIR/write-handoff-repo-and-issue.sh"

if [ -x "$NEW_HELPER" ]; then
  "$NEW_HELPER" "$@" | head -n 1
  exit 0
fi

# Fallback: reproduce original slug-only logic when sibling helper is absent.
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
else
  fallback=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
  case "$fallback" in
    null|'') ;;
    *) slug="$fallback" ;;
  esac
fi

printf '%s\n' "$slug"
exit 0
