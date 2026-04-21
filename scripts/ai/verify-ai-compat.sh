#!/usr/bin/env bash
# verify-ai-compat.sh — Claude Code + Codex CLI 호환 구조 검증
# 사용: `./scripts/ai/verify-ai-compat.sh` 또는 devShell에서 `verify-ai-compat`
# tomlkit 미가용 환경에서는 자동으로 `nix shell .#pythonWithTomlkit --command bash "$0"`로
# 재실행된다 (아래 tomlkit self-wrap 섹션 참조).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SKILLS_DIR="$REPO_ROOT/.claude/skills"
TARGET_SKILLS_DIR="$REPO_ROOT/.agents/skills"

errors=0
warnings=0

pass() { echo "  [OK] $1"; }
fail() { echo "  [FAIL] $1" >&2; errors=$((errors + 1)); }
warn() { echo "  [WARN] $1" >&2; warnings=$((warnings + 1)); }

# ─── tomlkit bootstrap ───
# sync-codex-config.py의 `check` subcommand가 tomlkit에 의존한다. 정책과 재실행 guard는
# scripts/ai/lib/tomlkit-bootstrap.sh 단일 소스에서 관리한다.
# Python 사전 체크보다 먼저 실행한다. host python3가 없거나 3.11 미만이어도
# nix shell .#pythonWithTomlkit으로 self-wrap된 뒤 그 안의 python3로 다시 사전 체크를 수행한다.
# 그래야 파일 상단의 "tomlkit 미가용 시 자동 재실행" 계약이 실제로 성립한다.
_VERIFY_AI_COMPAT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$_VERIFY_AI_COMPAT_REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
tomlkit_bootstrap_require "$_VERIFY_AI_COMPAT_REPO_ROOT" "${BASH_SOURCE[0]}" "$@"

# ─── Python 사전 체크 ───
# bootstrap 이후에도 ambient python3가 어떤 이유로 여전히 3.11 미만이면 명시적 실패.
# 일반적으로 이 분기에 도달하지 않는다 (nix shell이 Python 3.13+를 보장).
if ! command -v python3 >/dev/null 2>&1; then
  echo "  [FAIL] python3 not found in PATH (bootstrap 이후에도 부재)" >&2
  exit 1
fi
if ! python3 - <<'PY' 2>/dev/null
import sys, tomllib  # tomllib requires 3.11+
if sys.version_info < (3, 11):
    raise SystemExit(1)
PY
then
  echo "  [FAIL] python3 >= 3.11 with tomllib is required (bootstrap 이후에도 버전 부족)" >&2
  exit 1
fi

# ─── TOML helper ───
# 통합 helper. 모든 TOML inspection을 단일 `_toml_inspect --what=<mode>`로 수행한다.
# 이전의 _toml_parse/_toml_get_scalar/_toml_has_table/_file_mode는 모두 여기로 통합했다.
# 현재 호출 지점이 있는 모드만 남겨두며, 새 모드가 필요하면 호출처와 함께 추가한다.
#
# Mode별 반환 계약 (soft-fail 계약 유지 — 한 체크 실패가 이후 섹션을 끊지 않도록):
#   --what=scalar <file> <dotted.path>
#       stdout: scalar 값(str/int/float/bool). 없거나 파싱 실패면 empty.
#       exit  : 항상 0 (command substitution 안전)
#   --what=parse  <file>
#       stdout: 없음.
#       exit  : 유효한 TOML이면 0, 아니면 1 (if/then 분기용)
#   --what=mode   <file>
#       stdout: 8진수 mode 문자열 (예: "600"). 실패 시 "?".
#       exit  : 항상 0
_toml_inspect() {
  # $1 = --what=<mode>, $2 = file, $3 = optional dotted path (scalar/table 전용)
  local what="${1#--what=}"
  shift
  python3 - "$what" "$@" <<'PY'
import os, stat, sys, tomllib

what = sys.argv[1]
args = sys.argv[2:]


def inspect_parse(path):
    try:
        with open(path, "rb") as f:
            tomllib.load(f)
    except Exception:
        sys.exit(1)
    sys.exit(0)


def inspect_scalar(path, dotted):
    # soft-fail: 파일/파싱/경로 문제는 empty stdout + exit 0.
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except Exception:
        sys.exit(0)
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            sys.exit(0)
        cur = cur[part]
    if isinstance(cur, (str, int, float, bool)):
        print(cur)
    sys.exit(0)


def inspect_mode(path):
    try:
        print(f"{stat.S_IMODE(os.stat(path).st_mode):o}")
    except Exception:
        print("?")
    sys.exit(0)


dispatch = {
    "parse":  lambda: inspect_parse(args[0]),
    "scalar": lambda: inspect_scalar(args[0], args[1]),
    "mode":   lambda: inspect_mode(args[0]),
}
handler = dispatch.get(what)
if handler is None:
    print(f"_toml_inspect: unknown --what={what}", file=sys.stderr)
    sys.exit(2)
handler()
PY
}

