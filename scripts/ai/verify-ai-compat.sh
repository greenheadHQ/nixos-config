#!/usr/bin/env bash
# verify-ai-compat.sh — Claude Code + Codex CLI 호환 구조 검증
# 사용: `./scripts/ai/verify-ai-compat.sh` 또는 devShell에서 `verify-ai-compat`
# tomlkit 미가용 환경에서는 자동으로 `nix shell .#pythonWithTomlkit --command bash "$0"`로
# 재실행된다 (아래 tomlkit self-wrap 섹션 참조).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SKILLS_DIR="$REPO_ROOT/.claude/skills"
TARGET_SKILLS_DIR="$REPO_ROOT/.agents/skills"
SHARED_SKILLS_DIR="$REPO_ROOT/modules/shared/programs/claude/files/skills"
CODEX_GLOBAL_SKILLS_DIR="$HOME/.codex/skills"

# shellcheck source=/dev/null
. "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"

# Nix SoT(default.nix)와 독립된 감사 오라클.
# 두 리스트는 서로 교집합이 없어야 하며, shared 디렉토리의 모든 스킬이 둘 중 하나에 속해야 한다.
EXPECTED_EXPOSED=(
  create-issue
  create-pr
  grill-me
  parallel-audit
  plan-with-questions
  playwright-cli
  review-pr-feedback
  run-da
  syncing-codex-harness
  write-handoff
)
SHARED_EXPOSURE_EXCLUDE=(
  set-icons
  using-claude-p
  using-codex-exec
  codex-fan-out
)

# SKILL.md tool-neutral lint has its own exclusion policy. It currently matches
# the shared exposure exclusions because these four skills are legacy adapters,
# but future exposure-only exclusions must be added deliberately.
SKILL_NEUTRAL_LINT_EXCLUDE=(
  set-icons
  using-claude-p
  using-codex-exec
  codex-fan-out
)

errors=0
warnings=0

pass() { echo "  [OK] $1"; }
fail() { echo "  [FAIL] $1" >&2; errors=$((errors + 1)); }
warn() { echo "  [WARN] $1" >&2; warnings=$((warnings + 1)); }

in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

RUN_GUARDRAIL_FIXTURES=0
case "${1:-}" in
  "")
    ;;
  --run-fixture-tests)
    RUN_GUARDRAIL_FIXTURES=1
    shift
    ;;
  -h|--help)
    cat <<'EOF'
Usage: ./scripts/ai/verify-ai-compat.sh [--run-fixture-tests]

  --run-fixture-tests  Run only deterministic SKILL.md tool-neutral lint fixtures.
EOF
    exit 0
    ;;
  *)
    fail "unknown argument: $1"
    exit 2
    ;;
esac
if [ "$#" -gt 0 ]; then
  fail "unexpected extra arguments: $*"
  exit 2
fi

# ─── tomlkit bootstrap ───
# sync-codex-config.py의 `check` subcommand가 tomlkit에 의존한다. 정책과 재실행 guard는
# scripts/ai/lib/tomlkit-bootstrap.sh 단일 소스에서 관리한다.
# Python 사전 체크보다 먼저 실행한다. host python3가 없거나 3.11 미만이어도
# nix shell .#pythonWithTomlkit으로 self-wrap된 뒤 그 안의 python3로 다시 사전 체크를 수행한다.
# 그래야 파일 상단의 "tomlkit 미가용 시 자동 재실행" 계약이 실제로 성립한다.
_VERIFY_AI_COMPAT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [ "$RUN_GUARDRAIL_FIXTURES" -eq 0 ]; then
  # shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
  . "$_VERIFY_AI_COMPAT_REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
  tomlkit_bootstrap_require "$_VERIFY_AI_COMPAT_REPO_ROOT" "${BASH_SOURCE[0]}" "$@"
fi

# ─── Python 사전 체크 ───
# bootstrap 이후에도 ambient python3가 어떤 이유로 여전히 3.11 미만이면 명시적 실패.
# 일반적으로 이 분기에 도달하지 않는다 (nix shell이 Python 3.13+를 보장).
if ! command -v python3 >/dev/null 2>&1; then
  echo "  [FAIL] python3 not found in PATH (bootstrap 이후에도 부재)" >&2
  exit 1
fi
if [ "$RUN_GUARDRAIL_FIXTURES" -eq 1 ]; then
  if ! python3 - <<'PY' 2>/dev/null
import sys
if sys.version_info < (3, 10):
    raise SystemExit(1)
