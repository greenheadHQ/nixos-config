#!/usr/bin/env python3
"""Run-DA VERDICT_JSON validator.

VERDICT_JSON 계약 검증 (`validate_verdict_entry` + `--validate-only`) —
protocol.md "수렴 판정" caller 검증의 기계 검증 SSOT. Arbiter 결과 수집이 소비한다.

파일명은 초기 Fleiss kappa 집계 용도에서 유래했다. selective consistency(N=3
vote-shape·stability_status·kappa 집계)는 실사용 0건으로 제거됐고(#1257) 이 파일은
검증기 책임만 남았다 — 세션 scope에 단일 파일로 프로비저닝되는 계약이라 경로·이름은
유지한다 (개명하면 배포 체인과 HELPER_PATH 계약이 함께 움직여야 한다).

두 검증 모드가 있다 — 산출 주체별 분리 (#1259):
  --validate-only     Arbiter 결과 (VERDICT_JSON blocks, schema_version은
                      LIVE_SCHEMA_VERSION과 정확히 일치. arbiter-prompt.md "출력 형식")
  --validate-reviewer reviewer 결과 (da-domains.md "출력 형식" — CLEAR/VIOLATION/발견)

Usage:
    # Arbiter caller 검증 (파일별 schema/manifest 검사 결과 JSON,
    # 전체 통과 시 exit 0 / 위반 시 exit 1)
    fleiss-kappa.py --validate-only --expect-findings <ID,ID,...> <result.md>

    # reviewer 결과 검증 (#1259 — 산출 주체 분리: CLEAR/VIOLATION/발견 판별,
    # 건수 대조, 필수 라벨·ID 문법·placeholder·절단 판정)
    fleiss-kappa.py --validate-reviewer <unit-result.md>...

`--expect-findings`는 --validate-only에서 필수 인자다 — 생략은 검증 없음이 아니라 인자
오류다. manifest 없는 수집이 성공으로 처리되면 finding 누락이 그대로 소비되어 조기 수렴으로
샌다. --validate-reviewer는 manifest 없이 파일별 독립 검증한다.

Output: JSON on stdout. See main() for schema.
"""

import argparse
import json
import re
import sys
from pathlib import Path

VERDICT_CATEGORIES = ("CONFIRMED_ISSUE", "NOT_AN_ISSUE", "NEEDS_MORE_INFO")
CONFIDENCE_VALUES = ("HIGH", "MEDIUM", "LOW", "N/A")

# 현재 live schema의 semantic 계약 (protocol.md "수렴 판정" caller 검증 SSOT와 동기화)
SEVERITY_VALUES = ("CRITICAL", "HIGH", "MEDIUM", "LOW")
PLAUSIBILITY_VALUES = ("PASS", "FAIL", "UNKNOWN", "N/A")
PORTABILITY_VALUES = ("PASS", "FAIL", "N/A")
REJECTION_BASES = ("FACTUAL_FAIL", "RELEVANCE_FAIL", "PLAUSIBILITY_FAIL")
# 확정된 문제의 해소 방식 분류 (protocol.md "remediation scope" SSOT):
# FIX_NOW = changeset 범위 국소 수정 → write queue. REPLAN_REQUIRED = 구조 재설계 필요 →
# 루프 밖 배출(이슈 증거 필수). UNCLEAR = 판단 불가 → 사용자 판단 (headless는 미해결 처리).
REMEDIATION_SCOPES = ("FIX_NOW", "REPLAN_REQUIRED", "UNCLEAR")
# PLAUSIBILITY_FAIL 기각 근거의 수명주기 분류 (run-da/SKILL.md "세션 내 기각 이력" SSOT):
# FROZEN_SURFACE = frozen changeset의 불변 계약 근거 → 동일 changeset 내 suppress eligible
# ENVIRONMENT_WORKLOAD = 환경·워크로드 가정 근거 → suppress 비대상. 그 라운드의 판정으로
#   끝나고 다음 라운드에 같은 finding이 올라오면 다시 판정한다.
EVIDENCE_SCOPES = ("FROZEN_SURFACE", "ENVIRONMENT_WORKLOAD")
# verdict -> 허용되는 axes.plausibility 값 (정합 행렬)
PLAUSIBILITY_MATRIX = {
    "CONFIRMED_ISSUE": {"PASS"},
    "NOT_AN_ISSUE": {"FAIL", "N/A"},
    "NEEDS_MORE_INFO": {"PASS", "UNKNOWN"},
}
LIVE_SCHEMA_VERSION = "1.2"  # 실시간 결과는 정확히 이 버전 (새 계약 도입 시 검증기와 함께 갱신)


