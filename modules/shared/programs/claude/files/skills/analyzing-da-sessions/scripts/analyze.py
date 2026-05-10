#!/usr/bin/env python3
"""DA 세션 정량 분석 — analyzing-da-sessions Skill의 algorithm SSOT.

PR #670 정정 코멘트의 알고리즘 (분모 정정 + 4-tier fallback + source/confidence 라벨링)
+ severity 전이 + StabilitySource resolver를 통합한 단일 진입점.

Internal boundary:
  - constants/enums          — VERDICT_CATEGORIES, INTENSITY_VERDICTS, BUNDLE_MAP, regex 등
  - jsonl payload walker     — extract_text_payloads
  - finding_id normalizer    — get_bundle
  - verdict parser pipeline  — extract_strict_verdicts, extract_unmarked_json_verdicts,
                                extract_kv_verdicts, extract_nl_summary, extract_intensity_verdicts
  - severity transition      — find_severity_for_finding, severity_rank, compute_severity_transitions
  - stability source         — resolve_stability_status_from_round_summary (round summary 전용)
  - aggregate builder        — analyze_session, build_aggregate
  - markdown renderer        — render_markdown
  - json renderer            — render_json
  - host handling            — collect_local_files, collect_remote_files, fetch_remote_file,
                                analyze_remote_session, _validate_host, _validate_remote_path

CLI:
  --hosts <comma list>     default: mac,minipc. whitelist {mac, minipc} reject-fast.
  --corpus <path>          pinned manifest.json (files + snapshot_id 소비).
  --json out=<path>        JSON sidecar 경로 override (default: /tmp/analyze-da-sessions-<ISO>.json).

Output:
  stdout                  markdown 표 + 요약
  JSON sidecar            같은 aggregate 객체에서 렌더링 (불일치 위험 차단)
"""

import argparse
import concurrent.futures
import datetime
import glob
import json
import os
import platform
import posixpath
import re
import subprocess
import sys
from collections import Counter, defaultdict
from typing import Any, Iterable

# ─────────────────────────────────────────────────────────────────────────────
# 1. constants/enums
# ─────────────────────────────────────────────────────────────────────────────

VALID_HOSTS = {"mac", "minipc"}

VERDICT_CATEGORIES = ("CONFIRMED_ISSUE", "NOT_AN_ISSUE", "NEEDS_MORE_INFO")
INTENSITY_VERDICTS = ("FULL", "LITE", "SKIP")

# 4-tier fallback patterns
ARBITER_DIR_MARKER = re.compile(r"/tmp/da-[a-fA-F0-9]+-arbiter-(?!XXXXXX\b)[A-Za-z0-9]+")
INTENSITY_DIR_MARKER = re.compile(r"/tmp/da-[a-fA-F0-9]+-intensity-(?!XXXXXX\b)[A-Za-z0-9]+")
VERDICT_JSON_BLOCK = re.compile(
    r"<!--\s*verdict-json:start\s*-->\s*```json\s*(.*?)\s*```\s*<!--\s*verdict-json:end\s*-->",
    re.S,
)
HUMAN_VERDICT_HEADER = re.compile(
    r"###\s+([A-Za-z][A-Za-z_ ]*?(?:[-]\d+|\s+Finding\s+\d+))\s*[—\-]\s*(CONFIRMED_ISSUE|NOT_AN_ISSUE|NEEDS_MORE_INFO)"
)
FENCED_JSON_BLOCK = re.compile(r"```json\s*(\[?\s*\{.*?\}\s*\]?)\s*```", re.S)
VERDICT_KV = re.compile(
    r"\*\*판정\*\*\s*[:：]\s*\*?\*?(CONFIRMED_ISSUE|NOT_AN_ISSUE|NEEDS_MORE_INFO)\*?\*?"
)
NL_SUMMARY = re.compile(r"(CONFIRMED(?:_ISSUE)?|NOT_AN_ISSUE|NEEDS_MORE_INFO)\s*(\d+)\s*건")
ARBITER_RESULT_HEADER_COUNT = re.compile(r"Arbiter\s+검증\s+결과\s*[:：]?\s*(\d+)\s*건")

# Intensity verdict (인라인 체크리스트 출력의 첫 토큰 — Step 0 결과 라벨)
INTENSITY_VERDICT_LINE = re.compile(
    r"(?:^|\n)\s*\**\s*(?:Review\s+Intensity|검토\s+강도|판정)\s*\**\s*[:：]?\s*\*?\*?(SKIP|LITE|FULL)\*?\*?",
    re.I,
)

# Severity (M-4) — analyze-da-sessions.py SSOT
SEV_LINE = re.compile(
    r"\*\*심각도\*\*\s*[:：]\s*\*?\*?(CRITICAL|HIGH|MEDIUM|LOW)\*?\*?", re.I
)
SEVERITY_RANK = {"CRITICAL": 4, "HIGH": 3, "MEDIUM": 2, "LOW": 1}

# Finding ID normalize
FINDING_ID_NORMALIZE = re.compile(
    r"(Correctness|Design|Regression|Maintainability)[-\s]*(?:Finding\s+)?(\d+)", re.I
)
FINDING_ID_LEGACY = re.compile(
    r"(YAGNI|NGMI|HALLUCINATION|SECURITY|SIDE_EFFECT|CONSISTENCY|READABILITY|CLEAN_CODE)-(\d+)",
    re.I,
)
BUNDLE_MAP = {
    "correctness": "Correctness",
    "hallucination": "Correctness",
    "security": "Correctness",
    "design": "Design",
    "yagni": "Design",
    "ngmi": "Design",
    "regression": "Regression",
    "side_effect": "Regression",
    "consistency": "Regression",
    "maintainability": "Maintainability",
    "readability": "Maintainability",
    "clean_code": "Maintainability",
}

