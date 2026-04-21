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

# ─── Python 사전 체크 ───
# 이 스크립트는 python3 >= 3.11 (tomllib 내장)을 가정한다. 사전에 명확히 실패해서
# "tomllib 미존재" → "TOML parse 실패" 같은 오검진을 방지한다.
if ! command -v python3 >/dev/null 2>&1; then
  echo "  [FAIL] python3 not found in PATH" >&2
  exit 1
fi
if ! python3 - <<'PY' 2>/dev/null
import sys, tomllib  # tomllib requires 3.11+
if sys.version_info < (3, 11):
    raise SystemExit(1)
PY
then
  echo "  [FAIL] python3 >= 3.11 with tomllib is required" >&2
  exit 1
fi

# ─── TOML helper ───
# 여러 곳에서 쓰이는 python3 inline 블록을 단일 헬퍼로 통일.
# 사용법:
#   _toml_parse        <file>                : valid TOML이면 0, 아니면 1
#   _toml_get_scalar   <file> <dotted.path>  : 경로의 scalar(str/int/float/bool)을
#                                              stdout으로. 없거나 table이면 empty.
#                                              TOML parse 실패 시에도 empty + 0으로
#                                              끝나므로 `set -euo pipefail` 환경에서
#                                              command substitution으로 안전하게 호출 가능.
#   _toml_has_table    <file> <dotted.path>  : table로 존재하면 0, 아니면 1
#   _file_mode         <file>                : 8진수 mode 문자열 (예: "600"), 실패 시 "?"
_toml_parse() {
  python3 - "$1" <<'PY' >/dev/null 2>&1
import sys, tomllib
with open(sys.argv[1], 'rb') as f:
    tomllib.load(f)
PY
}

_toml_get_scalar() {
  python3 - "$1" "$2" <<'PY' 2>/dev/null || true
import sys, tomllib
try:
    with open(sys.argv[1], 'rb') as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(0)
cur = data
for part in sys.argv[2].split('.'):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(0)
    cur = cur[part]
if isinstance(cur, (str, int, float, bool)):
    print(cur)
PY
}

_toml_has_table() {
  python3 - "$1" "$2" <<'PY'
import sys, tomllib
try:
    with open(sys.argv[1], 'rb') as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(1)
cur = data
for part in sys.argv[2].split('.'):
    if not isinstance(cur, dict) or part not in cur:
        sys.exit(1)
    cur = cur[part]
sys.exit(0 if isinstance(cur, dict) else 1)
PY
}

_file_mode() {
  python3 -c 'import os, stat, sys; print(f"{stat.S_IMODE(os.stat(sys.argv[1]).st_mode):o}")' "$1" 2>/dev/null || echo "?"
}

echo "=== Codex 실행 정책 확인 ==="

CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
  _ap="$(_toml_get_scalar "$CODEX_CONFIG" approval_policy)"
  if [ "$_ap" = "never" ]; then
    pass "approval_policy = \"never\""
  else
    fail "approval_policy = \"never\" 미설정 (actual: \"$_ap\")"
  fi

  _sm="$(_toml_get_scalar "$CODEX_CONFIG" sandbox_mode)"
  if [ "$_sm" = "danger-full-access" ]; then
    pass "sandbox_mode = \"danger-full-access\""
  else
    fail "sandbox_mode = \"danger-full-access\" 미설정 (actual: \"$_sm\")"
  fi

  if grep -q 'nixos-config' "$CODEX_CONFIG"; then
    pass "프로젝트 trust 항목 존재 (선택)"
  else
    pass "프로젝트 trust 항목 없음 (선택)"
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
echo "=== 프로젝트 스킬 투영 확인 (디렉토리 심링크) ==="

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

    projected_entry="$TARGET_SKILLS_DIR/$skill_name"
    expected_target="../../.claude/skills/$skill_name"

    # 디렉토리 심링크 여부 확인
    if [ ! -L "$projected_entry" ]; then
      if [ -d "$projected_entry" ]; then
        fail "레거시 실디렉토리: .agents/skills/$skill_name (심링크 전환 필요)"
      else
        fail "투영 누락: .agents/skills/$skill_name"
      fi
      continue
    fi

    # 심링크 대상 경로 확인
    actual_target="$(readlink "$projected_entry")"
    if [ "$actual_target" != "$expected_target" ]; then
      fail "심링크 대상 불일치: $skill_name ($actual_target != $expected_target)"
      continue
    fi

    # 대상 존재 확인 (깨진 심링크 = warn, Nix 생성 스킬 허용)
    if [ ! -e "$projected_entry" ]; then
      warn "깨진 심링크: .agents/skills/$skill_name (소스 미존재, Nix 생성 스킬일 수 있음)"
      continue
    fi

    # SKILL.md 접근 가능 확인
    if [ -f "$projected_entry/SKILL.md" ]; then
      pass "디렉토리 심링크 정상: $skill_name"
    else
      fail "SKILL.md 접근 불가: $skill_name"
    fi
  done

  # 고아 심링크 탐지 (깨진 심링크도 포함)
  for entry in "$TARGET_SKILLS_DIR"/*; do
    [ -L "$entry" ] || [ -d "$entry" ] || continue
    skill_name="$(basename "$entry")"
    dst_count=$((dst_count + 1))

    if [ -d "$SOURCE_SKILLS_DIR/$skill_name" ]; then
      continue
    fi

    if [ -L "$entry" ]; then
      target="$(readlink "$entry")"
      if [[ "$target" = /* ]] && [ -f "$entry/SKILL.md" ]; then
        pass "플러그인 스킬 심링크 정상: $skill_name"
        continue
      fi
    fi

    fail "고아 투영: .agents/skills/$skill_name (원본 없음)"
  done

  echo ""
  echo "  소스 스킬: ${src_count}개, 투영 스킬: ${dst_count}개"
fi

echo ""
echo "=== 글로벌 설정 확인 ==="

# ~/.codex/config.toml 관리 상태
# activation의 syncCodexConfig가 repo-managed 키와 사용자 소유 섹션을 merge한 regular file로
# 유지한다. PASS 기준: (a) regular file, (b) mode 0600, (c) TOML 파싱 성공,
#                     (d) template-managed key 존재 (model/approval_policy/sandbox_mode).
# mode 불일치는 fail로 승격, legacy symlink 감지 시 nrs --force 안내.
_codex_cfg="$HOME/.codex/config.toml"
if [ ! -e "$_codex_cfg" ]; then
  fail "$_codex_cfg 없음"
elif [ -L "$_codex_cfg" ]; then
  fail "$_codex_cfg 심링크 — syncCodexConfig 미적용 (NO_CHANGES 경로 회피 위해 \`nrs --force\` 실행 필요)"
elif [ ! -f "$_codex_cfg" ]; then
  fail "$_codex_cfg regular file 아님"
else
  _mode="$(_file_mode "$_codex_cfg")"
  if [ "$_mode" = "600" ]; then
    pass "$_codex_cfg regular file, mode=0600"
  else
    fail "$_codex_cfg mode=$_mode (기대: 0600) — 권한 제한 실패"
  fi
  if ! _toml_parse "$_codex_cfg"; then
    fail "$_codex_cfg TOML 파싱 실패"
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

# ─── template-managed 계약 검증 ───
# syncCodexConfig merge 정책은 "repo-managed 키는 template wins"를 보장한다.
# 이 계약을 verify 수준에서 검증할 수 있도록, template이 반드시 가져야 하는 구조를 확인한다.
echo ""
echo "=== template-managed 계약 확인 ==="

if [ -f "$CODEX_CONFIG" ] && _toml_parse "$CODEX_CONFIG"; then
  # top-level 필수 키
  for _k in model approval_policy sandbox_mode service_tier personality; do
    if [ -n "$(_toml_get_scalar "$CODEX_CONFIG" "$_k")" ]; then
      pass "top-level 키 존재: $_k"
    else
      fail "top-level 키 누락: $_k (template-managed 계약 위반)"
    fi
  done
  # template table 존재
  if _toml_has_table "$CODEX_CONFIG" features; then
    pass "[features] table 존재"
  else
    fail "[features] table 누락"
  fi
  # Darwin template은 [mcp_servers.chrome-devtools]를 가지며 누락 시 fail.
  # Non-Darwin template에는 해당 섹션이 없으므로 존재하지 않는 것이 정상(pass).
  if _toml_has_table "$CODEX_CONFIG" "mcp_servers.chrome-devtools"; then
    pass "[mcp_servers.chrome-devtools] 존재 (Darwin template)"
  else
    case "$(uname -s)" in
      Darwin) fail "[mcp_servers.chrome-devtools] 누락 (Darwin template-managed 계약 위반)" ;;
      *)      pass "[mcp_servers.chrome-devtools] 없음 (non-Darwin platform)" ;;
    esac
  fi
else
  warn "template 계약 체크 스킵 (config 파일 없음 또는 파싱 실패)"
fi

echo ""
echo "=== Shared 글로벌 스킬 노출 정책 확인 ==="

SHARED_SKILLS_DIR="$REPO_ROOT/modules/shared/programs/claude/files/skills"
CODEX_GLOBAL_SKILLS_DIR="$HOME/.codex/skills"

# Nix SoT(default.nix)와 독립된 감사 오라클.
# 두 리스트는 서로 교집합이 없어야 하며, shared 디렉토리의 모든 스킬이 둘 중 하나에 속해야 한다.
EXPECTED_EXPOSED=(
  create-issue
  create-pr
  parallel-audit
  plan-with-questions
  playwright-cli
  review-pr-feedback
  run-da
  syncing-codex-harness
  write-handoff
)
INTENTIONAL_EXCLUDE=(
  set-icons
  using-claude-p
  using-codex-exec
  codex-fan-out
  documenting-intent
)

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

if [ ! -d "$SHARED_SKILLS_DIR" ]; then
  fail "shared skills 디렉토리 없음: $SHARED_SKILLS_DIR"
else
  shared_count=0
  for skill_dir in "$SHARED_SKILLS_DIR"/*/; do
    [ -d "$skill_dir" ] || continue
    [ -f "$skill_dir/SKILL.md" ] || continue
    skill_name="$(basename "$skill_dir")"
    shared_count=$((shared_count + 1))

    exposed_path="$CODEX_GLOBAL_SKILLS_DIR/$skill_name"

    if in_list "$skill_name" "${EXPECTED_EXPOSED[@]}"; then
      if [ ! -L "$exposed_path" ]; then
        fail "노출 누락: ~/.codex/skills/$skill_name (심링크 없음)"
        continue
      fi
      # Canonical target 검증: readlink -f 결과가 shared source에 도달해야 함
      resolved="$(readlink -f "$exposed_path" 2>/dev/null || true)"
      expected_real="$(readlink -f "$skill_dir" 2>/dev/null || true)"
      if [ -z "$resolved" ] || [ "$resolved" != "$expected_real" ]; then
        fail "노출 대상 불일치: $skill_name (actual=$resolved expected=$expected_real)"
        continue
      fi
      pass "shared 노출 정상: $skill_name"
    elif in_list "$skill_name" "${INTENTIONAL_EXCLUDE[@]}"; then
      # broken symlink도 노출 상태로 간주 (-e는 깨진 심링크에 false; -L || -e로 둘 다 검출)
      if [ -L "$exposed_path" ] || [ -e "$exposed_path" ]; then
        fail "의도적 비노출이 노출됨: $skill_name"
      else
        pass "의도적 비노출 확인: $skill_name"
      fi
    else
      fail "미분류 shared 스킬: $skill_name (EXPECTED_EXPOSED 또는 INTENTIONAL_EXCLUDE 중 하나에 등록 필요)"
    fi
  done

  echo ""
  echo "  shared 스킬: ${shared_count}개, 노출 기대값: ${#EXPECTED_EXPOSED[@]}개, 비노출 기대값: ${#INTENTIONAL_EXCLUDE[@]}개"
