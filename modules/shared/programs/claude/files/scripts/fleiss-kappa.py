#!/usr/bin/env python3
"""Run-DA Arbiter selective consistency harness (N=3 policy + optional offline Fleiss kappa).

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
    fleiss-kappa.py <arbiter1.md> <arbiter2.md> <arbiter3.md> \
        [--expect-findings <ID,ID,...>] [--offline]
    # first-pass caller 검증 (집계 없음 — 파일별 schema/manifest 검사 결과 JSON,
    # 전체 통과 시 exit 0 / 위반 시 exit 1)
    fleiss-kappa.py --validate-only --expect-findings <ID,ID,...> <result.md>

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
    finding_id의 존재·중복 검사는 parser(parse_verdict_json_blocks) 소관이고,
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
    if entry.get("stability_status") != "N/A":
        # stable/split/fragmented는 N=3 aggregate envelope 전용 — 개별 Arbiter
        # entry가 집계 상태를 환각하면 semantic malformed다 (arbiter-prompt.md).
        violations.append(
            f"개별 entry의 stability_status는 'N/A'만 허용: {entry.get('stability_status')!r}"
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
    return violations


def manifest_diff_violations(expected_ids, found_ids):
    """--expect-findings manifest 양방향 대조 위반 목록 (누락·미지 ID)."""
    issues = [f"기대 finding 누락: {fid}" for fid in sorted(expected_ids - found_ids)]
    issues += [f"manifest 밖 finding: {fid}" for fid in sorted(found_ids - expected_ids)]
    return issues


# arbiter-prompt.md "출력 형식 > 기계 파싱용 VERDICT_JSON 블록" 스키마와 일치
VERDICT_JSON_PATTERN = re.compile(
    r"<!-- verdict-json:start -->\s*```json\s*(?P<body>.+?)\s*```\s*<!-- verdict-json:end -->",
    re.DOTALL,
)


def parse_verdict_json_blocks(markdown_path: Path):
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
        if not isinstance(finding_id, str) or not re.fullmatch(r"[A-Za-z_]+-[0-9]+", finding_id):
            print(
                f"warning: VERDICT_JSON without valid finding_id in {markdown_path}",
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
            "Run-DA Arbiter selective consistency harness (N=3 vote-shape policy). "
            "v1에서는 정확히 3개 Arbiter 결과 markdown에서 vote-shape를 계산한다 "
            "(3 아닌 입력은 'unknown'으로 분류). "
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
            "집계 없이 각 입력 파일의 VERDICT_JSON schema 1.1 semantic 계약만 검증하고 "
            "JSON 결과를 출력한다 (first-pass caller 검증용 — protocol.md 수렴 판정 SSOT)"
        ),
    )
    parser.add_argument(
        "--expect-findings",
        help=(
            "쉼표 구분 finding ID manifest. 지정 시 각 파일의 유효 finding ID 집합이 "
            "이 집합과 정확히 일치해야 한다 — 누락·미지 ID는 위반 (finding 소실 차단). "
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

    expected_ids = None
    if args.expect_findings is not None:
        # 빈 문자열("")은 "옵션 미지정"이 아니라 인자 오류다 — truthiness 검사로 조용히
        # manifest 검증을 우회하는 경로(셸 변수 유실 등)를 차단한다.
        raw_ids = [fid.strip() for fid in args.expect_findings.split(",")]
        if "" in raw_ids or len(raw_ids) != len(set(raw_ids)):
            print(
                f"error: --expect-findings에 빈 항목 또는 중복 ID: {args.expect_findings!r}",
                file=sys.stderr,
            )
            return 1
        expected_ids = set(raw_ids)

    if args.validate_only:
        report = {"files": [], "ok": True}
        for path in args.arbiter_files:
            entries, malformed = parse_verdict_json_blocks(path)
            found_ids = set(entries.keys())
            manifest_violations = []
            if expected_ids is not None:
                manifest_violations = manifest_diff_violations(expected_ids, found_ids)
            file_ok = (
                malformed == 0 and len(entries) > 0 and not manifest_violations
            )
            report["files"].append(
                {
                    "path": str(path),
                    "valid_findings": sorted(found_ids),
                    "malformed_count": malformed,
                    "manifest_violations": manifest_violations,
                    "ok": file_ok,
                }
            )
            report["ok"] = report["ok"] and file_ok
        json.dump(report, sys.stdout, indent=2, ensure_ascii=False)
        print()
        return 0 if report["ok"] else 1

    # 각 Arbiter 파일에서 (entries, malformed_count) 수집.
    parsed = [parse_verdict_json_blocks(p) for p in args.arbiter_files]
    arbiter_entries = [entries for entries, _ in parsed]
    per_file_malformed = [mal for _, mal in parsed]
    # 파일이 아예 비었거나 모든 블록이 malformed인 경우 file-level failure.
    # caller는 이 상태를 partial_failure로 간주하여 BLOCKED 처리해야 한다.
    file_level_failures = [
        i
        for i, entries in enumerate(arbiter_entries)
        if len(entries) == 0
    ]
    all_finding_ids = set()
    manifest_violations = {}
    for i, entries in enumerate(arbiter_entries):
        all_finding_ids.update(entries.keys())
        if expected_ids is not None:
            issues = manifest_diff_violations(expected_ids, set(entries.keys()))
            if issues:
                manifest_violations[str(args.arbiter_files[i])] = issues
    if expected_ids is not None:
        # manifest 기준 집계: 세 Arbiter가 모두 같은 finding을 누락해도 missing으로 잡힌다.
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