# Round summary `selective:` line (M-5 fallback source)
SELECTIVE_LINE = re.compile(
    r"selective\s*:\s*trigger\s+(\d+)건.*?stable\s+(\d+)건.*?split\s+(\d+)건.*?fragmented\s+(\d+)건",
    re.I,
)

# Host path mapping —
#   command path:    SSH 명령 인자는 `~/.claude/projects` 등 relative tilde 표현을 사용한다
#                    (remote shell이 expansion). 본 map은 명령 인자에 직접 들어가지 않는다.
#   validation path: `_allowed_remote_path` boundary check가 본 absolute prefix와 비교하여
#                    SSH find stdout 비신뢰 line을 검증한다.
#   corpus path:     `--corpus manifest.json` 모드에서 host 분류 prefix로도 사용한다 (D-6).
HOST_PATH_MAP = {
    "mac": {
        "claude": "/Users/green/.claude/projects",
        "codex": "/Users/green/.codex/sessions",
    },
    "minipc": {
        "claude": "/home/greenhead/.claude/projects",
        "codex": "/home/greenhead/.codex/sessions",
    },
}

# Operational tunables — adjust here when window sizes / timeouts need recalibration
ARBITER_WINDOW_CHARS = 30000  # KV verdict 회수 시 Arbiter 결과 헤더 뒤 고정 window 크기
SEVERITY_LOOKBEHIND_CHARS = 200  # finding_id 등장 위치 기준 앞쪽 탐색 범위 (severity 라벨 회수)
SEVERITY_LOOKAHEAD_CHARS = 1000  # finding_id 등장 위치 기준 뒤쪽 탐색 범위
SSH_FIND_TIMEOUT_SECONDS = 60  # 원격 호스트의 find 명령 timeout
SSH_CAT_TIMEOUT_SECONDS = 120  # 원격 호스트의 cat 명령 timeout
FLEISS_KAPPA_TIMEOUT_SECONDS = 60  # fleiss-kappa.py helper 호출 timeout (현재 v1에서는 미사용)
SSH_FETCH_WORKERS = 8  # 원격 호스트당 동시 SSH cat worker 수 (host 순차 처리, host당 K=8 병렬)
SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS = 10  # ssh -O check / ssh true preflight timeout


def current_host() -> str:
    """현재 머신을 mac/minipc로 분류."""
    if platform.system() == "Darwin":
        return "mac"
    return "minipc"


# ─────────────────────────────────────────────────────────────────────────────
# 2. jsonl payload walker
# ─────────────────────────────────────────────────────────────────────────────

