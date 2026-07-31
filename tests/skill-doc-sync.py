#!/usr/bin/env python3
"""Check manual sync contracts across run-da skill docs."""

from __future__ import annotations

import re
import sys
from pathlib import Path


SKILL = Path("modules/shared/programs/claude/files/skills/run-da/SKILL.md")
INTENSITY_RULES = Path(
    "modules/shared/programs/claude/files/skills/run-da/references/intensity-rules.md"
)
STABILITY = Path(
    "modules/shared/programs/claude/files/skills/run-da/references/stability-measurement.md"
)
FLEISS_KAPPA = Path("modules/shared/programs/claude/files/scripts/fleiss-kappa.py")
RUNTIME_MAPPING = Path(
    "modules/shared/programs/claude/files/skills/run-da/references/runtime-mapping.md"
)
ARBITER_SCALING = Path(
    "modules/shared/programs/claude/files/skills/run-da/references/arbiter-scaling.md"
)
DA_DOMAINS = Path(
    "modules/shared/programs/claude/files/skills/run-da/references/da-domains.md"
)

EXPECTED_RULE_IDS = {
    "RULE-MAX-MODIFIER",
    "RULE-SECURITY",
    "RULE-MODULE-SERVICE",
    "RULE-CONFIG-DEPENDENCY",
    "RULE-SMALL-FUNCTION",
    "RULE-PURE-DOC",
    "RULE-MIXED",
    "RULE-UNCLEAR",
}
EXPECTED_CONSTANTS = {"STABLE_MIN", "ESCALATE_MIN"}
EXPECTED_PROFILES = {"strong", "standard"}
EXPECTED_CAPABILITY_PROFILES = {"current", "legacy", "unknown"}
_RUN_DA_DIR = Path("modules/shared/programs/claude/files/skills/run-da")
# capability profile 계약 (#1098) 대상 문서: unqualified close_agent / fixed
# `agents.max_threads` 6 literal 재도입을 차단하는 스캔 범위.
CAPABILITY_CONTRACT_DOCS = (
    Path("AGENTS.override.md"),
    SKILL,
    RUNTIME_MAPPING,
    ARBITER_SCALING,
    _RUN_DA_DIR / "modes/audit.md",
    _RUN_DA_DIR / "modes/for_plan.md",
    _RUN_DA_DIR / "modes/for_pr.md",
    _RUN_DA_DIR / "references/hardening-contract.md",
    _RUN_DA_DIR / "references/main-agent-obligations.md",
    Path(
        "modules/shared/programs/claude/files/skills/using-codex-exec/references/known-issues.md"
    ),
)
EXPECTED_BUNDLES = ("Correctness", "Design", "Regression", "Maintainability")
EXPECTED_AGENT_ARGS = {"agent=codex-xhigh", "agent=codex-high", "agent=codex-medium", "agent=claude"}
FORBIDDEN_MODEL_LITERALS = ("gpt-5", "opus", "sonnet")


class CheckFailure(Exception):
    """Raised when a sync contract is not satisfied."""


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError as exc:
        raise CheckFailure(f"missing file: {path}") from exc


def extract_intensity_rules(path: Path) -> dict[str, tuple[str, str]]:
    out = {}
    for line in read_text(path).splitlines():
        match = re.match(r"\|\s*`(RULE-[A-Z-]+)`\s*\|(.+)\|(.+)\|", line)
        if match:
            out[match.group(1)] = (match.group(2).strip(), match.group(3).strip())
    return out


def format_rule(rule_id: str, value: tuple[str, str] | None) -> str:
    if value is None:
        return "<missing>"
    condition, stage = value
    return f"condition={condition!r}, stage={stage!r}"