def validate_verdict_entry(entry):
    """현재 live schema 계약 위반 목록을 반환하는 단일 검증 진입점 (빈 리스트 = 통과).

    protocol.md "수렴 판정" caller 검증의 기계 검증 SSOT 구현체 —
    version·필수 필드·모든 enum·verdict 정합 행렬을 이 함수 하나가 검사한다.
    finding_id의 존재·중복 검사는 parser(load_validated_verdict_entries) 소관이고,
    reviewer 원본 finding과의 대조(reviewer_severity 은닉 차단)는 원본을 아는
    caller 몫이며, finding ID manifest는 --expect-findings로 전달된다.
    과거 산출물 하위호환은 없다 — LIVE_SCHEMA_VERSION과 정확히 일치하는 계약만 검증한다.
    """
    violations = []
    sv = entry.get("schema_version")
    if sv != LIVE_SCHEMA_VERSION:
        violations.append(
            f"live 결과는 schema_version {LIVE_SCHEMA_VERSION!r}이어야 함 (got {sv!r})"
        )
        return violations
    verdict = entry.get("verdict")
    if verdict not in VERDICT_CATEGORIES:
        violations.append(f"verdict 누락 또는 enum 밖 값: {verdict!r}")
        return violations
    conf = entry.get("confidence")
    if conf not in CONFIDENCE_VALUES:
        violations.append(f"confidence 누락 또는 enum 밖 값: {conf!r}")
    elif verdict in ("CONFIRMED_ISSUE", "NOT_AN_ISSUE") and conf == "N/A":
        # N/A 신뢰도는 NEEDS_MORE_INFO 전용 — 신뢰도 없는 확정/기각이
        # LOW-confidence fail-closed 승격을 우회하는 것을 차단한다.
        violations.append(f"확정 verdict({verdict})에 confidence=N/A 금지")
    axes = entry.get("axes")
    if not isinstance(axes, dict):
        violations.append(f"axes가 객체가 아님: {type(axes).__name__}")
        plaus = None
    else:
        plaus = axes.get("plausibility")
    if plaus not in PLAUSIBILITY_VALUES:
        violations.append(f"axes.plausibility 누락 또는 enum 밖 값: {plaus!r}")
    elif plaus not in PLAUSIBILITY_MATRIX[verdict]:
        violations.append(
            f"verdict 정합 행렬 위반: verdict={verdict} + plausibility={plaus}"
        )
    if entry.get("reviewer_severity") not in SEVERITY_VALUES:
        violations.append(
            f"reviewer_severity 누락 또는 enum 밖 값: {entry.get('reviewer_severity')!r}"
        )
    # accepted_severity는 scope 라우팅 대상 verdict(CONFIRMED/NEEDS_MORE_INFO)에만
    # 필수다 — NOT_AN_ISSUE는 write set에 들어가지 않으므로 요구하지 않는다 (있어도 무방).
    if verdict != "NOT_AN_ISSUE" and entry.get("accepted_severity") not in SEVERITY_VALUES:
        violations.append(
            f"accepted_severity 누락 또는 enum 밖 값: {entry.get('accepted_severity')!r}"
        )
    # remediation_scope도 scope 라우팅 대상 verdict에만 필수 — 재설계 지적의 루프 밖
    # 배출 라우팅(FIX_NOW/REPLAN_REQUIRED/UNCLEAR)이 이 값 하나로 기계 결정된다.
    # NOT_AN_ISSUE에는 필드 자체를 금지한다 (기각에는 해소 방식이 없다).
    rscope = entry.get("remediation_scope")
    if verdict != "NOT_AN_ISSUE":
        if rscope not in REMEDIATION_SCOPES:
            violations.append(
                f"remediation_scope 누락 또는 enum 밖 값: {rscope!r}"
            )
    elif "remediation_scope" in entry:
        # 키 존재 자체를 검사한다 — 명시적 null도 "필드 자체 금지" 위반이다
        # (get() 비교는 키 부재와 null을 구분하지 못해 null 출력이 통과한다).
        violations.append(
            f"NOT_AN_ISSUE에 remediation_scope 출력 금지 (got {rscope!r})"
        )
    # stability_status는 폐기된 과거 계약(selective consistency aggregate)의 필드다 —
    # 현행 계약에 적법한 산출 주체가 없으므로 값과 무관하게 위반이다 (aggregate 상태
    # 환각 경로 차단).
    if "stability_status" in entry:
        violations.append(
            "stability_status는 폐기된 필드 — entry에 출력 금지 "
            f"(got {entry['stability_status']!r})"
        )
    if isinstance(axes, dict) and axes.get("portability") not in PORTABILITY_VALUES:
        violations.append(
            f"axes.portability 누락 또는 enum 밖 값: {axes.get('portability')!r}"
        )
    basis = entry.get("rejection_basis")
    if verdict == "NOT_AN_ISSUE":
        if basis not in REJECTION_BASES:
            violations.append(f"NOT_AN_ISSUE에 rejection_basis 누락/비정상: {basis!r}")
        elif basis == "PLAUSIBILITY_FAIL" and plaus != "FAIL":
            violations.append("rejection_basis=PLAUSIBILITY_FAIL이면 plausibility=FAIL 필수")
        elif basis in ("FACTUAL_FAIL", "RELEVANCE_FAIL") and plaus not in ("N/A", "FAIL"):
            violations.append(
                f"rejection_basis={basis}와 plausibility={plaus} 조합 비정합"
            )
    elif basis is not None:
        violations.append(f"{verdict}에 rejection_basis 출력 금지 (got {basis!r})")
    # evidence_scope는 PLAUSIBILITY_FAIL 기각의 suppress 수명주기를 결정하므로
    # 그 경우에만 필수다 — 기록자가 사람용 rationale 재해석 없이 eligibility를 판단한다.
    scope = entry.get("evidence_scope")
    if basis == "PLAUSIBILITY_FAIL":
        if scope not in EVIDENCE_SCOPES:
            violations.append(
                f"PLAUSIBILITY_FAIL에 evidence_scope 누락 또는 enum 밖 값: {scope!r}"
            )
    elif scope is not None:
        violations.append(
            f"evidence_scope는 PLAUSIBILITY_FAIL 전용 (got {scope!r} with basis={basis!r})"
        )
    return violations


