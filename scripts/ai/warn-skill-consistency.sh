#!/usr/bin/env bash
# warn-skill-consistency.sh
# 목적: .claude/skills 원본과 .agents/skills 투영본의 정합성 회귀를 pre-commit에서 점검
# 정책:
# - 일반 커밋: warning-only
# - 스킬/Codex 관련 staged 변경 포함: fail-on-error
# - 우회: SKIP_AI_SKILL_CHECK=1 (또는 true)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SKILLS_DIR="$REPO_ROOT/.claude/skills"
PROJECTED_SKILLS_DIR="$REPO_ROOT/.agents/skills"

warn() {
  echo "[WARN] $1" >&2
}

err() {
  echo "[ERROR] $1" >&2
}

list_skill_dirs() {
  local base="$1"
  find "$base" -mindepth 1 -maxdepth 1 \( -type d -o -type l \) -exec basename {} \; | sort
}

is_true() {
  local val="${1:-}"
  val="${val,,}"
  [ "$val" = "1" ] || [ "$val" = "true" ] || [ "$val" = "yes" ]
}

should_enforce_fail=0
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r path; do
    case "$path" in
      .claude/skills/* | \
      .agents/skills/* | \
      modules/shared/programs/codex/* | \
      scripts/ai/verify-ai-compat.sh | \
      scripts/ai/warn-skill-consistency.sh | \
      lefthook.yml | \
      AGENTS.md | AGENTS.override.md | CLAUDE.md)
        should_enforce_fail=1
        break
        ;;
    esac
  done < <(git -C "$REPO_ROOT" diff --name-only --cached)
fi

warnings=0
has_source=1
has_projected=1

if [ ! -d "$SOURCE_SKILLS_DIR" ]; then
  warn ".claude/skills 없음: 정합성 체크 불가"
  warnings=$((warnings + 1))
  has_source=0
fi

if [ ! -d "$PROJECTED_SKILLS_DIR" ]; then
  warn ".agents/skills 없음: Codex project-scope 스킬 정합성 체크 불가"
  warn "해결: nrs (또는 동등 activation) 실행 후 다시 커밋"
  warnings=$((warnings + 1))
  has_projected=0
fi

if [ "$has_source" -eq 1 ] && [ "$has_projected" -eq 1 ]; then
  while IFS= read -r missing; do
    [ -n "$missing" ] || continue
    warn "투영 누락: .agents/skills/$missing"
    warnings=$((warnings + 1))
  done < <(comm -23 <(list_skill_dirs "$SOURCE_SKILLS_DIR") <(list_skill_dirs "$PROJECTED_SKILLS_DIR"))

  while IFS= read -r orphan; do
    [ -n "$orphan" ] || continue
    warn "고아 투영: .agents/skills/$orphan (원본 .claude/skills 없음)"
    warnings=$((warnings + 1))
  done < <(comm -13 <(list_skill_dirs "$SOURCE_SKILLS_DIR") <(list_skill_dirs "$PROJECTED_SKILLS_DIR"))

  while IFS= read -r skill_name; do
    [ -n "$skill_name" ] || continue

    projected_entry="$PROJECTED_SKILLS_DIR/$skill_name"
    expected_target="../../.claude/skills/$skill_name"

    # 디렉토리 심링크 여부 확인
    if [ ! -L "$projected_entry" ]; then
      if [ -d "$projected_entry" ]; then
        warn "레거시 실디렉토리: .agents/skills/$skill_name (심링크 전환 필요)"
        warnings=$((warnings + 1))
      fi
      continue
    fi

    # 심링크 대상 경로 확인
    actual_target="$(readlink "$projected_entry")"
    if [ "$actual_target" != "$expected_target" ]; then
      warn "심링크 대상 불일치: $skill_name ($actual_target != $expected_target)"
      warnings=$((warnings + 1))
    fi
  done < <(list_skill_dirs "$SOURCE_SKILLS_DIR")
fi

if [ "$warnings" -eq 0 ]; then
  exit 0
fi

warn "skills 구조 정합성 경고 ${warnings}건"
warn "권장: nrs 실행 후 ./scripts/ai/verify-ai-compat.sh 재검증"

if is_true "${SKIP_AI_SKILL_CHECK:-}"; then
  warn "SKIP_AI_SKILL_CHECK 설정으로 이번 커밋에서 차단을 우회합니다."
  exit 0
fi

if [ "$should_enforce_fail" -eq 1 ]; then
  err "스킬/Codex 관련 파일이 staged 되어 있어 커밋을 차단합니다."
  err "긴급 우회가 필요하면 SKIP_AI_SKILL_CHECK=1 로 재시도하세요."
  exit 1
fi

# 일반 변경에서는 warning-only
exit 0