def check_intensity_rules() -> None:
    skill_rules = extract_intensity_rules(SKILL)
    reference_rules = extract_intensity_rules(INTENSITY_RULES)

    details = []
    for label, rules in ((str(SKILL), skill_rules), (str(INTENSITY_RULES), reference_rules)):
        rule_ids = set(rules)
        if rule_ids != EXPECTED_RULE_IDS:
            details.append(
                f"{label}: expected rule IDs {sorted(EXPECTED_RULE_IDS)}, got {sorted(rule_ids)}"
            )

    for rule_id in sorted(EXPECTED_RULE_IDS):
        skill_value = skill_rules.get(rule_id)
        reference_value = reference_rules.get(rule_id)
        if skill_value != reference_value:
            details.append(
                "\n".join(
                    [
                        f"{rule_id} mismatch:",
                        f"  {SKILL}: {format_rule(rule_id, skill_value)}",
                        f"  {INTENSITY_RULES}: {format_rule(rule_id, reference_value)}",
                    ]
                )
            )

    if details:
        raise CheckFailure("\n".join(details))


def extract_constant_values(path: Path, pattern: str, flags: int = 0) -> dict[str, str]:
    values = {}
    for name, value in re.findall(pattern, read_text(path), flags):
        values[name] = value
    found = set(values)
    if found != EXPECTED_CONSTANTS:
        raise CheckFailure(
            f"{path}: expected constants {sorted(EXPECTED_CONSTANTS)}, got {sorted(found)}"
        )
    return values


def check_kappa_constants() -> None:
    doc_values = extract_constant_values(
        STABILITY, r"`(STABLE_MIN|ESCALATE_MIN)\s*=\s*([0-9.]+)`"
    )
    script_values = extract_constant_values(
        FLEISS_KAPPA, r"^(STABLE_MIN|ESCALATE_MIN)\s*=\s*([0-9.]+)", re.M
    )
    if doc_values != script_values:
        details = ["kappa threshold mismatch:"]
        for name in sorted(EXPECTED_CONSTANTS):
            details.append(f"  {name}: {STABILITY}={doc_values[name]!r}, {FLEISS_KAPPA}={script_values[name]!r}")
        raise CheckFailure("\n".join(details))


def extract_runtime_profiles() -> dict[str, dict[str, str]]:
    profiles = {}
    pattern = re.compile(
        r"^\|\s*`(strong|standard)`\s*\|[^|]+\|[^|]+\|\s*`(medium|high|xhigh)`\s*\|",
        re.M,
    )
    for profile, effort in pattern.findall(read_text(RUNTIME_MAPPING)):
        profiles[profile] = {"effort": effort}

    found = set(profiles)
    if found != EXPECTED_PROFILES:
        raise CheckFailure(
            f"{RUNTIME_MAPPING}: expected profiles {sorted(EXPECTED_PROFILES)}, got {sorted(found)}"
        )
    return profiles


def fenced_block_after(text: str, label: str) -> str:
    pattern = re.compile(rf"^{re.escape(label)}:\s*\n\s*```[^\n]*\n(.*?)\n```", re.M | re.S)
    match = pattern.search(text)
    if not match:
        raise CheckFailure(f"{ARBITER_SCALING}: missing fenced block after '{label}:'")
    return match.group(1)


def extract_arbiter_profile_efforts() -> dict[str, dict[str, str]]:
    profiles = {}
    pattern = re.compile(r"^\|\s*`(standard|strong)`\s*\|\s*`(medium|high|xhigh)`\s*\|", re.M)
    for profile, effort in pattern.findall(read_text(ARBITER_SCALING)):
        profiles[profile] = {"effort": effort}

    found = set(profiles)
    if found != EXPECTED_PROFILES:
        raise CheckFailure(
            f"{ARBITER_SCALING}: expected profiles {sorted(EXPECTED_PROFILES)}, got {sorted(found)}"
        )
    return profiles


def check_profile_efforts() -> None:
    runtime_profiles = extract_runtime_profiles()
    arbiter_profiles = extract_arbiter_profile_efforts()

    if runtime_profiles != arbiter_profiles:
        details = ["review profile effort mismatch:"]
        for profile in sorted(EXPECTED_PROFILES):
            details.append(
                f"  {profile}: {RUNTIME_MAPPING}={runtime_profiles[profile]}, "
                f"{ARBITER_SCALING}={arbiter_profiles[profile]}"
            )
        raise CheckFailure("\n".join(details))


