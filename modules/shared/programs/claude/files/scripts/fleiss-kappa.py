#!/usr/bin/env python3
"""Run-DA VERDICT_JSON validator.

VERDICT_JSON 계약 검증 (`validate_verdict_entry` + `--validate-only`) —
protocol.md "수렴 판정" caller 검증의 기계 검증 SSOT. Arbiter 결과 수집이 소비한다.

파일명은 초기 Fleiss kappa 집계 용도에서 유래했다. selective consistency(N=3
vote-shape·stability_status·kappa 집계)는 실사용 0건으로 제거됐고(#1257) 이 파일은
검증기 책임만 남았다 — 세션 scope에 단일 파일로 프로비저닝되는 계약이라 경로·이름은
유지한다 (개명하면 배포 체인과 HELPER_PATH 계약이 함께 움직여야 한다).

Each file must contain VERDICT_JSON blocks whose schema_version matches
LIVE_SCHEMA_VERSION exactly, with per-finding verdicts as defined in
arbiter-prompt.md "출력 형식" section.

Usage:
    # caller 검증 (파일별 schema/manifest 검사 결과 JSON,
    # 전체 통과 시 exit 0 / 위반 시 exit 1)
    fleiss-kappa.py --validate-only --expect-findings <ID,ID,...> <result.md>

`--expect-findings`는 필수 인자다 — 생략은 검증 없음이 아니라 인자 오류다.
manifest 없는 수집이 성공으로 처리되면 finding 누락이 그대로 소비되어 조기 수렴으로 샌다.

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
    # accepted_severity는 write set 진입 가능 verdict(CONFIRMED/NEEDS_MORE_INFO)에만
    # 필수다 — NOT_AN_ISSUE는 write set에 들어가지 않으므로 요구하지 않는다 (있어도 무방).
    if verdict != "NOT_AN_ISSUE" and entry.get("accepted_severity") not in SEVERITY_VALUES:
        violations.append(
            f"accepted_severity 누락 또는 enum 밖 값: {entry.get('accepted_severity')!r}"
        )
    # remediation_scope도 write set 진입 가능 verdict에만 필수 — 재설계 지적의 루프 밖
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


# finding ID의 shell-safe 문법 — `{prefix}-{순번}`. prefix가 bundle인지 subdomain인지는
# 여기서 강제하지 않는다 (reviewer bundle은 `Correctness-1`, exhaustive 경로는
# `SECURITY-2` 같은 subdomain prefix를 쓴다). 이 검사의 목적은 namespace 검증이 아니라,
# reviewer 산출 ID가 --expect-findings 셸 인자로 전달되기 전에 안전한 문자 집합만
# 통과시키는 것이다 (da-domains.md의 ID 형식 규약은 문서 계약으로 별도 유지).
SAFE_FINDING_ID_PATTERN = re.compile(r"[A-Za-z_]+-[0-9]+")

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
    entries = {}
    duplicated_ids = set()
    malformed = 0
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
        entries[finding_id] = entry
    for fid in duplicated_ids:
        entries.pop(fid, None)
    return entries, malformed


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Run-DA VERDICT_JSON validator. "
            f"--validate-only는 schema {LIVE_SCHEMA_VERSION} 계약과 finding manifest 대조를 수행한다 "
            "(caller 검증 — protocol.md 수렴 판정 SSOT). selective consistency 집계 모드는 "
            "제거됐다 (#1257)."
        ),
    )
    parser.add_argument(
        "arbiter_files",
        nargs="+",
        type=Path,
        help="Arbiter result markdown files containing VERDICT_JSON blocks",
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
            "쉼표 구분 finding ID manifest (필수). 각 파일의 유효 finding ID "
            "집합이 이 집합과 정확히 일치해야 한다 — 누락·미지 ID는 위반 (finding 소실 차단)"
        ),
    )
    args = parser.parse_args()

    if not args.validate_only:
        # 과거 N=3 vote-shape 집계 CLI와의 호출 혼동을 명시적으로 거부한다 —
        # 구버전 문서/스크립트가 집계 모드로 호출하면 조용한 오동작 대신 인자 오류.
        print(
            "error: selective consistency 집계 모드는 제거됐다 (#1257) — "
            "--validate-only로 호출한다",
            file=sys.stderr,
        )
        return 1

    expected_ids, arg_error = resolve_expected_ids(args)
    if arg_error:
        print(f"error: {arg_error}", file=sys.stderr)
        return 1

    parsed = parse_and_check_manifest(args.arbiter_files, expected_ids)

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