# reviewer 결과 형식 (da-domains.md "출력 형식" 정본과 동기화 — manual sync contract)
REVIEWER_CLEAR_PATTERN = re.compile(r"^\s*\[?[A-Za-z_ ]+\]?\s*[:：]\s*CLEAR\s*$")
REVIEWER_COUNT_PATTERN = re.compile(r"문제 발견\s*[:：]\s*(\d+)\s*건")
REVIEWER_VIOLATION_HEADER = re.compile(r"위반 상태\s*[:：]\s*VIOLATION")
REVIEWER_REQUIRED_LABELS = ("ID", "세부 관점", "위치", "문제", "근거", "심각도", "권장 수정")
# VIOLATION 보고의 필수 라벨 (da-domains.md 정본 형식과 동기화)
REVIEWER_VIOLATION_LABELS = ("유형", "이유", "필요 작업", "정리 대상", "로컬 정리 필요")


def _label_value(block, label):
    """블록에서 라벨의 비어 있지 않은 값을 반환한다 (없으면 None — 누락·빈 값 동일 취급).

    라벨은 line-start bullet에 고정한다 — 본문·fence 인용 라벨이 실제 누락을
    대신하는 경로 차단 (#1259). 값은 같은 줄 또는 다음 줄부터의 continuation
    (다음 bullet 라벨·heading 전까지)을 인정한다 — 라벨 다음 줄에 본문을 두는
    정상 Markdown 형식이 실존 세션에서 관측됐다. 같은 줄 공백은 [ \\t]로
    한정한다 — \\s*는 개행을 넘어 다음 줄을 빈 라벨의 값으로 오인한다.
    """
    m = re.search(rf"^-[ \t]*\*\*{label}\*\*[ \t]*[:：][ \t]*(.*)$", block, re.M)
    if not m:
        return None
    inline = m.group(1).strip()
    if inline:
        return inline
    cont_lines = []
    for line in block[m.end():].splitlines():
        if re.match(r"^-[ \t]*\*\*", line) or line.startswith("#"):
            break
        cont_lines.append(line)
    cont = "\n".join(cont_lines).strip()
    return cont if cont else None


def _header_unit_name(line):
    """결과 헤더에서 unit 이름을 추출한다 (형식 무관 — 첫 영문 단어)."""
    m = re.search(r"[A-Za-z_]+", line)
    return m.group(0) if m else None


