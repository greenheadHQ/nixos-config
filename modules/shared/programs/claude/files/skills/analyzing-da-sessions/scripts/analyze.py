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
import hashlib
import json
import os
import platform
import posixpath
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from typing import Any, Iterable

# ─────────────────────────────────────────────────────────────────────────────
# 1. constants/enums
# ─────────────────────────────────────────────────────────────────────────────

VALID_HOSTS = {"mac", "minipc"}

VERDICT_CATEGORIES = ("CONFIRMED_ISSUE", "NOT_AN_ISSUE", "NEEDS_MORE_INFO")
INTENSITY_VERDICTS = ("FULL", "LITE", "SKIP")
VERDICT_SOURCES = ("verdict_json", "md_header", "json_unmarked", "kv")
BLOCK_KINDS = ("first_pass", "selective", "summary")

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

# Session source traceability (S2-9)
ROLLOUT_FILENAME = re.compile(r"^rollout-(?P<body>.+)\.jsonl$")
ROLLOUT_BODY = re.compile(
    r"^(?P<iso>\d{4}-\d{2}-\d{2}T\d{2}(?::\d{2}:\d{2}|-\d{2}-\d{2})"
    r"(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)-(?P<id>.+)$"
)
ROLLOUT_DIR_DATE = re.compile(r"/(?P<year>\d{4})/(?P<month>\d{2})/(?P<day>\d{2})/")
PR_REF = re.compile(r"\b(?:PR|pull request)\s*#?(\d+)(?!\d)", re.I)
ISSUE_REF = re.compile(r"\b(?:issue|이슈)\s*#?(\d+)(?!\d)", re.I)
BARE_NUMBER_REF = re.compile(r"(?<![\w/])#(\d+)(?!\d)")