PY
  then
    echo "  [FAIL] python3 >= 3.10 is required for fixture mode" >&2
    exit 1
  fi
elif ! python3 - <<'PY' 2>/dev/null
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

# ─── SKILL.md 도구-중립성 lint helper ───
_skill_neutral_lint() {
  python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Finding:
    severity: str
    rule_id: str
    path: Path
    line_no: int
    message: str


ASCII_LEFT = r"(?<![A-Za-z0-9_])"
ASCII_RIGHT = r"(?![A-Za-z0-9_])"

FAIL_RULES = [
    ("fail.ask_user_question", re.compile(rf"{ASCII_LEFT}AskUserQuestion{ASCII_RIGHT}")),
    (
        "fail.runtime_tool_literal",
        re.compile(rf"{ASCII_LEFT}`?(?:Bash|Read|Write|Edit)`?\s+(?:tool|도구)(?:로|를|을|으로)?{ASCII_RIGHT}"),
    ),
    ("fail.skill_call", re.compile(rf"{ASCII_LEFT}Skill\s*\(")),
    ("fail.exit_plan_mode", re.compile(rf"{ASCII_LEFT}ExitPlanMode{ASCII_RIGHT}")),
    ("fail.enter_plan_mode", re.compile(rf"{ASCII_LEFT}EnterPlanMode{ASCII_RIGHT}")),
    ("fail.agent_tool", re.compile(rf"{ASCII_LEFT}`?Agent`?\s+(?:tool|도구)(?:로|를|을|으로)?{ASCII_RIGHT}")),
    ("fail.run_in_background", re.compile(rf"{ASCII_LEFT}run_in_background\s*:\s*true{ASCII_RIGHT}")),
]
WARN_RULES = [
    ("warn.plan_mode", re.compile(r"\bplan mode\b", re.IGNORECASE)),
    ("warn.web_tool_literal", re.compile(rf"{ASCII_LEFT}(?:WebFetch|WebSearch|ToolSearch){ASCII_RIGHT}")),
    (
        "warn.slash_command",
        re.compile(r"(?<![\w-])/(?:loop|ultrareview|fast|set-icons)(?![-A-Za-z0-9_])|(?<![\w-])/review(?![-A-Za-z0-9_])"),
    ),
]
STANDALONE_SEARCH_TOOL = re.compile(
    r"^\s*(?:[-*]\s+|\d+[.)]\s+)?`?(Glob|Grep)`?(?:\s*(?:tool|도구)?(?:로|으로|을|를)?(?:\s|:|,|-|$)|$)"
)
LEGACY_LITERAL = re.compile(
    rf"{ASCII_LEFT}(?:AskUserQuestion|`?Agent`?\s+(?:tool|도구)|`?Bash`?\s+(?:tool|도구)|`?Read`?\s+(?:tool|도구)|`?Write`?\s+(?:tool|도구)|`?Edit`?\s+(?:tool|도구)|run_in_background\s*:\s*true){ASCII_RIGHT}"
)
CODEX_EQUIVALENT = re.compile(
    r"\b(?:Codex|codex exec|request_user_input|exec_command|spawn_agent|wait_agent|close_agent|tool_search|multi_tool_use)\b"
)


def emit(kind: str, message: str) -> None:
    print(f"{kind} {message}")


def display_path(path: Path, repo_root: Path | None) -> str:
    if repo_root is not None:
        try:
            return str(path.resolve().relative_to(repo_root.resolve()))
        except ValueError:
            pass
    return str(path)


def is_heading(line: str) -> tuple[int, str] | None:
    match = re.match(r"^(#{1,6})\s+(.+?)\s*$", line.strip())
    if not match:
        return None
    return len(match.group(1)), match.group(2)


def is_table_row(line: str) -> bool:
    stripped = line.strip()
    return stripped.startswith("|") and stripped.endswith("|") and stripped.count("|") >= 2


def is_runtime_heading(text: str) -> bool:
    lowered = text.lower()
    return any(
        token in lowered
        for token in (
            "런타임 도구 매핑",
            "도구 매핑",
            "용어 binding",
            "도구 binding",
            "tool binding",
            "runtime tool",
            "runtime binding",
            "agent tool fallback",
            "codex exec 경로",
        )
    )


def in_structural_runtime_exception(line: str, runtime_section: bool, table_dual: bool) -> bool:
    if is_table_row(line) and runtime_section and table_dual and (CODEX_EQUIVALENT.search(line) or LEGACY_LITERAL.search(line)):
        return True
    return False


def rule_matches(line: str) -> list[tuple[str, str]]:
    matches: list[tuple[str, str]] = []
    for rule_id, pattern in FAIL_RULES:
        if pattern.search(line):
            matches.append(("FAIL", rule_id))
    if STANDALONE_SEARCH_TOOL.search(line):
        tool = STANDALONE_SEARCH_TOOL.search(line).group(1)
        matches.append(("FAIL", f"fail.standalone_{tool.lower()}"))
    for rule_id, pattern in WARN_RULES:
        if pattern.search(line):
            matches.append(("WARN", rule_id))
    return matches


def scan_file(path: Path, skill_name: str, exclude_names: set[str], repo_root: Path | None) -> tuple[list[Finding], bool]:
    if skill_name in exclude_names:
        return [], True

    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except UnicodeDecodeError:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()

    findings: list[Finding] = []
    in_frontmatter = bool(lines and lines[0].strip() == "---")
    in_fence = False
    runtime_section = False
    runtime_section_level = 0
    table_dual = False

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()

        if in_frontmatter:
            if idx > 1 and stripped == "---":
                in_frontmatter = False
            continue

        heading = is_heading(line)
        if heading is not None:
            level, text = heading
            if is_runtime_heading(text):
                runtime_section = True
                runtime_section_level = level
            elif runtime_section and level <= runtime_section_level:
                runtime_section = False
                runtime_section_level = 0
            table_dual = False

        if re.match(r"^\s*(```|~~~)", line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        table_row = is_table_row(line)
        if table_row and "codex" in line.lower() and "claude" in line.lower():
            table_dual = True
        elif not table_row:
            table_dual = False

        structural_exception = in_structural_runtime_exception(line, runtime_section, table_dual)
        blockquote = line.lstrip().startswith(">")

        for severity, rule_id in rule_matches(line):
            if severity == "FAIL" and structural_exception:
                continue
            actual_severity = "WARN" if severity == "FAIL" and blockquote else severity
            findings.append(
                Finding(
                    severity=actual_severity,
                    rule_id=rule_id,
                    path=path,
                    line_no=idx,
                    message=f"{rule_id} matched in {display_path(path, repo_root)}:{idx}",
                )
            )

    return findings, False


def discover_skill_files(roots: list[Path]) -> list[tuple[str, Path]]:
    discovered: list[tuple[str, Path]] = []
    seen: set[Path] = set()
    for root in roots:
        if not root.exists():
            continue
        for skill_dir in sorted(root.iterdir(), key=lambda p: p.name):
            if not skill_dir.is_dir():
                continue
            skill_file = skill_dir / "SKILL.md"
            if not skill_file.is_file():
                continue
            resolved = skill_file.resolve()
            if resolved in seen:
                continue
            seen.add(resolved)
            discovered.append((skill_dir.name, skill_file))
    return discovered


def run_live(args: argparse.Namespace) -> int:
    repo_root = Path(args.repo_root).resolve()
    exclude_names = set(args.exclude)
    skill_files = discover_skill_files([Path(root) for root in args.root])
    finding_count = 0
    excluded_count = 0
    scanned_count = 0

    for skill_name, skill_file in skill_files:
        findings, skipped = scan_file(skill_file, skill_name, exclude_names, repo_root)
        if skipped:
            excluded_count += 1
            continue
        scanned_count += 1
        for finding in findings:
            finding_count += 1
            emit(f"{finding.severity}_LINE", finding.message)

    emit("OK_LINE", f"SKILL.md 도구-중립성 lint 완료: 검사 {scanned_count}개, 제외 {excluded_count}개, finding {finding_count}개")
    return 0


def run_fixtures(args: argparse.Namespace) -> int:
    fixture_root = Path(args.fixture_root).resolve()
    manifest_path = fixture_root / "manifest.json"
    exclude_names = set(args.exclude)
    if not manifest_path.is_file():
        emit("FAIL_LINE", f"fixture manifest 없음: {manifest_path}")
        return 0

    try:
        cases = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 - verifier should report parse failure as a finding.
        emit("FAIL_LINE", f"fixture manifest 파싱 실패: {exc}")
        return 0

    failures = 0
    checked = 0
    for case in cases:
        checked += 1
        rel_path = case["path"]
        path = fixture_root / rel_path
        skill_name = case.get("skill_name")
        if not skill_name:
            skill_name = path.parent.name if path.name == "SKILL.md" else "fixture-skill"

        if not path.is_file():
            emit("FAIL_LINE", f"fixture 파일 없음: {rel_path}")
            failures += 1
            continue

        findings, skipped = scan_file(path, skill_name, exclude_names, fixture_root)
        fail_count = sum(1 for finding in findings if finding.severity == "FAIL")
        warn_count = sum(1 for finding in findings if finding.severity == "WARN")
        rule_ids = sorted({finding.rule_id for finding in findings})

        expected_fail = int(case.get("fail_count", 0))
        expected_warn = int(case.get("warn_count", 0))
        expected_skipped = bool(case.get("skipped", False))
        expected_rules = sorted(case.get("rule_ids", []))

        case_failures: list[str] = []
        if fail_count != expected_fail:
            case_failures.append(f"fail_count actual={fail_count} expected={expected_fail}")
        if warn_count != expected_warn:
            case_failures.append(f"warn_count actual={warn_count} expected={expected_warn}")
        if skipped != expected_skipped:
            case_failures.append(f"skipped actual={skipped} expected={expected_skipped}")
        if rule_ids != expected_rules:
            case_failures.append(f"rule_ids actual={rule_ids} expected={expected_rules}")

        if case_failures:
            failures += 1
            emit("FAIL_LINE", f"{rel_path}: " + "; ".join(case_failures))
        else:
            emit("OK_LINE", f"fixture OK: {rel_path}")

    if failures == 0:
        emit("OK_LINE", f"guardrail fixture self-test 통과: {checked}개")
    else:
        emit("FAIL_LINE", f"guardrail fixture self-test 실패: {failures}/{checked}개")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("live", "fixtures"), required=True)
    parser.add_argument("--repo-root", default=None)
    parser.add_argument("--fixture-root", default=None)
    parser.add_argument("--root", action="append", default=[])
    parser.add_argument("--exclude", action="append", default=[])
    args = parser.parse_args()

    if args.mode == "live":
        if args.repo_root is None:
            emit("FAIL_LINE", "--repo-root required for live mode")
            return 0
        return run_live(args)

    if args.fixture_root is None:
        emit("FAIL_LINE", "--fixture-root required for fixture mode")
        return 0
    return run_fixtures(args)


raise SystemExit(main())
PY
}

