#!/usr/bin/env python3
"""Check manual sync contracts across run-da skill docs."""

from __future__ import annotations

import importlib.util
import json
import re
import sys
from pathlib import Path


SKILL = Path("modules/shared/programs/claude/files/skills/run-da/SKILL.md")
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

EXPECTED_PROFILES = {"strong", "standard"}
EXPECTED_CAPABILITY_PROFILES = {"current", "unknown"}
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
ARBITER_PROMPT = _RUN_DA_DIR / "references/arbiter-prompt.md"
FORBIDDEN_MODEL_LITERALS = ("gpt-5", "opus", "sonnet")


class CheckFailure(Exception):
    """Raised when a sync contract is not satisfied."""


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except FileNotFoundError as exc:
        raise CheckFailure(f"missing file: {path}") from exc


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
    if "### 실행 경로·파라미터 지정" not in read_text(SKILL):
        details.append(f"{SKILL}: missing user exec params section")
    if "_DA_MODEL_TIER_OVERRIDES" not in read_text(RUNTIME_MAPPING):
        details.append(f"{RUNTIME_MAPPING}: missing _DA_MODEL_TIER_OVERRIDES in canonical command")
    if details:
        raise CheckFailure("\n".join(details))


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


def check_threat_path_types() -> None:
    """SECURITY threat path 유형 집합의 동기화를 검사한다.

    정의(이름+경로 조건)는 arbiter-prompt.md "SECURITY threat path" 절의 bullet이
    단독 소유하고, da-domains.md는 괄호 나열로 이름만 소비한다. 양쪽에서 유형
    집합을 파싱해 exact-set 비교하므로, 어느 쪽이든 유형을 추가·개명하고 다른
    쪽을 누락하면 실패한다 (고정 상수 목록을 두지 않는다 — 제3의 사본 방지).
    """
    arbiter_text = read_text(ARBITER_PROMPT)
    section_match = re.search(
        r"#### SECURITY threat path.*?(?=\n#{2,4} )", arbiter_text, re.DOTALL
    )
    if not section_match:
        raise CheckFailure(f"{ARBITER_PROMPT}: 'SECURITY threat path' 정의 섹션 누락")
    owner_types = set(
        re.findall(r"^- ([^:]+):", section_match.group(0), re.MULTILINE)
    )
    if not owner_types:
        raise CheckFailure(f"{ARBITER_PROMPT}: threat path bullet 유형을 파싱하지 못함")

    domains_text = read_text(DA_DOMAINS)
    consumer_match = re.search(
        r"취약점 유형별 threat path\(([^)]+)\)", domains_text
    )
    if not consumer_match:
        raise CheckFailure(f"{DA_DOMAINS}: threat path 유형 나열(괄호)을 찾지 못함")
    consumer_types = {part.strip() for part in consumer_match.group(1).split(",")}

    if owner_types != consumer_types:
        raise CheckFailure(
            "threat path 유형 집합 불일치:\n"
            f"  {ARBITER_PROMPT}: {sorted(owner_types)}\n"
            f"  {DA_DOMAINS}: {sorted(consumer_types)}"
        )


def check_verdict_json_examples() -> None:
    """arbiter-prompt.md의 VERDICT_JSON 골격 예시가 실제 검증기를 통과하는지 검사한다.

    schema 계약은 문서 예시(pseudo-JSON)·protocol 산문·validator 코드 세 곳에 손으로
    표현되어 왔고, 그래서 "골격대로 썼는데 semantic malformed로 거부"되는 드리프트가
    반복됐다. 이 검사는 문서 예시를 production 파서와 같은 delimiter 패턴으로 추출해
    `validate_verdict_entry()`에 직접 통과시키므로, 예시와 검증기가 어긋나면 실패한다
    (고정 기대값 목록을 두지 않는다 — 계약의 제3의 사본을 만들지 않기 위함).
    """
    spec = importlib.util.spec_from_file_location("_fleiss_kappa", FLEISS_KAPPA)
    if spec is None or spec.loader is None:
        raise CheckFailure(f"{FLEISS_KAPPA}: 검증기 모듈을 로드할 수 없음")
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)

    text = read_text(ARBITER_PROMPT)
    blocks = list(harness.VERDICT_JSON_PATTERN.finditer(text))
    if not blocks:
        raise CheckFailure(
            f"{ARBITER_PROMPT}: VERDICT_JSON 골격 예시를 찾지 못함 "
            "(delimiter 형식이 바뀌었거나 예시가 사라졌다)"
        )

    details = []
    seen_verdicts = set()
    for block in blocks:
        try:
            entry = json.loads(block.group("body"))
        except json.JSONDecodeError as exc:
            details.append(f"골격 예시가 유효한 JSON이 아님: {exc}")
            continue
        violations = harness.validate_verdict_entry(entry)
        if violations:
            details.append(
                f"골격 예시 {entry.get('finding_id')!r}가 검증기를 통과하지 못함: {violations}"
            )
        else:
            seen_verdicts.add(entry.get("verdict"))

    missing = set(harness.VERDICT_CATEGORIES) - seen_verdicts
    if missing:
        details.append(f"유효 골격 예시가 없는 verdict: {sorted(missing)}")
    if details:
        raise CheckFailure("\n".join(f"  {ARBITER_PROMPT}: {d}" for d in details))