def check_codex_command_contract() -> None:
    arbiter_text = read_text(ARBITER_SCALING)
    details = []
    for label in ("reviewer / Auditor (standard profile)", "Arbiter (strong profile)"):
        block = fenced_block_after(arbiter_text, label)
        if "-c model=" in block:
            details.append(f"{label}: command block must not pin a model literal")
        if '-c model_reasoning_effort="$RUN_DA_CODEX_EFFORT"' not in block:
            details.append(f"{label}: missing RUN_DA_CODEX_EFFORT effort pin")
        if 'RUN_DA_CODEX_EFFORT:?missing RUN_DA_CODEX_EFFORT' not in block:
            details.append(f"{label}: missing RUN_DA_CODEX_EFFORT guard")
        if '"${_DA_MODEL_TIER_OVERRIDES[@]}"' not in block:
            details.append(f"{label}: missing _DA_MODEL_TIER_OVERRIDES injection point")
        if "RUN_DA_USER_EFFORT_OVERRIDE" not in block:
            details.append(f"{label}: missing RUN_DA_USER_EFFORT_OVERRIDE gate for non-default effort")

    if details:
        raise CheckFailure("\n".join(details))


USER_EXEC_ENV_VARS = ("RUN_DA_CODEX_MODEL", "RUN_DA_CODEX_TIER", "RUN_DA_USER_EFFORT_OVERRIDE")

# Canonical override assembly loop (normalized): all three role command blocks in
# arbiter-scaling.md must carry this exact loop so no default/literal model can slip
# into the indirect `-c "$_kv"` injection path.
EXPECTED_OVERRIDE_LOOP = (
    '_DA_MODEL_TIER_OVERRIDES=() '
    'for _kv in "model=${RUN_DA_CODEX_MODEL:-}" "service_tier=${RUN_DA_CODEX_TIER:-}"; do '
    'case "${_kv#*=}" in '
    '"") ;; '
    '*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-]*) '
    'echo "invalid $_kv"; exit 1 ;; '
    '*) _DA_MODEL_TIER_OVERRIDES+=(-c "$_kv") ;; '
    'esac '
    'done'
)
EXEC_OVERRIDE_COPIES = 3


def _normalize_fragment(text: str) -> str:
    text = text.replace("ARBITER_FAILED: ", "")
    return re.sub(r"\s+", " ", text).strip()


def check_exec_override_copies() -> None:
    details = []
    text = read_text(ARBITER_SCALING)
    loops = re.findall(r"_DA_MODEL_TIER_OVERRIDES=\(\)\nfor _kv in .*?\ndone", text, re.S)
    if len(loops) != EXEC_OVERRIDE_COPIES:
        details.append(
            f"{ARBITER_SCALING}: expected {EXEC_OVERRIDE_COPIES} override assembly loops, got {len(loops)}"
        )
    for i, loop in enumerate(loops, 1):
        if _normalize_fragment(loop) != EXPECTED_OVERRIDE_LOOP:
            details.append(f"{ARBITER_SCALING}: override assembly loop #{i} deviates from canonical form")
    guards = re.findall(r'case "\$RUN_DA_CODEX_EFFORT" in.*?esac', text, re.S)
    if len(guards) != EXEC_OVERRIDE_COPIES:
        details.append(
            f"{ARBITER_SCALING}: expected {EXEC_OVERRIDE_COPIES} effort guards, got {len(guards)}"
        )
    for i, guard in enumerate(guards, 1):
        if "RUN_DA_USER_EFFORT_OVERRIDE" not in guard:
            details.append(f"{ARBITER_SCALING}: effort guard #{i} missing RUN_DA_USER_EFFORT_OVERRIDE gate")
    if len({_normalize_fragment(g) for g in guards}) > 1:
        details.append(f"{ARBITER_SCALING}: effort guards diverge across role command blocks")
    injections = re.findall(
        r'-c model_reasoning_effort="\$RUN_DA_CODEX_EFFORT" "\$\{_DA_MODEL_TIER_OVERRIDES\[@\]\}"',
        text,
    )
    if len(injections) != EXEC_OVERRIDE_COPIES:
        details.append(
            f"{ARBITER_SCALING}: expected {EXEC_OVERRIDE_COPIES} override injection points "
            f"on codex command lines, got {len(injections)}"
        )
    if details:
        raise CheckFailure("\n".join(details))