def validate_reviewer_file(path, expected_unit=None):
    """reviewer 결과 파일 하나를 검증한다 — (status, findings_count, violations).

    status: "clear" | "violation" | "findings" | "malformed".
    Arbiter 검증(--validate-only)과 산출 주체가 달라 분리된 검증기다 (#1259) —
    빈/절단 산출, 선언 건수 불일치, placeholder 값이 성공으로 집계되는 경로를 차단한다.
    VIOLATION 보고는 reviewer의 적법 산출이므로 정본 형식을 갖추면 별도 status로
    보고한다 (전이는 hardening-contract.md VIOLATION 공통 처리 소유).
    형식 판별은 상호 배타다 — CLEAR·VIOLATION 헤더·발견 헤더가 공존하면 malformed
    (finding 본문에 인용된 CLEAR 한 줄이 전체 결과를 0건으로 덮어쓰는 injection 차단).
    """
    if not path.is_file():
        return "malformed", 0, [f"파일 없음: {path}"]
    text = path.read_text(encoding="utf-8")
    stripped = text.strip()
    if not stripped:
        return "malformed", 0, ["빈 결과 파일"]
    # fenced code block은 구조 탐색에서 제외한다 — 본문 PoC·인용 안의 라벨·헤더
    # 형태가 파서를 조작하는 입력 기반 injection 경로 차단 (#1259).
    text = re.sub(r"```.*?```", "```(fence 제외)```", text, flags=re.S)
    # 형식 판정은 파일의 첫 비공백 줄(최상위 결과 헤더)에서만 한다 — 본문에 인용된
    # CLEAR·위반 헤더·건수 문구가 상태를 덮어쓰거나(injection) 정상 결과를 신호
    # 공존으로 오차단하는 경로를 모두 차단한다 (#1259).
    first_line = next(line for line in text.splitlines() if line.strip())
    is_clear = bool(REVIEWER_CLEAR_PATTERN.fullmatch(stripped))
    has_violation = bool(REVIEWER_VIOLATION_HEADER.search(first_line))
    count_match = REVIEWER_COUNT_PATTERN.search(first_line)
    # unit 결속 (#1259) — 배정 unit과 결과 헤더의 이름 대조. 다른 unit의 CLEAR가
    # 이 unit의 성공으로 집계되면 요청한 관점이 실행되지 않았는데 수렴에 포함된다.
    if expected_unit:
        header_name = _header_unit_name(stripped.splitlines()[0] if is_clear else first_line)
        if header_name is None or header_name.lower() != expected_unit.lower():
            return "malformed", 0, [
                f"unit 결속 위반 — 기대 unit {expected_unit!r}, 결과 헤더 {header_name!r}"
            ]
    if is_clear:
        return "clear", 0, []
    if has_violation:
        violations = []
        for label in REVIEWER_VIOLATION_LABELS:
            if _label_value(text, label) is None:
                violations.append(f"VIOLATION 필수 라벨 '{label}' 누락/빈 값 (정본: da-domains.md)")
        vtype = _label_value(text, "유형")
        if vtype is not None and not re.fullmatch(r"RECOVERABLE|STATEFUL", vtype.strip()):
            # fullmatch — 미치환 템플릿 "RECOVERABLE / STATEFUL"이 enum으로 통과하는 경로 차단
            violations.append(f"VIOLATION 유형 enum 밖 값 (단일 값 필수): {vtype.strip()[:30]!r}")
        cleanup = _label_value(text, "로컬 정리 필요")
        if cleanup is not None and not re.fullmatch(r"YES|NO", cleanup.strip()):
            violations.append(f"VIOLATION 로컬 정리 필요 enum 밖 값 (YES|NO): {cleanup.strip()[:30]!r}")
        reason = _label_value(text, "이유")
        if reason is not None and is_placeholder_value(reason):
            violations.append(f"VIOLATION 이유 값이 placeholder/미완: {reason.strip()[:40]!r}")
        return ("violation" if not violations else "malformed"), 0, violations
    if not count_match:
        return "malformed", 0, [
            "형식 불명 — CLEAR도, VIOLATION 헤더도, '문제 발견: N건' 헤더도 없음 (절단/미완 의심)"
        ]
    violations = []
    declared = int(count_match.group(1))
    if declared < 1:
        # 0건은 CLEAR 형식(파일 전체 fullmatch)으로만 표현한다 — "문제 발견: 0건"이
        # finding 0개 파일을 findings 성공으로 만들어 CLEAR 방어를 우회하는 경로 차단.
        return "malformed", 0, ["발견 형식의 선언 건수는 1 이상이어야 한다 — 0건은 CLEAR 형식 전용"]
    blocks = re.split(r"^###\s+", text, flags=re.M)[1:]
    finding_blocks = [b for b in blocks if re.search(r"\*\*ID\*\*", b)]
    if len(finding_blocks) != declared:
        violations.append(
            f"선언 건수({declared})와 finding 블록 수({len(finding_blocks)}) 불일치 (절단/미완 의심)"
        )
    seen_ids = set()
    for i, block in enumerate(finding_blocks, 1):
        values = {}
        for label in REVIEWER_REQUIRED_LABELS:
            value = _label_value(block, label)
            if value is None:
                violations.append(f"블록 {i}: 필수 라벨 '{label}' 누락/빈 값 (절단/미완 의심)")
            values[label] = value
        raw_id = (values.get("ID") or "").strip().strip("`")
        if raw_id:
            if raw_id in seen_ids:
                # 결과 내 중복 ID — Arbiter의 ID별 일대일 판정과 manifest 대조를 깨뜨린다
                violations.append(f"블록 {i}: 결과 내 중복 finding ID: {raw_id!r}")
            seen_ids.add(raw_id)
        if raw_id and not SAFE_FINDING_ID_PATTERN.fullmatch(raw_id):
            violations.append(
                f"블록 {i}: finding ID 문법 위반 (reviewer 기본형 {{PREFIX}}-{{순번}} 한정 — "
                f"라운드 suffix는 메인 부여): {raw_id!r}"
            )
        sev = (values.get("심각도") or "").strip()
        if sev and sev not in SEVERITY_VALUES:
            violations.append(f"블록 {i}: 심각도 enum 밖 값: {sev!r}")
        for label in ("문제", "근거"):
            if values.get(label) is not None and is_placeholder_value(values[label]):
                violations.append(
                    f"블록 {i}: '{label}' 값이 placeholder/미완: {values[label].strip()[:40]!r}"
                )
    return ("findings" if not violations else "malformed"), len(finding_blocks), violations