def check_arbiter_assembly_includes_output_format() -> None:
    """Arbiter 조립 템플릿이 출력 형식 섹션을 포함하는지 텍스트 검사한다 (#1258).

    과거 조립 지시는 "공통 프롬프트 섹션"만 넣으라고 해서 VERDICT_JSON 스키마·delimiter가
    조립 범위 밖에 있었다 — Arbiter가 기계 파싱 계약을 모른 채 출력하는 조립 결함.
    for_pr/for_plan 두 조립 템플릿 모두 출력 형식 포함 지시와 manifest 완전성 지시를
    유지해야 한다.
    """
    text = read_text(ARBITER_PROMPT)
    assembly = re.search(r"## 프롬프트 조립.*", text, re.DOTALL)
    if not assembly:
        raise CheckFailure(f"{ARBITER_PROMPT}: '프롬프트 조립' 섹션 누락")
    body = assembly.group(0)
    details = []
    # 전역 카운트는 한 템플릿에 지시가 2회 있고 다른 템플릿에 0회여도 통과한다 —
    # 모드 섹션별로 분리해 각각 검사한다 (PR #1271 리뷰).
    sections = {}
    for mode in ("for_pr", "for_plan"):
        m = re.search(rf"### {mode} 모드.*?(?=\n### |\Z)", body, re.DOTALL)
        if not m:
            details.append(f"{ARBITER_PROMPT}: 조립 템플릿에 '### {mode} 모드' 섹션 누락")
        else:
            sections[mode] = m.group(0)
    for mode, sec in sections.items():
        if '"출력 형식" 섹션 전체' not in sec:
            details.append(
                f"{ARBITER_PROMPT}: {mode} 조립 템플릿에 '출력 형식' 섹션 포함 지시 누락"
            )
        if "누락도 추가도 금지" not in sec:
            details.append(
                f"{ARBITER_PROMPT}: {mode} 조립 템플릿에 finding manifest 완전성 지시 누락"
            )
    if details:
        raise CheckFailure("\n".join(details))


def check_rc_tail_contract() -> None:
    """rc 캡처·guard 계약의 사본 동등성 (#1259).

    정본(using-codex-exec)과 run-da의 reviewer tail·Arbiter 수집 블록은 각각
    self-contained 셸 조각이라 참조로 대체할 수 없다 — 대신 세 위치 모두에
    핵심 guard 시퀀스(배열 스냅샷 → rc·좌측 비어있음 guard → 좌측 실패 반영)가
    존재하는지 기계 검사해 침묵 drift를 차단한다.
    """
    targets = {
        Path("modules/shared/programs/claude/files/skills/using-codex-exec/SKILL.md"): 1,
        ARBITER_SCALING: 2,
    }
    required = [
        r'pipe_rcs=\("\$\{pipestatus\[@\]\}"\)',
        r'\[ -n "\$rc" \] && \[ -n "\$\{pipe_rcs\[1\]\}" \]',
        r'\[ "\$\{pipe_rcs\[1\]\}" = "0" \] \|\| rc="\$\{pipe_rcs\[1\]\}"',
    ]
    details = []
    for path, min_count in targets.items():
        text = read_text(path)
        for pattern in required:
            found = len(re.findall(pattern, text))
            if found < min_count:
                details.append(
                    f"{path}: rc tail 계약 요소 {pattern!r} {found}회 (최소 {min_count}회 필요)"
                )
    if details:
        raise CheckFailure("\n".join(details))


def check_capability_profile() -> None:
    """native lifecycle capability profile 계약 (#1098) — 구조 검사만 수행한다.

    1. runtime-mapping.md의 SSOT 절에 current/unknown 2-profile 표가 존재한다
       (legacy profile은 실사용 0건으로 제거 — #1257; 과거 lifecycle 표면은 unknown으로 분류).
    2. fixed-literal 재도입 금지: `agents.max_threads`와 고정 6이 한 줄에 결합된
       리터럴을 대상 문서 전체에서 차단한다 (#1098 verify 계약).
    3. close_agent를 언급하는 문서는 SSOT 앵커 포인터를 유지한다.

    자연어 의미 추정(무조건 close 표현 판정 등)은 하지 않는다 — 라운드마다 오탐과
    미탐 지적이 상충해 유지비만 커지므로 제거했다 (사용자 결정). close 계약의 의미
    정합은 SSOT 문서와 코드 리뷰가 담당한다.
    """
    mapping_text = read_text(RUNTIME_MAPPING)
    section = section_after_heading(mapping_text, "## Codex native lifecycle capability profile")
    # 표 첫 열의 모든 profile 토큰을 수집해 exact-set 비교한다 — 기대 이름만 캡처하면
    # 제거된 profile 행(legacy 등)이 재도입돼도 검출하지 못한다.
    profile_pattern = re.compile(r"^\|\s*`([a-z][a-z-]*)`\s*\|", re.M)
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
        ("review profile efforts", check_profile_efforts),
        ("codex command contract", check_codex_command_contract),
        ("user exec params", check_user_exec_params),
        ("exec override copies", check_exec_override_copies),
        ("no hardcoded model literals", check_no_hardcoded_model_literals),
        ("reviewer bundle subdomains", check_bundle_subdomains),
        ("threat path types", check_threat_path_types),
        ("verdict json examples", check_verdict_json_examples),
        ("arbiter assembly output format", check_arbiter_assembly_includes_output_format),
        ("rc tail contract", check_rc_tail_contract),
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