def check_user_exec_params() -> None:
    details = []
    arbiter_text = read_text(ARBITER_SCALING)
    for var in USER_EXEC_ENV_VARS:
        if var not in arbiter_text:
            details.append(f"{ARBITER_SCALING}: missing user exec env {var}")
    if "## 사용자 지정 실행 파라미터" not in arbiter_text:
        details.append(f"{ARBITER_SCALING}: missing user exec params section")
    if "### 사용자 지정 실행 파라미터" not in read_text(SKILL):
        details.append(f"{SKILL}: missing user exec params section")
    if "_DA_MODEL_TIER_OVERRIDES" not in read_text(RUNTIME_MAPPING):
        details.append(f"{RUNTIME_MAPPING}: missing _DA_MODEL_TIER_OVERRIDES in canonical command")
    if details:
        raise CheckFailure("\n".join(details))


def extract_agent_args(path: Path) -> set[str]:
    values = set(re.findall(r"`(agent=(?:codex-xhigh|codex-high|codex-medium|claude))`", read_text(path)))
    if values != EXPECTED_AGENT_ARGS:
        raise CheckFailure(f"{path}: expected agent args {sorted(EXPECTED_AGENT_ARGS)}, got {sorted(values)}")
    return values


def check_agent_args() -> None:
    extract_agent_args(SKILL)
    extract_agent_args(RUNTIME_MAPPING)


def check_no_hardcoded_model_literals() -> None:
    root = Path("modules/shared/programs/claude/files/skills/run-da")
    details = []
    for path in sorted(root.rglob("*.md")):
        text = read_text(path)
        for literal in FORBIDDEN_MODEL_LITERALS:
            if literal in text:
                details.append(f"{path}: forbidden model literal {literal!r}")
    if details:
        raise CheckFailure("\n".join(details))


def section_after_heading(text: str, heading: str) -> str:
    pattern = re.compile(rf"^{re.escape(heading)}\s*$", re.M)
    match = pattern.search(text)
    if not match:
        raise CheckFailure(f"missing heading: {heading}")
    start = match.end()
    next_heading = re.search(r"^##\s+", text[start:], re.M)
    end = start + next_heading.start() if next_heading else len(text)
    return text[start:end]


def markdown_cells(line: str) -> list[str]:
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


def normalize_subdomains(cell: str) -> set[str]:
    cleaned = cell.replace("`", "")
    return {part.strip() for part in re.split(r"\s*(?:\+|,)\s*", cleaned) if part.strip()}


def extract_bundle_subdomains(path: Path, section_heading: str) -> dict[str, set[str]]:
    table_section = section_after_heading(read_text(path), section_heading)
    bundles = {}
    for line in table_section.splitlines():
        if not line.startswith("|"):
            continue
        cells = markdown_cells(line)
        if len(cells) < 2:
            continue
        bundle, subdomains = cells[0], cells[1]
        if bundle in EXPECTED_BUNDLES:
            bundles[bundle] = normalize_subdomains(subdomains)

    found = set(bundles)
    expected = set(EXPECTED_BUNDLES)
    if found != expected:
        raise CheckFailure(f"{path}: expected bundles {sorted(expected)}, got {sorted(found)}")
    return bundles


