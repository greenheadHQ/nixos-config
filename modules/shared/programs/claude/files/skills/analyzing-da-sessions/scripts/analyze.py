#!/usr/bin/env python3
"""DA 세션 정량 분석 — analyzing-da-sessions Skill의 algorithm SSOT.

PR #670 정정 코멘트의 알고리즘 (분모 정정 + 4-tier fallback + source/confidence 라벨링)
+ severity 전이를 통합한 단일 진입점.

Internal boundary:
  - constants/enums          — VERDICT_CATEGORIES, INTENSITY_VERDICTS, BUNDLE_MAP, regex 등
  - jsonl payload walker     — extract_text_payloads_with_paths
  - finding_id normalizer    — get_bundle
  - verdict parser pipeline  — extract_strict_verdicts, extract_unmarked_json_verdicts,
                                extract_kv_verdicts, extract_nl_summary, extract_intensity_verdicts
  - severity transition      — find_severity_for_finding, severity_rank, compute_severity_transitions
  - aggregate builder        — analyze_session, build_aggregate
  - markdown renderer        — render_markdown
  - json renderer            — render_json
  - host handling            — collect_local_files + 원격 수집(생존 preflight → tar batch 우선,
                                per-file cat fallback, host budget clamp). 함수 나열 대신
                                정책·경계는 references/host-handling.md가 SSOT.

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
import io
import json
import os
import platform
import posixpath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field, replace
from typing import Any, Iterable

# ─────────────────────────────────────────────────────────────────────────────
# 1. constants/enums
# ─────────────────────────────────────────────────────────────────────────────

VALID_HOSTS = {"mac", "minipc"}

VERDICT_CATEGORIES = ("CONFIRMED_ISSUE", "NOT_AN_ISSUE", "NEEDS_MORE_INFO")
INTENSITY_VERDICTS = ("FULL", "LITE", "SKIP")
VERDICT_SOURCES = ("verdict_json", "md_header", "json_unmarked", "kv")
# legacy provenance 분류다 — "selective"는 폐기된 selective consistency(#1257) 블록을,
# "first_pass"는 그 시절 first/N=3 구분의 흔적을 가리킨다. 현행 run-da는 단일 Arbiter
# 판정만 생성하므로 새 로그는 전부 "first_pass"로 직렬화된다 (후속 pass가 있다는 뜻이
# 아니다). 과거 로그의 블록 유형을 보존하기 위한 provenance 필드로만 유지한다.
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
SSH_HOST_FETCH_BUDGET_SECONDS = 600  # host별 remote find + fetch 전체 wall-clock budget
SSH_TAR_TIMEOUT_SECONDS = 480  # 단일 tar batch 호출 상한 (실제 budget 준수는 timeout_for clamp가 담당)
# 세션 파일 크기 상한.
#
# 2026-08 mac ~/.codex/sessions에 상한 초과 rollout 158건(약 180GB)이 쌓여 host budget을
# 초과시켰고, mac 수집이 4주 연속 0건이 됐다 (issue #1067 W30~W33).
#
# 이 cap은 "신호 없는 파일 제외"가 아니라 의도적 corpus 편향이다 — 크기는 verdict 신호의
# 판별자가 아니다. 실측(2026-08-15 mac): 초과분 대부분은 verdict 0건의 대용량 tool output
# 이지만, 470MB rollout 1건에서 verdict 160건이 정상 추출된다. 즉 cap은 수집 가용성을 위해
# 일부 실제 verdict를 버리는 trade-off이며, 버린 규모는 corpus_exclusions에 파일 수로
# 기록한다 (제외 세션의 verdict 수는 남지 않으므로 지표 분모 자체를 재구성하지는 못한다).
# 신호 기준 선별(원격 marker grep prefilter)은 별도 범위다.
CORPUS_FILE_SIZE_CAP_MIB = 50
CORPUS_FILE_SIZE_CAP_BYTES = CORPUS_FILE_SIZE_CAP_MIB * 1024 * 1024
# find -size의 `M` suffix는 구현마다 의미가 다르다 — GNU는 크기를 MB 단위로 올림해 비교하고
# (그래서 `-50M`과 `+50M` 사이에 1MiB 폭의 구간이 어디에도 안 잡힌다), BSD는 바이트 정확
# 비교라 갭이 cap 값 한 점이다. 어느 쪽이든 수집 목록과 초과 카운트 양쪽에서 빠지는 구간이
# 생긴다(침묵 절단). `c`(바이트) suffix는 양 구현 모두 정확 비교라 로컬 `getsize` 판정과
# 경계가 일치한다. 수집은 cap 이하(`-{cap+1}c`), 초과 카운트는 cap 초과(`+{cap}c`)로 상보 분할.
REMOTE_FIND_SIZE_INCLUDE = f"-{CORPUS_FILE_SIZE_CAP_BYTES + 1}c"
REMOTE_FIND_SIZE_EXCLUDE = f"+{CORPUS_FILE_SIZE_CAP_BYTES}c"
SSH_FETCH_WORKERS = 8  # 원격 호스트당 동시 SSH cat worker 수 (host 순차 처리, host당 K=8 병렬)
SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS = 10  # ssh preflight / ControlMaster check timeout

REMOTE_PATH_FORBIDDEN_CHARS = set(" \n\r\t;|&$`(){}[]<>*?\"'\\")


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
    match_offset: int | None = None


@dataclass
class HostFetchBudget:
    """원격 host 하나의 find + fetch 전체 wall-clock budget."""

    host: str
    deadline: float
    warning_emitted: bool = False
    warning_lock: threading.Lock = field(
        default_factory=threading.Lock,
        repr=False,
        compare=False,
    )

    @classmethod
    def start(cls, host: str) -> "HostFetchBudget":
        _validate_host(host)
        return cls(host=host, deadline=time.monotonic() + SSH_HOST_FETCH_BUDGET_SECONDS)

    def remaining_seconds(self) -> float:
        return self.deadline - time.monotonic()

    def expired(self) -> bool:
        return self.remaining_seconds() <= 0

    def timeout_for(self, requested_seconds: float) -> tuple[float | None, bool]:
        """요청 timeout을 host budget 잔여 시간으로 clamp한다."""
        remaining = self.remaining_seconds()
        if remaining <= 0:
            return None, True
        return min(requested_seconds, remaining), remaining < requested_seconds

    def warn_exceeded(self, warnings: list[str]) -> None:
        with self.warning_lock:
            if self.warning_emitted:
                return
            warnings.append(
                f"host {self.host}: ssh fetch budget 초과 — remote 수집 중단, partial result"
            )
            self.warning_emitted = True


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
    match_offset: int | None
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
    if " 또는 " in body or (" / " in body and "CONFIRMED_ISSUE" in body):
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
    """persistence_key(M-6)의 perspective 후보를 finding_id 또는 finding block에서 추출."""
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


def _window_around_match(text: str, m: re.Match) -> str:
    start = text.rfind("\n###", 0, m.start())
    if start == -1:
        start = max(0, m.start() - 800)
    next_header = text.find("\n###", m.end())
    if next_header == -1:
        next_header = min(len(text), m.end() + 1800)
    return text[start:next_header]


def finding_context_windows(text: str, finding_id: str, match_offset: int | None = None) -> list[str]:
    """finding_id 주변 markdown block 후보들을 우선순위 순으로 반환한다.

    같은 payload 안에서 동일 finding_id가 서로 다른 위치로 반복될 때 모든 record가
    첫 occurrence의 location/fingerprint를 공유하면 persistence_key가 오염된다
    (M-6 정확성). match_offset이 주어지면 근접 순으로 정렬하되, VERDICT_JSON 내부
    문자열보다 markdown 헤더(###) 라인의 occurrence를 우선한다. 실제 Arbiter 출력은
    서술 블록(위치 포함)과 판정 블록(위치 없음)이 분리되므로, 호출자는 후보를
    순회하며 location이 추출되는 첫 block을 채택한다.
    """
    if not finding_id:
        return [text[:2000]]
    candidates = list(re.finditer(re.escape(finding_id), text))
    if not candidates:
        return [text[:2000]]
    header_candidates = []
    for candidate in candidates:
        line_start = text.rfind("\n", 0, candidate.start()) + 1
        if text.startswith("###", line_start):
            header_candidates.append(candidate)
    pool = header_candidates or candidates
    if match_offset is not None:
        pool = sorted(pool, key=lambda c: abs(c.start() - match_offset))
    return [_window_around_match(text, c) for c in pool]


def finding_context_window(text: str, finding_id: str, match_offset: int | None = None) -> str:
    """단일 block이 필요한 호출자용 — 최우선 후보를 반환한다."""
    windows = finding_context_windows(text, finding_id, match_offset)
    return windows[0]


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
    # Arbiter 사람용 블록의 메타데이터 라벨 — finding 요약으로 채택되면 안 된다.
    # 라벨이 추가될 때 여기 함께 넣지 않으면 그 줄이 요약으로 잡혀
    # finding_fingerprint가 심각도나 evidence scope의 해시가 되고,
    # 라운드 사이 그 값이 바뀌면 동일 finding의 M-6 persistence가 분리된다.
    excluded_prefixes = (
        "**판정**",
        "**신뢰도**",
        "**기준 평가**",
        "**stability_status**",
        "**evidence_scope**",
        "**심각도 판정**",
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


def derive_persistence_fields(text: str, finding_id: str, match_offset: int | None = None) -> dict:
    blocks = finding_context_windows(text, finding_id, match_offset)
    # 근접 후보가 위치 없는 판정 블록(### ID — VERDICT)일 수 있으므로,
    # location이 추출되는 첫 후보를 채택한다 (없으면 최우선 후보 유지).
    block = blocks[0]
    location_identity = None
    for candidate in blocks:
        candidate_location = extract_location_identity(candidate)
        if candidate_location:
            block = candidate
            location_identity = candidate_location
            break
    perspective = get_perspective(finding_id, block)
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

    persistence = derive_persistence_fields(text, finding_id, ctx.match_offset)
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
            snippet=text_snippet(finding_context_window(text, finding_id, ctx.match_offset)),
        )

    block_kind = ctx.block_kind if ctx.block_kind in BLOCK_KINDS else "first_pass"
    confidence = item.get("confidence", "N/A")
    canonical_source = {
        "schema_version": item.get("schema_version", "1.0"),
        "finding_id": finding_id,
        "verdict": verdict,
        "confidence": confidence,
        "axes": item.get("axes", {}),
    }
    record = VerdictRecord(
        session_path=ctx.session_path,
        jsonl_line_no=ctx.jsonl_line_no,
        payload_traversal_path=ctx.payload_traversal_path,
        payload_hash=ctx.payload_hash,
        block_index=ctx.block_index,
        block_kind=block_kind,
        match_offset=ctx.match_offset,
        finding_id=finding_id,
        verdict=verdict,
        confidence=str(confidence),
        source_confidence=source_confidence,
        severity=find_severity_for_finding(text, finding_id, ctx.match_offset),
        source=source,
        bundle=get_bundle(finding_id),
        perspective=persistence.get("perspective"),
        location_identity=persistence.get("location_identity"),
        finding_fingerprint=persistence.get("finding_fingerprint"),
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
    strict_finding_ids: set[str] = set()
    ctx = context or PayloadContext()
    for m in VERDICT_JSON_BLOCK.finditer(text):
        match_ctx = replace(ctx, match_offset=m.start())
        exclusion = classify_template_exclusion(
            text, m.start(), m.end(), m.group(1), "verdict_json"
        )
        if exclusion:
            add_diagnostic(
                diagnostics,
                match_ctx,
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
                match_ctx,
                "parse_failure",
                msg,
                source="verdict_json",
                snippet=text_snippet(m.group(1)),
            )
            continue
        if not isinstance(v, dict):
            add_diagnostic(
                diagnostics,
                match_ctx,
                "invalid_json_type",
                f"verdict_json root must be object, got {type(v).__name__}",
                source="verdict_json",
                snippet=text_snippet(m.group(1)),
            )
            continue
        record = make_verdict_record(v, text, "verdict_json", "high", match_ctx, diagnostics)
        if record is None:
            continue
        verdicts.append(record)
        finding_id = record.get("finding_id", "")
        if finding_id:
            strict_finding_ids.add(finding_id)
    for m in HUMAN_VERDICT_HEADER.finditer(text):
        match_ctx = replace(ctx, match_offset=m.start())
        if in_any_code_fence(text, m.start()):
            add_diagnostic(
                diagnostics,
                match_ctx,
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
                match_ctx,
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
        if finding_id in strict_finding_ids:
            continue
        record = make_verdict_record({
            "finding_id": finding_id,
            "verdict": m.group(2),
            "confidence": "N/A",
        }, text, "md_header", "high", match_ctx, diagnostics)
        if record is None:
            continue
        verdicts.append(record)
    return verdicts


def json_items_with_offsets(body: str) -> list[tuple[Any, int]]:
    """Return top-level JSON object/array items with their offset inside body."""
    decoder = json.JSONDecoder()
    idx = 0
    end = len(body)
    while idx < end and body[idx].isspace():
        idx += 1
    if idx >= end:
        return []
    if body[idx] != "[":
        item, _ = decoder.raw_decode(body, idx)
        return [(item, idx)]

    idx += 1
    items = []
    while True:
        while idx < end and body[idx].isspace():
            idx += 1
        if idx < end and body[idx] == "]":
            return items
        item_offset = idx
        item, idx = decoder.raw_decode(body, idx)
        items.append((item, item_offset))
        while idx < end and body[idx].isspace():
            idx += 1
        if idx < end and body[idx] == ",":
            idx += 1
            continue
        if idx < end and body[idx] == "]":
            return items
        return items


def extract_unmarked_json_verdicts(
    text: str,
    diagnostics: list | None = None,
    context: PayloadContext | None = None,
) -> list[dict]:
    """Tier 3: marker 없는 fenced JSON array/object에서 verdict 회수."""
    verdicts = []
    ctx = context or PayloadContext()
    for m in FENCED_JSON_BLOCK.finditer(text):
        match_ctx = replace(ctx, match_offset=m.start())
        if inside_verdict_json_marker(text, m.start(), m.end()):
            continue
        body = m.group(1)
        exclusion = classify_template_exclusion(text, m.start(), m.end(), body, "json_unmarked")
        if exclusion:
            add_diagnostic(
                diagnostics,
                match_ctx,
                "exclusion",
                exclusion,
                source="json_unmarked",
                snippet=text_snippet(m.group(0)),
            )
            continue
        try:
            item_offsets = json_items_with_offsets(body)
        except Exception:
            continue
        body_start = m.start(1)
        for item, item_offset in item_offsets:
            item_ctx = replace(ctx, match_offset=body_start + item_offset)
            if not isinstance(item, dict):
                add_diagnostic(
                    diagnostics,
                    item_ctx,
                    "invalid_json_type",
                    f"json_unmarked item must be object, got {type(item).__name__}",
                    source="json_unmarked",
                    snippet=text_snippet(body),
                )
                continue
            if "verdict" not in item:
                continue
            record = make_verdict_record(item, text, "json_unmarked", "high", item_ctx, diagnostics)
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
                record = make_verdict_record(
                    {
                        "finding_id": "",
                        "verdict": vm.group(1),
                        "confidence": "N/A",
                    },
                    text,
                    "kv",
                    "medium",
                    replace(ctx, match_offset=absolute_start),
                    diagnostics,
                )
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


def find_severity_for_finding(
    text_blob: str,
    finding_id: str,
    match_offset: int | None = None,
) -> str | None:
    """analyze-da-sessions.py 패턴: finding header 인접 영역에서 severity 라벨 추출.

    match_offset이 주어지면 근접 occurrence부터 순회한다 — 같은 payload 안에서
    동일 finding_id가 다른 severity로 반복될 때 뒤 record가 앞선 severity를
    물려받아 M-4 전이가 틀어지는 것을 막는다. 주의: match_offset은 호출한 text와
    같은 좌표계여야 한다 (payload 단위 호출 전용 — 세션 blob fallback에는 넘기지 않음).
    """
    if not finding_id:
        return None
    occurrences = list(re.finditer(re.escape(finding_id), text_blob))
    if match_offset is not None:
        occurrences.sort(key=lambda m: abs(m.start() - match_offset))
    # finding_id 등장 위치의 앞뒤 window에서 severity 라벨 검색.
    # severity 줄은 finding 헤더 뒤에 오는 구조이므로 2-pass로 본다: 모든 occurrence의
    # lookahead를 먼저 전수 확인하고, 전부 없을 때만 behind fallback. occurrence별로
    # (ahead→behind)를 섞으면 근접 1순위(판정 블록, 심각도 없음)의 behind에 걸린
    # 앞 finding의 severity가 2순위(서술 블록)의 정답 ahead보다 먼저 오채택된다.
    for m in occurrences:
        ahead = text_blob[m.end():min(len(text_blob), m.end() + SEVERITY_LOOKAHEAD_CHARS)]
        sm = SEV_LINE.search(ahead)
        if sm:
            return sm.group(1).upper()
    for m in occurrences:
        behind = text_blob[max(0, m.start() - SEVERITY_LOOKBEHIND_CHARS):m.start()]
        behind_matches = list(SEV_LINE.finditer(behind))
        if behind_matches:
            # lookbehind에서는 occurrence에 가장 가까운 (마지막) 매치를 채택한다.
            return behind_matches[-1].group(1).upper()
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
# 6. aggregate builder
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
    seen_payload_keys: set[tuple[str, int, str]] = set()
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
            # VerdictRecord dedupe SSOT. The pre-parse payload key only prevents
            # revisiting the exact same string at the exact same traversal path.
            key = (
                record.get("session_path"),
                record.get("jsonl_line_no"),
                record.get("payload_traversal_path"),
                record.get("finding_id"),
                record.get("source"),
                record.get("match_offset"),
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
                    payload_key = (payload_hash, line_no, payload_path)
                    if payload_key in seen_payload_keys:
                        continue
                    seen_payload_keys.add(payload_key)
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
    corpus_exclusions: list[dict] | None = None,
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
        for field_name in ("cwd", "git_branch", "session_id"):
            if session_meta.get(field_name):
                traceability_field_counter[field_name] += 1
        for field_name in session_meta.get("fallback_fields", []):
            traceability_fallback_counter[field_name] += 1
        for field_name in session_meta.get("missing_fields", []):
            traceability_missing_counter[field_name] += 1

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
        # corpus 정책 제외 (실패 아님 — host partial 판정 입력인 warnings와 분리).
        # 소비자는 이 값으로 제외 규모(파일 수)를 읽는다.
        "corpus_exclusions": corpus_exclusions or [],
    }


# ─────────────────────────────────────────────────────────────────────────────
# 7. markdown renderer
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
# 8. json renderer
# ─────────────────────────────────────────────────────────────────────────────

def render_json(agg: dict) -> str:
    return json.dumps(agg, indent=2, ensure_ascii=False)


# ─────────────────────────────────────────────────────────────────────────────
# Host handling
# ─────────────────────────────────────────────────────────────────────────────

def _validate_host(alias: str) -> None:
    if alias not in VALID_HOSTS:
        raise ValueError(f"invalid host: {alias!r}. valid: {sorted(VALID_HOSTS)}")


def collect_local_files(
    host: str,
    corpus_exclusions: list[dict] | None = None,
) -> list[str]:
    """현재 머신의 jsonl 파일 glob.

    corpus 정의는 실행 위치에 따라 달라지면 안 되므로, 원격 수집과 동일한
    `CORPUS_FILE_SIZE_CAP_MIB` 상한을 적용하고 제외 건수를 같은 형식으로 기록한다.
    """
    _validate_host(host)
    paths = HOST_PATH_MAP[host]
    files = []
    # logical_base는 corpus_exclusions 기록용 논리 이름이다 — 원격 수집은 SSH argv의 tilde
    # 표현을 쓰므로, 같은 corpus가 실행 위치에 따라 다른 문자열로 기록되지 않게 맞춘다.
    for base, pattern, logical_base in [
        (paths["claude"], "**/*.jsonl", "~/.claude/projects"),
        (paths["codex"], "**/rollout-*.jsonl", "~/.codex/sessions"),
    ]:
        glob_path = os.path.join(base, pattern)
        oversized = 0
        for f in glob.glob(glob_path, recursive=True):
            if "/subagents/" in f:
                continue
            try:
                if os.path.getsize(f) > CORPUS_FILE_SIZE_CAP_BYTES:
                    oversized += 1
                    continue
            except OSError:
                # 경합으로 사라진 파일은 수집 대상에서 빠지며, 아래 open 단계와 같은
                # 방식으로 조용히 건너뛴다 (제외 카운트에도 넣지 않는다).
                continue
            files.append(f)
        if oversized and corpus_exclusions is not None:
            corpus_exclusions.append(
                _corpus_exclusion_entry(host, logical_base, oversized)
            )
    return files


def _remote_path_has_disallowed_chars(path: str) -> bool:
    """remote shell/tar list 경계에서 금지할 제어문자와 shell metacharacter 검사."""
    return any(
        c in REMOTE_PATH_FORBIDDEN_CHARS or ord(c) < 32 or ord(c) == 127
        for c in path
    )


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
    if _remote_path_has_disallowed_chars(path):
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


def _build_remote_tar_argv(host: str) -> list[str]:
    """remote tar batch fetch argv. GNU tar/bsdtar 공통 옵션만 사용한다."""
    _validate_host(host)
    remote_prefix = ["ssh", host]
    if host == "mac":
        remote_prefix.extend(["env", "COPYFILE_DISABLE=1"])
    return remote_prefix + ["tar", "-C", "/", "-cf", "-", "-T", "-"]


def _prepare_remote_tar_entries(
    host: str,
    paths: Iterable[str],
    warnings: list[str],
) -> list[tuple[str, str]]:
    """remote absolute path를 검증하고 `tar -C /` 기준 상대 path로 변환한다.

    반환 tuple은 `(logical_absolute_path, tar_relative_path)`이다. `tar -T -`는
    newline-delimited list만 지원하므로 개행 포함 path는 fallback에서도 제외한다.
    """
    _validate_host(host)
    entries: list[tuple[str, str]] = []
    for path in paths:
        if not isinstance(path, str):
            warnings.append(
                f"host {host}: remote tar path excluded by validation: {path!r}"
            )
            continue
        if "\n" in path or "\r" in path:
            warnings.append(
                f"host {host}: remote tar path excluded because it contains newline: {path!r}"
            )
            continue
        if not _allowed_remote_path(host, path):
            warnings.append(
                f"host {host}: remote tar path excluded by validation: {path!r}"
            )
            continue
        path_norm = posixpath.normpath(path)
        entries.append((path_norm, path_norm.removeprefix("/")))
    return entries


def _build_remote_tar_stdin(entries: Iterable[tuple[str, str]]) -> bytes:
    """`tar -T -`에 넘길 newline-delimited relative path list."""
    lines = [relative_path for _, relative_path in entries]
    if not lines:
        return b""
    return ("\n".join(lines) + "\n").encode("utf-8")


def _normalize_tar_member_name(name: str) -> str | None:
    """tar member path를 tempdir 내부 상대 path로 정규화한다."""
    if not isinstance(name, str) or not name:
        return None
    if _remote_path_has_disallowed_chars(name):
        return None
    # 정규화 전에 raw component를 검사한다. `ignored/../allowlisted`를 먼저
    # normpath하면 allowlist member와 같아져 traversal 입력이 채택될 수 있다.
    if ".." in name.split("/"):
        return None
    name_norm = posixpath.normpath(name)
    if name_norm in ("", ".") or posixpath.isabs(name_norm):
        return None
    if name_norm == ".." or name_norm.startswith("../") or "/../" in name_norm:
        return None
    return name_norm


def _extract_tar_stream_to_dir(
    host: str,
    tar_stream: Any,
    entries: list[tuple[str, str]],
    dest_dir: str,
    warnings: list[str],
) -> bool:
    """remote tar stream을 tempdir에 추출한다. 실패 시 False로 fallback을 유도한다."""
    expected_rel_paths = {relative_path for _, relative_path in entries}
    extracted_rel_paths: set[str] = set()
    dest_root = os.path.abspath(dest_dir)

    try:
        with tarfile.open(fileobj=tar_stream, mode="r:*") as tf:
            for member in tf:
                member_rel = _normalize_tar_member_name(member.name)
                if member_rel not in expected_rel_paths:
                    warnings.append(
                        f"host {host}: tar member skipped by validation: {member.name!r}"
                    )
                    continue
                if not member.isfile():
                    warnings.append(
                        f"host {host}: tar member is not a regular file: {member.name!r}"
                    )
                    continue
                source = tf.extractfile(member)
                if source is None:
                    warnings.append(
                        f"host {host}: tar member could not be read: {member.name!r}"
                    )
                    continue

                dest_path = os.path.abspath(os.path.join(dest_dir, *member_rel.split("/")))
                try:
                    if os.path.commonpath([dest_root, dest_path]) != dest_root:
                        warnings.append(
                            f"host {host}: tar member escaped tempdir: {member.name!r}"
                        )
                        continue
                except ValueError:
                    warnings.append(
                        f"host {host}: tar member escaped tempdir: {member.name!r}"
                    )
                    continue

                os.makedirs(os.path.dirname(dest_path), exist_ok=True)
                with open(dest_path, "wb") as fp:
                    shutil.copyfileobj(source, fp)
                extracted_rel_paths.add(member_rel)
    except tarfile.TarError as e:
        warnings.append(
            f"host {host}: ssh tar stream could not be read ({type(e).__name__}: {e})"
            " — falling back to per-file cat"
        )
        return False

    if not extracted_rel_paths and entries:
        warnings.append(
            f"host {host}: ssh tar produced no extractable files — falling back to per-file cat"
        )
        return False

    missing = sorted(expected_rel_paths - extracted_rel_paths)
    for relative_path in missing:
        warnings.append(
            f"host {host}: tar extract missing {relative_path} — partial result"
        )
    return True


def _extract_tar_bytes_to_dir(
    host: str,
    tar_bytes: bytes,
    entries: list[tuple[str, str]],
    dest_dir: str,
    warnings: list[str],
) -> bool:
    """bytes-backed wrapper for unit checks around tar extraction."""
    if not tar_bytes:
        warnings.append(
            f"host {host}: ssh tar produced empty stream — falling back to per-file cat"
        )
        return False
    return _extract_tar_stream_to_dir(
        host,
        io.BytesIO(tar_bytes),
        entries,
        dest_dir,
        warnings,
    )


def _corpus_exclusion_entry(host: str, base: str, excluded_files: int) -> dict:
    """corpus 제외 엔트리의 단일 생성점 (sidecar 공개 계약 — host-handling.md SSOT).

    로컬·원격 두 수집 경로가 같은 스키마를 내도록 여기서만 만든다.
    """
    return {
        "host": host,
        "base": base,
        "reason": "size_cap",
        "cap_mib": CORPUS_FILE_SIZE_CAP_MIB,
        "excluded_files": excluded_files,
    }


def _remote_find_argv(host: str, base: str, size_expr: str) -> list[str]:
    """원격 jsonl 목록 find의 고정 argv. 수집 경로와 제외 카운트 경로가 공유한다.

    `'*.jsonl'`의 홑따옴표는 오타가 아니다 — SSH는 argv를 single string으로 합쳐
    원격 shell에 전달하므로, 따옴표로 감싸야 원격 glob expansion이 차단된다.
    `size_expr`은 `REMOTE_FIND_SIZE_INCLUDE`/`REMOTE_FIND_SIZE_EXCLUDE` 중 하나다.
    """
    return [
        "ssh",
        host,
        "find",
        base,
        "-type",
        "f",
        "-name",
        "'*.jsonl'",
        "-size",
        size_expr,
    ]


def _validated_remote_jsonl_lines(host: str, stdout: str) -> list[str]:
    """원격 find stdout에서 대상 정의를 만족하는 path만 남긴다.

    크기 판정은 하지 않는다 — size 조건은 호출한 find 쿼리가 적용하고, 이 함수는
    경로 검증만 담당한다. 수집 목록과 초과 건수 카운트가 같은 검증을 써야
    "제외된 N건"이 실제 대상 기준이 된다. `/subagents/` 하위는 wrapper output이라
    대상이 아니고, 비신뢰 path line은 `_allowed_remote_path`로 검증한다.
    """
    return [
        line
        for line in stdout.splitlines()
        if "/subagents/" not in line and _allowed_remote_path(host, line)
    ]


def _count_remote_oversized_files(
    host: str,
    base: str,
    budget: HostFetchBudget | None,
) -> int | None:
    """size cap으로 제외된 원격 jsonl 수를 센다 (침묵 절단 방지용 보조 카운트).

    측정 실패(budget 소진·timeout·ssh 부재·nonzero)는 `None`을 반환해 "제외 0건"과
    구분한다 — 실패를 0으로 축약하면 실제로 파일을 버리면서 리포트에는 제외 없음으로
    보이고, 이 카운트가 막으려던 침묵 절단이 카운트 자신에서 재발한다.
    """
    timeout: float = SSH_FIND_TIMEOUT_SECONDS
    if budget is not None:
        timeout_value, _ = budget.timeout_for(SSH_FIND_TIMEOUT_SECONDS)
        if timeout_value is None:
            return None
        timeout = timeout_value
    try:
        proc = subprocess.run(
            _remote_find_argv(host, base, REMOTE_FIND_SIZE_EXCLUDE),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return None
    if proc.returncode != 0:
        return None
    return len(_validated_remote_jsonl_lines(host, proc.stdout))


def collect_remote_files(
    host: str,
    warnings: list[str],
    budget: HostFetchBudget | None = None,
    corpus_exclusions: list[dict] | None = None,
) -> list[str]:
    """원격 호스트에서 jsonl 파일 path glob (subprocess.run 고정 argv).

    SSH 명령 인자에는 host-neutral relative tilde 표현 (`~/.claude/projects`,
    `~/.codex/sessions`)을 사용해 host별 absolute home prefix hardcoded를 피한다.
    원격 shell이 `~`를 해당 user의 home directory로 expansion한다.

    원격 find stdout의 path 라인은 비신뢰 입력으로 간주하여, `_allowed_remote_path`가
    통과한 line만 수집한다 — 제어문자/shell metacharacter/relative path/sibling-prefix
    포함 line은 silently 폐기한다. 검증은 absolute `HOST_PATH_MAP` prefix와의
    boundary 비교로 수행한다.

    cap 초과 파일은 목록에서 제외하고, 제외 건수를 `corpus_exclusions`
    리스트에 구조화 기록한다. 이 제외는 실패가 아니라 설계된 corpus 정책이므로
    `warnings`(=host partial 판정 입력)에 넣지 않는다.
    """
    _validate_host(host)
    all_files: list[str] = []
    for base in ("~/.claude/projects", "~/.codex/sessions"):
        budget_limited = False
        timeout = SSH_FIND_TIMEOUT_SECONDS
        if budget is not None:
            timeout_value, budget_limited = budget.timeout_for(SSH_FIND_TIMEOUT_SECONDS)
            if timeout_value is None:
                budget.warn_exceeded(warnings)
                break
            timeout = timeout_value
        try:
            proc = subprocess.run(
                _remote_find_argv(host, base, REMOTE_FIND_SIZE_INCLUDE),
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            if proc.returncode != 0:
                warnings.append(
                    f"host {host}: ssh find failed (rc={proc.returncode}) for {base}"
                )
                if budget is not None and budget.expired():
                    budget.warn_exceeded(warnings)
                    break
                continue
            all_files.extend(_validated_remote_jsonl_lines(host, proc.stdout))
            oversized = _count_remote_oversized_files(host, base, budget)
            if oversized is None:
                # 측정 실패는 partial 신호로 올린다 — 제외 건수를 모른 채 "0건"으로
                # 보고하면 corpus 편향이 리포트에서 사라진다.
                warnings.append(
                    f"host {host}: ssh size cap 제외 건수 측정 실패 for {base}"
                    " — 제외 규모 미상, partial result"
                )
            elif oversized and corpus_exclusions is not None:
                corpus_exclusions.append(_corpus_exclusion_entry(host, base, oversized))
            if budget is not None and budget.expired():
                budget.warn_exceeded(warnings)
                break
        except subprocess.TimeoutExpired:
            if budget_limited or (budget is not None and budget.expired()):
                budget.warn_exceeded(warnings)
                break
            warnings.append(f"host {host}: ssh find timeout for {base} — partial result")
        except FileNotFoundError:
            warnings.append(f"host {host}: ssh binary not found — partial result")
            break
    return all_files


def fetch_remote_file(
    host: str,
    path: str,
    warnings: list[str],
    budget: HostFetchBudget | None = None,
) -> str | None:
    """원격 jsonl 내용 가져오기. SSH 실패는 warnings 누적 + None 반환 (partial result)."""
    _validate_host(host)
    _validate_remote_path(host, path)
    budget_limited = False
    timeout = SSH_CAT_TIMEOUT_SECONDS
    if budget is not None:
        timeout_value, budget_limited = budget.timeout_for(SSH_CAT_TIMEOUT_SECONDS)
        if timeout_value is None:
            budget.warn_exceeded(warnings)
            return None
        timeout = timeout_value
    try:
        proc = subprocess.run(
            ["ssh", host, "cat", path],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        if budget_limited or (budget is not None and budget.expired()):
            budget.warn_exceeded(warnings)
        else:
            warnings.append(f"host {host}: ssh cat timeout for {path} — partial result")
        return None
    except FileNotFoundError:
        warnings.append(f"host {host}: ssh binary not found — partial result")
        return None
    if budget is not None and budget.expired():
        budget.warn_exceeded(warnings)
    if proc.returncode != 0:
        warnings.append(
            f"host {host}: ssh cat failed (rc={proc.returncode}) for {path} — partial result"
        )
        return None
    return proc.stdout


def _stderr_snippet(stderr: bytes) -> str:
    return stderr.decode("utf-8", "replace").strip()[:200]


def _fetch_remote_files_tar_to_dir(
    host: str,
    entries: list[tuple[str, str]],
    dest_dir: str,
    warnings: list[str],
    budget: HostFetchBudget | None = None,
) -> bool:
    """원격 파일 묶음을 단일 tar stream으로 가져와 tempdir에 추출한다."""
    _validate_host(host)
    if not entries:
        return True

    budget_limited = False
    timeout = SSH_TAR_TIMEOUT_SECONDS
    if budget is not None:
        timeout_value, budget_limited = budget.timeout_for(SSH_TAR_TIMEOUT_SECONDS)
        if timeout_value is None:
            budget.warn_exceeded(warnings)
            return False
        timeout = timeout_value

    try:
        with tempfile.NamedTemporaryFile(
            prefix=f"remote-{host}-",
            suffix=".tar",
            dir=dest_dir,
        ) as archive_fp:
            proc = subprocess.run(
                _build_remote_tar_argv(host),
                input=_build_remote_tar_stdin(entries),
                stdout=archive_fp,
                stderr=subprocess.PIPE,
                timeout=timeout,
            )
            archive_fp.flush()
            archive_size = archive_fp.tell()

            if proc.returncode != 0:
                detail = _stderr_snippet(proc.stderr)
                suffix = f": {detail}" if detail else ""
                warnings.append(
                    f"host {host}: ssh tar failed (rc={proc.returncode}){suffix}"
                    " — falling back to per-file cat"
                )
                return False

            if archive_size == 0:
                warnings.append(
                    f"host {host}: ssh tar produced empty stream — falling back to per-file cat"
                )
                return False

            archive_fp.seek(0)
            return _extract_tar_stream_to_dir(host, archive_fp, entries, dest_dir, warnings)
    except subprocess.TimeoutExpired:
        if budget_limited or (budget is not None and budget.expired()):
            budget.warn_exceeded(warnings)
        else:
            warnings.append(
                f"host {host}: ssh tar timeout — falling back to per-file cat"
            )
        return False
    except FileNotFoundError:
        warnings.append(
            f"host {host}: ssh binary not found during tar fetch — falling back to per-file cat"
        )
        return False


def analyze_remote_sessions_via_tar(
    host: str,
    entries: list[tuple[str, str]],
    warnings: list[str],
    budget: HostFetchBudget | None = None,
) -> list[dict] | None:
    """remote jsonl 목록을 tar batch로 fetch 후 로컬 tempdir에서 분석한다.

    반환값이 None이면 caller가 기존 per-file cat fallback을 실행한다.
    """
    _validate_host(host)
    if not entries:
        return []

    with tempfile.TemporaryDirectory(prefix=f"analyze-da-sessions-{host}-") as tmp_dir:
        if not _fetch_remote_files_tar_to_dir(host, entries, tmp_dir, warnings, budget):
            return None

        sessions: list[dict] = []
        for logical_path, relative_path in entries:
            local_path = os.path.join(tmp_dir, *relative_path.split("/"))
            if not os.path.isfile(local_path):
                warnings.append(
                    f"host {host}: tar extracted file missing for {logical_path} — partial result"
                )
                continue
            result = analyze_session(local_path, logical_path=logical_path)
            if result is not None:
                sessions.append(result)
        return sessions


def check_remote_host_preflight(host: str, warnings: list[str]) -> bool:
    """원격 host가 실제로 응답하는지 저비용으로 확인한다.

    Python fetch preflight uses ConnectTimeout plus a subprocess timeout and
    deliberately does not pass BatchMode=yes. The weekly shell retry-window
    preflight uses BatchMode=yes and no separate subprocess timeout; update
    both callsite comments and host-handling.md if either contract changes.
    """
    _validate_host(host)
    try:
        proc = subprocess.run(
            [
                "ssh",
                "-o",
                f"ConnectTimeout={SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS}",
                host,
                "true",
            ],
            capture_output=True,
            text=True,
            timeout=SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS,
        )
        if proc.returncode == 0:
            return True
        warnings.append(
            f"host {host}: ssh preflight failed (rc={proc.returncode}) — fetch skip, partial result"
        )
        return False
    except subprocess.TimeoutExpired:
        warnings.append(
            f"host {host}: ssh preflight timeout (절전/무응답 가능성) — fetch skip, partial result"
        )
        return False
    except FileNotFoundError:
        warnings.append(
            f"host {host}: ssh binary not found during preflight — partial result"
        )
        return False


def check_controlmaster_active(
    host: str,
    warnings: list[str],
    preflight_already_ok: bool = False,
    budget: HostFetchBudget | None = None,
) -> bool:
    """ControlMaster master socket이 활성인지 확인한다.

    mux socket 존재만으로 원격 생존을 판단하지 않기 위해, caller가 이미 확인하지 않은
    경우에는 `ssh -o ConnectTimeout=10 <host> true` preflight를 먼저 수행한다.
    반환값이 False이면 caller가 해당 host fetch를 skip한다 (fail-fast).
    """
    _validate_host(host)
    if not preflight_already_ok and not check_remote_host_preflight(host, warnings):
        return False

    budget_limited = False
    timeout = SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS
    if budget is not None:
        timeout_value, budget_limited = budget.timeout_for(
            SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS
        )
        if timeout_value is None:
            budget.warn_exceeded(warnings)
            return False
        timeout = timeout_value

    try:
        proc = subprocess.run(
            ["ssh", "-O", "check", host],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if budget is not None and budget.expired():
            budget.warn_exceeded(warnings)
            return False
        if proc.returncode == 0:
            return True
    except subprocess.TimeoutExpired:
        if budget_limited or (budget is not None and budget.expired()):
            budget.warn_exceeded(warnings)
            return False
    except FileNotFoundError:
        pass
    warnings.append(
        f"host {host}: ControlMaster 확인 실패 — fetch skip, partial result"
    )
    return False


def analyze_remote_session(
    host: str,
    path: str,
    warnings: list[str],
    budget: HostFetchBudget | None = None,
) -> dict | None:
    """원격 jsonl을 fetch하여 임시 파일에 쓰고 analyze_session 호출."""
    content = fetch_remote_file(host, path, warnings, budget)
    if content is None or not content:
        return None
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
        if _remote_path_has_disallowed_chars(home):
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
    # corpus 정책으로 제외한 파일 기록 — 실패가 아니므로 warnings와 분리한다
    # (warnings는 host partial 판정 입력이라, 상시 발생하는 제외를 섞으면 수집이
    # 정상인 주에도 영구 partial이 된다).
    corpus_exclusions: list[dict] = []
    cur_host = current_host()
    host_budgets: dict[str, HostFetchBudget] = {}
    remote_preflight_ok: set[str] = set()
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
                files_by_host[host] = collect_local_files(host, corpus_exclusions)
            else:
                if not check_remote_host_preflight(host, warnings):
                    files_by_host[host] = []
                    continue
                remote_preflight_ok.add(host)
                budget = HostFetchBudget.start(host)
                host_budgets[host] = budget
                files_by_host[host] = collect_remote_files(
                    host, warnings, budget, corpus_exclusions
                )
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

        budget = host_budgets.get(host)
        if budget is not None and budget.expired():
            budget.warn_exceeded(warnings)
            continue

        # remote: ControlMaster preflight + worker pool.
        # ControlMaster 비활성이면 K=1 강등이 수천 파일 직렬 fetch ≈ 수십 분으로 host budget
        # 안에 끝나기 어려우므로 fail-fast로 host 전체 fetch를 skip하고 명시적 warning을
        # 누적한다. 사용자가 ControlMaster 활성화 (mac nrs 등) 누락을 즉시 인지할 수 있다.
        cm_active = check_controlmaster_active(
            host,
            warnings,
            preflight_already_ok=host in remote_preflight_ok,
            budget=budget,
        )
        if not cm_active:
            if budget is not None and budget.warning_emitted:
                continue
            warnings.append(
                f"host {host}: ControlMaster 비활성으로 fetch skip — 활성화 후 재실행 필요"
                f" (직렬 fallback은 {SSH_HOST_FETCH_BUDGET_SECONDS}초 budget 안에 완료 불가능)."
                f" minipc는 nrs, mac은 사용자 수동 nrs."
            )
            continue
        if budget is None:
            budget = HostFetchBudget.start(host)
            host_budgets[host] = budget
        if budget.expired():
            budget.warn_exceeded(warnings)
            continue

        tar_entries = _prepare_remote_tar_entries(host, files, warnings)
        if not tar_entries:
            continue

        try:
            tar_sessions = analyze_remote_sessions_via_tar(
                host,
                tar_entries,
                warnings,
                budget,
            )
        except Exception as e:
            warnings.append(
                f"host {host}: ssh tar batch exception ({type(e).__name__}: {e})"
                " — falling back to per-file cat"
            )
            tar_sessions = None
        if tar_sessions is not None:
            sessions.extend(tar_sessions)
            continue
        if budget.warning_emitted or budget.expired():
            budget.warn_exceeded(warnings)
            continue

        fallback_files = [logical_path for logical_path, _ in tar_entries]

        # remote_warnings는 worker별로 분리 수집 후 main thread에서 path 순으로 merge.
        # CPython GIL이 list.append를 atomic하게 보장하지만 worker 간 순서가 비결정적이므로
        # 별도 list로 받아 deterministic ordering을 강제한다.
        def _fetch_one(p: str) -> tuple[str, dict | None, list[str]]:
            local_warnings: list[str] = []
            res = analyze_remote_session(host, p, local_warnings, budget)
            return (p, res, local_warnings)

        host_results: list[tuple[str, dict | None, list[str]]] = []
        with concurrent.futures.ThreadPoolExecutor(max_workers=SSH_FETCH_WORKERS) as executor:
            futures = {executor.submit(_fetch_one, p): p for p in fallback_files}
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
    agg = build_aggregate(
        sessions, args.hosts, corpus_label, warnings, json_path, corpus_exclusions
    )

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
