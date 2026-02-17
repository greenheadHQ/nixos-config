#!/usr/bin/env bash
# regen-and-stage-openai-yaml.sh
# Pre-commit hook: .agents/skills/*/agents/openai.yaml 재생성 + 자동 staging
# 목적: nrs(Nix activation)와 sync.sh 간 openai.yaml 불일치 예방
#
# 안전장치:
# - lefthook piped 모드에서 priority 1로 실행 → 다른 훅(gitleaks 등)보다 먼저 완료
# - unstaged SKILL.md 변경이 있으면 해당 스킬의 openai.yaml은 staging하지 않음
#   (커밋에 포함되지 않은 SKILL.md 변경이 openai.yaml에 반영되는 오염 방지)
# - .claude/skills에 소스가 있는 로컬 스킬만 대상 (plugin-projected 스킬은 제외)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC_SCRIPT="$REPO_ROOT/modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh"

if [ ! -f "$SYNC_SCRIPT" ]; then
  echo "[WARN] sync.sh not found, skipping openai.yaml regeneration" >&2
  exit 0
fi

if [ ! -d "$REPO_ROOT/.agents/skills" ]; then
  # nrs가 아직 한 번도 실행되지 않은 상태 — skip
  exit 0
fi

# Regenerate all openai.yaml files from working tree SKILL.md
bash "$SYNC_SCRIPT" regen-yaml "$REPO_ROOT" >/dev/null

# Collect skills with unstaged SKILL.md changes (these must NOT be auto-staged)
unstaged_skills=""
if [ -d "$REPO_ROOT/.claude/skills" ]; then
  unstaged_skills="$(git -C "$REPO_ROOT" diff --name-only -- '.claude/skills/*/SKILL.md' 2>/dev/null)" || true
fi

# Stage changed openai.yaml files, excluding:
# - Skills whose SKILL.md has unstaged changes (commit contamination prevention)
# - Plugin-projected skills without .claude/skills source
# NB: pipe from git diff -z to avoid Bash NUL stripping in $()
staged_count=0
git -C "$REPO_ROOT" diff --name-only -z -- '.agents/skills/*/agents/openai.yaml' 2>/dev/null \
| while IFS= read -r -d '' yaml_path; do
    [ -n "$yaml_path" ] || continue

    # Extract skill name: .agents/skills/<name>/agents/openai.yaml → <name>
    skill_name="$(echo "$yaml_path" | sed 's|^\.agents/skills/\([^/]*\)/.*|\1|')"

    # Skip plugin-projected skills (no .claude/skills source)
    if [ ! -d "$REPO_ROOT/.claude/skills/$skill_name" ]; then
      continue
    fi

    # Skip if the corresponding SKILL.md has unstaged changes
    if echo "$unstaged_skills" | grep -qF ".claude/skills/$skill_name/SKILL.md"; then
      echo "[WARN] Skipping $yaml_path — .claude/skills/$skill_name/SKILL.md has unstaged changes" >&2
      continue
    fi

    git -C "$REPO_ROOT" add -- "$yaml_path"
    staged_count=$((staged_count + 1))
  done

# staged_count is in subshell (pipe), so re-check for output message
actually_staged="$(git -C "$REPO_ROOT" diff --cached --name-only -- '.agents/skills/*/agents/openai.yaml' 2>/dev/null | wc -l | tr -d ' ')" || true
if [ "${actually_staged:-0}" -gt 0 ]; then
  echo "[INFO] Auto-staged openai.yaml file(s)" >&2
fi