def run_reviewer_validation(paths, expected_unit=None):
    """--validate-reviewer 진입점 — 파일별 검증 후 JSON 리포트를 출력한다."""
    report = {"files": [], "ok": True}
    for path in paths:
        status, count, violations = validate_reviewer_file(path, expected_unit)
        file_ok = not violations
        report["files"].append(
            {
                "path": str(path),
                "status": status,
                "findings_count": count,
                "format_errors": violations,
                "ok": file_ok,
            }
        )
        report["ok"] = report["ok"] and file_ok
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0 if report["ok"] else 1


def manifest_diff_violations(expected_ids, found_ids):
    """--expect-findings manifest 대조 위반 목록 (exact-set: 누락·미지 ID 모두 위반)."""
    issues = [f"기대 finding 누락: {fid}" for fid in sorted(expected_ids - found_ids)]
    issues += [f"manifest 밖 finding: {fid}" for fid in sorted(found_ids - expected_ids)]
    return issues


def parse_and_check_manifest(paths, expected_ids):
    """파일별 (entries, malformed, manifest 위반)을 한 번에 산출하는 공통 흐름."""
    parsed = []
    for path in paths:
        entries, malformed = load_validated_verdict_entries(path)
        issues = manifest_diff_violations(expected_ids, set(entries.keys()))
        parsed.append({
            "path": path,
            "entries": entries,
            "malformed": malformed,
            "manifest_violations": issues,
        })
    return parsed


def resolve_expected_ids(args):
    """--expect-findings 인자에서 expected_ids를 결정한다.

    manifest 대조는 모든 수집 경로의 필수 경계이므로(protocol.md 수렴 판정),
    옵션 생략은 "검증 없음"이 아니라 인자 오류다 — manifest 없는 호출이 성공하면
    finding 누락이 그대로 소비된다.
    반환: (expected_ids | None, error_message | None).
    """
    if args.expect_findings is None:
        return None, "--expect-findings가 필요하다 (finding manifest 대조는 필수)"
    # 빈 문자열("")은 "옵션 미지정"이 아니라 인자 오류다 — truthiness 검사로 조용히
    # manifest 검증을 우회하는 경로(셸 변수 유실 등)를 차단한다.
    raw_ids = [fid.strip() for fid in args.expect_findings.split(",")]
    if "" in raw_ids:
        return None, f"--expect-findings에 빈 항목: {args.expect_findings!r}"
    if len(raw_ids) != len(set(raw_ids)):
        return None, f"--expect-findings에 중복 ID: {args.expect_findings!r}"
    return set(raw_ids), None