_apply_lint_directives() {
  local _line
  while IFS= read -r _line; do
    case "$_line" in
      "OK_LINE "*)   pass "${_line#OK_LINE }" ;;
      "WARN_LINE "*) warn "${_line#WARN_LINE }" ;;
      "FAIL_LINE "*) fail "${_line#FAIL_LINE }" ;;
      "INFO_LINE "*) echo "  → ${_line#INFO_LINE }" >&2 ;;
      *)             fail "skill-neutral lint 알 수 없는 directive: $_line" ;;
    esac
  done
}

_run_skill_neutral_lint_checked() {
  local _output
  local _status
  local _line

  set +e
  _output="$(_skill_neutral_lint "$@" 2>&1)"
  _status=$?
  set -e

  if [ "$_status" -eq 0 ]; then
    if [ -z "$_output" ]; then
      fail "skill-neutral lint helper produced no output"
      return 0
    fi
    _apply_lint_directives <<< "$_output"
    return 0
  fi

  if [ -n "$_output" ]; then
    while IFS= read -r _line; do
      echo "  → skill-neutral lint helper output: $_line" >&2
    done <<< "$_output"
  fi
  fail "skill-neutral lint helper failed (exit $_status)"
}

run_skill_neutral_fixture_tests() {
  echo "=== SKILL.md 도구-중립성 fixture self-test ==="
  local _fixture_root="$REPO_ROOT/scripts/ai/fixtures/guardrail"
  local -a _exclude_args=()
  local _skill
  for _skill in "${SKILL_NEUTRAL_LINT_EXCLUDE[@]}"; do
    _exclude_args+=(--exclude "$_skill")
  done

  _run_skill_neutral_lint_checked \
    --mode fixtures \
    --fixture-root "$_fixture_root" \
    "${_exclude_args[@]}"

  echo ""
  echo "========================================="
  if [ "$errors" -gt 0 ]; then
    echo "fixture self-test 실패: ${errors}개 오류, ${warnings}개 경고"
    exit 1
  elif [ "$warnings" -gt 0 ]; then
    echo "fixture self-test 통과 (경고 ${warnings}개)"
    exit 0
  else
    echo "fixture self-test 완전 통과"
    exit 0
  fi
}