def extract_text_payloads(obj: Any, accumulator: list) -> None:
    """JSONL record에서 string payload만 추출 (raw blob regex 금지)."""
    if isinstance(obj, str):
        accumulator.append(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            extract_text_payloads(v, accumulator)
    elif isinstance(obj, list):
        for v in obj:
            extract_text_payloads(v, accumulator)


# ─────────────────────────────────────────────────────────────────────────────
# 3. finding_id normalizer
# ─────────────────────────────────────────────────────────────────────────────

def get_bundle(finding_id: str | None) -> str | None:
    """finding_id의 reviewer 묶음 매핑."""
    if not finding_id:
        return None
    m = FINDING_ID_NORMALIZE.search(finding_id)
    if m:
        return BUNDLE_MAP.get(m.group(1).lower())
    m = FINDING_ID_LEGACY.search(finding_id)
    if m:
        return BUNDLE_MAP.get(m.group(1).lower())
    return None


# ─────────────────────────────────────────────────────────────────────────────
# 4. verdict parser pipeline (4-tier fallback)
# ─────────────────────────────────────────────────────────────────────────────

def extract_strict_verdicts(text: str, parse_failures: list | None = None) -> list[dict]:
    """Tier 1 (VERDICT_JSON marker)을 우선 적용, finding_id 단위로 Tier 2 (### header)
    fallback. 같은 finding_id가 두 source에 모두 있으면 Tier 1만 채택해 중복 카운트를 차단한다.
    parse_failures가 주어지면 JSON parse 실패를 silent swallow 대신 누적한다.
    """
    verdicts = []
    seen_finding_ids: set[str] = set()
    for m in VERDICT_JSON_BLOCK.finditer(text):
        try:
            v = json.loads(m.group(1))
        except Exception as e:
            if parse_failures is not None:
                snippet = m.group(1)[:80].replace("\n", " ")
                parse_failures.append(f"verdict_json parse error: {type(e).__name__}: {snippet}")
            continue
        finding_id = v.get("finding_id", "")
        verdicts.append({
            "finding_id": finding_id,
            "verdict": v.get("verdict", ""),
            "confidence": v.get("confidence", "N/A"),
            "stability_status": v.get("stability_status", "N/A"),
            "bundle": get_bundle(finding_id),
            "source": "verdict_json",
            "source_confidence": "high",
        })
        if finding_id:
            seen_finding_ids.add(finding_id)
    for m in HUMAN_VERDICT_HEADER.finditer(text):
        finding_id = m.group(1)
        # Tier 1에서 이미 회수된 finding은 skip (4-tier fallback 의무 — 중복 카운트 차단)
        if finding_id in seen_finding_ids:
            continue
        verdicts.append({
            "finding_id": finding_id,
            "verdict": m.group(2),
            "confidence": "N/A",
            "stability_status": "N/A",
            "bundle": get_bundle(finding_id),
            "source": "md_header",
            "source_confidence": "high",
        })
        seen_finding_ids.add(finding_id)
    return verdicts


def extract_unmarked_json_verdicts(text: str) -> list[dict]:
    """Tier 3: marker 없는 fenced JSON array/object에서 verdict 회수."""
    verdicts = []
    for m in FENCED_JSON_BLOCK.finditer(text):
        body = m.group(1)
        try:
            obj = json.loads(body)
        except Exception:
            continue
        items = obj if isinstance(obj, list) else [obj]
        for item in items:
            if not isinstance(item, dict):
                continue
            v = item.get("verdict")
            if v in VERDICT_CATEGORIES:
                verdicts.append({
                    "finding_id": item.get("finding_id", ""),
                    "verdict": v,
                    "confidence": item.get("confidence", "N/A"),
                    "stability_status": item.get("stability_status", "N/A"),
                    "bundle": get_bundle(item.get("finding_id", "")),
                    "source": "json_unmarked",
                    "source_confidence": "high",
                })
    return verdicts


def extract_kv_verdicts(text: str, arbiter_window_only: bool = True) -> list[dict]:
    """Tier 4: KV `**판정**: VERDICT`. Arbiter 결과 헤더 window 안만."""
    verdicts = []
    if arbiter_window_only:
        for m in re.finditer(r"##\s+Arbiter\s+검증\s+결과", text):
            start = m.end()
            end = min(len(text), start + ARBITER_WINDOW_CHARS)
            window = text[start:end]
            nxt = re.search(r"\n##\s", window)
            if nxt:
                window = window[: nxt.start()]
            for vm in VERDICT_KV.finditer(window):
                verdicts.append({
                    "finding_id": "",
                    "verdict": vm.group(1),
                    "confidence": "N/A",
                    "stability_status": "N/A",
                    "bundle": None,
                    "source": "kv",
                    "source_confidence": "medium",
                })
    return verdicts


def extract_nl_summary(text: str) -> tuple[bool, int]:
    """Tier 5 (session-only): NL summary signal. finding-level 분포 미포함."""
    has_signal = False
    estimated_count = 0
    for m in ARBITER_RESULT_HEADER_COUNT.finditer(text):
        has_signal = True
        estimated_count = max(estimated_count, int(m.group(1)))
    for _ in NL_SUMMARY.finditer(text):
        has_signal = True
    return has_signal, estimated_count


def extract_intensity_verdicts(text: str) -> list[str]:
    """M-1: 인라인 체크리스트 출력에서 SKIP/LITE/FULL 첫 토큰 추출."""
    return [m.group(1).upper() for m in INTENSITY_VERDICT_LINE.finditer(text)]


# ─────────────────────────────────────────────────────────────────────────────
# 5. severity transition extractor (M-4, plan D-9 SSOT 정정)
# ─────────────────────────────────────────────────────────────────────────────

def severity_rank(s: str | None) -> int:
    return SEVERITY_RANK.get((s or "").upper(), 0)


def severity_label(rank: int) -> str:
    for label, r in SEVERITY_RANK.items():
        if r == rank:
            return label
    return "NONE"


def find_severity_for_finding(text_blob: str, finding_id: str) -> str | None:
    """analyze-da-sessions.py 패턴: finding header 인접 영역에서 severity 라벨 추출."""
    if not finding_id:
        return None
    # finding_id 등장 위치의 앞뒤 window에서 severity 라벨 검색
    for m in re.finditer(re.escape(finding_id), text_blob):
        start = max(0, m.start() - SEVERITY_LOOKBEHIND_CHARS)
        end = min(len(text_blob), m.end() + SEVERITY_LOOKAHEAD_CHARS)
        window = text_blob[start:end]
        sm = SEV_LINE.search(window)
        if sm:
            return sm.group(1).upper()
    return None


def compute_severity_transitions(
    rounds_data: list[list[dict]],
) -> Counter:
    """라운드별 confirmed finding 집합의 max severity 전이 매트릭스.

    rounds_data: list of [verdict dict, ...] per round.
    Returns Counter of (from_label, to_label) tuples.
    """
    transitions: Counter = Counter()
    for i in range(len(rounds_data) - 1):
        cur_confirmed = [v for v in rounds_data[i] if v.get("verdict") == "CONFIRMED_ISSUE"]
        nxt_confirmed = [v for v in rounds_data[i + 1] if v.get("verdict") == "CONFIRMED_ISSUE"]
        cur_max = max(
            (severity_rank(v.get("severity")) for v in cur_confirmed), default=0
        )
        nxt_max = max(
            (severity_rank(v.get("severity")) for v in nxt_confirmed), default=0
        )
        transitions[(severity_label(cur_max), severity_label(nxt_max))] += 1
    return transitions


# ─────────────────────────────────────────────────────────────────────────────
# 6. stability source resolver (M-5, plan D-10)
# ─────────────────────────────────────────────────────────────────────────────

def resolve_stability_status_from_round_summary(text: str) -> Counter:
    """M-5 v1 source: round summary `selective:` 라인 파싱.

    개별 Arbiter VERDICT_JSON의 `stability_status`는 항상 `N/A`이므로 source 대상 아님.
    `fleiss-kappa.py` aggregate envelope 호출은 selective consistency arbiter result 디렉터리를
    session-level에서 직접 추적해야 하는데, 본 Skill의 전체 corpus 스캔 모델에서는 그 경계가
    자연스럽지 않다 — v1은 round summary 패턴만 사용하고, 둘 다 부재 시 unavailable로 보고한다.
    """
    counter: Counter = Counter()
    for m in SELECTIVE_LINE.finditer(text):
        # trigger, stable, split, fragmented 카운트 누적
        counter["stable"] += int(m.group(2))
        counter["split"] += int(m.group(3))
        counter["fragmented"] += int(m.group(4))
    return counter


# ─────────────────────────────────────────────────────────────────────────────
# 7. aggregate builder
# ─────────────────────────────────────────────────────────────────────────────

def analyze_session(path: str) -> dict | None:
    """단일 jsonl 세션 분석. 모든 metric 입력을 추출하여 dict로 반환."""
    has_arbiter_marker = False
    has_intensity_marker = False
    intensity_verdicts: list[str] = []
    all_verdicts: list[dict] = []
    nl_signal_only = False
    nl_estimated = 0
    full_text = []
    parse_failures: list[str] = []

    try:
        with open(path, "r", errors="replace") as fp:
            for line in fp:
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                payloads: list[str] = []
                extract_text_payloads(obj, payloads)
                for text in payloads:
                    full_text.append(text)
                    if ARBITER_DIR_MARKER.search(text):
                        has_arbiter_marker = True
                    if INTENSITY_DIR_MARKER.search(text):
                        has_intensity_marker = True

                    intensity_verdicts.extend(extract_intensity_verdicts(text))

                    sv = extract_strict_verdicts(text, parse_failures)
                    if sv:
                        all_verdicts.extend(sv)
                        continue
                    uj = extract_unmarked_json_verdicts(text)
                    if uj:
                        all_verdicts.extend(uj)
                        continue
                    kv = extract_kv_verdicts(text, arbiter_window_only=True)
                    if kv:
                        all_verdicts.extend(kv)
                        continue
                    has_signal, est = extract_nl_summary(text)
                    if has_signal:
                        nl_signal_only = True
                        nl_estimated = max(nl_estimated, est)
    except Exception:
        return None

    text_blob = "\n".join(full_text)
    # severity 라벨링 — finding_id 인접 window에서 수집
    for v in all_verdicts:
        if v.get("verdict") == "CONFIRMED_ISSUE" and v.get("finding_id"):
            sev = find_severity_for_finding(text_blob, v["finding_id"])
            if sev:
                v["severity"] = sev

    return {
        "path": path,
        "has_arbiter_marker": has_arbiter_marker,
        "has_intensity_marker": has_intensity_marker,
        "intensity_verdicts": intensity_verdicts,
        "verdicts": all_verdicts,
        "nl_signal_only": nl_signal_only,
        "nl_estimated_count": nl_estimated,
        "round_summary_stability": resolve_stability_status_from_round_summary(text_blob),
        "parse_failures": parse_failures,
    }


def build_aggregate(
    sessions: list[dict],
    hosts: list[str],
    corpus_label: str,
    warnings: list[str],
) -> dict:
    """모든 세션 분석 결과를 통합 aggregate 객체로 빌드."""
    arbiter_marker_sessions = [s for s in sessions if s and s["has_arbiter_marker"]]
    intensity_marker_sessions = [s for s in sessions if s and s["has_intensity_marker"]]

    # parse_failures (verdict_json JSON parse error 등)를 warnings에 누적해 silent swallow 차단
    parse_failure_total = 0
    for s in sessions:
        if s and s.get("parse_failures"):
            parse_failure_total += len(s["parse_failures"])
    if parse_failure_total > 0:
        warnings.append(
            f"verdict_json parse failures: {parse_failure_total}건 — diagnostics는 session-level parse_failures 참조"
        )

    # M-1: 검토 강도 verdict 분포
    m1_counter: Counter = Counter()
    for s in intensity_marker_sessions:
        for v in s["intensity_verdicts"]:
            if v in INTENSITY_VERDICTS:
                m1_counter[v] += 1
    m1_n = sum(m1_counter.values())

    # M-2: 판정자 verdict 분포 (high+medium confidence subset)
    m2_counter: Counter = Counter()
    source_counter: dict = defaultdict(lambda: {"count": 0, "confidence": ""})
    for s in arbiter_marker_sessions:
        for v in s["verdicts"]:
            if v["source"] in ("verdict_json", "md_header", "json_unmarked", "kv"):
                m2_counter[v["verdict"]] += 1
                src = v["source"]
                source_counter[src]["count"] += 1
                source_counter[src]["confidence"] = v["source_confidence"]
    m2_n = sum(m2_counter.values())

    # M-3: reviewer 묶음별 confirmed-rate
    bundle_total: Counter = Counter()
    bundle_confirmed: Counter = Counter()
    for s in arbiter_marker_sessions:
        for v in s["verdicts"]:
            b = v.get("bundle")
            if not b:
                continue
            bundle_total[b] += 1
            if v["verdict"] == "CONFIRMED_ISSUE":
                bundle_confirmed[b] += 1
    m3 = {}
    for b in ("Correctness", "Design", "Regression", "Maintainability"):
        total = bundle_total[b]
        confirmed = bundle_confirmed[b]
        m3[b] = {
            "total": total,
            "confirmed": confirmed,
            "confirmed_rate": (confirmed / total) if total else 0.0,
        }

    # M-4: severity transition (per-session round 그룹핑)
    transitions: Counter = Counter()
    for s in arbiter_marker_sessions:
        # 라운드 분리: arbiter marker 등장 횟수로 라운드 추정 (단순 휴리스틱).
        # session 안의 verdict 목록을 인접 그룹으로 나누어 round로 간주.
        verdicts = [v for v in s["verdicts"] if v["source"] in ("verdict_json", "md_header")]
        if len(verdicts) < 2:
            continue
        # 단순화: finding_id 중복 등장 시 새 round로 간주
        rounds: list[list[dict]] = []
        seen_ids: set = set()
        cur: list[dict] = []
        for v in verdicts:
            fid = v.get("finding_id", "")
            if fid in seen_ids and cur:
                rounds.append(cur)
                cur = []
                seen_ids = set()
            cur.append(v)
            if fid:
                seen_ids.add(fid)
        if cur:
            rounds.append(cur)
        if len(rounds) >= 2:
            transitions += compute_severity_transitions(rounds)

    # M-5: stability_status 분포
    m5_source = "round_summary_fallback"
    m5_counter: Counter = Counter()
    for s in arbiter_marker_sessions:
        m5_counter += s["round_summary_stability"]
    if not m5_counter:
        m5_source = "unavailable"
    m5_n = sum(m5_counter.values())

    # derived: intensity_full_finding_zero_rate
    full_sessions = [s for s in intensity_marker_sessions if "FULL" in s["intensity_verdicts"]]
    full_zero = [s for s in full_sessions if not any(
        v["verdict"] == "CONFIRMED_ISSUE" for v in s["verdicts"]
    )]
    intensity_full_zero_rate = (
        len(full_zero) / len(full_sessions) if full_sessions else 0.0
    )

    return {
        "schema_version": "1.0",
        "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "hosts": hosts,
        "corpus": corpus_label,
        "session_counts": {
            "total": len([s for s in sessions if s]),
            "arbiter_marker_sessions": len(arbiter_marker_sessions),
            "intensity_marker_sessions": len(intensity_marker_sessions),
        },
        "metrics": {
            "M-1": {
                "denominator": "intensity_marker_sessions",
                "n": m1_n,
                "distribution": dict(m1_counter),
                "percentages": {
                    k: round(100 * v / m1_n, 1) if m1_n else 0.0
                    for k, v in m1_counter.items()
                },
            },
            "M-2": {
                "denominator": "arbiter_marker_sessions_findings_high_medium",
                "n": m2_n,
                "distribution": dict(m2_counter),
                "percentages": {
                    k: round(100 * v / m2_n, 1) if m2_n else 0.0
                    for k, v in m2_counter.items()
                },
                "source_distribution": dict(source_counter),
            },
            "M-3": {"by_bundle": m3},
            "M-4": {"transition_matrix": {f"{a}->{b}": c for (a, b), c in transitions.items()}},
            "M-5": {
                "source": m5_source,
                "n": m5_n,
                "distribution": dict(m5_counter),
            },
        },
        "derived": {
            "intensity_full_finding_zero_rate": round(intensity_full_zero_rate, 3),
        },
        "warnings": warnings,
    }


# ─────────────────────────────────────────────────────────────────────────────
# 8. markdown renderer
# ─────────────────────────────────────────────────────────────────────────────

def render_markdown(agg: dict) -> str:
    out = []
    out.append(f"# DA 세션 정량 분석 — {agg['captured_at']}")
    out.append("")
    out.append("| 항목 | 값 |")
    out.append("|------|-----|")
    out.append(f"| 호스트 | {', '.join(agg['hosts'])} |")
    out.append(f"| corpus | {agg['corpus']} |")
    out.append(f"| 분석 파일 수 | {agg['session_counts']['total']} |")
    out.append(f"| Arbiter marker 세션 | {agg['session_counts']['arbiter_marker_sessions']} |")
    out.append(f"| Intensity marker 세션 | {agg['session_counts']['intensity_marker_sessions']} |")
    out.append("")

    # M-1
    m1 = agg["metrics"]["M-1"]
    out.append(f"## M-1: 검토 강도 verdict 분포 (n={m1['n']})")
    out.append("")
    out.append("| verdict | 카운트 | 비율 |")
    out.append("|---------|--------|------|")
    for v in INTENSITY_VERDICTS:
        c = m1["distribution"].get(v, 0)
        p = m1["percentages"].get(v, 0.0)
        out.append(f"| {v} | {c} | {p}% |")
    out.append("")
    if m1["n"]:
        out.append("```mermaid")
        out.append("pie title 검토 강도 verdict 분포")
        for v in INTENSITY_VERDICTS:
            c = m1["distribution"].get(v, 0)
            if c:
                out.append(f'  "{v}" : {c}')
        out.append("```")
        out.append("")

    # M-2
    m2 = agg["metrics"]["M-2"]
    out.append(f"## M-2: 판정자 verdict 분포 (n={m2['n']})")
    out.append("")
    out.append("| verdict | 카운트 | 비율 |")
    out.append("|---------|--------|------|")
    for v in VERDICT_CATEGORIES:
        c = m2["distribution"].get(v, 0)
        p = m2["percentages"].get(v, 0.0)
        out.append(f"| {v} | {c} | {p}% |")
    out.append("")
    if m2.get("source_distribution"):
        out.append("source 분포:")
        for src, info in m2["source_distribution"].items():
            out.append(f"- {src} ({info['confidence']}): {info['count']}")
        out.append("")

    # M-3
    m3 = agg["metrics"]["M-3"]
    out.append("## M-3: reviewer 묶음별 confirmed-rate")
    out.append("")
    out.append("| 묶음 | total | CONFIRMED_ISSUE | confirmed-rate |")
    out.append("|------|-------|-----------------|----------------|")
    for b, info in m3["by_bundle"].items():
        rate = info["confirmed_rate"]
        out.append(f"| {b} | {info['total']} | {info['confirmed']} | {rate * 100:.1f}% |")
    out.append("")

    # M-4
    m4 = agg["metrics"]["M-4"]
    out.append("## M-4: 동일 세션 max severity 전이 매트릭스")
    out.append("")
    if m4["transition_matrix"]:
        out.append("| from -> to | count |")
        out.append("|------------|-------|")
        for k, v in sorted(m4["transition_matrix"].items()):
            out.append(f"| {k} | {v} |")
    else:
        out.append("(전이 데이터 없음)")
    out.append("")

    # M-5
    m5 = agg["metrics"]["M-5"]
    out.append(f"## M-5: selective consistency stability_status 분포 (source: {m5['source']}, n={m5['n']})")
    out.append("")
    if m5["distribution"]:
        out.append("| stability_status | 카운트 |")
        out.append("|------------------|--------|")
        for k, v in m5["distribution"].items():
            out.append(f"| {k} | {v} |")
    else:
        out.append("(M-5 source unavailable)")
    out.append("")

    # Derived
    out.append("## Derived")
    out.append("")
    d = agg["derived"]
    out.append(f"- intensity_full_finding_zero_rate: {d['intensity_full_finding_zero_rate'] * 100:.1f}%")
    out.append("")

    # Warnings
    if agg["warnings"]:
        out.append("---")
        out.append("⚠ Warnings:")
        for w in agg["warnings"]:
            out.append(f"- {w}")

    return "\n".join(out)


# ─────────────────────────────────────────────────────────────────────────────
# 9. json renderer
# ─────────────────────────────────────────────────────────────────────────────

def render_json(agg: dict) -> str:
    return json.dumps(agg, indent=2, ensure_ascii=False)


# ─────────────────────────────────────────────────────────────────────────────
# Host handling
# ─────────────────────────────────────────────────────────────────────────────

def _validate_host(alias: str) -> None:
    if alias not in VALID_HOSTS:
        raise ValueError(f"invalid host: {alias!r}. valid: {sorted(VALID_HOSTS)}")


def collect_local_files(host: str) -> list[str]:
    """현재 머신의 jsonl 파일 glob."""
    _validate_host(host)
    paths = HOST_PATH_MAP[host]
    files = []
    for base, pattern in [
        (paths["claude"], "**/*.jsonl"),
        (paths["codex"], "**/rollout-*.jsonl"),
    ]:
        glob_path = os.path.join(base, pattern)
        for f in glob.glob(glob_path, recursive=True):
            if "/subagents/" not in f:
                files.append(f)
    return files


def _allowed_remote_path(host: str, path: str) -> bool:
    """원격 path가 정확한 base prefix 아래의 안전한 .jsonl 경로인지 확인.

    SSH remote command는 원격 shell이 해석하므로 shell metacharacter (`;`, `$()`,
    newline, backtick, space 등)가 포함된 경로는 명령 인젝션/word-splitting 위험이
    있다. 따라서 다음 검사를 통과시킨다:

    1. 제어문자/shell metacharacter/공백 부재.
    2. `.jsonl` 확장자.
    3. `posixpath.normpath`로 traversal(`../`) 정규화.
    4. `posixpath.isabs`로 relative path 폐기 (find stdout 비신뢰).
    5. `posixpath.commonpath([base_norm, path_norm]) == base_norm` boundary 비교 —
       sibling-prefix(`/Users/green/.claude/projects-evil/...`)는 commonpath가
       base_norm와 다르므로 거부. absolute/relative mix는 ValueError → 폐기.
    6. `path_norm != base_norm`로 base 자체 통과를 차단 (`.jsonl` 확장자 검사가
       이미 거부하지만 방어적 명시).
    """
    if not isinstance(path, str) or not path:
        return False
    # 제어문자 / shell metacharacter / space 거부
    if any(c in path for c in " \n\r\t;|&$`(){}[]<>*?\"'\\"):
        return False
    if not path.endswith(".jsonl"):
        return False
    try:
        path_norm = posixpath.normpath(path)
    except Exception:
        return False
    if not posixpath.isabs(path_norm):
        return False
    paths = HOST_PATH_MAP.get(host, {})
    bases = (paths.get("claude", ""), paths.get("codex", ""))
    for base in bases:
        if not base:
            continue
        base_norm = posixpath.normpath(base)
        try:
            if posixpath.commonpath([base_norm, path_norm]) == base_norm and path_norm != base_norm:
                return True
        except ValueError:
            # absolute/relative mix 등 — 폐기
            continue
    return False


def _validate_remote_path(host: str, path: str) -> None:
    if not _allowed_remote_path(host, path):
        raise ValueError(f"disallowed remote path for host {host}: {path!r}")


def collect_remote_files(host: str, warnings: list[str]) -> list[str]:
    """원격 호스트에서 jsonl 파일 path glob (subprocess.run 고정 argv).

    SSH 명령 인자에는 host-neutral relative tilde 표현 (`~/.claude/projects`,
    `~/.codex/sessions`)을 사용해 host별 absolute home prefix hardcoded를 피한다.
    원격 shell이 `~`를 해당 user의 home directory로 expansion한다.

    원격 find stdout의 path 라인은 비신뢰 입력으로 간주하여, `_allowed_remote_path`가
    통과한 line만 수집한다 — 제어문자/shell metacharacter/relative path/sibling-prefix
    포함 line은 silently 폐기한다. 검증은 absolute `HOST_PATH_MAP` prefix와의
    boundary 비교로 수행한다.
    """
    _validate_host(host)
    all_files: list[str] = []
    for base in ("~/.claude/projects", "~/.codex/sessions"):
        try:
            # SSH는 argv를 single string으로 합쳐 원격 shell에 전달하므로
            # `*.jsonl`을 single-quote로 감싸 원격 glob expansion을 차단한다.
            proc = subprocess.run(
                ["ssh", host, "find", base, "-type", "f", "-name", "'*.jsonl'"],
                capture_output=True,
                text=True,
                timeout=SSH_FIND_TIMEOUT_SECONDS,
            )
            if proc.returncode != 0:
                warnings.append(
                    f"host {host}: ssh find failed (rc={proc.returncode}) for {base}"
                )
                continue
            for line in proc.stdout.splitlines():
                if "/subagents/" in line:
                    continue
                if not _allowed_remote_path(host, line):
                    continue
                all_files.append(line)
        except subprocess.TimeoutExpired:
            warnings.append(f"host {host}: ssh find timeout for {base} — partial result")
        except FileNotFoundError:
            warnings.append(f"host {host}: ssh binary not found — partial result")
    return all_files


def fetch_remote_file(host: str, path: str, warnings: list[str]) -> str | None:
    """원격 jsonl 내용 가져오기. SSH 실패는 warnings 누적 + None 반환 (partial result)."""
    _validate_host(host)
    _validate_remote_path(host, path)
    try:
        proc = subprocess.run(
            ["ssh", host, "cat", path],
            capture_output=True,
            text=True,
            timeout=SSH_CAT_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        warnings.append(f"host {host}: ssh cat timeout for {path} — partial result")
        return None
    except FileNotFoundError:
        warnings.append(f"host {host}: ssh binary not found — partial result")
        return None
    if proc.returncode != 0:
        warnings.append(
            f"host {host}: ssh cat failed (rc={proc.returncode}) for {path} — partial result"
        )
        return None
    return proc.stdout


def check_controlmaster_active(host: str, warnings: list[str]) -> bool:
    """ControlMaster master socket이 활성인지 확인. 비활성이면 master 생성을 1회 시도 후 재확인.

    `ssh -O check <host>`는 master 부재 시 실패한다. 따라서 실패 시 일반 `ssh <host> true`로
    master 생성 시도 후 다시 `-O check`로 확인하는 2단계 sequence로 구성한다.

    반환값이 False이면 caller가 해당 host fetch를 skip한다 (fail-fast).
    """
    _validate_host(host)
    try:
        proc = subprocess.run(
            ["ssh", "-O", "check", host],
            capture_output=True,
            text=True,
            timeout=SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS,
        )
        if proc.returncode == 0:
            return True
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    # master 부재로 추정 — `ssh true`로 master 생성 시도
    try:
        gen = subprocess.run(
            ["ssh", host, "true"],
            capture_output=True,
            text=True,
            timeout=SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS,
        )
        if gen.returncode != 0:
            warnings.append(
                f"host {host}: ssh true (ControlMaster 생성 시도) 실패 (rc={gen.returncode}) — fetch skip"
            )
            return False
    except (subprocess.TimeoutExpired, FileNotFoundError):
        warnings.append(
            f"host {host}: ssh true 시간 초과 또는 binary 부재 — fetch skip"
        )
        return False
    # 재확인
    try:
        re_check = subprocess.run(
            ["ssh", "-O", "check", host],
            capture_output=True,
            text=True,
            timeout=SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS,
        )
        if re_check.returncode == 0:
            return True
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    warnings.append(
        f"host {host}: ControlMaster 재확인 실패 — fetch skip"
    )
    return False


def analyze_remote_session(host: str, path: str, warnings: list[str]) -> dict | None:
    """원격 jsonl을 fetch하여 임시 파일에 쓰고 analyze_session 호출."""
    content = fetch_remote_file(host, path, warnings)
    if content is None or not content:
        return None
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as tf:
        tf.write(content)
        tmp_path = tf.name
    try:
        return analyze_session(tmp_path)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


# ─────────────────────────────────────────────────────────────────────────────
# CLI
# ─────────────────────────────────────────────────────────────────────────────

def parse_hosts(s: str) -> list[str]:
    hosts = [h.strip() for h in s.split(",") if h.strip()]
    for h in hosts:
        if h not in VALID_HOSTS:
            raise argparse.ArgumentTypeError(
                f"invalid host: {h!r}. valid: {sorted(VALID_HOSTS)}"
            )
    return hosts


def parse_json_arg(s: str) -> str:
    """--json out=<path> 형식 파싱."""
    if s.startswith("out="):
        return s[4:]
    return s


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="analyze.py",
        description="DA 세션 정량 분석 — analyzing-da-sessions Skill SSOT",
    )
    parser.add_argument(
        "--hosts",
        type=parse_hosts,
        default=["mac", "minipc"],
        help="comma-separated host list (default: mac,minipc). whitelist: mac, minipc",
    )
    parser.add_argument(
        "--corpus",
        type=str,
        default=None,
        help="pinned manifest.json path for ±5% regression gate (default: live home log)",
    )
    parser.add_argument(
        "--json",
        type=parse_json_arg,
        default=None,
        help="JSON sidecar output path (default: /tmp/analyze-da-sessions-<ISO>.json)",
    )
    args = parser.parse_args()

    warnings: list[str] = []
    cur_host = current_host()

    # 파일 수집
    if args.corpus:
        # pinned corpus 모드
        try:
            with open(args.corpus, "r") as fp:
                manifest = json.load(fp)
        except Exception as e:
            print(f"ERROR: corpus manifest read failed: {e}", file=sys.stderr)
            return 1
        all_files = manifest.get("files", [])
        # host 분류는 HOST_PATH_MAP base prefix 순회 — 호스트 추가 시 한 곳만 수정.
        # 미매칭 path는 silent host 배정 대신 warning만 누적한다 (예전 단순 /Users/-mac
        # /home/-minipc fallback은 HOST_PATH_MAP 경계를 우회하는 별도 규칙이라 제거 —
        # 새 host 지원은 HOST_PATH_MAP에 명시 추가가 정답).
        # live mode와 동일하게 (a) /subagents/ 하위는 wrapper output이라 제외하고
        # (b) --hosts whitelist 밖 host로 분류된 path는 분석에서 제외한다.
        files_by_host: dict[str, list[str]] = defaultdict(list)
        for f in all_files:
            if "/subagents/" in f:
                continue
            matched_host = None
            for host_alias, host_paths in HOST_PATH_MAP.items():
                for base in (host_paths.get("claude", ""), host_paths.get("codex", "")):
                    if base and f.startswith(base + os.sep):
                        matched_host = host_alias
                        break
                if matched_host is not None:
                    break
            if matched_host is None:
                warnings.append(f"corpus host unclassified (HOST_PATH_MAP 미일치): {f}")
            elif matched_host in args.hosts:
                files_by_host[matched_host].append(f)
        corpus_label = manifest.get("snapshot_id", "pinned")
    else:
        files_by_host = defaultdict(list)
        for host in args.hosts:
            if host == cur_host:
                files_by_host[host] = collect_local_files(host)
            else:
                files_by_host[host] = collect_remote_files(host, warnings)
        corpus_label = "live"

    # 분석 — host 순차 처리, remote host는 ControlMaster preflight 후 worker pool dispatch.
    # 각 worker는 local warnings list로 분리 수집한 뒤 main thread에서 path 순으로 merge
    # 한다 (warning ordering deterministic 보장).
    sessions: list[dict] = []

    for host, files in files_by_host.items():
        is_remote = host != cur_host
        if not is_remote:
            # local: 직렬 처리 (파일 read는 빠름, 동시성 이득 미미)
            for path in files:
                result = analyze_session(path)
                if result is not None:
                    sessions.append(result)
            continue

        # 빈 remote files list (예: corpus 모드에서 해당 host 미분류 파일)는 ControlMaster
        # preflight 비용 (~30s timeout)을 회피해 즉시 다음 host로 진행한다.
        if not files:
            continue

        # remote: ControlMaster preflight + worker pool.
        # ControlMaster 비활성이면 K=1 강등이 5526 파일 직렬 fetch ≈ 37분으로 5분 timeout
        # 안에 끝나기 어려우므로 fail-fast로 host 전체 fetch를 skip하고 명시적 warning을
        # 누적한다. 사용자가 ControlMaster 활성화 (mac nrs 등) 누락을 즉시 인지할 수 있다.
        cm_active = check_controlmaster_active(host, warnings)
        if not cm_active:
            warnings.append(
                f"host {host}: ControlMaster 비활성으로 fetch skip — 활성화 후 재실행 필요"
                f" (직렬 fallback은 5분 budget 안에 완료 불가능). minipc는 nrs, mac은 사용자 수동 nrs."
            )
            continue

        # remote_warnings는 worker별로 분리 수집 후 main thread에서 path 순으로 merge.
        # CPython GIL이 list.append를 atomic하게 보장하지만 worker 간 순서가 비결정적이므로
        # 별도 list로 받아 deterministic ordering을 강제한다.
        def _fetch_one(p: str) -> tuple[str, dict | None, list[str]]:
            local_warnings: list[str] = []
            res = analyze_remote_session(host, p, local_warnings)
            return (p, res, local_warnings)

        host_results: list[tuple[str, dict | None, list[str]]] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=SSH_FETCH_WORKERS) as executor:
            futures = {executor.submit(_fetch_one, p): p for p in files}
            for fut in concurrent.futures.as_completed(futures):
                try:
                    host_results.append(fut.result())
                except Exception as e:
                    p = futures[fut]
                    host_results.append((p, None, [
                        f"host {host}: worker exception for {p}: {type(e).__name__}: {e}"
                    ]))

        # path 기준 정렬 후 sessions append + warnings merge (deterministic ordering).
        host_results.sort(key=lambda triple: triple[0])
        for _, result, local_warnings in host_results:
            if result is not None:
                sessions.append(result)
            warnings.extend(local_warnings)

    # aggregate
    agg = build_aggregate(sessions, args.hosts, corpus_label, warnings)

    # 출력: markdown stdout
    print(render_markdown(agg))

    # 출력: JSON sidecar
    if args.json:
        json_path = args.json
    else:
        ts = datetime.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
        json_path = f"/tmp/analyze-da-sessions-{ts}.json"
    try:
        with open(json_path, "w") as fp:
            fp.write(render_json(agg))
        print(f"\n---\nJSON sidecar: {json_path}", file=sys.stderr)
    except OSError as e:
        print(f"WARNING: JSON sidecar write failed: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