def check_bundle_subdomains() -> None:
    skill_bundles = extract_bundle_subdomains(SKILL, "## DA reviewer bundles")
    reference_bundles = extract_bundle_subdomains(DA_DOMAINS, "## 기본 reviewer bundle 정의")

    if skill_bundles != reference_bundles:
        details = ["reviewer bundle subdomain mismatch:"]
        for bundle in EXPECTED_BUNDLES:
            if skill_bundles[bundle] != reference_bundles[bundle]:
                details.append(
                    f"  {bundle}: {SKILL}={sorted(skill_bundles[bundle])}, "
                    f"{DA_DOMAINS}={sorted(reference_bundles[bundle])}"
                )
        raise CheckFailure("\n".join(details))


def check_capability_profile() -> None:
    """native lifecycle capability profile 계약 (#1098) — 구조 검사만 수행한다.

    1. runtime-mapping.md의 SSOT 절에 current/legacy/unknown 3-profile 표가 존재한다.
    2. fixed-literal 재도입 금지: `agents.max_threads`와 고정 6이 한 줄에 결합된
       리터럴을 대상 문서 전체에서 차단한다 (#1098 verify 계약).
    3. close_agent를 언급하는 문서는 SSOT 앵커 포인터를 유지한다.

    자연어 의미 추정(무조건 close 표현 판정 등)은 하지 않는다 — 라운드마다 오탐과
    미탐 지적이 상충해 유지비만 커지므로 제거했다 (사용자 결정). close 계약의 의미
    정합은 SSOT 문서와 코드 리뷰가 담당한다.
    """
    mapping_text = read_text(RUNTIME_MAPPING)
    section = section_after_heading(mapping_text, "## Codex native lifecycle capability profile")
    profile_pattern = re.compile(
        r"^\|\s*`(" + "|".join(sorted(EXPECTED_CAPABILITY_PROFILES)) + r")`\s*\|", re.M
    )
    found_profiles = set(profile_pattern.findall(section))
    if found_profiles != EXPECTED_CAPABILITY_PROFILES:
        raise CheckFailure(
            f"{RUNTIME_MAPPING}: expected capability profiles "
            f"{sorted(EXPECTED_CAPABILITY_PROFILES)}, got {sorted(found_profiles)}"
        )

    details = []
    for path in CAPABILITY_CONTRACT_DOCS:
        text = read_text(path)
        for lineno, line in enumerate(text.splitlines(), start=1):
            if re.search(r"agents\.max_threads.*6", line):
                details.append(f"{path}:{lineno}: fixed `agents.max_threads` 6 literal 재도입")
        if "close_agent" in text and path != RUNTIME_MAPPING:
            if "codex-native-lifecycle-capability-profile" not in text and (
                "Codex native lifecycle capability profile" not in text
            ):
                details.append(f"{path}: close_agent 언급하지만 capability profile SSOT 포인터 없음")
    if details:
        raise CheckFailure("\n".join(details))


def main() -> int:
    checks = (
        ("intensity rules", check_intensity_rules),
        ("kappa constants", check_kappa_constants),
        ("review profile efforts", check_profile_efforts),
        ("codex command contract", check_codex_command_contract),
        ("user exec params", check_user_exec_params),
        ("exec override copies", check_exec_override_copies),
        ("agent args", check_agent_args),
        ("no hardcoded model literals", check_no_hardcoded_model_literals),
        ("reviewer bundle subdomains", check_bundle_subdomains),
        ("capability profile", check_capability_profile),
    )

    passed = 0
    for name, check in checks:
        try:
            check()
        except CheckFailure as exc:
            print(f"FAIL {name}:")
            print(exc)
        else:
            passed += 1
            print(f"PASS {name}")

    if passed == len(checks):
        print(f"OK: {passed}/{len(checks)} pairs in sync")
        return 0

    print(f"FAIL: {passed}/{len(checks)} pairs in sync")
    return 1


if __name__ == "__main__":
    sys.exit(main())