if [ "$RUN_GUARDRAIL_FIXTURES" -eq 1 ]; then
  run_skill_neutral_fixture_tests
fi

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
    elif in_list "$skill_name" "${SHARED_EXPOSURE_EXCLUDE[@]}"; then
      # broken symlink도 노출 상태로 간주 (-e는 깨진 심링크에 false; -L || -e로 둘 다 검출)
      if [ -L "$exposed_path" ] || [ -e "$exposed_path" ]; then
        fail "의도적 비노출이 노출됨: $skill_name"
      else
        pass "의도적 비노출 확인: $skill_name"
      fi
    else
      fail "미분류 shared 스킬: $skill_name (EXPECTED_EXPOSED 또는 SHARED_EXPOSURE_EXCLUDE 중 하나에 등록 필요)"
    fi
  done

  echo ""
  echo "  shared 스킬: ${shared_count}개, 노출 기대값: ${#EXPECTED_EXPOSED[@]}개, 비노출 기대값: ${#SHARED_EXPOSURE_EXCLUDE[@]}개"
fi

echo ""
echo "=== SKILL.md 도구-중립성 lint ==="

_skill_lint_exclude_args=()
for _skill_lint_exclude in "${SKILL_NEUTRAL_LINT_EXCLUDE[@]}"; do
  _skill_lint_exclude_args+=(--exclude "$_skill_lint_exclude")
