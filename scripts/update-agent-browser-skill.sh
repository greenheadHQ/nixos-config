#!/usr/bin/env bash
# agent-browser 공식 Skill 파일을 최신 버전으로 업데이트
# troubleshooting.md는 우리가 작성한 파일이므로 업데이트 대상에서 제외
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/vercel-labs/agent-browser/main/skills/agent-browser"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)/.claude/skills/agent-browser"

mkdir -p "$SKILL_DIR/references" "$SKILL_DIR/templates"

echo "Updating agent-browser skill files..."
curl -fsSL "$BASE_URL/SKILL.md" -o "$SKILL_DIR/SKILL.md"

for ref in authentication commands proxy-support session-management snapshot-refs video-recording; do
  curl -fsSL "$BASE_URL/references/$ref.md" -o "$SKILL_DIR/references/$ref.md"
done

for tpl in authenticated-session capture-workflow form-automation; do
  curl -fsSL "$BASE_URL/templates/$tpl.sh" -o "$SKILL_DIR/templates/$tpl.sh"
  chmod +x "$SKILL_DIR/templates/$tpl.sh"
done

echo "Done. Run 'git diff' to review changes."