fi

echo ""
echo "=== Codex helper 스크립트 확인 ==="

# Codex 프로비저닝된 helper가 shared source를 정확히 가리키는지 검증 (#486 F4/F8)
verify_codex_helper() {
  local helper="$1"
  local helper_path="$HOME/.codex/scripts/$helper"
  local helper_source="$REPO_ROOT/modules/shared/programs/claude/files/scripts/$helper"
  if [ ! -L "$helper_path" ]; then
    fail "$helper_path 심링크 없음"
    return
  fi
  local resolved expected
  resolved="$(readlink -f "$helper_path" 2>/dev/null || true)"
  expected="$(readlink -f "$helper_source" 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ "$resolved" != "$expected" ]; then
    fail "$helper_path 대상 불일치: actual=$resolved expected=$expected"
  else
    pass "Codex helper 정상: $helper"
  fi
}

verify_codex_helper "write-handoff-repo-slug.sh"

echo ""
echo "=== Hooks 산출물 확인 ==="

if [ -e "$REPO_ROOT/.codex/hooks.json" ] || [ -e "$REPO_ROOT/.codex/hooks.compatibility.json" ]; then
  fail "stale Codex hook artifacts present (.codex/hooks*.json)"
else
  pass "repo-local Codex hook artifacts 없음"
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