done
_run_skill_neutral_lint_checked \
  --mode live \
  --repo-root "$REPO_ROOT" \
  --root "$SOURCE_SKILLS_DIR" \
  --root "$SHARED_SKILLS_DIR" \
  "${_skill_lint_exclude_args[@]}"

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

verify_codex_helper "write-handoff-repo-and-issue.sh"
verify_codex_helper "write-handoff-repo-slug.sh"
verify_codex_helper "fleiss-kappa.py"

# Claude helper도 양쪽 scope에 동일 source가 프로비저닝되는지 확인 (selective consistency harness)
verify_claude_helper() {
  local helper="$1"
  local helper_path="$HOME/.claude/scripts/$helper"
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
    pass "Claude helper 정상: $helper"
  fi
}

verify_claude_helper "write-handoff-repo-and-issue.sh"
verify_claude_helper "write-handoff-repo-slug.sh"
verify_claude_helper "fleiss-kappa.py"

echo ""
echo "=== Hooks 산출물 확인 ==="

# stale guard: <repo>/.codex/hooks.json 또는 <repo>/.codex/hooks.compatibility.json은
# 폐기된 패턴이라 잔재 시 fail. 단 user-level ~/.codex/hooks.json은 공식 hook source라
# 존재 자체가 아니라 알려진 legacy entry만 검사한다.
if [ -e "$REPO_ROOT/.codex/hooks.json" ] || [ -L "$REPO_ROOT/.codex/hooks.json" ] || \
   [ -e "$REPO_ROOT/.codex/hooks.compatibility.json" ] || [ -L "$REPO_ROOT/.codex/hooks.compatibility.json" ]; then
  fail "stale Codex hook artifacts present (.codex/hooks*.json)"
else
  pass "repo-local Codex hook artifacts 없음"
fi

_user_hooks_json="$HOME/.codex/hooks.json"
_user_hooks_report="$HOME/.codex/hooks.compatibility.json"

if [ -e "$_user_hooks_report" ] || [ -L "$_user_hooks_report" ]; then
  fail "stale user-level Codex hook artifact present ($_user_hooks_report) — run nrs to remove retired hooks.compatibility.json"
else
  pass "user-level Codex hooks.compatibility.json 없음"
fi

if [ -L "$_user_hooks_json" ] && [ ! -e "$_user_hooks_json" ]; then
  fail "$_user_hooks_json dangling symlink — user-level hook file must be repaired manually"
