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

has_staged_snapshot_input() {
  [ -n "${STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE:-}" ] || [ -n "${STAGED_SNAPSHOT_STAGED_NAME_STATUS_NUL_FILE:-}" ]
}

staged_paths() {
  if [ -n "${STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE:-}" ]; then
    while IFS= read -r -d '' path; do
      printf '%s\n' "$path"
    done < "$STAGED_SNAPSHOT_STAGED_FILES_NUL_FILE"
    return 0
  fi

  git -C "$REPO_ROOT" diff --name-only --cached
}

staged_added_paths() {
  local status path

  if [ -n "${STAGED_SNAPSHOT_STAGED_NAME_STATUS_NUL_FILE:-}" ]; then
    while IFS= read -r -d '' status; do
      case "$status" in
        A)
          if ! IFS= read -r -d '' path; then
            err "malformed staged name-status metadata: missing path for added entry"
            return 1
          fi
          printf '%s\n' "$path"
          ;;
        R* | C*)
          if ! IFS= read -r -d '' path; then
            err "malformed staged name-status metadata: missing source path for $status entry"
            return 1
          fi
          if ! IFS= read -r -d '' path; then
            err "malformed staged name-status metadata: missing target path for $status entry"
            return 1
          fi
          ;;
        *)
          if ! IFS= read -r -d '' path; then
            err "malformed staged name-status metadata: missing path for $status entry"
            return 1
          fi
          ;;
      esac
    done < "$STAGED_SNAPSHOT_STAGED_NAME_STATUS_NUL_FILE"
    return 0
  fi

  git -C "$REPO_ROOT" diff --name-only --cached --diff-filter=A
}

staged_added_shared_skill_markdowns() {
  local added_paths path
  added_paths="$(staged_added_paths)" || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [[ "$path" =~ ^modules/shared/programs/claude/files/skills/[^/]+/SKILL\.md$ ]]; then
      printf '%s\n' "$path"
    fi
  done <<< "$added_paths"
}

should_enforce_fail=0
if has_staged_snapshot_input || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  while IFS= read -r path; do
    case "$path" in
      .claude/skills/* | \
      .agents/skills/* | \
      modules/shared/programs/claude/* | \
      modules/shared/programs/codex/* | \
      scripts/ai/verify-ai-compat.sh | \
      scripts/ai/warn-skill-consistency.sh | \
      scripts/ai/commit-msg-pinning.sh | \
      scripts/ai/lib/* | \
      libraries/python-runtimes.nix | \
      flake.nix | \
      lefthook.yml | \
      AGENTS.md | AGENTS.override.md | CLAUDE.md)
        should_enforce_fail=1
        break
        ;;
      esac
  done < <(staged_paths)
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

# Shared user-scope skill source ↔ 노출 정책 정합성 검사
# 신규 스킬이 modules/shared/programs/claude/files/skills/ 아래 staged 되었을 때
# Home Manager 노출(.claude/skills/<name>)과 Codex SoT(exposedCodexSkills 또는
# intentionallyNotExposed)가 함께 갱신됐는지 확인한다. 양쪽 projection이 함께
# stale인 상태에서는 기존 .claude/skills ↔ .agents/skills 비교만으로는
# regression을 잡을 수 없다.
SHARED_CLAUDE_NIX="$REPO_ROOT/modules/shared/programs/claude/default.nix"
SHARED_CODEX_NIX="$REPO_ROOT/modules/shared/programs/codex/default.nix"

if [ -f "$SHARED_CLAUDE_NIX" ] && { has_staged_snapshot_input || git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; }; then
  shared_skill_markdowns="$(staged_added_shared_skill_markdowns)"
  while IFS= read -r shared_skill_md; do
    [ -n "$shared_skill_md" ] || continue
    skill_name="$(basename "$(dirname "$shared_skill_md")")"
    if ! grep -qF "\".claude/skills/$skill_name\"" "$SHARED_CLAUDE_NIX"; then
      err "신규 shared 스킬 '$skill_name': modules/shared/programs/claude/default.nix 에 .claude/skills/$skill_name 엔트리 누락"
      warnings=$((warnings + 1))
      should_enforce_fail=1
    fi
    if [ -f "$SHARED_CODEX_NIX" ] && ! grep -qE "\"$skill_name\"" "$SHARED_CODEX_NIX"; then
      err "신규 shared 스킬 '$skill_name': modules/shared/programs/codex/default.nix 의 exposedCodexSkills 또는 intentionallyNotExposed 리스트에 미분류"
      warnings=$((warnings + 1))
      should_enforce_fail=1
    fi
  done <<< "$shared_skill_markdowns"
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
