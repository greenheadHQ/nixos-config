#!/usr/bin/env bash
# verify-ai-compat.sh — Claude Code + Codex CLI 호환 구조 검증
# 사용: ./scripts/ai/verify-ai-compat.sh 또는 devShell에서 verify-ai-compat
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SKILLS_DIR="$REPO_ROOT/.claude/skills"
TARGET_SKILLS_DIR="$REPO_ROOT/.agents/skills"

errors=0
warnings=0

pass() { echo "  [OK] $1"; }
fail() { echo "  [FAIL] $1" >&2; errors=$((errors + 1)); }
warn() { echo "  [WARN] $1" >&2; warnings=$((warnings + 1)); }

echo "=== Trust 설정 확인 ==="

CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
  if grep -q 'nixos-config' "$CODEX_CONFIG"; then
    pass "nixos-config 프로젝트 trust 설정됨"
  else
    fail "nixos-config 프로젝트 trust 미설정 — .agents/skills/ 발견 불가"
  fi
else
  fail "$HOME/.codex/config.toml 없음"
fi

echo ""
echo "=== AGENTS.md 심링크 확인 ==="

if [ -L "$REPO_ROOT/AGENTS.md" ]; then
  target="$(readlink "$REPO_ROOT/AGENTS.md")"
  if [ "$target" = "CLAUDE.md" ]; then
    pass "AGENTS.md → CLAUDE.md"
  else
    fail "AGENTS.md → '$target' (expected: CLAUDE.md)"
  fi
else
  fail "AGENTS.md 심링크 없음"
fi

echo ""
echo "=== AGENTS.override.md 확인 ==="

if [ -f "$REPO_ROOT/AGENTS.override.md" ]; then
  pass "AGENTS.override.md 존재"
else
  warn "AGENTS.override.md 없음 (Codex 전용 보충 규칙 누락)"
fi

echo ""
echo "=== 프로젝트 스킬 투영 확인 ==="

if [ ! -d "$TARGET_SKILLS_DIR" ]; then
  fail ".agents/skills/ 디렉토리 없음"
else
  src_count=0
  dst_count=0

  for skill_dir in "$SOURCE_SKILLS_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    src_count=$((src_count + 1))

    projected_dir="$TARGET_SKILLS_DIR/$skill_name"
    if [ ! -d "$projected_dir" ]; then
      fail "투영 누락: .agents/skills/$skill_name"
      continue
    fi

    # SKILL.md 실파일 확인 (symlink가 아닌 복사본)
    projected_skill="$projected_dir/SKILL.md"
    source_skill="$skill_dir/SKILL.md"
    if [ ! -f "$projected_skill" ]; then
      fail "SKILL.md 파일 누락: $skill_name"
    elif [ -L "$projected_skill" ]; then
      fail "SKILL.md가 심링크임: $skill_name (project-scope 누락 가능성)"
    elif cmp -s "$source_skill" "$projected_skill"; then
      pass "SKILL.md 복사본 일치: $skill_name"
    else
      fail "SKILL.md 내용 불일치: $skill_name"
    fi

    # openai.yaml 존재 확인
    if [ -f "$projected_dir/agents/openai.yaml" ]; then
      pass "openai.yaml: $skill_name"
    else
      warn "openai.yaml 누락: $skill_name"
    fi

    # references/scripts/assets 심링크 확인 (소스에 존재 시)
    for child in references scripts assets; do
      if [ -e "$skill_dir/$child" ]; then
        if [ -L "$projected_dir/$child" ]; then
          if [ ! -e "$projected_dir/$child" ]; then
            fail "깨진 $child 심링크: $skill_name"
          fi
        else
          warn "$child 심링크 누락: $skill_name"
        fi
      fi
    done
  done

  # 고아 디렉토리 탐지
  for projected_dir in "$TARGET_SKILLS_DIR"/*/; do
    [ -d "$projected_dir" ] || continue
    skill_name="$(basename "$projected_dir")"
    dst_count=$((dst_count + 1))
    if [ ! -d "$SOURCE_SKILLS_DIR/$skill_name" ]; then
      fail "고아 투영: .agents/skills/$skill_name (원본 없음)"
    fi
  done

  echo ""
  echo "  소스 스킬: ${src_count}개, 투영 스킬: ${dst_count}개"
fi

echo ""
echo "=== 글로벌 설정 확인 ==="

# ~/.codex/config.toml 심링크
if [ -L "$HOME/.codex/config.toml" ]; then
  pass "$HOME/.codex/config.toml 심링크"
else
  if [ -f "$HOME/.codex/config.toml" ]; then
    warn "$HOME/.codex/config.toml 일반 파일 (심링크 아님)"
  else
    fail "$HOME/.codex/config.toml 없음"
  fi
fi

# ~/.codex/AGENTS.md
if [ -L "$HOME/.codex/AGENTS.md" ]; then
  pass "$HOME/.codex/AGENTS.md 심링크"
elif [ -f "$HOME/.codex/AGENTS.md" ]; then
  warn "$HOME/.codex/AGENTS.md 일반 파일 (심링크 아님)"
else
  warn "$HOME/.codex/AGENTS.md 없음"
fi

# ~/.codex/skills/agent-browser
if [ -d "$HOME/.codex/skills/agent-browser" ]; then
  pass "$HOME/.codex/skills/agent-browser 존재"
else
  warn "$HOME/.codex/skills/agent-browser 없음"
fi

echo ""
echo "=== 원본 무결성 확인 ==="

cd "$REPO_ROOT"
if git diff --quiet .claude/skills/ 2>/dev/null; then
  pass ".claude/skills/ 원본 무변경"
else
  warn ".claude/skills/ 에 uncommitted 변경 있음"
fi

echo ""
echo "========================================="
if [ "$errors" -gt 0 ]; then
  echo "검증 실패: ${errors}개 오류, ${warnings}개 경고"
  exit 1
elif [ "$warnings" -gt 0 ]; then
  echo "검증 통과 (경고 ${warnings}개)"
  exit 0
else
  echo "검증 완전 통과"
  exit 0
fi
