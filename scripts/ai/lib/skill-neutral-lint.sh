#!/usr/bin/env bash
# scripts/ai/lib/skill-neutral-lint.sh
#
# verify-ai-compat.sh의 SKILL.md 도구-중립성 lint engine.
# source한 caller가 REPO_ROOT, SKILL_NEUTRAL_LINT_EXCLUDE, pass/fail/warn,
# errors/warnings 전역을 제공한다.

# shellcheck disable=SC2154

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
