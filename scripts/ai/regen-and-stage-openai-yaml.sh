#!/usr/bin/env bash
# regen-and-stage-openai-yaml.sh
# Pre-commit hook: .agents/skills/*/agents/openai.yaml 재생성 + 자동 staging
# 목적: nrs(Nix activation)와 sync.sh 간 openai.yaml 불일치 예방
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

# Regenerate all openai.yaml files
bash "$SYNC_SCRIPT" regen-yaml "$REPO_ROOT" >/dev/null

# Stage any changed openai.yaml files
changed_files="$(git -C "$REPO_ROOT" diff --name-only -- '.agents/skills/*/agents/openai.yaml')" || true
if [ -n "$changed_files" ]; then
  echo "$changed_files" | xargs git -C "$REPO_ROOT" add
  file_count="$(echo "$changed_files" | wc -l | tr -d ' ')"
  echo "[INFO] Auto-staged $file_count regenerated openai.yaml file(s)" >&2
fi
