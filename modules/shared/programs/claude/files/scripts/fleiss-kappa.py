#!/usr/bin/env python3
"""Run-DA VERDICT_JSON validator + selective consistency aggregator.

이 파일은 두 책임을 소유한다 (파일명은 초기 Fleiss kappa 용도에서 유래했고, 세션 scope에
단일 파일로 프로비저닝되는 계약이라 유지한다 — 분리하면 프로비저닝 대상이 늘어난다):

  1. VERDICT_JSON 계약 검증 (`validate_verdict_entry` + `--validate-only`) —
     protocol.md "수렴 판정" caller 검증의 기계 검증 SSOT. first-pass 결과 수집이 소비한다.
  2. selective consistency 집계 (`classify_vote_shape` 이하 + 기본 CLI 경로) —
     N=3 vote-shape와 stability_status 산출. trigger된 finding에만 실행된다.

두 모드는 parse_and_check_manifest()의 같은 파싱·manifest 결과를 소비한다.

v1 정책: selective consistency가 발동한 finding에 대해 **N=3 독립 Arbiter** 결과를 받아
vote-shape(3:0 / 2:1 / 1:1:1)와 stability_status(stable / split / fragmented)를 계산한다.
입력 파일이 정확히 3개가 아니면 vote-shape는 "unknown"으로 분류되어 v1 정책 범위 밖이다.

Each file must contain VERDICT_JSON blocks (schema_version exactly "1.1") with per-finding verdicts
as defined in arbiter-prompt.md "출력 형식" section.

With --offline flag, also compute corpus-level Fleiss' kappa across findings
(Fleiss 1971, chance-corrected agreement among N raters on categorical verdicts).
Kappa는 **배포 후 장기 관찰 지표**이며 v1 실시간 분기에는 사용하지 않는다.
corpus 전용이므로 2개 이상의 finding이 있어야 정의된다.

Threshold policy SSOT: stability-measurement.md (STABLE_MIN / ESCALATE_MIN).

Usage:
    # N=3 vote-shape 집계 (aggregate JSON을 stdout에 출력)
    fleiss-kappa.py --expect-findings <ID,ID,...> \
        <arbiter1.md> <arbiter2.md> <arbiter3.md> [--offline]
    # first-pass caller 검증 (집계 없음 — 파일별 schema/manifest 검사 결과 JSON,
    # 전체 통과 시 exit 0 / 위반 시 exit 1)
    fleiss-kappa.py --validate-only --expect-findings <ID,ID,...> <result.md>

`--expect-findings`는 모든 호출의 필수 인자다 — 생략은 검증 없음이 아니라 인자 오류다.
manifest 없는 수집이 성공으로 처리되면 finding 누락이 그대로 소비되어 조기 수렴으로 샌다.

Output: JSON on stdout. See main() for schema.
"""

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

# 단일 진실 원천 (stability-measurement.md와 동기화)
STABLE_MIN = 0.6
ESCALATE_MIN = 0.4

VERDICT_CATEGORIES = ("CONFIRMED_ISSUE", "NOT_AN_ISSUE", "NEEDS_MORE_INFO")
CONFIDENCE_VALUES = ("HIGH", "MEDIUM", "LOW", "N/A")

# schema 1.1 semantic 계약 (protocol.md "수렴 판정" caller 검증 SSOT와 동기화)
SEVERITY_VALUES = ("CRITICAL", "HIGH", "MEDIUM", "LOW")
PLAUSIBILITY_VALUES = ("PASS", "FAIL", "UNKNOWN", "N/A")
REJECTION_BASES = ("FACTUAL_FAIL", "RELEVANCE_FAIL", "PLAUSIBILITY_FAIL")
# PLAUSIBILITY_FAIL 기각 근거의 수명주기 분류 (dismissal-ledger.md 영속 eligibility SSOT):
# FROZEN_SURFACE = frozen changeset의 불변 계약 근거 → ledger 영속 eligible
# ENVIRONMENT_WORKLOAD = 환경·워크로드 가정 근거 → 비영속 (현재 루프 한정 suppress)
EVIDENCE_SCOPES = ("FROZEN_SURFACE", "ENVIRONMENT_WORKLOAD")
# verdict -> 허용되는 axes.plausibility 값 (정합 행렬)
PLAUSIBILITY_MATRIX = {
    "CONFIRMED_ISSUE": {"PASS"},
    "NOT_AN_ISSUE": {"FAIL", "N/A"},
    "NEEDS_MORE_INFO": {"PASS", "UNKNOWN"},
}
LIVE_SCHEMA_VERSION = "1.1"  # 실시간 결과는 정확히 이 버전 (새 계약 도입 시 검증기와 함께 갱신)