elif [ -f "$_user_hooks_json" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    fail "jq 없음 — $_user_hooks_json stale entry 검사 불가"
  else
    _user_stale_hook_count=""
    if ! _user_stale_hook_count="$(jq -r "$(codex_legacy_user_hook_count_jq_filter)" "$_user_hooks_json")"; then
      fail "$_user_hooks_json JSON 파싱 실패 — user-level hook 파일을 수동 점검하세요"
    elif [ "$_user_stale_hook_count" -gt 0 ] 2>/dev/null; then
      if [ -L "$_user_hooks_json" ]; then
        fail "stale user-level Codex hook entries present ($_user_hooks_json count=$_user_stale_hook_count) — symlinked hook files are preserved by nrs; remove known Claude-era entries manually"
      else
        fail "stale user-level Codex hook entries present ($_user_hooks_json count=$_user_stale_hook_count) — run nrs to prune known Claude-era entries"
      fi
    else
      pass "user-level Codex hooks.json stale legacy entry 없음"
    fi
  fi
else
  pass "user-level Codex hooks.json 없음"
fi

echo ""
echo "=== Codex active hooks 검사 ==="

# Codex 0.124+ stable hook host-state 검사:
#   1) ~/.codex/config.toml의 [[hooks.UserPromptSubmit]]에 expected managed command가 포함되어 있는지.
#      sync-codex-config.py는 같은 event의 사용자 추가 entry를 보존하지 않으므로 사용자 hook 추가는
#      template 미선언 event로 등록하는 것이 보존된다. 본 검사는 managed entry 존재만 확인한다.
#   2) ~/.codex/config.toml의 [[hooks.Stop]]는 정확히 single managed dispatcher entry — Codex가
#      same-event multiple command를 concurrent 실행하므로 ordering 보장을 dispatcher에 위임한다.
#   3) ~/.codex/config.toml의 [[hooks.PostToolUse]]에 expected pinning-alert managed command가 포함되어 있는지.
#      issue #603에서 PostToolUse도 template-owned event로 전환되었다 (warn-only pinning alert).
#   4) UserPromptSubmit / Stop / PostToolUse expected command가 가리키는 hook + dispatcher 사본 + 3 sub-script + pinning-alert 실재
#   5) tests/test-codex-hook-fixtures.sh deterministic 모드 통과 (live fixture 미실행)
# fail() 한 건이라도 발생하면 errors++ → exit 1 (FAIL gate).

_active_hooks_runner="$REPO_ROOT/tests/test-codex-hook-fixtures.sh"
# Hook contract expectation oracle: tests/lib/codex-hook-expectations.sh가 단일 정의 위치.
# shellcheck source=../../tests/lib/codex-hook-expectations.sh
. "$REPO_ROOT/tests/lib/codex-hook-expectations.sh"

if [ ! -f "$CODEX_CONFIG" ]; then
  fail "$CODEX_CONFIG 없음 — active hooks 검사 불가"
elif ! _toml_inspect --what=parse "$CODEX_CONFIG"; then
  # tomllib hard-exit 대신 soft-fail로 wrap. 다른 검사 섹션과 동일 accumulate 패턴 유지
  # (errors++ → 최종 summary에서 한꺼번에 보고).
  fail "$CODEX_CONFIG TOML 파싱 실패 — active hooks 구조 검사 skip"
else
  # tomllib로 hooks 구조 파싱 (bootstrap에서 python3 ≥ 3.11 보장).
  # parse는 위에서 이미 성공 확인했으므로 여기서 traceback이 나오면 race(파일 교체) 외 케이스는 없다.
  # UserPromptSubmit은 expected managed command가 포함되었는지만 검증 (사용자 추가 entry 허용).
  # Stop은 정확히 single managed dispatcher entry 강제 (concurrent 회피 contract).
  _hooks_dump=""
  if ! _hooks_dump="$(python3 - "$CODEX_CONFIG" "$EXPECTED_USER_PROMPT_COMMAND" "$EXPECTED_STOP_DISPATCHER_COMMAND" "$EXPECTED_POST_TOOL_USE_PINNING_COMMAND" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
expected_ups = sys.argv[2]
expected_stop = sys.argv[3]
expected_post = sys.argv[4]
hooks = data.get("hooks", {})
ups = hooks.get("UserPromptSubmit", []) or []
stop = hooks.get("Stop", []) or []
post = hooks.get("PostToolUse", []) or []

ups_managed = any(
    h.get("command") == expected_ups
    for entry in ups
    for h in (entry.get("hooks", []) or [])
)
print(f"UPS_TOTAL_COUNT {len(ups)}")
print(f"UPS_HAS_MANAGED {'1' if ups_managed else '0'}")

print(f"STOP_COUNT {len(stop)}")
if len(stop) == 1:
    sub = stop[0].get("hooks", []) or []
    print(f"STOP_INNER_COUNT {len(sub)}")
    if sub:
        print(f"STOP_COMMAND {sub[0].get('command', '')}")

post_managed = any(
    h.get("command") == expected_post
    for entry in post
    for h in (entry.get("hooks", []) or [])
)
print(f"POST_TOTAL_COUNT {len(post)}")
print(f"POST_HAS_MANAGED {'1' if post_managed else '0'}")
PY
  )"; then
    fail "$CODEX_CONFIG hooks 구조 파싱 실패 (race 또는 invariant 위반)"
  else
    _ups_total_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="UPS_TOTAL_COUNT"{print $2}')"
    _ups_has_managed="$(printf '%s\n' "$_hooks_dump" | awk '$1=="UPS_HAS_MANAGED"{print $2}')"
    _stop_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="STOP_COUNT"{print $2}')"
    _stop_inner_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="STOP_INNER_COUNT"{print $2}')"
    _stop_command="$(printf '%s\n' "$_hooks_dump" | sed -n 's/^STOP_COMMAND //p')"
    _post_total_count="$(printf '%s\n' "$_hooks_dump" | awk '$1=="POST_TOTAL_COUNT"{print $2}')"
    _post_has_managed="$(printf '%s\n' "$_hooks_dump" | awk '$1=="POST_HAS_MANAGED"{print $2}')"

    if [ "${_ups_total_count:-0}" -ge 1 ] 2>/dev/null; then
      pass "[[hooks.UserPromptSubmit]] entry 존재 (count=$_ups_total_count)"
    else
      fail "[[hooks.UserPromptSubmit]] entry 부재 (count=${_ups_total_count:-?})"
    fi

    if [ "$_ups_has_managed" = "1" ]; then
      pass "UserPromptSubmit에 expected managed command 포함: $EXPECTED_USER_PROMPT_COMMAND"
    else
      fail "UserPromptSubmit에 expected managed command 없음 (expected='$EXPECTED_USER_PROMPT_COMMAND')"
    fi

    # Stop은 dispatcher 단일 entry contract — concurrent 실행 회피.
    # 사용자 추가 hook은 template 미선언 event(예: PreToolUse, SessionStart)에 등록할 때만
    # sync-codex-config.py가 보존한다. Stop dispatcher 경유 sub-script 추가는 _stop-dispatcher.sh가
    # tracked 파일이라 user-config로 지원되지 않는다 (config.toml 주석 참조).
    if [ "${_stop_count:-0}" = "1" ] && [ "${_stop_inner_count:-0}" = "1" ]; then
      pass "[[hooks.Stop]] single managed dispatcher entry (concurrent 회피)"
    else
      fail "[[hooks.Stop]]은 정확히 single dispatcher entry여야 함 (outer=${_stop_count:-?} inner=${_stop_inner_count:-?})"
    fi

    if [ "$_stop_command" = "$EXPECTED_STOP_DISPATCHER_COMMAND" ]; then
      pass "Stop dispatcher command = $EXPECTED_STOP_DISPATCHER_COMMAND"
    else
      fail "Stop dispatcher command 불일치 (actual='$_stop_command' expected='$EXPECTED_STOP_DISPATCHER_COMMAND')"
    fi

    # PostToolUse는 issue #603에서 template-owned로 등록 — pinning-alert managed entry 포함 여부 검사.
    # 사용자 추가 entry는 sync-codex-config.py 정책상 보존되지 않지만, 본 검사는 managed entry 존재만 확인.
    if [ "${_post_total_count:-0}" -ge 1 ] 2>/dev/null; then
      pass "[[hooks.PostToolUse]] entry 존재 (count=$_post_total_count)"
    else
      fail "[[hooks.PostToolUse]] entry 부재 (count=${_post_total_count:-?})"
    fi

    if [ "$_post_has_managed" = "1" ]; then
      pass "PostToolUse에 expected managed command 포함: $EXPECTED_POST_TOOL_USE_PINNING_COMMAND"
    else
      fail "PostToolUse에 expected managed command 없음 (expected='$EXPECTED_POST_TOOL_USE_PINNING_COMMAND')"
    fi
  fi
