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
EXPECTED_BUNDLES = ("Correctness", "Design", "Regression", "Maintainability")


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
        r"^- .*?\((strong|standard) review profile\).*?"
        r'Codex:\s*`model="([^"]+)"`,\s*`reasoning_effort="([^"]+)"`',
        re.M,
    )
    for profile, model, effort in pattern.findall(read_text(RUNTIME_MAPPING)):
        profiles[profile] = {"model": model, "effort": effort}

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


def extract_command_profile(block: str, label: str) -> dict[str, str]:
    models = re.findall(r'-c\s+model="([^"]+)"', block)
    efforts = re.findall(r'-c\s+model_reasoning_effort="([^"]+)"', block)
    details = []
    if len(models) != 1:
        details.append(f"{label}: expected exactly one model literal, got {models}")
    if len(efforts) != 1:
        details.append(f"{label}: expected exactly one model_reasoning_effort literal, got {efforts}")
    if details:
        raise CheckFailure("\n".join(details))
    return {"model": models[0], "effort": efforts[0]}


def check_profile_literals() -> None:
    runtime_profiles = extract_runtime_profiles()
    arbiter_text = read_text(ARBITER_SCALING)
    command_profiles = {
        "standard": extract_command_profile(
            fenced_block_after(arbiter_text, "reviewer / Auditor (standard profile)"),
            "reviewer / Auditor (standard profile)",
        ),
        "strong": extract_command_profile(
            fenced_block_after(arbiter_text, "Arbiter (strong profile)"),
            "Arbiter (strong profile)",
        ),
    }

    if runtime_profiles != command_profiles:
        details = ["review profile literal mismatch:"]
        for profile in sorted(EXPECTED_PROFILES):
            details.append(
                f"  {profile}: {RUNTIME_MAPPING}={runtime_profiles[profile]}, "
                f"{ARBITER_SCALING}={command_profiles[profile]}"
            )
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


def main() -> int:
    checks = (
        ("intensity rules", check_intensity_rules),
        ("kappa constants", check_kappa_constants),
        ("review profile literals", check_profile_literals),
        ("reviewer bundle subdomains", check_bundle_subdomains),
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