# Host path mapping —
#   command path:    SSH 명령 인자는 `~/.claude/projects` 등 relative tilde 표현을 사용한다
#                    (remote shell이 expansion). 본 map은 명령 인자에 직접 들어가지 않는다.
#   validation path: `_allowed_remote_path` boundary check가 본 absolute prefix와 비교하여
#                    SSH find stdout 비신뢰 line을 검증한다.
#   corpus path:     `--corpus manifest.json` 모드에서 host 분류 prefix로도 사용한다 (D-6).
HOST_PATH_MAP = {
    "mac": {
        "claude": "/Users/greenhead/.claude/projects",
        "codex": "/Users/greenhead/.codex/sessions",
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


@dataclass
class PayloadContext:
    """VERDICT_JSON record provenance.

    `extract_*` 함수는 기존 list[dict] 계약을 유지하지만, analyze_session 경로에서는
    이 context를 붙여 VerdictRecord 필드를 완성한다.
    """

    session_path: str | None = None
    jsonl_line_no: int | None = None
    payload_traversal_path: str | None = None
    payload_hash: str | None = None
    block_index: int | None = None
    block_kind: str = "first_pass"


@dataclass
class VerdictRecord:
    """Validated finding-level verdict.

    기존 dict 소비자 호환을 위해 `to_dict()`로 반환한다. 기존 필드
    finding_id/verdict/confidence/source_confidence/source/bundle은 그대로 유지하고,
    측정 재현성에 필요한 provenance와 persistence 입력 필드를 추가한다.
    """

    session_path: str | None
    jsonl_line_no: int | None
    payload_traversal_path: str | None
    payload_hash: str | None
    block_index: int | None
    block_kind: str
    finding_id: str
    verdict: str
    confidence: str
    source_confidence: str
    severity: str | None
    source: str
    bundle: str | None
    perspective: str | None
    location_identity: str | None
    finding_fingerprint: str | None
    stability_status: str
    canonical_verdict_hash: str

    def to_dict(self) -> dict:
        return asdict(self)


@dataclass
class ExtractionDiagnostic:
    """Extraction sidecar entry. Exclusions/invalid/parse failures are not verdicts."""

    session_path: str | None
    jsonl_line_no: int | None
    payload_traversal_path: str | None
    payload_hash: str | None
    block_index: int | None
    match_kind: str
    classification_reason: str
    source: str | None = None
    finding_id: str | None = None
    verdict: str | None = None
    snippet: str | None = None

    def to_dict(self) -> dict:
        return asdict(self)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()


def canonical_json_hash(obj: Any) -> str:
    encoded = json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return sha256_text(encoded)


def text_snippet(text: str, limit: int = 160) -> str:
    return re.sub(r"\s+", " ", text).strip()[:limit]


def diagnostic_to_dict(item: ExtractionDiagnostic | dict | str) -> dict:
    if isinstance(item, ExtractionDiagnostic):
        return item.to_dict()
    if isinstance(item, dict):
        return item
    return {
        "session_path": None,
        "jsonl_line_no": None,
        "payload_traversal_path": None,
        "payload_hash": None,
        "block_index": None,
        "match_kind": "parse_failure",
        "classification_reason": str(item),
        "source": None,
        "finding_id": None,
        "verdict": None,
        "snippet": None,
    }


def infer_host_for_path(path: str | None) -> str | None:
    """HOST_PATH_MAP prefix 기준으로 세션 path의 host를 추정한다."""
    if not path:
        return None
    for host, paths in HOST_PATH_MAP.items():
        for base in (paths.get("claude", ""), paths.get("codex", "")):
            if base and (path == base or path.startswith(base + os.sep)):
                return host
    return None


def new_session_traceability(path: str | None) -> dict:
    """세션 단위 소스 추적성 sidecar skeleton."""
    meta = {
        "path": path,
        "host": infer_host_for_path(path),
        "format": "unknown",
        "cwd": None,
        "git_branch": None,
        "session_id": None,
        "rollout_date": None,
        "source_fields": [],
        "fallback_fields": [],
        "missing_fields": [],
        "references": {
            "prs": [],
            "issues": [],
            "bare_numbers": [],
        },
    }
    apply_codex_rollout_filename_fallback(meta)
    return meta


def _set_meta_field(meta: dict, field: str, value: Any, source: str) -> None:
    if value in (None, ""):
        return
    existing = meta.get(field)
    fallback_key = "rollout_filename.session_id"
    can_replace_fallback = (
        field == "session_id"
        and existing not in (None, "")
        and fallback_key in meta.get("fallback_fields", [])
        and source != fallback_key
    )
    if existing not in (None, "") and not can_replace_fallback:
        return
    meta[field] = str(value)
    if can_replace_fallback:
        meta["fallback_fields"] = [
            item for item in meta.get("fallback_fields", []) if item != fallback_key
        ]
    if source not in meta["source_fields"]:
        meta["source_fields"].append(source)


def _get_nested(obj: Any, path: tuple[str, ...]) -> Any:
    cur = obj
    for key in path:
        if not isinstance(cur, dict):
            return None
        cur = cur.get(key)
    return cur


def apply_codex_rollout_filename_fallback(meta: dict) -> None:
    """Codex rollout path에서 session id/date를 best-effort로 보강한다."""
    path = meta.get("path")
    if not path:
        return
    basename = os.path.basename(path)
    m = ROLLOUT_FILENAME.match(basename)
    if not m:
        return
    if meta.get("format") == "unknown":
        meta["format"] = "codex"
    if not meta.get("session_id"):
        body = m.group("body")
        body_match = ROLLOUT_BODY.match(body)
        if body_match:
            meta["session_id"] = body_match.group("id")
        else:
            meta["session_id"] = body.rsplit("-", 1)[-1]
        meta["fallback_fields"].append("rollout_filename.session_id")
    dm = ROLLOUT_DIR_DATE.search(path)
    if dm and not meta.get("rollout_date"):
        meta["rollout_date"] = (
            f"{dm.group('year')}-{dm.group('month')}-{dm.group('day')}"
        )
        meta["fallback_fields"].append("rollout_directory.date")


def update_session_traceability_from_obj(meta: dict, obj: Any) -> None:
    """Claude/Codex JSONL object의 세션 메타 필드를 fail-soft로 추출한다."""
    if not isinstance(obj, dict):
        return

    if any(key in obj for key in ("cwd", "gitBranch", "sessionId")):
        meta["format"] = "claude"
        _set_meta_field(meta, "cwd", obj.get("cwd"), "claude.cwd")
        _set_meta_field(meta, "git_branch", obj.get("gitBranch"), "claude.gitBranch")
        _set_meta_field(meta, "session_id", obj.get("sessionId"), "claude.sessionId")

    payload = obj.get("payload")
    if isinstance(payload, dict) and any(
        key in payload for key in ("cwd", "git", "id")
    ):
        if meta.get("format") == "unknown":
            meta["format"] = "codex"
        _set_meta_field(meta, "cwd", payload.get("cwd"), "codex.payload.cwd")
        _set_meta_field(
            meta,
            "git_branch",
            _get_nested(payload, ("git", "branch")),
            "codex.payload.git.branch",
        )
        _set_meta_field(meta, "session_id", payload.get("id"), "codex.payload.id")

    apply_codex_rollout_filename_fallback(meta)


def extract_issue_references(text: str) -> dict:
    """세션 본문에서 PR/issue 번호를 best-effort로 수집한다."""
    prs = {m.group(1) for m in PR_REF.finditer(text)}
    issues = {m.group(1) for m in ISSUE_REF.finditer(text)}
    bare = {m.group(1) for m in BARE_NUMBER_REF.finditer(text)}
    return {
        "prs": sorted(prs, key=int)[:20],
        "issues": sorted(issues, key=int)[:20],
        "bare_numbers": sorted(bare - prs - issues, key=int)[:20],
    }


def finalize_session_traceability(meta: dict, text_blob: str) -> dict:
    """coverage 계산에 쓰기 쉬운 traceability dict로 마감한다."""
    required = ("cwd", "git_branch", "session_id")
    meta["references"] = extract_issue_references(text_blob)
    meta["source_fields"] = sorted(set(meta.get("source_fields", [])))
    meta["fallback_fields"] = sorted(set(meta.get("fallback_fields", [])))
    meta["missing_fields"] = [field for field in required if not meta.get(field)]
    meta["complete"] = not meta["missing_fields"] and meta.get("format") != "unknown"
    return meta


def add_diagnostic(
    diagnostics: list | None,
    context: PayloadContext | None,
    match_kind: str,
    classification_reason: str,
    *,
    source: str | None = None,
    finding_id: str | None = None,
    verdict: str | None = None,
    snippet: str | None = None,
) -> None:
    if diagnostics is None:
        return
    ctx = context or PayloadContext()
    diagnostics.append(ExtractionDiagnostic(
        session_path=ctx.session_path,
        jsonl_line_no=ctx.jsonl_line_no,
        payload_traversal_path=ctx.payload_traversal_path,
        payload_hash=ctx.payload_hash,
        block_index=ctx.block_index,
        match_kind=match_kind,
        classification_reason=classification_reason,
        source=source,
        finding_id=finding_id,
        verdict=verdict,
        snippet=snippet,
    ))


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


def extract_text_payloads_with_paths(
    obj: Any,
    accumulator: list[tuple[str, str]],
    path: str = "$",
) -> None:
    """JSONL record에서 string payload와 traversal path를 함께 추출."""
    if isinstance(obj, str):
        accumulator.append((path, obj))
    elif isinstance(obj, dict):
        for key, value in obj.items():
            child_path = f"{path}.{key}"
            extract_text_payloads_with_paths(value, accumulator, child_path)
    elif isinstance(obj, list):
        for idx, value in enumerate(obj):
            extract_text_payloads_with_paths(value, accumulator, f"{path}[{idx}]")


def in_long_outer_fence(text: str, pos: int) -> bool:
    """4개 이상 backtick fence 안쪽인지 확인한다.

    run-da 문서는 outer 4-backtick example 안에 실제 3-backtick VERDICT_JSON 예시를
    넣는다. 내부 3-backtick은 분석 대상이지만 outer example 안이면 측정에서 제외한다.
    """
    open_len: int | None = None
    for line in text[:pos].splitlines():
        m = re.match(r"^\s*(`{4,}|~{4,})", line)
        if not m:
            continue
        fence_len = len(m.group(1))
        if open_len is None:
            open_len = fence_len
        elif fence_len >= open_len:
            open_len = None
    return open_len is not None


def in_any_code_fence(text: str, pos: int) -> bool:
    open_fence: tuple[str, int] | None = None
    for line in text[:pos].splitlines():
        m = re.match(r"^\s*(`{3,}|~{3,})", line)
        if not m:
            continue
        marker = m.group(1)
        char = marker[0]
        length = len(marker)
        if open_fence is None:
            open_fence = (char, length)
        elif char == open_fence[0] and length >= open_fence[1]:
            open_fence = None
    return open_fence is not None


def inside_verdict_json_marker(text: str, start: int, end: int) -> bool:
    """Fenced JSON block이 이미 strict VERDICT_JSON delimiter 안에 있는지 확인."""
    marker_start = text.rfind("<!-- verdict-json:start -->", 0, start)
    marker_end_before = text.rfind("<!-- verdict-json:end -->", 0, start)
    if marker_start == -1 or marker_end_before > marker_start:
        return False
    marker_end_after = text.find("<!-- verdict-json:end -->", end)
    return marker_end_after != -1


def classify_template_exclusion(
    text: str,
    start: int,
    end: int,
    body: str,
    match_kind: str,
) -> str | None:
    """문서/프롬프트 템플릿 예시의 VERDICT_JSON false positive를 분류."""
    context_start = max(0, start - 1200)
    context_before = text[context_start:start]
    if in_long_outer_fence(text, start):
        return "outer_fenced_example"
    if re.search(r'"\{[^"{}\n]{1,80}\}"', body):
        return "placeholder_template"
    if re.search(r"(CONFIRMED_ISSUE|NOT_AN_ISSUE|NEEDS_MORE_INFO)\"?\s*\|\s*", body):
        return "union_string_template"
    if re.search(r"(HIGH|MEDIUM|LOW|N/A)\"?\s*\|\s*", body):
        return "union_string_template"
    if " 또는 " in body or " / " in body and "CONFIRMED_ISSUE" in body:
        return "or_pattern_template"
    template_markers = (
        "Arbiter 프롬프트 템플릿",
        "기계 파싱용 VERDICT_JSON 블록",
        "예시 블록",
        "Few-shot 교정 예시",
        "가상 예시",
        "실제 Arbiter 출력 시",
        "공통 프롬프트",
    )
    if any(marker in context_before for marker in template_markers):
        return "arbiter_prompt_template_context"
    if match_kind == "json_unmarked" and "schema_version" in body and "{finding ID" in body:
        return "arbiter_prompt_template_context"
    return None


def infer_block_kind(text: str) -> str:
    lowered = text.lower()
    if "selective:" in lowered or "selective consistency" in lowered or "fleiss-kappa" in lowered:
        return "selective"
    if "round summary" in lowered or "라운드 요약" in text:
        return "summary"
    return "first_pass"


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


def get_perspective(finding_id: str | None, text: str = "") -> str | None:
    """ledger key의 perspective 후보를 finding_id 또는 finding block에서 추출."""
    if finding_id:
        m = FINDING_ID_LEGACY.search(finding_id)
        if m:
            return m.group(1).upper()
        m = FINDING_ID_NORMALIZE.search(finding_id)
        if m:
            return m.group(1)
    pm = re.search(
        r"(?:관점|perspective)\s*[:：]\s*`?([A-Z][A-Z_]+|Correctness|Design|Regression|Maintainability)`?",
        text,
        re.I,
    )
    if pm:
        value = pm.group(1)
        return value.upper() if "_" in value else value
    return None


def finding_context_window(text: str, finding_id: str) -> str:
    """finding_id 주변 markdown block을 잘라 persistence 입력 추출에 사용."""
    if not finding_id:
        return text[:2000]
    m = re.search(re.escape(finding_id), text)
    if not m:
        return text[:2000]
    start = text.rfind("\n###", 0, m.start())
    if start == -1:
        start = max(0, m.start() - 800)
    next_header = text.find("\n###", m.end())
    if next_header == -1:
        next_header = min(len(text), m.end() + 1800)
    return text[start:next_header]


def extract_location_identity(block: str) -> str | None:
    patterns = (
        r"(?:\*\*)?(?:위치|Location|파일|경로)(?:\*\*)?\s*[:：]\s*`?([^`\n]+)`?",
        r"`?([A-Za-z0-9_./-]+\.(?:nix|py|sh|md|lua|ts|tsx|js|json|ya?ml|toml):\d+)`?",
    )
    for pattern in patterns:
        m = re.search(pattern, block, re.I)
        if not m:
            continue
        value = m.group(1).strip()
        value = re.split(r"\s+[—-]\s+|\s{2,}", value, maxsplit=1)[0].strip()
        return value.strip("` ")
    return None


def extract_finding_summary(block: str) -> str | None:
    patterns = (
        r"(?:\*\*)?(?:문제|요약|Summary|Finding|Issue)(?:\*\*)?\s*[:：]\s*(.+)",
        r"^-\s+(.+)",
    )
    excluded_prefixes = (
        "**판정**",
        "**신뢰도**",
        "**기준 평가**",
        "**stability_status**",
        "**근거**",
        "**증거**",
    )
    for pattern in patterns:
        for m in re.finditer(pattern, block, re.I | re.M):
            value = m.group(1).strip()
            if not value or any(value.startswith(prefix) for prefix in excluded_prefixes):
                continue
            if "CONFIRMED_ISSUE" in value or "NOT_AN_ISSUE" in value or "NEEDS_MORE_INFO" in value:
                continue
            return value.strip("` ")
    return None


def normalize_fingerprint_text(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def derive_persistence_fields(text: str, finding_id: str) -> dict:
    block = finding_context_window(text, finding_id)
    perspective = get_perspective(finding_id, block)
    location_identity = extract_location_identity(block)
    summary = extract_finding_summary(block)
    finding_fingerprint = sha256_text(normalize_fingerprint_text(summary)) if summary else None
    return {
        "perspective": perspective,
        "location_identity": location_identity,
        "finding_fingerprint": finding_fingerprint,
    }


# ─────────────────────────────────────────────────────────────────────────────
# 4. verdict parser pipeline (4-tier fallback)
# ─────────────────────────────────────────────────────────────────────────────

def make_verdict_record(
    item: dict,
    text: str,
    source: str,
    source_confidence: str,
    context: PayloadContext | None = None,
    diagnostics: list | None = None,
) -> dict | None:
    """Validated VerdictRecord dict를 만든다. invalid verdict는 diagnostic으로 분리."""
    ctx = context or PayloadContext()
    verdict = item.get("verdict", "")
    finding_id = item.get("finding_id", "")
    if finding_id is None:
        finding_id = ""
    finding_id = str(finding_id)
    if verdict not in VERDICT_CATEGORIES:
        add_diagnostic(
            diagnostics,
            ctx,
            "invalid_verdict",
            "verdict enum validation failed",
            source=source,
            finding_id=finding_id,
            verdict=str(verdict),
            snippet=text_snippet(json.dumps(item, ensure_ascii=False)),
        )
        return None

    persistence = derive_persistence_fields(text, finding_id)
    missing_components = [
        key for key in ("perspective", "location_identity", "finding_fingerprint")
        if not persistence.get(key)
    ]
    if missing_components:
        add_diagnostic(
            diagnostics,
            ctx,
            "missing_persistence_component",
            "persistence_key component extraction failed: " + ",".join(missing_components),
            source=source,
            finding_id=finding_id,
            verdict=verdict,
            snippet=text_snippet(finding_context_window(text, finding_id)),
        )

    block_kind = ctx.block_kind if ctx.block_kind in BLOCK_KINDS else "first_pass"
    confidence = item.get("confidence", "N/A")
    stability_status = item.get("stability_status", "N/A")
    canonical_source = {
        "schema_version": item.get("schema_version", "1.0"),
        "finding_id": finding_id,
        "verdict": verdict,
        "confidence": confidence,
        "stability_status": stability_status,
        "axes": item.get("axes", {}),
    }
    record = VerdictRecord(
        session_path=ctx.session_path,
        jsonl_line_no=ctx.jsonl_line_no,
        payload_traversal_path=ctx.payload_traversal_path,
        payload_hash=ctx.payload_hash,
        block_index=ctx.block_index,
        block_kind=block_kind,
        finding_id=finding_id,
        verdict=verdict,
        confidence=str(confidence),
        source_confidence=source_confidence,
        severity=find_severity_for_finding(text, finding_id),
        source=source,
        bundle=get_bundle(finding_id),
        perspective=persistence.get("perspective"),
        location_identity=persistence.get("location_identity"),
        finding_fingerprint=persistence.get("finding_fingerprint"),
        stability_status=str(stability_status),
        canonical_verdict_hash=canonical_json_hash(canonical_source),
    )
    return record.to_dict()


def extract_strict_verdicts(
    text: str,
    parse_failures: list | None = None,
    diagnostics: list | None = None,
    context: PayloadContext | None = None,
) -> list[dict]:
    """Tier 1 (VERDICT_JSON marker)을 우선 적용, finding_id 단위로 Tier 2 (### header)
    fallback. 같은 finding_id가 두 source에 모두 있으면 Tier 1만 채택해 중복 카운트를 차단한다.
    parse_failures가 주어지면 JSON parse 실패를 silent swallow 대신 누적한다.
    """
    verdicts = []
    seen_finding_ids: set[str] = set()
    ctx = context or PayloadContext()
    for m in VERDICT_JSON_BLOCK.finditer(text):
        exclusion = classify_template_exclusion(
            text, m.start(), m.end(), m.group(1), "verdict_json"
        )
        if exclusion:
            add_diagnostic(
                diagnostics,
                ctx,
                "exclusion",
                exclusion,
                source="verdict_json",
                snippet=text_snippet(m.group(0)),
            )
            continue
        try:
            v = json.loads(m.group(1))
        except Exception as e:
            msg = f"verdict_json parse error: {type(e).__name__}: {text_snippet(m.group(1), 80)}"
            if parse_failures is not None:
                parse_failures.append(msg)
            add_diagnostic(
                diagnostics,
                ctx,
                "parse_failure",
                msg,
                source="verdict_json",
                snippet=text_snippet(m.group(1)),
            )
            continue
        if not isinstance(v, dict):
            add_diagnostic(
                diagnostics,
                ctx,
                "invalid_json_type",
                f"verdict_json root must be object, got {type(v).__name__}",
                source="verdict_json",
                snippet=text_snippet(m.group(1)),
            )
            continue
        record = make_verdict_record(v, text, "verdict_json", "high", ctx, diagnostics)
        if record is None:
            continue
        verdicts.append(record)
        finding_id = record.get("finding_id", "")
        if finding_id:
            seen_finding_ids.add(finding_id)
    for m in HUMAN_VERDICT_HEADER.finditer(text):
        if in_any_code_fence(text, m.start()):
            add_diagnostic(
                diagnostics,
                ctx,
                "exclusion",
                "markdown_header_inside_fenced_example",
                source="md_header",
                finding_id=m.group(1),
                verdict=m.group(2),
                snippet=text_snippet(m.group(0)),
            )
            continue
        exclusion = classify_template_exclusion(text, m.start(), m.end(), m.group(0), "md_header")
        if exclusion:
            add_diagnostic(
                diagnostics,
                ctx,
                "exclusion",
                exclusion,
                source="md_header",
                finding_id=m.group(1),
                verdict=m.group(2),
                snippet=text_snippet(m.group(0)),
            )
            continue
        finding_id = m.group(1)
        # Tier 1에서 이미 회수된 finding은 skip (4-tier fallback 의무 — 중복 카운트 차단)
        if finding_id in seen_finding_ids:
            continue
        record = make_verdict_record({
            "finding_id": finding_id,
            "verdict": m.group(2),
            "confidence": "N/A",
            "stability_status": "N/A",
        }, text, "md_header", "high", ctx, diagnostics)
        if record is None:
            continue
        verdicts.append(record)
        if finding_id:
            seen_finding_ids.add(finding_id)
    return verdicts


def extract_unmarked_json_verdicts(
    text: str,
    diagnostics: list | None = None,
    context: PayloadContext | None = None,
) -> list[dict]:
    """Tier 3: marker 없는 fenced JSON array/object에서 verdict 회수."""
    verdicts = []
    ctx = context or PayloadContext()
    for m in FENCED_JSON_BLOCK.finditer(text):
        if inside_verdict_json_marker(text, m.start(), m.end()):
            continue
        body = m.group(1)
        exclusion = classify_template_exclusion(text, m.start(), m.end(), body, "json_unmarked")
        if exclusion:
            add_diagnostic(
                diagnostics,
                ctx,
                "exclusion",
                exclusion,
                source="json_unmarked",
                snippet=text_snippet(m.group(0)),
            )
            continue
        try:
            obj = json.loads(body)
        except Exception:
            continue
        items = obj if isinstance(obj, list) else [obj]
        for item in items:
            if not isinstance(item, dict):
                add_diagnostic(
                    diagnostics,
                    ctx,
                    "invalid_json_type",
                    f"json_unmarked item must be object, got {type(item).__name__}",
                    source="json_unmarked",
                    snippet=text_snippet(body),
                )
                continue
            record = make_verdict_record(item, text, "json_unmarked", "high", ctx, diagnostics)
            if record is not None:
                verdicts.append(record)
    return verdicts


def extract_kv_verdicts(
    text: str,
    arbiter_window_only: bool = True,
    diagnostics: list | None = None,
    context: PayloadContext | None = None,
) -> list[dict]:
    """Tier 4: KV `**판정**: VERDICT`. Arbiter 결과 헤더 window 안만."""
    verdicts = []
    ctx = context or PayloadContext()
    if arbiter_window_only:
        for m in re.finditer(r"##\s+Arbiter\s+검증\s+결과", text):
            start = m.end()
            end = min(len(text), start + ARBITER_WINDOW_CHARS)
            window = text[start:end]
            nxt = re.search(r"\n##\s", window)
            if nxt:
                window = window[: nxt.start()]
            for vm in VERDICT_KV.finditer(window):
                absolute_start = start + vm.start()
                if in_any_code_fence(text, absolute_start):
                    add_diagnostic(
                        diagnostics,
                        ctx,
                        "exclusion",
                        "kv_inside_fenced_example",
                        source="kv",
                        verdict=vm.group(1),
                        snippet=text_snippet(vm.group(0)),
                    )
                    continue
                exclusion = classify_template_exclusion(
                    text, absolute_start, start + vm.end(), vm.group(0), "kv"
                )
                if exclusion:
                    add_diagnostic(
                        diagnostics,
                        ctx,
                        "exclusion",
                        exclusion,
                        source="kv",
                        verdict=vm.group(1),
                        snippet=text_snippet(vm.group(0)),
                    )
                    continue
                record = make_verdict_record({
                    "finding_id": "",
                    "verdict": vm.group(1),
                    "confidence": "N/A",
                    "stability_status": "N/A",
                }, text, "kv", "medium", ctx, diagnostics)
                if record is not None:
                    verdicts.append(record)
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


def compute_persistence_metrics(sessions: list[dict]) -> dict:
    """동일 persistence_key가 여러 result block에 걸쳐 반복되는 정도를 계산."""
    key_blocks: dict[tuple, set] = defaultdict(set)
    key_verdicts: dict[tuple, Counter] = defaultdict(Counter)
    session_key_blocks: dict[str, dict[tuple, set]] = defaultdict(lambda: defaultdict(set))
    missing_components = 0
    eligible_records = 0

    for s in sessions:
        path = s.get("path")
        for record in s.get("verdicts", []):
            components = (
                record.get("perspective"),
                record.get("location_identity"),
                record.get("finding_fingerprint"),
            )
            if not all(components):
                missing_components += 1
                continue
            block_index = record.get("block_index")
            if block_index is None:
                missing_components += 1
                continue
            eligible_records += 1
            key = components
            block_key = (path, block_index)
            key_blocks[key].add(block_key)
            key_verdicts[key][record.get("verdict")] += 1
            session_key_blocks[path][key].add(block_index)

    distribution: Counter = Counter()
    for blocks in key_blocks.values():
        block_count = len(blocks)
        if block_count > 1:
            distribution[str(block_count)] += 1

    top_offenders_by_session: dict[str, list[dict]] = {}
    for path, per_key in session_key_blocks.items():
        offenders = []
        for key, blocks in per_key.items():
            if len(blocks) <= 1:
                continue
            offenders.append({
                "persistence_key": {
                    "perspective": key[0],
                    "location_identity": key[1],
                    "finding_fingerprint": key[2],
                },
                "block_count": len(blocks),
                "blocks": sorted(blocks),
                "verdicts": dict(key_verdicts[key]),
            })
        offenders.sort(key=lambda item: (-item["block_count"], item["persistence_key"]["location_identity"]))
        if offenders:
            top_offenders_by_session[path] = offenders[:5]

    return {
        "key_block_count_distribution": dict(distribution),
        "top_offenders_by_session": top_offenders_by_session,
        "coverage": {
            "eligible_records": eligible_records,
            "missing_persistence_components": missing_components,
        },
    }


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

def analyze_session(path: str, logical_path: str | None = None) -> dict | None:
    """단일 jsonl 세션 분석. 모든 metric 입력을 추출하여 dict로 반환."""
    session_path = logical_path or path
    has_arbiter_marker = False
    has_intensity_marker = False
    intensity_verdicts: list[str] = []
    all_verdicts: list[dict] = []
    nl_signal_only = False
    nl_estimated = 0
    full_text = []
    parse_failures: list[str] = []
    diagnostics: list[ExtractionDiagnostic] = []
    seen_payload_hashes: set[str] = set()
    seen_record_keys: set[tuple] = set()
    current_block_index = -1
    last_result_line_no: int | None = None
    session_traceability = new_session_traceability(session_path)

    def predicted_block_index(line_no: int) -> int:
        if last_result_line_no is not None and line_no <= last_result_line_no + 1:
            return current_block_index
        return current_block_index + 1

    def append_records(records: list[dict], line_no: int, block_index: int) -> None:
        nonlocal current_block_index, last_result_line_no
        for record in records:
            key = (
                record.get("session_path"),
                record.get("jsonl_line_no"),
                record.get("payload_traversal_path"),
                record.get("finding_id"),
                record.get("source"),
                record.get("canonical_verdict_hash"),
            )
            if key in seen_record_keys:
                continue
            seen_record_keys.add(key)
            all_verdicts.append(record)
        if records:
            current_block_index = block_index
            last_result_line_no = line_no

    try:
        with open(path, "r", errors="replace") as fp:
            for line_no, line in enumerate(fp, start=1):
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                update_session_traceability_from_obj(session_traceability, obj)
                payloads: list[tuple[str, str]] = []
                extract_text_payloads_with_paths(obj, payloads)
                for payload_path, text in payloads:
                    payload_hash = sha256_text(text)
                    if payload_hash in seen_payload_hashes:
                        continue
                    seen_payload_hashes.add(payload_hash)
                    full_text.append(text)
                    if ARBITER_DIR_MARKER.search(text):
                        has_arbiter_marker = True
                    if INTENSITY_DIR_MARKER.search(text):
                        has_intensity_marker = True

                    intensity_verdicts.extend(extract_intensity_verdicts(text))

                    ctx = PayloadContext(
                        session_path=session_path,
                        jsonl_line_no=line_no,
                        payload_traversal_path=payload_path,
                        payload_hash=payload_hash,
                        block_index=predicted_block_index(line_no),
                        block_kind=infer_block_kind(text),
                    )

                    before_diag = len(diagnostics)
                    sv = extract_strict_verdicts(text, parse_failures, diagnostics, ctx)
                    if sv:
                        append_records(sv, line_no, ctx.block_index or 0)
                        continue
                    uj = extract_unmarked_json_verdicts(text, diagnostics, ctx)
                    if uj:
                        append_records(uj, line_no, ctx.block_index or 0)
                        continue
                    kv = extract_kv_verdicts(text, arbiter_window_only=True, diagnostics=diagnostics, context=ctx)
                    if kv:
                        append_records(kv, line_no, ctx.block_index or 0)
                        continue
                    has_signal, est = extract_nl_summary(text)
                    if has_signal:
                        nl_signal_only = True
                        nl_estimated = max(nl_estimated, est)
                    if len(diagnostics) > before_diag:
                        current_block_index = ctx.block_index or 0
                        last_result_line_no = line_no
    except Exception:
        return None

    text_blob = "\n".join(full_text)
    session_traceability = finalize_session_traceability(session_traceability, text_blob)
    # severity 라벨링 — finding_id 인접 window에서 수집
    for v in all_verdicts:
        if v.get("verdict") == "CONFIRMED_ISSUE" and v.get("finding_id") and not v.get("severity"):
            sev = find_severity_for_finding(text_blob, v["finding_id"])
            if sev:
                v["severity"] = sev

    return {
        "path": session_path,
        "has_arbiter_marker": has_arbiter_marker,
        "has_intensity_marker": has_intensity_marker,
        "intensity_verdicts": intensity_verdicts,
        "verdicts": all_verdicts,
        "nl_signal_only": nl_signal_only,
        "nl_estimated_count": nl_estimated,
        "round_summary_stability": resolve_stability_status_from_round_summary(text_blob),
        "parse_failures": parse_failures,
        "diagnostics": [d.to_dict() for d in diagnostics],
        "session_meta": session_traceability,
    }


def build_aggregate(
    sessions: list[dict],
    hosts: list[str],
    corpus_label: str,
    warnings: list[str],
    json_sidecar_path: str | None = None,
) -> dict:
    """모든 세션 분석 결과를 통합 aggregate 객체로 빌드."""
    arbiter_marker_sessions = [s for s in sessions if s and s["has_arbiter_marker"]]
    intensity_marker_sessions = [s for s in sessions if s and s["has_intensity_marker"]]

    diagnostics_by_session = []
    diagnostic_counter: Counter = Counter()
    traceability_sessions = []
    traceability_format_counter: Counter = Counter()
    traceability_host_counter: Counter = Counter()
    traceability_field_counter: Counter = Counter()
    traceability_fallback_counter: Counter = Counter()
    traceability_missing_counter: Counter = Counter()
    traceability_complete = 0
    for s in sessions:
        if not s:
            continue
        session_meta = s.get("session_meta") or new_session_traceability(s.get("path"))
        traceability_sessions.append(session_meta)
        traceability_format_counter[session_meta.get("format", "unknown")] += 1
        traceability_host_counter[session_meta.get("host") or "unknown"] += 1
        if session_meta.get("complete"):
            traceability_complete += 1
        for field in ("cwd", "git_branch", "session_id"):
            if session_meta.get(field):
                traceability_field_counter[field] += 1
        for field in session_meta.get("fallback_fields", []):
            traceability_fallback_counter[field] += 1
        for field in session_meta.get("missing_fields", []):
            traceability_missing_counter[field] += 1

        session_diagnostics = [diagnostic_to_dict(d) for d in s.get("diagnostics", [])]
        for d in session_diagnostics:
            diagnostic_counter[d.get("match_kind", "unknown")] += 1
        if s.get("parse_failures") or session_diagnostics:
            diagnostics_by_session.append({
                "path": s.get("path"),
                "parse_failures": list(s.get("parse_failures", [])),
                "exclusions": [
                    d for d in session_diagnostics
                    if d.get("match_kind") == "exclusion"
                ],
                "invalid_verdicts": [
                    d for d in session_diagnostics
                    if d.get("match_kind") == "invalid_verdict"
                ],
                "diagnostics": session_diagnostics,
            })
    diagnostic_total = sum(diagnostic_counter.values())
    if diagnostic_total > 0:
        sidecar_hint = json_sidecar_path or "(JSON sidecar path unavailable)"
        warnings.append(
            f"extraction diagnostics: {diagnostic_total}건 — JSON sidecar {sidecar_hint}의 diagnostics 참조"
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
            if v.get("source") in VERDICT_SOURCES and v.get("verdict") in VERDICT_CATEGORIES:
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
            if v.get("verdict") not in VERDICT_CATEGORIES:
                continue
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
        by_block: dict[int, list[dict]] = defaultdict(list)
        for v in s["verdicts"]:
            if v.get("source") not in VERDICT_SOURCES:
                continue
            block_index = v.get("block_index")
            if block_index is None:
                continue
            by_block[int(block_index)].append(v)
        rounds = [by_block[i] for i in sorted(by_block)]
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
    persistence_metrics = compute_persistence_metrics(arbiter_marker_sessions)

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
            "M-4": {
                "round_key": "(session_path, block_index)",
                "baseline_note": "v1부터 result block 기반 새 baseline이며 이전 finding_id 재등장 휴리스틱 수치와 단절된다.",
                "transition_matrix": {f"{a}->{b}": c for (a, b), c in transitions.items()},
            },
            "M-5": {
                "source": m5_source,
                "n": m5_n,
                "distribution": dict(m5_counter),
            },
            "M-6": {
                "name": "persistence_key non-convergence",
                "persistence_key": "(perspective, location_identity, finding_fingerprint)",
                **persistence_metrics,
            },
        },
        "derived": {
            "intensity_full_finding_zero_rate": round(intensity_full_zero_rate, 3),
        },
        "diagnostics": {
            "summary": dict(diagnostic_counter),
            "sessions": diagnostics_by_session,
        },
        "traceability": {
            "coverage": {
                "sessions_total": len([s for s in sessions if s]),
                "complete_sessions": traceability_complete,
                "unknown_format_sessions": traceability_format_counter.get("unknown", 0),
                "format_distribution": dict(traceability_format_counter),
                "host_distribution": dict(traceability_host_counter),
                "field_presence": dict(traceability_field_counter),
                "missing_fields": dict(traceability_missing_counter),
                "fallback_fields": dict(traceability_fallback_counter),
            },
            "sessions": traceability_sessions,
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
    out.append(f"- round key: `{m4['round_key']}`")
    out.append(f"- baseline: {m4['baseline_note']}")
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

    # M-6
    m6 = agg["metrics"]["M-6"]
    out.append("## M-6: persistence_key 비수렴 지표")
    out.append("")
    out.append(f"- key: `{m6['persistence_key']}`")
    out.append(
        f"- coverage: eligible {m6['coverage']['eligible_records']}, "
        f"missing {m6['coverage']['missing_persistence_components']}"
    )
    if m6["key_block_count_distribution"]:
        out.append("")
        out.append("| block_count | key count |")
        out.append("|-------------|-----------|")
        for k, v in sorted(m6["key_block_count_distribution"].items(), key=lambda item: int(item[0])):
            out.append(f"| {k} | {v} |")
    else:
        out.append("- repeated persistence_key 없음")
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
       sibling-prefix(`/Users/greenhead/.claude/projects-evil/...`)는 commonpath가
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
        return analyze_session(tmp_path, logical_path=path)
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


def parse_host_home_arg(s: str) -> list[tuple[str, str]]:
    """--host-home host=/abs/home[,host=/abs/home] 형식 파싱."""
    pairs = []
    for item in s.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise argparse.ArgumentTypeError(
                "--host-home expects host=/abs/home"
            )
        host, home = item.split("=", 1)
        host = host.strip()
        home = home.strip()
        if host not in VALID_HOSTS:
            raise argparse.ArgumentTypeError(
                f"invalid host in --host-home: {host!r}. valid: {sorted(VALID_HOSTS)}"
            )
        if not posixpath.isabs(home):
            raise argparse.ArgumentTypeError(
                f"--host-home for {host} must be absolute: {home!r}"
            )
        if any(c in home for c in "\n\r\t;|&$`(){}[]<>*?\"'\\"):
            raise argparse.ArgumentTypeError(
                f"--host-home for {host} contains disallowed shell metacharacter"
            )
        pairs.append((host, posixpath.normpath(home)))
    return pairs


def apply_host_home_overrides(overrides: Iterable[tuple[str, str]]) -> None:
    for host, home in overrides:
        HOST_PATH_MAP[host] = {
            "claude": posixpath.join(home, ".claude/projects"),
            "codex": posixpath.join(home, ".codex/sessions"),
        }


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
    parser.add_argument(
        "--host-home",
        type=parse_host_home_arg,
        action="append",
        default=[],
        help="override host home prefix, repeatable: host=/abs/home[,host=/abs/home]",
    )
    args = parser.parse_args()

    warnings: list[str] = []
    cur_host = current_host()
    apply_host_home_overrides(pair for group in args.host_home for pair in group)

    if args.json:
        json_path = args.json
    else:
        ts = datetime.datetime.now().strftime("%Y-%m-%dT%H-%M-%S")
        json_path = f"/tmp/analyze-da-sessions-{ts}.json"

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
            matched_host = infer_host_for_path(f)
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
    agg = build_aggregate(sessions, args.hosts, corpus_label, warnings, json_path)

    # 출력: markdown stdout
    print(render_markdown(agg))

    # 출력: JSON sidecar
    try:
        with open(json_path, "w") as fp:
            fp.write(render_json(agg))
        print(f"\n---\nJSON sidecar: {json_path}", file=sys.stderr)
    except OSError as e:
        print(f"WARNING: JSON sidecar write failed: {e}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