# finding ID의 shell-safe 문법 — `{prefix}-{순번}` (기본형). reviewer 원본과
# Arbiter 입력·manifest는 기본형만 적법하다 — 라운드 suffix(`-r{라운드}`)는 메인이
# 라운드 경계를 넘는 기록·서술에만 부여하는 축이라 live 검증 경로에는 나타나지
# 않는다 (da-domains.md 정본. 확장형의 기계 소비자는 세션 분석기뿐이다).
# prefix가 bundle인지 subdomain인지는 여기서 강제하지 않는다. 이 검사의 목적은
# namespace 검증이 아니라, reviewer 산출 ID가 --expect-findings 셸 인자로 전달되기
# 전에 안전한 문자 집합만 통과시키는 것이다.
SAFE_FINDING_ID_PATTERN = re.compile(r"[A-Za-z_]+-[0-9]+")

# 사람용 블록의 근거 라벨 값에 대한 placeholder 판정 (#1259 — 실측에서 필수 필드가
# 리터럴 "test"인 산출이 성공 집계된 사고). 값의 유일 토큰 집합이 sentinel뿐이거나
# sentinel로 시작하는 미완 표기를 거부한다 (길이 기준 없음 — 짧은 레퍼런스는 유효).
PLACEHOLDER_TOKENS = frozenset({"test", "todo", "placeholder", "tbd", "..."})


def is_placeholder_value(value):
    """근거·문제 서술 값이 placeholder/미완인지 판정한다 (True = 위반).

    범위는 관측된 sentinel 계열로 한정한다 — 빈 값, 유일 토큰 반복("test test
    test"), sentinel로 시작하는 미완 표기("TODO: ..."). 길이 기준은 두지 않는다 —
    짧은 파일:줄·계획 항목 레퍼런스는 계약상 유효한 근거다. 길이·토큰을 채운
    위장 placeholder는 기계 판정 범위 밖이며(의미 판정은 Arbiter·리뷰 몫),
    이 함수는 성공 집계 차단용 하한이다.
    """
    stripped = value.strip().strip("`\"'.,;:-— ").lower()
    if not stripped:
        return True
    words = set(re.findall(r"[a-z가-힣]+", stripped))
    if words and words <= PLACEHOLDER_TOKENS:
        return True
    # sentinel 접두어는 뒤에 실질 서술이 없을 때만 미완이다 — "TODO 주석이 남아
    # 있다"처럼 sentinel 자체를 다루는 완성된 근거를 오차단하지 않는다.
    m = re.match(r"(todo|tbd|placeholder|fixme)\b", stripped)
    if m:
        rest_words = set(re.findall(r"[a-z가-힣]+", stripped[m.end():]))
        return not rest_words or rest_words <= PLACEHOLDER_TOKENS
    return False

# arbiter-prompt.md "출력 형식 > 기계 파싱용 VERDICT_JSON 블록" 스키마와 일치
VERDICT_JSON_PATTERN = re.compile(
    r"<!-- verdict-json:start -->\s*```json\s*(?P<body>.+?)\s*```\s*<!-- verdict-json:end -->",
    re.DOTALL,
)