def validate_verdict_entry(entry):
    """schema 1.1 계약 위반 목록을 반환하는 단일 검증 진입점 (빈 리스트 = 통과).

    protocol.md "수렴 판정" caller 검증의 기계 검증 SSOT 구현체 —
    version·필수 필드·모든 enum·verdict 정합 행렬을 이 함수 하나가 검사한다.
    finding_id의 존재·중복 검사는 parser(load_validated_verdict_entries) 소관이고,
    reviewer 원본 finding과의 대조(reviewer_severity 은닉 차단)는 원본을 아는
    caller 몫이며, finding ID manifest는 --expect-findings로 전달된다.
    과거 1.0 산출물 지원은 없다 — 실시간 계약(정확히 1.1)만 검증한다.
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
        # selective consistency LOW 트리거를 우회하는 것을 차단한다.
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
    # stability_status는 aggregate envelope 전용 필드다 — 개별 Arbiter는 산출할 수
    # 없으므로 개별 entry에 두지 않는다. 자리표시자 'N/A'를 요구하면 아무도 읽지
    # 않는 필드가 계약 표면에 남고, 값을 허용하면 aggregate 상태 환각 경로가 열린다.
    if "stability_status" in entry:
        violations.append(
            "stability_status는 aggregate 전용 필드 — 개별 entry에 출력 금지 "
            f"(got {entry['stability_status']!r})"
        )
    if isinstance(axes, dict) and axes.get("portability") not in ("PASS", "FAIL", "N/A"):
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
    # evidence_scope는 PLAUSIBILITY_FAIL 기각의 ledger 수명주기를 결정하므로
    # 그 경우에만 필수다 — 기록자가 사람용 rationale 재해석 없이 영속 여부를 판단한다.
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
    """--expect-findings manifest 양방향 대조 위반 목록 (누락·미지 ID)."""
    issues = [f"기대 finding 누락: {fid}" for fid in sorted(expected_ids - found_ids)]
    issues += [f"manifest 밖 finding: {fid}" for fid in sorted(found_ids - expected_ids)]
    return issues


def parse_and_check_manifest(paths, expected_ids):
    """파일별 (entries, malformed, manifest 위반)을 한 번에 산출하는 공통 흐름.

    validate-only와 N=3 집계가 같은 파싱·manifest 대조 결과를 소비하도록
    두 분기의 조립을 여기로 모은다 (동일 계약이 두 제어 흐름에 복제되지 않게 한다).
    """
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
      malformed_count: int — 수 보존. caller는 malformed>0을 partial_failure로 승격.

    방어 규칙:
      - JSONDecodeError: malformed 카운트 +1, 해당 block skip.
      - json 결과가 dict가 아니면(list/str/null 등): malformed +1, skip.
      - finding_id 누락/비문자열: malformed +1, skip.
      - validate_verdict_entry() 위반 (schema 1.1 계약 전체): malformed +1, skip.
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


def classify_vote_shape(verdicts):
    """Classify verdicts into vote-shape and stability_status (N=3 정책).

    Args:
        verdicts: list of verdict strings (each in VERDICT_CATEGORIES)

    Returns:
        (vote_shape, majority_verdict, stability_status)
        - 3:0 → stable (majority_verdict is the unanimous verdict)
        - 2:1 → split (majority_verdict is the majority)
        - 1:1:1 → fragmented (majority_verdict is None)
        Non-N=3 inputs: `stability_status="unknown"`, `vote_shape`는 관측된 카운트
        문자열 그대로 반환(예: N=2에서 `"2"` 또는 `"1:1"`, N=4에서 `"4"` 등). v1 정책
        범위 밖이므로 caller는 `stability_status=="unknown"`으로 판정하면 된다.
    """
    counts = Counter(verdicts)
    sorted_counts = sorted(counts.values(), reverse=True)
    if sorted_counts == [3]:
        # "3:0" 표기로 통일 (stability-measurement.md와 일치).
        return "3:0", counts.most_common(1)[0][0], "stable"
    if sorted_counts == [2, 1]:
        return "2:1", counts.most_common(1)[0][0], "split"
    if sorted_counts == [1, 1, 1]:
        return "1:1:1", None, "fragmented"
    # N ≠ 3 이거나 unexpected shape (e.g., N=2, N=4). 정책 범위 밖.
    return ":".join(str(c) for c in sorted_counts), None, "unknown"


# Confidence 순서 (HIGH > MEDIUM > LOW > N/A). selective consistency에서 stable unanimous이더라도
# 어떤 Arbiter 하나라도 LOW를 보고했으면 fail-closed 경로를 유지하기 위해 min_confidence를 전파한다.
_CONFIDENCE_RANK = {"HIGH": 3, "MEDIUM": 2, "LOW": 1, "N/A": 0}


def min_confidence(confidences):
    """Return the lowest confidence level among entries, or 'N/A' if empty.

    HIGH > MEDIUM > LOW > N/A. 'N/A'는 판정 불가이므로 실질 최하로 간주하지 않고 별도 표시.
    """
    ranked = [c for c in confidences if c in _CONFIDENCE_RANK]
    if not ranked:
        return "N/A"
    # N/A를 제외한 실제 confidence 값 중 최소. 모두 N/A이면 N/A.
    real = [c for c in ranked if c != "N/A"]
    if not real:
        return "N/A"
    return min(real, key=lambda c: _CONFIDENCE_RANK[c])


def fleiss_kappa(findings):
    """Compute Fleiss' kappa for N raters per item, across multiple items.

    Fleiss 1971, "Measuring Nominal Scale Agreement among Many Raters".

    Args:
        findings: list of per-item verdict lists. Each inner list has N verdicts
                  (raters), all drawn from VERDICT_CATEGORIES.

    Returns:
        kappa in [-1, 1]. Returns float('nan') if ill-defined:
        - empty input
        - fewer than 2 raters
        - unanimous marginal distribution (P_e == 1)

    Raises:
        ValueError if rater counts differ across items.
    """
    if not findings:
        return float("nan")

    n_raters = len(findings[0])
    if any(len(f) != n_raters for f in findings):
        raise ValueError("all findings must have the same number of raters")
    if n_raters < 2:
        return float("nan")

    n_items = len(findings)

    # n_ij: rater count matrix (item i, category j)
    n_ij = []
    for verdicts in findings:
        row = [verdicts.count(cat) for cat in VERDICT_CATEGORIES]
        n_ij.append(row)

    # p_j: marginal proportion of category j across all ratings
    total_ratings = n_items * n_raters
    p_j = [
        sum(row[j] for row in n_ij) / total_ratings
        for j in range(len(VERDICT_CATEGORIES))
    ]

    # P_i: agreement proportion on item i
    P_i = []
    for row in n_ij:
        squared_sum = sum(count * count for count in row)
        P_i.append((squared_sum - n_raters) / (n_raters * (n_raters - 1)))

    P_bar = sum(P_i) / n_items
    P_e = sum(p * p for p in p_j)

    if P_e == 1.0:
        return float("nan")
    return (P_bar - P_e) / (1 - P_e)


def interpret_kappa(kappa):
    """Map kappa to interpretation label using stability-measurement.md thresholds.

    Returns "undefined" for NaN, "stable"/"moderate"/"poor" otherwise.
    """
    if kappa != kappa:  # NaN check without importing math
        return "undefined"
    if kappa >= STABLE_MIN:
        return "stable"
    if kappa >= ESCALATE_MIN:
        return "moderate"
    return "poor"


def main():
    parser = argparse.ArgumentParser(
        description=(
            "Run-DA VERDICT_JSON validator + selective consistency aggregator. "
            "--validate-only는 schema 1.1 계약과 finding manifest 대조만 수행한다 "
            "(first-pass caller 검증). 기본 경로는 정확히 3개 Arbiter 결과 markdown에서 "
            "vote-shape를 계산한다 (3 아닌 입력은 'unknown'으로 분류). "
            "--offline 플래그로 corpus-level Fleiss kappa를 장기 관찰 목적으로 추가 계산."
        ),
    )
    parser.add_argument(
        "arbiter_files",
        nargs="+",
        type=Path,
        help="Arbiter result markdown files containing VERDICT_JSON blocks (v1 vote-shape는 N=3 정책)",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help=(
            "집계 없이 각 입력 파일의 VERDICT_JSON schema 1.1 계약과 finding manifest 대조를 "
            "검증하고 JSON 결과를 출력한다 (first-pass caller 검증용 — protocol.md 수렴 판정 SSOT)"
        ),
    )
    parser.add_argument(
        "--expect-findings",
        help=(
            "쉼표 구분 finding ID manifest (실시간 경로 필수). 각 파일의 유효 finding ID "
            "집합이 이 집합과 정확히 일치해야 한다 — 누락·미지 ID는 위반 (finding 소실 차단). "
            "N=3 집계에서도 이 집합 기준으로 missing을 판정한다"
        ),
    )
    parser.add_argument(
        "--offline",
        action="store_true",
        help=(
            "Also compute corpus-level Fleiss kappa (offline observation only; "
            "not a v1 runtime gate — see stability-measurement.md)"
        ),
    )
    args = parser.parse_args()

    expected_ids, arg_error = resolve_expected_ids(args)
    if arg_error:
        print(f"error: {arg_error}", file=sys.stderr)
        return 1

    parsed = parse_and_check_manifest(args.arbiter_files, expected_ids)

    if args.validate_only:
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

    arbiter_entries = [item["entries"] for item in parsed]
    per_file_malformed = [item["malformed"] for item in parsed]
    # 파일이 아예 비었거나 모든 블록이 malformed인 경우 file-level failure.
    # caller는 이 상태를 partial_failure로 간주하여 BLOCKED 처리해야 한다.
    file_level_failures = [
        i
        for i, entries in enumerate(arbiter_entries)
        if len(entries) == 0
    ]
    manifest_violations = {}
    for item in parsed:
        if item["manifest_violations"]:
            manifest_violations[str(item["path"])] = item["manifest_violations"]
    # manifest 기준 집계: 세 Arbiter가 모두 같은 finding을 누락해도 missing으로 잡힌다
    # (관측된 ID의 union을 쓰면 공통 누락이 집합에서 사라져 조용히 통과한다).
    all_finding_ids = set(expected_ids)

    per_finding = []
    missing = {}
    for fid in sorted(all_finding_ids):
        verdicts = []
        confidences = []
        entries_for_finding = []
        missing_indices = []
        for i, entries in enumerate(arbiter_entries):
            entry = entries.get(fid)
            v = entry.get("verdict") if entry else None
            if v in VERDICT_CATEGORIES:
                verdicts.append(v)
                confidences.append(entry.get("confidence", "N/A"))
                entries_for_finding.append(entry)
            else:
                missing_indices.append(i)
        if missing_indices:
            # Fail-closed: any Arbiter missing a verdict for this finding excludes it
            # from vote-shape classification. protocol.md는 이 경우를 partial_failure로
            # 처리하며, AskUser 미지원 런타임에서는 BLOCKED 상태 지정.
            missing[fid] = {
                "missing_arbiter_indices": missing_indices,
                "partial_verdicts": verdicts,
            }
            continue
        shape, majority, status = classify_vote_shape(verdicts)
        lowest_confidence = min_confidence(confidences)
        # stable + unanimous verdict이라도 Arbiter 중 하나가 LOW confidence면 fail-closed 승격 필요.
        # protocol.md "Arbiter 출력 요건"에 따라 caller는 low_confidence_warning=true를
        # stable 상태에서도 NEEDS_MORE_INFO 경로로 취급한다.
        low_confidence_warning = lowest_confidence == "LOW"
        per_finding.append(
            {
                "finding_id": fid,
                # Aggregate envelope: 원본 VERDICT_JSON entries를 그대로 보존하여
                # caller가 axes/schema_version 등을 재접근할 수 있도록 한다.
                "entries": entries_for_finding,
                # 편의 필드 (entries에서 파생):
                "verdicts": verdicts,
                "confidences": confidences,
                # 집계 결과:
                "vote_shape": shape,
                "majority_verdict": majority,
                "min_confidence": lowest_confidence,
                "low_confidence_warning": low_confidence_warning,
                "stability_status": status,
            }
        )

    result = {
        "n_arbiters": len(args.arbiter_files),
        "n_findings": len(all_finding_ids),
        "n_classified": len(per_finding),
        "per_finding": per_finding,
        "per_file_malformed": per_file_malformed,
    }

    partial_failure = False
    if manifest_violations:
        # --expect-findings 양방향 대조 위반 (누락·미지 ID) — finding 소실/오염 차단.
        result["manifest_violations"] = manifest_violations
        partial_failure = True
    if missing:
        result["missing"] = missing
        partial_failure = True
    if file_level_failures:
        # 파일이 비어 있거나 전부 malformed — arbiter-scaling.md "Selective consistency N=3 partial failure"
        # 계약에 따라 BLOCKED 처리되어야 한다.
        result["file_level_failures"] = file_level_failures
        partial_failure = True
    if any(m > 0 for m in per_file_malformed):
        partial_failure = True
    if partial_failure:
        result["partial_failure"] = True

    if args.offline:
        # Fleiss kappa is a corpus-level metric (requires ≥2 items to be meaningful).
        # See stability-measurement.md: v1에서 kappa는 offline 관찰 전용.
        complete_verdict_matrix = [f["verdicts"] for f in per_finding]
        if len(complete_verdict_matrix) >= 2:
            kappa = fleiss_kappa(complete_verdict_matrix)
            result["kappa"] = kappa
            result["kappa_interpretation"] = interpret_kappa(kappa)
        else:
            result["kappa"] = None
            result["kappa_interpretation"] = "insufficient_items"
        result["kappa_thresholds"] = {
            "STABLE_MIN": STABLE_MIN,
            "ESCALATE_MIN": ESCALATE_MIN,
        }

    json.dump(result, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    sys.exit(main())
