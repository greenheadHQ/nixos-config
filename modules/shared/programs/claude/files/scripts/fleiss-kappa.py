#!/usr/bin/env python3
"""Run-DA Arbiter selective consistency harness (N=3 policy + optional offline Fleiss kappa).

v1 정책: selective consistency가 발동한 finding에 대해 **N=3 독립 Arbiter** 결과를 받아
vote-shape(3:0 / 2:1 / 1:1:1)와 stability_status(stable / split / fragmented)를 계산한다.
입력 파일이 정확히 3개가 아니면 vote-shape는 "unknown"으로 분류되어 v1 정책 범위 밖이다.

Each file must contain VERDICT_JSON blocks (schema_version=1.0) with per-finding verdicts
as defined in arbiter-prompt.md "출력 형식" section.

With --offline flag, also compute corpus-level Fleiss' kappa across findings
(Fleiss 1971, chance-corrected agreement among N raters on categorical verdicts).
Kappa는 **배포 후 장기 관찰 지표**이며 v1 실시간 분기에는 사용하지 않는다.
corpus 전용이므로 2개 이상의 finding이 있어야 정의된다.

Threshold policy SSOT: stability-measurement.md (STABLE_MIN / ESCALATE_MIN).

Usage:
    fleiss-kappa.py <arbiter1.md> <arbiter2.md> <arbiter3.md> [--offline]

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

# 지원되는 VERDICT_JSON 스키마 major 버전. breaking change 시 이 set을 갱신.
SUPPORTED_SCHEMA_MAJOR = {"1"}

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
      - schema_version이 SUPPORTED_SCHEMA_MAJOR에 없으면: malformed +1, skip.
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
        if not isinstance(finding_id, str) or not finding_id:
            print(
                f"warning: VERDICT_JSON without valid finding_id in {markdown_path}",
                file=sys.stderr,
            )
            malformed += 1
            continue
        # schema_version 검증: 없으면 보수적으로 skip (1.0 assumed만 허용).
        sv = entry.get("schema_version")
        if sv is not None:
            major = str(sv).split(".", 1)[0]
            if major not in SUPPORTED_SCHEMA_MAJOR:
                print(
                    f"warning: unsupported schema_version={sv!r} in {markdown_path}",
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
        # confidence enum strict validation (arbiter-prompt.md "출력 형식" 스키마).
        conf = entry.get("confidence")
        if conf is not None and conf not in CONFIDENCE_VALUES:
            print(
                f"warning: invalid confidence={conf!r} in {markdown_path} (finding_id={finding_id})",
                file=sys.stderr,
            )
            malformed += 1
            continue
        # verdict enum 검증 — downstream에서도 거르지만 조기 거부로 caller 계약 명확화.
        v = entry.get("verdict")
        if v is not None and v not in VERDICT_CATEGORIES:
            print(
                f"warning: invalid verdict={v!r} in {markdown_path} (finding_id={finding_id})",
                file=sys.stderr,
            )
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
        "--offline",
        action="store_true",
        help=(
            "Also compute corpus-level Fleiss kappa (offline observation only; "
            "not a v1 runtime gate — see stability-measurement.md)"
        ),
    )
    args = parser.parse_args()

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
    for entries in arbiter_entries:
        all_finding_ids.update(entries.keys())

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
    main()