def load_validated_verdict_entries(markdown_path: Path):
    """Parse VERDICT_JSON blocks from Arbiter result markdown.

    Returns (entries, malformed_count):
      entries: dict mapping finding_id -> verdict entry dict (valid only).
      malformed_count: int — 수 보존. caller는 malformed>0을 위반으로 승격.

    방어 규칙:
      - JSONDecodeError: malformed 카운트 +1, 해당 block skip.
      - json 결과가 dict가 아니면(list/str/null 등): malformed +1, skip.
      - finding_id 누락/비문자열: malformed +1, skip.
      - validate_verdict_entry() 위반 (live schema 계약 전체): malformed +1, skip.
      - 동일 파일 내 동일 finding_id 중복: malformed +1, 해당 finding entries에서 제거
        (silent overwrite 방지; caller는 BLOCKED 취급).
    """
    text = markdown_path.read_text(encoding="utf-8")
    # blockquote 인용 줄은 구조 파싱에서 제외한다 — 인용된 완전한 verdict 형식이
    # 실제 산출로 소비되는 injection 경로 차단 (#1259).
    text = re.sub(r"^[ \t]*>.*$", "", text, flags=re.M)
    # 사람용 섹션·근거 탐색은 fence를 마스킹한 별도 view에서 수행한다 — fenced
    # PoC·재인용 속 헤더·라벨이 실제 근거 블록을 대신하는 경로 차단. VERDICT_JSON
    # 블록 자체는 ```json fence이므로 원문 text에서 계속 파싱한다.
    rationale_view = re.sub(r"```.*?```", "```masked```", text, flags=re.S)
    entries = {}
    duplicated_ids = set()
    malformed = 0
    # delimiter 쌍 무결성 — 완전한 VERDICT_JSON match에 속하지 않는 raw start
    # marker(라인 시작)는 절단·손상 산출의 직접 신호다 (미완 파일이 마지막 블록만
    # 잃고 통과하는 경로 차단, #1259). 단순 개수 비교는 쓰지 않는다 — 사람용
    # 본문에 인라인 인용된 marker(계약 자체를 리뷰하는 정상 산출)를 오차단하고,
    # orphan start/end가 상쇄되는 손상은 놓친다. end 단독 인용은 판정하지 않는다.
    match_spans = [m.span() for m in VERDICT_JSON_PATTERN.finditer(text)]
    # orphan 판정은 start marker만 — 절단은 언제나 짝 없는 start를 남기고, end 단독은
    # delimiter 계약을 인용·예시하는 정상 산출에서 line-start로도 나타난다 (#1259).
    for sm in re.finditer(r"^<!-- verdict-json:start -->", text, re.M):
        if not any(s <= sm.start() < e for s, e in match_spans):
            print(
                f"warning: orphan verdict-json start marker (truncated block?) in {markdown_path}",
                file=sys.stderr,
            )
            malformed += 1
    for match in VERDICT_JSON_PATTERN.finditer(text):
        raw = match.group("body")
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError as exc:
            print(
                f"warning: malformed VERDICT_JSON in {markdown_path}: {exc}",
                file=sys.stderr,
            )
            malformed += 1
            continue
        if not isinstance(entry, dict):
            print(
                f"warning: VERDICT_JSON is not an object ({type(entry).__name__}) in {markdown_path}",
                file=sys.stderr,
            )
            malformed += 1
            continue
        finding_id = entry.get("finding_id")
        if not isinstance(finding_id, str) or not SAFE_FINDING_ID_PATTERN.fullmatch(finding_id):
            print(
                f"warning: VERDICT_JSON without shell-safe finding_id in {markdown_path}",
                file=sys.stderr,
            )
            malformed += 1
            continue
        semantic_violations = validate_verdict_entry(entry)
        if semantic_violations:
            for v in semantic_violations:
                print(
                    f"warning: semantic malformed VERDICT_JSON ({finding_id}) in {markdown_path}: {v}",
                    file=sys.stderr,
                )
            malformed += 1
            continue
        if finding_id in entries:
            # 같은 파일 안 중복 — 어느 쪽도 신뢰 불가. 해당 finding을 duplicated_ids에 표시.
            print(
                f"warning: duplicate finding_id={finding_id!r} in {markdown_path}",
                file=sys.stderr,
            )
            duplicated_ids.add(finding_id)
            malformed += 1
            continue
        rationale_violation = arbiter_rationale_violation(rationale_view, finding_id, entry["verdict"])
        if rationale_violation:
            print(
                f"warning: semantic malformed VERDICT_JSON ({finding_id}) in "
                f"{markdown_path}: {rationale_violation}",
                file=sys.stderr,
            )
            malformed += 1
            continue
        entries[finding_id] = entry
    for fid in duplicated_ids:
        entries.pop(fid, None)
    return entries, malformed


def arbiter_rationale_violation(text, finding_id, verdict):
    """finding의 사람용 블록 근거 라벨을 검사한다 (None = 통과, str = 위반 사유).

    VERDICT_JSON enum 필드의 placeholder는 기존 enum 검증이 차단하지만, 사람용
    블록의 근거가 비어 있거나 리터럴 placeholder인 미완 산출은 JSON만으로는
    걸러지지 않는다 (#1259 실측 — 자유 서술 필드가 전부 "test"인데 성공 집계).
    섹션은 entry의 verdict와 일치하는 헤더에 일대일 결속한다 — 입력 재인용
    섹션이나 예시 인용이 실제 verdict 블록의 근거 누락을 대신하는 우회 차단.
    """
    sections = list(re.finditer(
        rf"^###\s+{re.escape(finding_id)}\s*[—\-]\s*{re.escape(verdict)}\s*$.*?(?=^###\s|\Z)",
        text, re.M | re.S,
    ))
    if not sections:
        return "사람용 블록(### finding — verdict 섹션) 누락"
    if len(sections) > 1:
        return "동일 finding의 사람용 섹션 중복 — 결속 판정 불가"
    value = _label_value(sections[0].group(0), "근거")
    if value is None:
        return "사람용 블록에 근거 라벨 누락/빈 값"
    if is_placeholder_value(value):
        return f"근거 값이 placeholder/미완: {value.strip()[:40]!r}"
    return None