echo "=== Codex 실행 정책 확인 ==="

CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
  _ap="$(_toml_inspect --what=scalar "$CODEX_CONFIG" approval_policy)"
  if [ "$_ap" = "never" ]; then
    pass "approval_policy = \"never\""
  else
    fail "approval_policy = \"never\" 미설정 (actual: \"$_ap\")"
  fi

  _sm="$(_toml_inspect --what=scalar "$CODEX_CONFIG" sandbox_mode)"
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
  _mode="$(_toml_inspect --what=mode "$_codex_cfg")"
  if [ "$_mode" = "600" ]; then
    pass "$_codex_cfg regular file, mode=0600"
  else
    fail "$_codex_cfg mode=$_mode (기대: 0600) — 권한 제한 실패"
  fi
  if ! _toml_inspect --what=parse "$_codex_cfg"; then
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

# ─── template ↔ live drift 검증 ───
# sync-codex-config.py의 `check` 서브커맨드에게 drift 계산을 위임한다. writer와
# 동일한 `_walk_template_leaves` iterator를 쓰므로 ownership policy drift가 구조적으로
# 차단된다. 플랫폼별 하드코딩(예: [mcp_servers.chrome-devtools] Darwin 전용) 없이,
# 해당 플랫폼의 template 파일에 선언된 leaf만 자동으로 검증된다.
echo ""
echo "=== template ↔ live drift 검증 ==="

# Nix store에 복사된 template seed가 아니라 현재 flake 워킹트리의 template을 검증 기준으로 쓴다.
if [ "$(uname -s)" = "Darwin" ]; then
  _TEMPLATE="$REPO_ROOT/modules/shared/programs/codex/files/config.darwin.toml"
else
  _TEMPLATE="$REPO_ROOT/modules/shared/programs/codex/files/config.toml"
fi
_CHECK_SCRIPT="$REPO_ROOT/modules/shared/programs/codex/files/sync-codex-config.py"

if [ ! -f "$_TEMPLATE" ]; then
  fail "template 파일 없음: $_TEMPLATE"
elif [ ! -f "$_CHECK_SCRIPT" ]; then
  fail "sync-codex-config.py 없음: $_CHECK_SCRIPT"
else
  # rc 흡수 패턴: EXIT_DRIFT(1)는 데이터 있는 정상 경로이므로 `if ...; then rc=0; else rc=$?; fi`로
  # 받아 set -euo pipefail 하에서도 verifier가 조기 종료되지 않는다. EXIT_ERROR(2)만 섹션 종료.
  _check_stdout=""
  _check_stderr=""
  _check_rc=0
  _check_err_file="$(mktemp "${TMPDIR:-/tmp}/verify-ai-compat-check-err.XXXXXX")"
  if _check_stdout="$(python3 "$_CHECK_SCRIPT" check "$_TEMPLATE" "$CODEX_CONFIG" 2>"$_check_err_file")"; then
    _check_rc=0
  else
    _check_rc=$?
  fi
  _check_stderr="$(cat "$_check_err_file")"
  rm -f "$_check_err_file"

  case "$_check_rc" in
    0|1)
      # check.py JSON 소비는 scripts/ai/lib/render-check-report.py 단일 helper에 위임한다.
      # helper가 `OK_LINE/FAIL_LINE/INFO_LINE <message>` 형식의 directive를 stdout에 쓰고,
      # verifier는 그 라인을 case 분기로 pass/fail/info에 매핑만 한다.
      # subshell pipe 대신 process substitution을 써서 fail()의 errors 증가가 부모 shell로 반영되도록 한다.
      while IFS= read -r _line; do
        case "$_line" in
          "OK_LINE "*)   pass "${_line#OK_LINE }" ;;
          "FAIL_LINE "*) fail "${_line#FAIL_LINE }" ;;
          "INFO_LINE "*) echo "  → ${_line#INFO_LINE }" >&2 ;;
          *)             fail "render-check-report.py 알 수 없는 directive: $_line" ;;
        esac
      done < <(printf '%s' "$_check_stdout" | python3 "$REPO_ROOT/scripts/ai/lib/render-check-report.py")
      ;;
    2)
      # EXIT_ERROR는 template read/parse, target read/parse 모두를 포함한 hard error 공용 신호다.
      # 원인을 제자리에서 단정하지 말고 subprocess stderr를 그대로 노출한다.
      fail "check.py EXIT_ERROR: ${_check_stderr:-(no stderr)}"
      ;;
    *)
      fail "check.py 비정상 종료 (rc=$_check_rc): $_check_stderr"
      ;;
  esac
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
  prd
  review-implementation
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