fi

# command resolution: $HOME 확장 후 hook 사본이 실재 + executable + canonical target이
# 어떤 nixos-config checkout의 modules/shared/programs/codex/files/hooks/<name>인지 검증.
# worktree 환경에서는 activation이 mkOutOfStoreSymlink target을 main checkout(nixosConfigPath)으로
# 두지만 verifier는 worktree REPO_ROOT에서 실행되므로 두 경로가 다를 수 있다. 따라서 path suffix
# 매칭(.../modules/shared/programs/codex/files/hooks/<name>)과 readlink target 실재만 검사하여
# main checkout / worktree 양쪽에서 false fail이 나지 않도록 한다.
_check_hook_executable() {
  local relpath="$1" abspath="$HOME/$1" hook_name
  hook_name="$(basename "$relpath")"
  local expected_suffix="modules/shared/programs/codex/files/hooks/$hook_name"
  if [ ! -e "$abspath" ]; then
    fail "hook 사본 없음: $abspath"
    return
  fi
  if [ ! -x "$abspath" ]; then
    fail "hook 실행 권한 없음: $abspath"
    return
  fi
  local resolved
  resolved="$(readlink -f "$abspath" 2>/dev/null || true)"
  if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    fail "hook 사본 readlink 실패 또는 target 부재: $relpath (resolved=$resolved)"
    return
  fi
  case "$resolved" in
    */"$expected_suffix")
      pass "hook 사본 OK: $relpath"
      ;;
    *)
      fail "hook 사본 대상 path suffix 불일치: $relpath (resolved=$resolved expected_suffix=*/$expected_suffix)"
      ;;
  esac
}