def main():
    # preflight capability 조회 — 배포 helper의 live 계약 버전을 기계 조회한다
    # (protocol.md 검증기 호출 계약). argparse 이전 선처리인 이유: 파일 인자 없이
    # 호출되는 조회 플래그이고, 구버전 helper의 unrecognized-argument 비0 종료
    # 자체가 "계약보다 오래된 배포본" fail-closed 신호로 쓰인다.
    if "--print-live-schema" in sys.argv[1:]:
        print(LIVE_SCHEMA_VERSION)
        return 0
    # helper CLI capability 조회 — Arbiter 출력 계약 버전(schema)과 별개 축이다.
    # schema가 같아도 검증 능력(reviewer 모드 등)이 다른 배포본을 preflight가
    # 구분해야 한다 (#1259) — 구버전의 비0 종료 자체가 미지원 신호다.
    if "--print-capabilities" in sys.argv[1:]:
        print("arbiter-validate")
        print("reviewer-validate")
        print("rationale-check")
        return 0
    parser = argparse.ArgumentParser(
        description=(
            "Run-DA VERDICT_JSON validator. "
            f"--validate-only는 schema {LIVE_SCHEMA_VERSION} 계약과 finding manifest 대조를 수행한다 "
            "(caller 검증 — protocol.md 수렴 판정 SSOT). selective consistency 집계 모드는 "
            "제거됐다 (#1257)."
        ),
    )
    parser.add_argument(
        "result_files",
        nargs="+",
        type=Path,
        help="검증 대상 결과 파일 — --validate-only는 Arbiter 결과, --validate-reviewer는 reviewer 결과",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help=(
            f"각 입력 파일의 VERDICT_JSON schema {LIVE_SCHEMA_VERSION} 계약과 finding "
            "manifest 대조를 검증하고 JSON 결과를 출력한다 "
            "(caller 검증용 — protocol.md 수렴 판정 SSOT)"
        ),
    )
    parser.add_argument(
        "--expect-findings",
        help=(
            "쉼표 구분 finding ID manifest (--validate-only 필수). 각 파일의 유효 finding ID "
            "집합이 이 집합과 정확히 일치해야 한다 — 누락·미지 ID는 위반 (finding 소실 차단)"
        ),
    )
    parser.add_argument(
        "--expect-unit",
        help=(
            "--validate-reviewer 전용: 배정 reviewer unit 이름 (bundle 또는 MAX 세부 관점). "
            "결과 헤더의 이름과 대조해 다른 unit의 산출이 이 unit의 성공으로 집계되는 것을 차단한다"
        ),
    )
    parser.add_argument(
        "--validate-reviewer",
        action="store_true",
        help=(
            "reviewer 결과 파일 검증 모드 (#1259) — Arbiter 검증과 분리된 산출 주체별 "
            "검증기. CLEAR/VIOLATION/발견 형식 판별, 선언 건수와 finding 블록 수 대조, "
            "필수 라벨·ID 문법·심각도 enum·placeholder/절단 판정을 수행하고 JSON을 출력한다"
        ),
    )
    args = parser.parse_args()

    if args.validate_reviewer and args.validate_only:
        print("error: --validate-only와 --validate-reviewer는 상호 배타다", file=sys.stderr)
        return 1
    if args.validate_reviewer:
        if args.expect_findings:
            print("error: --expect-findings는 --validate-only 전용이다", file=sys.stderr)
            return 1
        return run_reviewer_validation(args.result_files, args.expect_unit)
    if args.expect_unit:
        print("error: --expect-unit은 --validate-reviewer 전용이다", file=sys.stderr)
        return 1

    if not args.validate_only:
        # 과거 N=3 vote-shape 집계 CLI와의 호출 혼동을 명시적으로 거부한다 —
        # 구버전 문서/스크립트가 집계 모드로 호출하면 조용한 오동작 대신 인자 오류.
        print(
            "error: selective consistency 집계 모드는 제거됐다 (#1257) — "
            "--validate-only 또는 --validate-reviewer로 호출한다",
            file=sys.stderr,
        )
        return 1

    expected_ids, arg_error = resolve_expected_ids(args)
    if arg_error:
        print(f"error: {arg_error}", file=sys.stderr)
        return 1

    parsed = parse_and_check_manifest(args.result_files, expected_ids)

    report = {"files": [], "ok": True}
    for item in parsed:
        file_ok = (
            item["malformed"] == 0
            and len(item["entries"]) > 0
            and not item["manifest_violations"]
        )
        report["files"].append(
            {
                "path": str(item["path"]),
                "valid_findings": sorted(item["entries"].keys()),
                "malformed_count": item["malformed"],
                "manifest_violations": item["manifest_violations"],
                "ok": file_ok,
            }
        )
        report["ok"] = report["ok"] and file_ok
    json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
