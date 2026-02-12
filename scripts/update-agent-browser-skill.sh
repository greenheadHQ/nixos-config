#!/usr/bin/env bash
# agent-browser 공식 Skill 파일을 최신 버전으로 업데이트
# troubleshooting.md는 우리가 작성한 파일이므로 업데이트 대상에서 제외
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/vercel-labs/agent-browser/main/skills/agent-browser"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)/modules/shared/programs/claude/files/skills/agent-browser"
PARENT_DIR="$(dirname "$SKILL_DIR")"
WORK_DIR="$(mktemp -d "${PARENT_DIR}/.agent-browser-update.XXXXXX")"
STAGE_DIR="$WORK_DIR/agent-browser"
BACKUP_DIR="$WORK_DIR/agent-browser.backup"

cleanup() {
  if [ -d "$BACKUP_DIR" ] && [ ! -d "$SKILL_DIR" ]; then
    mv "$BACKUP_DIR" "$SKILL_DIR"
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [ -d "$SKILL_DIR" ]; then
  cp -a "$SKILL_DIR" "$STAGE_DIR"
else
  mkdir -p "$STAGE_DIR/references" "$STAGE_DIR/templates"
fi

mkdir -p "$STAGE_DIR/references" "$STAGE_DIR/templates"

echo "Updating agent-browser skill files (staging)..."
curl -fsSL "$BASE_URL/SKILL.md" -o "$STAGE_DIR/SKILL.md"

for ref in authentication commands proxy-support session-management snapshot-refs video-recording; do
  curl -fsSL "$BASE_URL/references/$ref.md" -o "$STAGE_DIR/references/$ref.md"
done

for tpl in authenticated-session capture-workflow form-automation; do
  curl -fsSL "$BASE_URL/templates/$tpl.sh" -o "$STAGE_DIR/templates/$tpl.sh"
  chmod +x "$STAGE_DIR/templates/$tpl.sh"
done

echo "Applying update..."
if [ -d "$SKILL_DIR" ]; then
  mv "$SKILL_DIR" "$BACKUP_DIR"
fi
mv "$STAGE_DIR" "$SKILL_DIR"
rm -rf "$BACKUP_DIR"

trap - EXIT
rm -rf "$WORK_DIR"

echo "Done. Run 'git diff' to review changes."