_check_hook_executable ".codex/hooks/record-prompt-submit.sh"
_check_hook_executable ".codex/hooks/_stop-dispatcher.sh"
for _sub in "${EXPECTED_DISPATCHER_SUB_SCRIPTS[@]}"; do
  _check_hook_executable ".codex/hooks/$_sub"
done
_check_hook_executable ".codex/hooks/pinning-alert.sh"

# Pinning patterns lockstep 검사 (issue #603 R2 Maintainability-1):
#   scripts/ai/commit-msg-pinning.sh를 SSOT로 두고 신규 PostToolUse hook 두 개가 PATTERN_A/B/C/D
#   + HASH_MIN/MAX를 inline 사본으로 들고 있다. drift 자동 감지 자동화 없음을 운영 검증으로
#   대체한다는 정책이지만, 최소한 수동 갱신 누락을 verifier가 잡아내야 한다.
echo ""
echo "=== Pinning patterns SSOT lockstep 검사 ==="
_pinning_ssot="$REPO_ROOT/scripts/ai/commit-msg-pinning.sh"
_pinning_hooks=(
  "$REPO_ROOT/modules/shared/programs/claude/files/hooks/pinning-alert.sh"
  "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-alert.sh"
)
for _var in PATTERN_A PATTERN_B PATTERN_C PATTERN_D HASH_MIN HASH_MAX; do
  # `set -euo pipefail` 아래에서 grep 매치 실패 시 nonzero가 command substitution을
  # 통해 부모 shell을 종료시켜 drift 보고 자체가 막히므로 `|| true`로 무력화한다.
  _ssot_line="$(grep -m1 -E "^${_var}=" "$_pinning_ssot" || true)"
  if [ -z "$_ssot_line" ]; then
    fail "SSOT $_var 정의 부재 (scripts/ai/commit-msg-pinning.sh)"
    continue
  fi
  for _hook in "${_pinning_hooks[@]}"; do
    _hook_basename="${_hook#"$REPO_ROOT"/}"
    _hook_line="$(grep -m1 -E "^${_var}=" "$_hook" || true)"
    if [ "$_hook_line" = "$_ssot_line" ]; then
      pass "pinning $_var lockstep OK: $_hook_basename"
    else
      # fail()는 첫 인자만 출력하므로 SSOT/HOOK 세부 비교를 단일 형식 문자열로 결합한다.
      fail "$(printf 'pinning %s drift: %s\n    SSOT: %s\n    HOOK: %s' \
        "$_var" "$_hook_basename" "$_ssot_line" "${_hook_line:-<missing>}")"
    fi
  done
done

# fixture self-test (deterministic, live 미실행).
if [ ! -x "$_active_hooks_runner" ]; then
  fail "tests/test-codex-hook-fixtures.sh 실행 불가 (path=$_active_hooks_runner)"
else
  _runner_log="$(mktemp "${TMPDIR:-/tmp}/codex-hook-fixtures-runner.XXXXXX")"
  if "$_active_hooks_runner" --no-live >"$_runner_log" 2>&1; then
    pass "test-codex-hook-fixtures.sh deterministic 통과"
  else
    fail "test-codex-hook-fixtures.sh deterministic 실패 — 아래 로그 참조"
    sed 's/^/    /' "$_runner_log" >&2
  fi
  rm -f "$_runner_log"
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
