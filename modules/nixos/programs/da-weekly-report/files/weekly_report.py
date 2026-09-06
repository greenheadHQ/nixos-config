#!/usr/bin/env python3
"""da-weekly-report weekly JSON assembler, delta calculator, and renderer.

The canonical report schema is documented in
`modules/shared/programs/claude/files/skills/analyzing-da-sessions/references/output-format.md`.

Only `weekly-????-W??.json` files are delta inputs. `*-publish.json` is an
append-only publish log and is structurally excluded from the delta glob.
"""

from __future__ import annotations

import argparse
import datetime as dt
import glob
import html
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import zoneinfo
from pathlib import Path
from typing import Any, NamedTuple


SCHEMA_VERSION = 1
HEALTH_FORMULA_VERSION = 2
# v2 (#1237): drift_repair_commits 측정 창을 발행 주차 [월 00:00, +7d)에서 발행 주차 직전
# 7일로 재정의. v1 창은 실행 시점에 대부분 미래라 실행 시각까지의 몇 시간치만 관측됐으므로 v1
# 리포트와의 delta는 주간 활동 변화가 아니다 — algorithm.md "run-da 건강 지표" 계약대로 버전을 올리고 단절을 명시한다.
# 단절은 상태가 아니라 관계다: build_weekly_report가 비교 대상 리포트 중 더 낮은 산식 버전이
# 있는 주(전환 주)에만 이 문자열을 health.formula_break에 싣고, 그 외 주는 None이다.
HEALTH_FORMULA_BREAK = (
    "v2 (#1237): drift_repair_commits 측정 창을 발행 주차 직전 7일로 재정의 — "
    "v1 창은 실행 시각까지의 몇 시간치만 관측돼 v1 리포트와의 delta는 주간 활동 변화가 아니다"
)
MEASUREMENT_WINDOW_DAYS = 7
# 렌더러 2종(전문·GitHub)과 해설 프롬프트가 공유하는 라벨 — 문구 변경 지점을 한 곳으로.
# 테스트는 의도적으로 문구 리터럴을 고정한다(상수를 참조하면 문구 회귀를 잡지 못한다) —
# 문구를 바꾸면 테스트도 함께 갱신한다.
METRIC_SCOPE_LABEL = "M-1~M-4·M-6"  # M-5는 #1257에서 폐기 — 저장소 정본 표기
# 아래 지표 범위 행·해설 프롬프트의 "누적값" 정의는 analyzing-da-sessions algorithm.md "Metric Catalog"
# 절의 재서술이다 — 계약의 소유자는 sidecar 수집 범위(analyze.py live 전수)이지 이 파일이 아니다.
WEEK_ROW_LABEL = "발행 주차"
MEASUREMENT_WINDOW_ROW_LABEL = "측정 창 (drift repair 커밋)"
MEASUREMENT_WINDOW_SUFFIX = f"발행 주차 직전 {MEASUREMENT_WINDOW_DAYS}일"
METRIC_SCOPE_ROW = (
    f"| 지표 범위 | {METRIC_SCOPE_LABEL}·세션 수는 전체 코퍼스 누적값 "
    "(주간 값 아님 — 주간 변화는 전주 delta 표) |"
)
KST = dt.timezone(dt.timedelta(hours=9), "KST")
KST_NAME = "Asia/Seoul"
RUN_DA_PATH = "modules/shared/programs/claude/files/skills/run-da/"
RUN_DA_SKILL_PATH = RUN_DA_PATH + "SKILL.md"
WEEKLY_REPORT_RE = re.compile(r"^weekly-\d{4}-W\d{2}\.json$")
DRIFT_SUBJECT_RE = re.compile(r"(fix|refactor|chore)", re.I)
DRIFT_BODY_RE = re.compile(r"(drift|참조|사본|dangling|동기화|SSOT)", re.I)
REMOTE_PREFLIGHT_ALERT_KEY = "remote_preflight_alert_attempted"
RETRYABLE_PUBLISH_STATUSES = {"failed", "blocked"}
TRACEABILITY_RENDER_SESSION_LIMIT = 50
COMMENTARY_INPUT_MAX_BYTES = 262_144
GITHUB_MARKDOWN_MAX_BYTES = 60_000
COMMENTARY_PROMPT = "\n".join([
    "아래 DA weekly report projection을 읽고 특이점, 공통점/차이점, 다음 주에 볼 신호를 한국어 한두 문단으로 해설하라.",
    "숫자를 새로 만들지 말고 입력 JSON의 값만 근거로 사용하라.",
    f"지표 정의 (오독 방지 — #1237): metrics의 {METRIC_SCOPE_LABEL}과 session_counts는 분석 시점 전체 코퍼스의 누적값이다 — 그 주의 활동량이 아니다. "
    "주간 변화는 deltas.items[].comparisons만 근거로 삼는다 — comparisons는 존재하는 최근 리포트 각각과의 비교이므로, week_id가 발행 주차 바로 전 주인 comparison의 session_counts.total delta만 그 주에 새로 쌓인 세션 수의 근사치이고(sidecar의 total 정의가 주차 간 같다는 전제 — 이 리포트는 그 정의 변경을 감지하지 않는다), 주 간격이 벌어진 comparison은 그 기간의 누적 증가분이다. "
    f"health.drift_repair_commit_count만 week.measurement_start~measurement_end({MEASUREMENT_WINDOW_SUFFIX}) 창의 값이며, health.formula_break가 있으면 deltas.previous_reports 중 health_formula_version이 현재 health.health_formula_version보다 낮은 주와의 health delta는 산식 변경분이지 활동 변화가 아니다. "
    "hosts의 analyzed_sessions가 0이거나 status가 partial이면 그 호스트의 수집 실패이지 활동 감소가 아니므로 품질 회귀로 해석하지 마라.",
])
M1_KEYS = ("FULL", "LITE", "SKIP")
M2_KEYS = ("CONFIRMED_ISSUE", "NOT_AN_ISSUE", "NEEDS_MORE_INFO")
M3_BUNDLES = ("Correctness", "Design", "Regression", "Maintainability")
WEEKDAY_INDEX = {
    "Mon": 0,
    "Tue": 1,
    "Wed": 2,
    "Thu": 3,
    "Fri": 4,
    "Sat": 5,
    "Sun": 6,
}
SECRET_ASSIGNMENT_NAMES = {
    "GH_PAT",
    "GH_TOKEN",
    "GITHUB_PAT",
    "GITHUB_TOKEN",
    "PUSHOVER_TOKEN",
    "PUSHOVER_USER",
}
GITHUB_PUBLISH_REASON_OK = "ok"
GITHUB_PUBLISH_REASON_URL_MISSING = "url_missing"
GITHUB_PUBLISH_REASON_GH_NONZERO = "gh_nonzero"
GITHUB_PUBLISH_REASON_PROJECTION = "projection_or_staging"
GITHUB_PUBLISH_REASON_SECRET_SNAPSHOT = "secret_snapshot"
GITHUB_PUBLISH_REASON_OUTBOUND_SECRET = "outbound_secret"
GITHUB_PUBLISH_REASON_UNAVAILABLE = "publisher_unavailable"
GITHUB_PUBLISH_STATUS_BY_REASON = {
    GITHUB_PUBLISH_REASON_OK: "success",
    GITHUB_PUBLISH_REASON_URL_MISSING: "success",
    GITHUB_PUBLISH_REASON_GH_NONZERO: "failed",
    GITHUB_PUBLISH_REASON_PROJECTION: "blocked",
    GITHUB_PUBLISH_REASON_SECRET_SNAPSHOT: "blocked",
    GITHUB_PUBLISH_REASON_OUTBOUND_SECRET: "blocked",
    GITHUB_PUBLISH_REASON_UNAVAILABLE: "blocked",
}


class ProjectionError(ValueError):
    """A bounded consumer projection cannot be produced safely."""


class SecretSnapshotError(ValueError):
    """Outbound secret sources cannot be snapshotted safely."""


class GuardedPublishResult(NamedTuple):
    """Validated wire result shared by the Python publisher and Bash consumer."""

    status: str
    reason: str
    url: str


def guarded_publish_result(reason: str, url: str = "") -> GuardedPublishResult:
    """Build one exact status/reason/url tuple from the producer contract."""
    status = GITHUB_PUBLISH_STATUS_BY_REASON[reason]
    if (reason == GITHUB_PUBLISH_REASON_OK) != bool(url):
        raise ValueError("guarded publisher URL contract violated")
    return GuardedPublishResult(status, reason, url)


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def parse_datetime(value: str, default_tz: dt.tzinfo = KST) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=default_tz)
    return parsed


def timezone_for_name(timezone_name: str) -> dt.tzinfo:
    if timezone_name == KST_NAME:
        return KST
    try:
        return zoneinfo.ZoneInfo(timezone_name)
    except zoneinfo.ZoneInfoNotFoundError as exc:
        raise ValueError(f"unknown timezone: {timezone_name}") from exc


def default_week_bounds(now: dt.datetime | None = None) -> tuple[dt.datetime, dt.datetime]:
    base = now or dt.datetime.now(KST)
    base = base.astimezone(KST)
    start_date = base.date() - dt.timedelta(days=base.weekday())
    start = dt.datetime.combine(start_date, dt.time.min, tzinfo=KST)
    return start, start + dt.timedelta(days=7)


def measurement_window(week_start: dt.datetime) -> tuple[dt.datetime, dt.datetime]:
    """발행 주차 시작(월 00:00 KST) 직전 7일 — health 측정 창(drift repair 커밋).

    리포트는 발행 주차 월요일 09~14시 재시도 창에서 생성되므로 [week_start, week_end)는
    실행 시점에 대부분 미래다. 그 창으로 `git log --since/--until`을 세면
    drift_repair_commits는 실행 시각까지의 몇 시간치만 잡혀 주간 값이 아니다 (#1237 — 2026-W33
    LLM 해설이 그 0을 "정비 활동 부재"라는 품질 신호로 오독한 실측). 발행 주차 id·경계는 그대로
    두고, 측정 창만 직전 7일(지난 주 월 00:00 ~ 이번 주 월 00:00)로 옮긴다.
    """
    return week_start - dt.timedelta(days=MEASUREMENT_WINDOW_DAYS), week_start


def week_id_for(start: dt.datetime) -> str:
    iso = start.astimezone(KST).isocalendar()
    return f"{iso.year:04d}-W{iso.week:02d}"


def report_filename(week_id: str) -> str:
    return f"weekly-{week_id}.json"


def attempt_state_filename(week_id: str) -> str:
    return f"attempt-{week_id}.state"


def attempt_state_path(state_dir: str | os.PathLike[str], week_id: str) -> str:
    return str(Path(state_dir) / attempt_state_filename(week_id))


def validate_deadline_hour(deadline_hour: int) -> int:
    if not 0 <= deadline_hour <= 23:
        raise ValueError("deadline hour must be between 0 and 23")
    return deadline_hour


def validate_start_hour(start_hour: int) -> int:
    if not 0 <= start_hour <= 23:
        raise ValueError("start hour must be between 0 and 23")
    return start_hour


def validate_window_weekday(weekday: str) -> str:
    if weekday not in WEEKDAY_INDEX:
        raise ValueError(f"window weekday must be one of: {', '.join(WEEKDAY_INDEX)}")
    return weekday


def validate_retry_window(start_hour: int, deadline_hour: int) -> tuple[int, int]:
    start_hour = validate_start_hour(start_hour)
    deadline_hour = validate_deadline_hour(deadline_hour)
    if start_hour > deadline_hour:
        raise ValueError("start hour must be <= deadline hour")
    return start_hour, deadline_hour


def deadline_reached_at(
    now: dt.datetime,
    deadline_hour: int,
    timezone_name: str = KST_NAME,
    *,
    window_weekday: str = "Mon",
    start_hour: int = 0,
) -> bool:
    start_hour, deadline_hour = validate_retry_window(start_hour, deadline_hour)
    weekday_index = WEEKDAY_INDEX[validate_window_weekday(window_weekday)]
    timezone = timezone_for_name(timezone_name)
    local_now = now.astimezone(timezone)
    week_start = local_now.date() - dt.timedelta(days=local_now.weekday())
    window_date = week_start + dt.timedelta(days=weekday_index)
    window_start_at = dt.datetime.combine(
        window_date,
        dt.time(hour=start_hour),
        tzinfo=timezone,
    )
    deadline_at = dt.datetime.combine(
        window_date,
        dt.time(hour=deadline_hour),
        tzinfo=timezone,
    )
    if local_now < window_start_at:
        return False
    return local_now >= deadline_at


def parse_attempt_state(text: str) -> dict[str, str]:
    state = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        state[key.strip()] = value.strip()
    return state


def claim_attempt_state_key(
    path: str | os.PathLike[str],
    key: str = REMOTE_PREFLIGHT_ALERT_KEY,
    value: str | None = None,
) -> bool:
    target = Path(path)
    try:
        existing_text = target.read_text(encoding="utf-8")
    except FileNotFoundError:
        existing_text = ""

    if key in parse_attempt_state(existing_text):
        return False

    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fp:
        if existing_text and not existing_text.endswith("\n"):
            fp.write("\n")
        fp.write(f"{key}={value or utc_now_iso()}\n")
    target.chmod(0o600)
    return True


def load_json(path: str | os.PathLike[str]) -> dict:
    with open(path, "r", encoding="utf-8") as fp:
        return json.load(fp)


def stage_text(path: str | os.PathLike[str], text: str) -> Path:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target.name}.",
        suffix=".tmp",
        dir=target.parent,
        text=True,
    )
    tmp = Path(tmp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fp:
            fp.write(text)
            fp.flush()
            os.fsync(fp.fileno())
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        tmp.unlink(missing_ok=True)
        raise
    return tmp


def replace_staged_text(tmp: Path, path: str | os.PathLike[str]) -> None:
    target = Path(path)
    os.replace(tmp, target)
    target.chmod(0o600)


def atomic_write_text(path: str | os.PathLike[str], text: str) -> None:
    tmp = stage_text(path, text)
    try:
        replace_staged_text(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def atomic_write_json(path: str | os.PathLike[str], obj: dict) -> None:
    atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


def atomic_write_report_pair(
    json_path: str | os.PathLike[str],
    report: dict,
    markdown_path: str | os.PathLike[str],
) -> None:
    """Stage both canonical views, then replace Markdown before JSON commit marker."""
    json_text = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    markdown_text = render_markdown(report) + "\n"
    staged_json: Path | None = None
    staged_markdown: Path | None = None
    try:
        staged_markdown = stage_text(markdown_path, markdown_text)
        staged_json = stage_text(json_path, json_text)
        replace_staged_text(staged_markdown, markdown_path)
        staged_markdown = None
        replace_staged_text(staged_json, json_path)
        staged_json = None
    finally:
        if staged_markdown is not None:
            staged_markdown.unlink(missing_ok=True)
        if staged_json is not None:
            staged_json.unlink(missing_ok=True)


def run_git(repo_root: str, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", repo_root, *args],
        capture_output=True,
        text=True,
        check=False,
    )


def line_count(text: str) -> int:
    if not text:
        return 0
    return text.count("\n") + (0 if text.endswith("\n") else 1)


def collect_document_size(repo_root: str, warnings: list[str]) -> dict:
    proc = run_git(repo_root, ["ls-tree", "-r", "HEAD", "--name-only", "--", RUN_DA_PATH])
    if proc.returncode != 0:
        warnings.append(f"git ls-tree failed for run-da docs: {proc.stderr.strip()}")
        return {"markdown_file_count": 0, "total_line_count": 0, "files": []}

    md_files = [
        path
        for path in proc.stdout.splitlines()
        if path.endswith(".md") and "/evals/" not in path
    ]
    total_lines = 0
    file_entries = []
    for path in md_files:
        show = run_git(repo_root, ["show", f"HEAD:{path}"])
        if show.returncode != 0:
            warnings.append(f"git show failed for {path}: {show.stderr.strip()}")
            continue
        lines = line_count(show.stdout)
        total_lines += lines
        file_entries.append({"path": path, "line_count": lines})
    return {
        "markdown_file_count": len(file_entries),
        "total_line_count": total_lines,
        "files": file_entries,
        "excluded": "paths containing /evals/",
    }


def parse_drift_log(output: str) -> list[dict]:
    commits = []
    for raw_record in output.split("\x1e"):
        record = raw_record.strip("\n")
        if not record:
            continue
        parts = record.split("\x00", 2)
        if len(parts) != 3:
            continue
        commit_hash, subject, body = parts
        haystack = f"{subject}\n{body}"
        if DRIFT_SUBJECT_RE.search(subject) and DRIFT_BODY_RE.search(haystack):
            commits.append({
                "hash": commit_hash,
                "subject": subject.strip(),
            })
    return commits


def collect_drift_repair_commits(
    repo_root: str,
    window_start: dt.datetime,
    window_end: dt.datetime,
    warnings: list[str],
) -> dict:
    """측정 창 [window_start, window_end)의 drift 수리 커밋 — 발행 주차가 아니라
    measurement_window()가 낸 직전 7일을 받는다 (#1237)."""
    git_format = "%H%x00%s%x00%B%x1e"
    proc = run_git(repo_root, [
        "log",
        f"--since={window_start.isoformat()}",
        f"--until={window_end.isoformat()}",
        "--first-parent",
        "main",
        f"--format={git_format}",
        "--",
        RUN_DA_PATH,
    ])
    if proc.returncode != 0:
        warnings.append(f"git log failed for drift repair commits: {proc.stderr.strip()}")
        commits: list[dict] = []
    else:
        commits = parse_drift_log(proc.stdout)
    return {
        "count": len(commits),
        "commit_hashes": [item["hash"] for item in commits],
        "commits": commits,
        "since": window_start.isoformat(),
        "until": window_end.isoformat(),
        "subject_regex": DRIFT_SUBJECT_RE.pattern,
        "body_regex": DRIFT_BODY_RE.pattern,
        "branch": "main",
        "first_parent": True,
    }


def markdown_section(text: str, heading: str) -> str:
    pattern = re.compile(rf"^##\s+{re.escape(heading)}\s*$", re.M)
    match = pattern.search(text)
    if not match:
        return ""
    next_heading = re.search(r"^##\s+", text[match.end():], re.M)
    if not next_heading:
        return text[match.end():]
    return text[match.end(): match.end() + next_heading.start()]


def count_rules_from_text(skill_text: str) -> dict:
    invariants = markdown_section(skill_text, "핵심 invariants")
    cautions = markdown_section(skill_text, "주의사항")
    non_goals = markdown_section(skill_text, "Non-goals")
    core_count = len(re.findall(r"^\s*\d+\.\s+", invariants, re.M))
    caution_count = len(re.findall(r"^\s*[-*]\s+", cautions, re.M))
    non_goal_count = len(re.findall(r"^\s*\d+\.\s+", non_goals, re.M))
    return {
        "core_invariants_numbered": core_count,
        "cautions_bullets": caution_count,
        "non_goals_numbered": non_goal_count,
        "total": core_count + caution_count + non_goal_count,
    }


def collect_rule_counts(repo_root: str, warnings: list[str]) -> dict:
    path = Path(repo_root) / RUN_DA_SKILL_PATH
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        warnings.append(f"run-da SKILL.md read failed: {exc}")
        return {
            "core_invariants_numbered": 0,
            "cautions_bullets": 0,
            "non_goals_numbered": 0,
            "total": 0,
        }
    return count_rules_from_text(text)


def collect_health_metrics(repo_root: str, week_start: dt.datetime) -> dict:
    """발행 주차 시작(week_start)에서 측정 창을 유도해 health를 수집한다.

    창의 소유자는 여기서 부르는 measurement_window 하나다 — 리포트의
    week.measurement_start/end는 이 결과의 drift_repair_commits.since/until을 그대로 읽는다.
    formula_break는 이 함수가 아니라 build_weekly_report가 비교 대상 리포트를 보고 결정한다.
    """
    warnings: list[str] = []
    window_start, window_end = measurement_window(week_start)
    return {
        "health_formula_version": HEALTH_FORMULA_VERSION,
        "run_da_path": RUN_DA_PATH,
        "document_size": collect_document_size(repo_root, warnings),
        "drift_repair_commits": collect_drift_repair_commits(
            repo_root, window_start, window_end, warnings
        ),
        "rule_counts": collect_rule_counts(repo_root, warnings),
        "warnings": warnings,
    }


def normalize_analysis(sidecar: dict) -> dict:
    metrics = sidecar.get("metrics", {})
    normalized_metrics = {
        "M-1": {
            "denominator": metrics.get("M-1", {}).get("denominator"),
            "n": metrics.get("M-1", {}).get("n", 0),
            "distribution": metrics.get("M-1", {}).get("distribution", {}),
            "percentages": metrics.get("M-1", {}).get("percentages", {}),
        },
        "M-2": {
            "denominator": metrics.get("M-2", {}).get("denominator"),
            "n": metrics.get("M-2", {}).get("n", 0),
            "distribution": metrics.get("M-2", {}).get("distribution", {}),
            "percentages": metrics.get("M-2", {}).get("percentages", {}),
            "source_distribution": metrics.get("M-2", {}).get("source_distribution", {}),
        },
        "M-3": {
            "by_bundle": metrics.get("M-3", {}).get("by_bundle", {}),
        },
        "M-4": {
            "round_key": metrics.get("M-4", {}).get("round_key"),
            "baseline_note": metrics.get("M-4", {}).get("baseline_note"),
            "transition_matrix": metrics.get("M-4", {}).get("transition_matrix", {}),
        },
        "M-6": {
            "name": metrics.get("M-6", {}).get("name", "persistence_key non-convergence"),
            "persistence_key": metrics.get("M-6", {}).get("persistence_key"),
            "key_block_count_distribution": metrics.get("M-6", {}).get(
                "key_block_count_distribution", {}
            ),
            "coverage": metrics.get("M-6", {}).get("coverage", {}),
        },
    }
    return {
        "sidecar_schema_version": sidecar.get("schema_version"),
        "captured_at": sidecar.get("captured_at"),
        "hosts": sidecar.get("hosts", []),
        "corpus": sidecar.get("corpus"),
        "session_counts": sidecar.get("session_counts", {}),
        "metrics": normalized_metrics,
        "derived": {
            "intensity_full_finding_zero_rate": sidecar.get("derived", {}).get(
                "intensity_full_finding_zero_rate", 0.0
            )
        },
        "warnings": sidecar.get("warnings", []),
    }


def warning_hosts(warnings: list[str]) -> set[str]:
    hosts = set()
    for warning in warnings:
        match = re.match(r"host\s+([A-Za-z0-9_-]+):", warning)
        if match:
            hosts.add(match.group(1))
    return hosts


def build_coverage(sidecar: dict, health: dict, analyze_exit_code: int) -> dict:
    diagnostics = sidecar.get("diagnostics", {}).get("summary", {})
    session_counts = sidecar.get("session_counts", {})
    total_sessions = session_counts.get("total", 0) or 0
    warnings = sidecar.get("warnings", [])
    warning_host_set = warning_hosts(warnings)
    corpus_exclusions = [
        entry for entry in sidecar.get("corpus_exclusions", []) if isinstance(entry, dict)
    ]
    trace_hosts = sidecar.get("traceability", {}).get("coverage", {}).get("host_distribution", {})
    host_collection = {}
    for host in sidecar.get("hosts", []):
        analyzed_count = trace_hosts.get(host, 0)
        status = "partial" if host in warning_host_set else "ok"
        if analyzed_count == 0 and host not in warning_host_set:
            status = "unknown"
        host_collection[host] = {
            "status": status,
            "analyzed_sessions": analyzed_count,
            "warnings": [w for w in warnings if w.startswith(f"host {host}:")],
            # corpus 정책 제외 (size cap 등). 실패가 아니므로 status/partial에 영향을
            # 주지 않고, 분모 변화를 읽을 수 있도록 건수만 노출한다.
            "excluded_files": sum(
                entry.get("excluded_files", 0) or 0
                for entry in corpus_exclusions
                if entry.get("host") == host
            ),
        }

    arbiter_sessions = session_counts.get("arbiter_marker_sessions", 0) or 0
    intensity_sessions = session_counts.get("intensity_marker_sessions", 0) or 0
    return {
        "partial": bool(warnings or health.get("warnings") or analyze_exit_code != 0),
        "analyze_exit_code": analyze_exit_code,
        "diagnostics": {
            "parse_failure_count": diagnostics.get("parse_failure", 0),
            "exclusion_count": diagnostics.get("exclusion", 0),
            "invalid_verdict_count": diagnostics.get("invalid_verdict", 0),
            "missing_persistence_component_count": diagnostics.get(
                "missing_persistence_component", 0
            ),
            "all": diagnostics,
        },
        "diagnostic_rates": {
            "parse_failures_per_session": (
                diagnostics.get("parse_failure", 0) / total_sessions if total_sessions else 0.0
            ),
            "exclusions_per_session": (
                diagnostics.get("exclusion", 0) / total_sessions if total_sessions else 0.0
            ),
        },
        "marker_missing_rates": {
            "arbiter_marker_missing_rate": (
                (total_sessions - arbiter_sessions) / total_sessions if total_sessions else 0.0
            ),
            "intensity_marker_missing_rate": (
                (total_sessions - intensity_sessions) / total_sessions if total_sessions else 0.0
            ),
        },
        "m2_source_distribution": sidecar.get("metrics", {}).get("M-2", {}).get(
            "source_distribution", {}
        ),
        "host_collection": host_collection,
        "warnings": warnings,
        "health_warnings": health.get("warnings", []),
    }


def build_traceability(
    sidecar: dict,
    limit: int = TRACEABILITY_RENDER_SESSION_LIMIT,
) -> dict:
    # Keep rendered comments compact while preserving the most link-rich sessions.
    raw = sidecar.get("traceability", {})
    sessions = raw.get("sessions", [])

    def session_score(item: dict) -> tuple[int, str]:
        refs = item.get("references", {})
        ref_count = sum(len(refs.get(key, [])) for key in ("prs", "issues", "bare_numbers"))
        # limit 초과 시 참조가 실제로 많은 세션을 유지한다 (path는 tie-breaker).
        return (ref_count, item.get("path") or "")

    selected = sorted(sessions, key=session_score, reverse=True)[:limit]
    stable_sessions = []
    for item in selected:
        stable_sessions.append({
            "path": item.get("path"),
            "host": item.get("host"),
            "format": item.get("format"),
            "cwd": item.get("cwd"),
            "git_branch": item.get("git_branch"),
            "session_id": item.get("session_id"),
            "rollout_date": item.get("rollout_date"),
            "complete": item.get("complete"),
            "missing_fields": item.get("missing_fields", []),
            "fallback_fields": item.get("fallback_fields", []),
            "references": item.get("references", {}),
        })
    return {
        "coverage": raw.get("coverage", {}),
        "sessions": stable_sessions,
        "omitted_session_count": max(0, len(sessions) - len(stable_sessions)),
    }


def previous_report_paths(state_dir: str, current_week_id: str | None = None) -> list[str]:
    paths = []
    for path in glob.glob(str(Path(state_dir) / "weekly-????-W??.json")):
        name = os.path.basename(path)
        if not WEEKLY_REPORT_RE.match(name):
            continue
        if current_week_id and name == report_filename(current_week_id):
            continue
        paths.append(path)
    return sorted(paths, reverse=True)[:2]


def get_path(obj: dict, dotted_path: str) -> Any:
    cur: Any = obj
    for part in dotted_path.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


DELTA_SPECS = [
    # 누적 코퍼스 세션 수의 전주 대비 증가분 = 그 주에 새로 쌓인 세션 수의 근사치
    # (수집 실패로 분모가 줄면 음수가 나올 수 있다 — 그 자체가 수집 이상 신호다, #1237).
    ("analysis.session_counts.total", "count", "count"),
    ("analysis.metrics.M-1.percentages.FULL", "%p", "pct100"),
    ("analysis.metrics.M-1.percentages.LITE", "%p", "pct100"),
    ("analysis.metrics.M-1.percentages.SKIP", "%p", "pct100"),
    ("analysis.metrics.M-2.percentages.CONFIRMED_ISSUE", "%p", "pct100"),
    ("analysis.metrics.M-2.percentages.NOT_AN_ISSUE", "%p", "pct100"),
    ("analysis.metrics.M-2.percentages.NEEDS_MORE_INFO", "%p", "pct100"),
    ("analysis.metrics.M-3.by_bundle.Correctness.confirmed_rate", "%p", "rate"),
    ("analysis.metrics.M-3.by_bundle.Design.confirmed_rate", "%p", "rate"),
    ("analysis.metrics.M-3.by_bundle.Regression.confirmed_rate", "%p", "rate"),
    ("analysis.metrics.M-3.by_bundle.Maintainability.confirmed_rate", "%p", "rate"),
    ("analysis.derived.intensity_full_finding_zero_rate", "%p", "rate"),
    ("health.document_size.markdown_file_count", "count", "count"),
    ("health.document_size.total_line_count", "count", "count"),
    ("health.drift_repair_commits.count", "count", "count"),
    ("health.rule_counts.total", "count", "count"),
]


def numeric(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    return None


def delta_for(current: float, previous: float, kind: str) -> float:
    if kind == "rate":
        return round((current - previous) * 100, 2)
    if kind == "pct100":
        return round(current - previous, 2)
    return round(current - previous, 2)


def compute_deltas(current_report: dict, previous_reports: list[dict]) -> dict:
    previous_meta = []
    for report in previous_reports:
        previous_meta.append({
            "path": report.get("provenance", {}).get("report_json_path"),
            "week_id": report.get("week", {}).get("id"),
            # 해설 LLM이 formula_break 규칙을 comparison 단위로 판정할 수 있게 비교 대상의 산식 버전을 싣는다
            "health_formula_version": get_path(report, "health.health_formula_version"),
        })

    items = []
    for metric_path, unit, kind in DELTA_SPECS:
        current_value = numeric(get_path(current_report, metric_path))
        if current_value is None:
            continue
        comparisons = []
        for previous in previous_reports:
            previous_value = numeric(get_path(previous, metric_path))
            if previous_value is None:
                continue
            comparisons.append({
                "week_id": previous.get("week", {}).get("id"),
                "previous": previous_value,
                "delta": delta_for(current_value, previous_value, kind),
            })
        if comparisons:
            items.append({
                "metric": metric_path,
                "unit": unit,
                "current": current_value,
                "comparisons": comparisons,
            })
    return {
        "previous_reports": previous_meta,
        "items": items,
    }


def commentary_object(text: str | None, failure_reason: str | None) -> dict:
    cleaned = text.strip() if text else ""
    if cleaned:
        return {"text": cleaned, "failure_reason": None}
    return {"text": None, "failure_reason": failure_reason or "commentary unavailable"}


def shell_assignment_value(line: str) -> tuple[str, str] | None:
    stripped = line.strip()
    if stripped.startswith("export "):
        stripped = stripped.removeprefix("export ").strip()
    if "=" not in stripped:
        return None
    try:
        parts = shlex.split(stripped, comments=True, posix=True)
    except ValueError:
        parts = [stripped]
    if len(parts) != 1 or "=" not in parts[0]:
        return None
    key, value = parts[0].split("=", 1)
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
        return None
    return key, value


def strict_shell_assignment_value(line: str) -> tuple[str, str] | None:
    """Parse one assignment without the finalize path's permissive fallback."""
    stripped = line.strip()
    if stripped.startswith("export "):
        stripped = stripped.removeprefix("export ").strip()
    if "=" not in stripped:
        return None
    try:
        parts = shlex.split(stripped, comments=True, posix=True)
    except ValueError as exc:
        raise SecretSnapshotError("secret source invalid") from exc
    if len(parts) != 1 or "=" not in parts[0]:
        raise SecretSnapshotError("secret source invalid")
    key, value = parts[0].split("=", 1)
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
        raise SecretSnapshotError("secret source invalid")
    return key, value


def secret_values_from_text(text: str) -> list[str]:
    values: list[str] = []
    saw_assignment = False
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        assignment = shell_assignment_value(line)
        if assignment is None:
            continue
        saw_assignment = True
        key, value = assignment
        if key in SECRET_ASSIGNMENT_NAMES and value:
            values.append(value)
    if not saw_assignment:
        first_line = text.splitlines()[0].strip() if text.splitlines() else ""
        if first_line:
            values.append(first_line)
    return values


def strict_secret_values_from_text(text: str) -> list[str]:
    """Parse every meaningful source line or reject the whole snapshot."""
    lines = [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.strip().startswith("#")
    ]
    if not lines:
        raise SecretSnapshotError("secret source invalid")

    assignments: list[str] = []
    raw_values: list[str] = []
    for line in lines:
        assignment = strict_shell_assignment_value(line)
        if assignment is None:
            raw_values.append(line)
            continue
        _, value = assignment
        if not value:
            raise SecretSnapshotError("secret source invalid")
        # Strict outbound guarding treats every assignment value as sensitive,
        # including future credential names unknown to the finalize sanitizer.
        assignments.append(value)

    if assignments and raw_values:
        raise SecretSnapshotError("secret source invalid")
    if raw_values:
        if len(raw_values) != 1 or "=" in raw_values[0]:
            raise SecretSnapshotError("secret source invalid")
        return raw_values
    return assignments


def load_secret_values(paths: list[str]) -> list[str]:
    values: list[str] = []
    seen: set[str] = set()
    for raw_path in paths:
        if not raw_path:
            continue
        try:
            text = Path(raw_path).read_text(encoding="utf-8")
        except OSError:
            continue
        for value in secret_values_from_text(text):
            if value and value not in seen:
                values.append(value)
                seen.add(value)
    return values


def strict_secret_snapshot(
    token_source: str,
    secret_sources: list[str],
) -> tuple[str, list[str]]:
    """Read each source once and return the exact token plus comparison values."""
    cache: dict[str, str] = {}

    def read_once(path: str) -> str:
        normalized = os.path.realpath(path)
        if normalized not in cache:
            try:
                cache[normalized] = Path(path).read_text(encoding="utf-8")
            except (OSError, UnicodeError) as exc:
                raise SecretSnapshotError("secret source unavailable") from exc
        return cache[normalized]

    token_text = read_once(token_source)
    token = token_text.rstrip("\r\n")
    if not token or "\n" in token or "\r" in token:
        raise SecretSnapshotError("token source invalid")

    values = [token]
    seen = {token}
    for path in secret_sources:
        parsed = strict_secret_values_from_text(read_once(path))
        for value in parsed:
            if value and value not in seen:
                values.append(value)
                seen.add(value)
    return token, values


def iter_string_values(value: Any):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for child in value.values():
            yield from iter_string_values(child)
    elif isinstance(value, (list, tuple)):
        for child in value:
            yield from iter_string_values(child)


def projection_source_contains_secret(source: dict, secret_values: list[str]) -> bool:
    return any(
        secret in value
        for value in iter_string_values(source)
        for secret in secret_values
    )


def body_contains_secret(body: bytes, secret_values: list[str]) -> bool:
    return any(secret.encode("utf-8") in body for secret in secret_values)


def _safe_gh_environment(token: str) -> dict[str, str]:
    allowed = (
        "HOME",
        "PATH",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "NIX_SSL_CERT_FILE",
    )
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    env["GH_TOKEN"] = token
    return env


def _protected_publisher_paths(
    report_json: str,
    token_source: str,
    secret_sources: list[str],
    report: dict | None = None,
) -> set[str]:
    protected = {
        os.path.realpath(path)
        for path in [report_json, token_source, *secret_sources]
        if path
    }
    if report is not None:
        provenance = report.get("provenance", {})
        for key in ("report_json_path", "report_markdown_path"):
            path = provenance.get(key)
            if isinstance(path, str) and path:
                protected.add(os.path.realpath(path))
    return protected


def publish_github_guarded(
    *,
    report_json: str,
    issue: str,
    repo_root: str,
    token_source: str,
    secret_sources: list[str],
    output_body: str,
) -> GuardedPublishResult:
    """Render, guard, and publish one exact bounded body without leaking details."""
    output_path = os.path.realpath(output_body)
    if output_path in _protected_publisher_paths(
        report_json,
        token_source,
        secret_sources,
    ):
        return guarded_publish_result(GITHUB_PUBLISH_REASON_PROJECTION)
    output_is_safe_to_unlink = True
    try:
        try:
            report = load_json(report_json)
            source = build_github_projection_source(report)
            if output_path in _protected_publisher_paths(
                report_json,
                token_source,
                secret_sources,
                report,
            ):
                output_is_safe_to_unlink = False
                return guarded_publish_result(GITHUB_PUBLISH_REASON_PROJECTION)
        except (OSError, UnicodeError, json.JSONDecodeError, ProjectionError, TypeError):
            return guarded_publish_result(GITHUB_PUBLISH_REASON_PROJECTION)

        try:
            token, secret_values = strict_secret_snapshot(token_source, secret_sources)
        except SecretSnapshotError:
            return guarded_publish_result(GITHUB_PUBLISH_REASON_SECRET_SNAPSHOT)

        if projection_source_contains_secret(source, secret_values):
            return guarded_publish_result(GITHUB_PUBLISH_REASON_OUTBOUND_SECRET)

        try:
            rendered = render_github_markdown_source(source)
            body = rendered.encode("utf-8")
            if body_contains_secret(body, secret_values):
                return guarded_publish_result(GITHUB_PUBLISH_REASON_OUTBOUND_SECRET)
            atomic_write_text(output_body, rendered)
        except (OSError, UnicodeError, ProjectionError, TypeError, ValueError):
            return guarded_publish_result(GITHUB_PUBLISH_REASON_PROJECTION)

        env = _safe_gh_environment(token)
        if shutil.which("gh", path=env.get("PATH")) is None:
            return guarded_publish_result(GITHUB_PUBLISH_REASON_UNAVAILABLE)
        try:
            proc = subprocess.run(
                ["gh", "issue", "comment", issue, "--body-file", "-"],
                cwd=repo_root,
                env=env,
                input=body,
                capture_output=True,
                check=False,
            )
        except OSError:
            return guarded_publish_result(GITHUB_PUBLISH_REASON_UNAVAILABLE)
        if proc.returncode != 0:
            return guarded_publish_result(GITHUB_PUBLISH_REASON_GH_NONZERO)
        match = re.search(rb"https://github\.com/[^\s]+", proc.stdout)
        if match is None:
            return guarded_publish_result(GITHUB_PUBLISH_REASON_URL_MISSING)
        return guarded_publish_result(
            GITHUB_PUBLISH_REASON_OK,
            match.group(0).decode("ascii", errors="ignore"),
        )
    finally:
        if output_is_safe_to_unlink:
            try:
                Path(output_body).unlink(missing_ok=True)
            except OSError:
                pass


def commentary_contains_secret(text: str, secret_values: list[str]) -> bool:
    return any(secret_value in text for secret_value in secret_values)


def read_sanitized_commentary(
    commentary_file: str | None,
    commentary_error: str | None,
    secret_source_paths: list[str],
) -> tuple[str | None, str | None]:
    commentary_text = None
    effective_error = commentary_error
    if commentary_file:
        try:
            commentary_text = Path(commentary_file).read_text(encoding="utf-8")
        except OSError:
            return None, "commentary file read failed"
        if commentary_text and commentary_contains_secret(
            commentary_text,
            load_secret_values(secret_source_paths),
        ):
            try:
                Path(commentary_file).unlink()
            except OSError:
                pass
            return None, "sanitize gate: secret-like content"
    return commentary_text, effective_error


def has_older_formula_version(previous_reports: list[dict]) -> bool:
    """비교 대상 리포트 중 현재보다 낮은 health 산식 버전이 있는가 — 전환 주 판정."""
    for report in previous_reports:
        version = numeric(get_path(report, "health.health_formula_version"))
        if (version or 0) < HEALTH_FORMULA_VERSION:
            return True
    return False


def build_weekly_report(
    sidecar: dict,
    health: dict,
    week_start: dt.datetime,
    week_end: dt.datetime,
    previous_reports: list[dict],
    commentary_text: str | None,
    commentary_failure: str | None,
    provenance: dict,
    analyze_exit_code: int = 0,
) -> dict:
    week_id = week_id_for(week_start)
    # 측정 창 표기는 health 수집이 실제로 쓴 창(drift_repair_commits.since/until)을 그대로 읽는다 —
    # 창의 소유자는 collect_health_metrics 안의 measurement_window 하나이고 여기서 재유도하지 않는다.
    drift_window = health.get("drift_repair_commits", {})
    health = {
        **health,
        # 산식 단절은 관계다 — 비교 대상 리포트 중 더 낮은 산식 버전(버전 필드가 없는 옛 리포트 포함)이
        # 있는 전환 주에만 사유 문자열을 싣고, 그 외 주는 None (algorithm.md 건강 지표 계약).
        "formula_break": (
            HEALTH_FORMULA_BREAK if has_older_formula_version(previous_reports) else None
        ),
    }
    report = {
        "schema_version": SCHEMA_VERSION,
        "week": {
            "id": week_id,
            "start": week_start.isoformat(),
            "end": week_end.isoformat(),
            "tz": KST_NAME,
            # health 측정 창 (drift repair 커밋). M-1~M-4·M-6·세션 수는 이 창과 무관한
            # 전체 코퍼스 누적값이다 — 렌더러와 해설 프롬프트가 그 사실을 명시한다 (#1237).
            "measurement_start": drift_window.get("since"),
            "measurement_end": drift_window.get("until"),
        },
        "analysis": normalize_analysis(sidecar),
        "health": health,
        "coverage": build_coverage(sidecar, health, analyze_exit_code),
        "traceability": build_traceability(sidecar),
        "deltas": {"previous_reports": [], "items": []},
        "commentary": commentary_object(commentary_text, commentary_failure),
        "provenance": {
            **provenance,
            "generated_at": utc_now_iso(),
        },
    }
    report["deltas"] = compute_deltas(report, previous_reports)
    return report


def pct(value: float | int | None, scale: float = 1.0) -> str:
    if value is None:
        return "N/A"
    return f"{float(value) * scale:.1f}%"


def num(value: Any) -> str:
    if value is None:
        return "N/A"
    if isinstance(value, float):
        return f"{value:.2f}"
    return str(value)


def esc(value: Any) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\n", " ")


def _measurement_window_rows(start: Any, end: Any) -> list[str]:
    """측정 창 행 — v1 리포트(measurement_* 부재)를 v2 렌더러로 재발행할 때 쓰지도 않은 창을
    단정하지 않도록, 값이 없으면(None 또는 projection 기본값) 행을 만들지 않는다."""
    if start in (None, "unknown") or end in (None, "unknown"):
        return []
    return [f"| {MEASUREMENT_WINDOW_ROW_LABEL} | {esc(start)} ~ {esc(end)} — {MEASUREMENT_WINDOW_SUFFIX} |"]


def _safe_number(value: Any, default: int | float | None = 0) -> int | float | None:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value
    return default


def _safe_string(value: Any, default: str | None = None) -> str | None:
    return value if isinstance(value, str) else default


def _numeric_subset(mapping: Any, keys: tuple[str, ...]) -> dict[str, int | float]:
    source = mapping if isinstance(mapping, dict) else {}
    return {
        key: _safe_number(source[key])
        for key in keys
        if key in source
    }


def _numeric_key_dict(mapping: Any) -> dict[str, int | float]:
    if not isinstance(mapping, dict):
        return {}
    result: dict[str, int | float] = {}
    for key in sorted(mapping, key=lambda item: str(item)):
        key_text = str(key)
        value = mapping[key]
        if key_text.isdigit() and isinstance(value, (int, float)) and not isinstance(value, bool):
            result[key_text] = value
    return result


def _warning_category(warning: str, *, health: bool = False) -> str:
    if health:
        return "health"
    lowered = warning.lower()
    if "tar member" in lowered or "validation" in lowered or "newline" in lowered:
        return "validation"
    # "budget"은 ssh 토큰이 없던 구 문구("fetch budget 초과 (절전/무응답 가능성)")를 담은
    # 과거 주차 sidecar를 재처리할 때만 쓰인다 — 현행 문구는 ssh 토큰으로 이미 분류된다.
    if any(token in lowered for token in ("ssh", "remote", "tar ", "find ", "budget")):
        return "remote_collection"
    if any(token in lowered for token in ("parse", "diagnostic", "verdict")):
        return "analysis"
    return "other"


def _warning_summary(coverage: dict) -> dict:
    raw_warnings = [
        warning
        for warning in coverage.get("warnings", [])
        if isinstance(warning, str)
    ]
    health_warnings = [
        warning
        for warning in coverage.get("health_warnings", [])
        if isinstance(warning, str)
    ]
    category_counts = {
        key: 0
        for key in ("remote_collection", "validation", "analysis", "health", "other")
    }
    host_counts = {"mac": 0, "minipc": 0, "unattributed": 0}
    for warning in raw_warnings:
        category_counts[_warning_category(warning)] += 1
        host_match = re.match(r"^host\s+(mac|minipc):", warning)
        host_counts[host_match.group(1) if host_match else "unattributed"] += 1
    for warning in health_warnings:
        category_counts[_warning_category(warning, health=True)] += 1
        host_counts["unattributed"] += 1
    total = len(raw_warnings) + len(health_warnings)
    return {
        "total_count": total,
        "category_counts": category_counts,
        "host_counts": host_counts,
        # Consumer projections intentionally carry counts, never raw samples.
        "omitted_count": total,
    }


def _metric_projection(metrics: dict) -> dict:
    m1 = metrics.get("M-1", {})
    m2 = metrics.get("M-2", {})
    m3 = metrics.get("M-3", {})
    m4 = metrics.get("M-4", {})
    m6 = metrics.get("M-6", {})
    severities = ("CRITICAL", "HIGH", "MEDIUM", "LOW", "NONE")
    transition_keys = tuple(
        f"{before}->{after}" for before in severities for after in severities
    )
    source_distribution = {}
    for source in ("verdict_json", "md_header", "json_unmarked", "kv"):
        info = m2.get("source_distribution", {}).get(source)
        if isinstance(info, dict):
            confidence = info.get("confidence")
            source_distribution[source] = {
                "count": _safe_number(info.get("count")),
                "confidence": confidence
                if confidence in {"high", "medium", "low"}
                else "unknown",
            }
    by_bundle = {}
    for bundle in M3_BUNDLES:
        info = m3.get("by_bundle", {}).get(bundle)
        if isinstance(info, dict):
            by_bundle[bundle] = {
                "total": _safe_number(info.get("total")),
                "confirmed": _safe_number(info.get("confirmed")),
                "confirmed_rate": _safe_number(info.get("confirmed_rate")),
            }
    return {
        "M-1": {
            "denominator": _safe_string(m1.get("denominator"), "unknown"),
            "n": _safe_number(m1.get("n")),
            "distribution": _numeric_subset(m1.get("distribution"), M1_KEYS),
            "percentages": _numeric_subset(m1.get("percentages"), M1_KEYS),
        },
        "M-2": {
            "denominator": _safe_string(m2.get("denominator"), "unknown"),
            "n": _safe_number(m2.get("n")),
            "distribution": _numeric_subset(m2.get("distribution"), M2_KEYS),
            "percentages": _numeric_subset(m2.get("percentages"), M2_KEYS),
            "source_distribution": source_distribution,
        },
        "M-3": {
            "by_bundle": by_bundle,
        },
        "M-4": {
            "round_key": _safe_string(m4.get("round_key"), "unknown"),
            "baseline_note": _safe_string(m4.get("baseline_note"), "unavailable"),
            "transition_matrix": _numeric_subset(
                m4.get("transition_matrix"), transition_keys
            ),
        },
        "M-6": {
            "name": _safe_string(m6.get("name"), "persistence non-convergence"),
            "persistence_key": _safe_string(m6.get("persistence_key"), "unavailable"),
            "key_block_count_distribution": _numeric_key_dict(
                m6.get("key_block_count_distribution")
            ),
            "coverage": {
                "eligible_records": _safe_number(
                    m6.get("coverage", {}).get("eligible_records")
                ),
                "missing_persistence_components": _safe_number(
                    m6.get("coverage", {}).get("missing_persistence_components")
                ),
            },
        },
    }


def _delta_projection(deltas: dict) -> dict:
    previous_reports = [
        {
            "week_id": _safe_string(item.get("week_id"), "unknown"),
            # 부재(버전 필드 없는 옛 리포트)는 canonical과 같은 None — 0으로 뭉개면 해설이 "v0"으로 읽는다
            "health_formula_version": _safe_number(item.get("health_formula_version"), None),
        }
        for item in deltas.get("previous_reports", [])
        if isinstance(item, dict)
    ]
    delta_order = {metric: index for index, (metric, _, _) in enumerate(DELTA_SPECS)}
    delta_units = {metric: unit for metric, unit, _ in DELTA_SPECS}
    projected_items = []
    for item in deltas.get("items", []):
        if not isinstance(item, dict) or item.get("metric") not in delta_order:
            continue
        comparisons = [
            {
                "week_id": _safe_string(comparison.get("week_id"), "unknown"),
                "previous": _safe_number(comparison.get("previous")),
                "delta": _safe_number(comparison.get("delta")),
            }
            for comparison in item.get("comparisons", [])
            if isinstance(comparison, dict)
        ]
        comparisons.sort(key=lambda value: str(value.get("week_id") or ""))
        projected_items.append({
            "metric": item.get("metric"),
            "unit": delta_units[str(item.get("metric"))],
            "current": _safe_number(item.get("current")),
            "comparisons": comparisons,
        })
    projected_items.sort(key=lambda item: delta_order[str(item["metric"])])
    previous_reports.sort(key=lambda item: str(item.get("week_id") or ""))
    return {"previous_reports": previous_reports, "items": projected_items}


def build_consumer_summary(report: dict) -> dict:
    """Build the deterministic allowlist shared by bounded consumers."""
    if report.get("schema_version") != SCHEMA_VERSION:
        raise ProjectionError("unsupported canonical report schema")
    analysis = report.get("analysis", {})
    coverage = report.get("coverage", {})
    health = report.get("health", {})
    session_counts = analysis.get("session_counts", {})
    diagnostics = coverage.get("diagnostics", {})
    host_collection = coverage.get("host_collection", {})
    hosts = {}
    for host in ("mac", "minipc"):
        info = host_collection.get(host, {})
        status = info.get("status")
        hosts[host] = {
            "status": status if status in {"ok", "partial", "unknown"} else "unknown",
            "analyzed_sessions": _safe_number(info.get("analyzed_sessions")),
            "warning_count": len(info.get("warnings", [])),
            "excluded_files": _safe_number(info.get("excluded_files")),
        }
    return {
        "week": {
            "id": _safe_string(report.get("week", {}).get("id"), "unknown"),
            "start": _safe_string(report.get("week", {}).get("start"), "unknown"),
            "end": _safe_string(report.get("week", {}).get("end"), "unknown"),
            "tz": _safe_string(report.get("week", {}).get("tz"), "unknown"),
            "measurement_start": _safe_string(
                report.get("week", {}).get("measurement_start"), "unknown"
            ),
            "measurement_end": _safe_string(
                report.get("week", {}).get("measurement_end"), "unknown"
            ),
        },
        "session_counts": {
            "total": _safe_number(session_counts.get("total")),
            "arbiter_marker_sessions": _safe_number(
                session_counts.get("arbiter_marker_sessions")
            ),
            "intensity_marker_sessions": _safe_number(
                session_counts.get("intensity_marker_sessions")
            ),
        },
        "metrics": _metric_projection(analysis.get("metrics", {})),
        "derived": {
            "intensity_full_finding_zero_rate": _safe_number(
                analysis.get("derived", {}).get("intensity_full_finding_zero_rate")
            ),
        },
        "health": {
            "health_formula_version": _safe_number(health.get("health_formula_version")),
            # 전환 주가 아니면 canonical과 같은 None — 빈 문자열로 뭉개면 GitHub 표에 상시 행이 생기고
            # 해설 프롬프트의 "있으면" 조건이 항상 참이 된다.
            "formula_break": _safe_string(health.get("formula_break")),
            "document_size": {
                "markdown_file_count": _safe_number(
                    health.get("document_size", {}).get("markdown_file_count")
                ),
                "total_line_count": _safe_number(
                    health.get("document_size", {}).get("total_line_count")
                ),
            },
            "drift_repair_commit_count": _safe_number(
                health.get("drift_repair_commits", {}).get("count")
            ),
            "rule_counts": {
                key: _safe_number(health.get("rule_counts", {}).get(key))
                for key in (
                    "core_invariants_numbered",
                    "cautions_bullets",
                    "non_goals_numbered",
                    "total",
                )
            },
        },
        "coverage": {
            "partial": bool(coverage.get("partial", False)),
            "analyze_exit_code": _safe_number(coverage.get("analyze_exit_code")),
            "counts": {
                key: _safe_number(diagnostics.get(key))
                for key in (
                    "parse_failure_count",
                    "exclusion_count",
                    "invalid_verdict_count",
                    "missing_persistence_component_count",
                )
            },
            "diagnostic_rates": {
                key: _safe_number(coverage.get("diagnostic_rates", {}).get(key))
                for key in ("parse_failures_per_session", "exclusions_per_session")
            },
            "marker_missing_rates": {
                key: _safe_number(coverage.get("marker_missing_rates", {}).get(key))
                for key in (
                    "arbiter_marker_missing_rate",
                    "intensity_marker_missing_rate",
                )
            },
        },
        "hosts": hosts,
        "warnings": _warning_summary(coverage),
        "deltas": _delta_projection(report.get("deltas", {})),
    }


def _bounded_utf8(text: str, limit: int, label: str) -> str:
    if len(text.encode("utf-8")) > limit:
        raise ProjectionError(f"{label} exceeds UTF-8 byte budget")
    return text


def render_commentary_input(report: dict) -> str:
    payload = json.dumps(
        build_consumer_summary(report),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return _bounded_utf8(
        f"{COMMENTARY_PROMPT}\n\n{payload}\n",
        COMMENTARY_INPUT_MAX_BYTES,
        "commentary projection",
    )


def _safe_commentary_failure_reason(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value)
    fixed = {
        "LLM commentary pending",
        "codex-exec-supervised produced empty commentary",
        "codex-exec-supervised not found",
        "sanitize gate: secret-like content",
        "commentary file read failed",
        "bounded commentary projection unavailable",
        "commentary unavailable",
    }
    if text in fixed or re.fullmatch(r"codex-exec-supervised failed with exit \d+", text):
        return text
    return "commentary unavailable"


def build_github_projection_source(report: dict) -> dict:
    commentary = report.get("commentary", {})
    commentary_text = commentary.get("text")
    return {
        "summary": build_consumer_summary(report),
        "commentary": {
            "text": commentary_text if isinstance(commentary_text, str) else None,
            "failure_reason": _safe_commentary_failure_reason(
                commentary.get("failure_reason")
            ),
        },
    }


def _json_cell(value: Any) -> str:
    return esc(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def _append_metric_section(out: list[str], name: str, metric: dict) -> None:
    out.extend([f"## {name}", "", "| 항목 | 값 |", "|------|-----|"])
    for key, value in metric.items():
        out.append(f"| {esc(key)} | {_json_cell(value)} |")
    out.append("")


def _render_github_markdown_source(source: dict) -> str:
    summary = source["summary"]
    week = summary["week"]
    counts = summary["session_counts"]
    coverage = summary["coverage"]
    health = summary["health"]
    out = [f"# DA Weekly Report — {week.get('id')}", ""]
    out.extend([
        "## 핵심 요약",
        "",
        "| 항목 | 값 |",
        "|------|-----|",
        f"| {WEEK_ROW_LABEL} | {esc(week.get('start'))} ~ {esc(week.get('end'))} ({esc(week.get('tz'))}) |",
        *_measurement_window_rows(week.get('measurement_start'), week.get('measurement_end')),
        METRIC_SCOPE_ROW,
        f"| 전체 세션 | {counts.get('total', 0)} |",
        f"| Arbiter marker 세션 | {counts.get('arbiter_marker_sessions', 0)} |",
        f"| Intensity marker 세션 | {counts.get('intensity_marker_sessions', 0)} |",
        f"| partial | {coverage.get('partial')} |",
        "",
        "## 커버리지",
        "",
        "| 항목 | 값 |",
        "|------|-----|",
    ])
    for key, value in coverage.get("counts", {}).items():
        out.append(f"| {esc(key)} | {num(value)} |")
    for group in ("diagnostic_rates", "marker_missing_rates"):
        for key, value in coverage.get(group, {}).items():
            out.append(f"| {esc(key)} | {num(value)} |")
    out.extend([
        "",
        "| host | status | analyzed sessions | warning count | excluded (size cap) |",
        "|------|--------|-------------------|---------------|---------------------|",
    ])
    for host, info in summary.get("hosts", {}).items():
        out.append(
            f"| {esc(host)} | {esc(info.get('status'))} | {num(info.get('analyzed_sessions'))} "
            f"| {num(info.get('warning_count'))} | {num(info.get('excluded_files'))} |"
        )
    out.append("")

    for metric_name in ("M-1", "M-2", "M-3", "M-4", "M-6"):
        _append_metric_section(out, metric_name, summary["metrics"][metric_name])

    out.extend(["## Health 요약", "", "| 항목 | 값 |", "|------|-----|"])
    for key, value in health.items():
        if value is None:
            # 전환 주가 아닌 리포트의 formula_break(null) 등 부재 값은 행을 만들지 않는다 — 전문 렌더와 같은 규칙
            continue
        out.append(f"| {esc(key)} | {_json_cell(value)} |")
    out.extend(["", "## 전주 delta", ""])
    delta_items = summary.get("deltas", {}).get("items", [])
    if delta_items:
        out.extend([
            "| metric | current | week | previous | delta | unit |",
            "|--------|---------|------|----------|-------|------|",
        ])
        for item in delta_items:
            for comparison in item.get("comparisons", []):
                out.append(
                    f"| {esc(item.get('metric'))} | {num(item.get('current'))} | {esc(comparison.get('week_id'))} | {num(comparison.get('previous'))} | {num(comparison.get('delta'))} | {esc(item.get('unit'))} |"
                )
    else:
        out.append("첫 회 또는 비교 가능한 직전 리포트 없음.")

    warnings = summary["warnings"]
    out.extend(["", "## Warning 요약", "", "| category | count |", "|----------|-------|"])
    for category, count in warnings["category_counts"].items():
        out.append(f"| {esc(category)} | {num(count)} |")
    out.extend(["", "| host | count |", "|------|-------|"])
    for host, count in warnings["host_counts"].items():
        out.append(f"| {esc(host)} | {num(count)} |")
    out.extend(["", f"omitted raw warnings: {warnings['omitted_count']}", "", "## LLM 해설", ""])
    commentary = source["commentary"]
    if commentary.get("text"):
        commentary_text = str(commentary["text"])
    else:
        commentary_text = f"해설 없음: {commentary.get('failure_reason') or 'commentary unavailable'}"
    out.extend(["<pre>", html.escape(commentary_text, quote=False), "</pre>", ""])
    return "\n".join(out)


def render_github_markdown(report: dict) -> str:
    return render_github_markdown_source(build_github_projection_source(report))


def render_github_markdown_source(source: dict) -> str:
    return _bounded_utf8(
        _render_github_markdown_source(source),
        GITHUB_MARKDOWN_MAX_BYTES,
        "GitHub projection",
    )


def render_distribution_table(distribution: dict, percentages: dict | None = None) -> list[str]:
    rows = ["| 항목 | 카운트 | 비율 |", "|------|--------|------|"]
    for key in sorted(distribution):
        count = distribution.get(key, 0)
        percent = percentages.get(key, 0.0) if percentages else 0.0
        rows.append(f"| {esc(key)} | {count} | {percent:.1f}% |")
    return rows


def render_mermaid_pie(title: str, distribution: dict) -> list[str]:
    nonzero = [(key, distribution[key]) for key in sorted(distribution) if distribution[key]]
    if not nonzero:
        return []
    rows = ["```mermaid", f"pie title {title}"]
    for key, value in nonzero:
        rows.append(f'  "{esc(key)}" : {value}')
    rows.append("```")
    return rows


def render_markdown(report: dict) -> str:
    analysis = report["analysis"]
    metrics = analysis["metrics"]
    health = report["health"]
    coverage = report["coverage"]
    out: list[str] = []
    out.append(f"# DA Weekly Report — {report['week']['id']}")
    out.append("")
    out.append("| 항목 | 값 |")
    out.append("|------|-----|")
    out.append(f"| {WEEK_ROW_LABEL} | {report['week']['start']} ~ {report['week']['end']} ({report['week']['tz']}) |")
    out.extend(_measurement_window_rows(report['week'].get('measurement_start'), report['week'].get('measurement_end')))
    out.append(METRIC_SCOPE_ROW)
    out.append(f"| 호스트 | {', '.join(analysis.get('hosts', []))} |")
    out.append(f"| corpus | {analysis.get('corpus')} |")
    out.append(f"| partial | {coverage.get('partial')} |")
    out.append("")

    out.append("## 핵심 수치 요약")
    out.append("")
    m1 = metrics["M-1"]
    m2 = metrics["M-2"]
    m6 = metrics["M-6"]
    out.append("| 지표 | 값 |")
    out.append("|------|-----|")
    out.append(f"| 분석 세션 | {analysis.get('session_counts', {}).get('total', 0)} |")
    out.append(f"| M-1 FULL | {m1.get('distribution', {}).get('FULL', 0)} ({m1.get('percentages', {}).get('FULL', 0.0):.1f}%) |")
    out.append(f"| M-2 CONFIRMED_ISSUE | {m2.get('distribution', {}).get('CONFIRMED_ISSUE', 0)} ({m2.get('percentages', {}).get('CONFIRMED_ISSUE', 0.0):.1f}%) |")
    out.append(f"| M-6 missing persistence | {m6.get('coverage', {}).get('missing_persistence_components', 0)} |")
    out.append(f"| run-da docs | {health.get('document_size', {}).get('markdown_file_count', 0)} files / {health.get('document_size', {}).get('total_line_count', 0)} lines |")
    out.append(f"| run-da rules | {health.get('rule_counts', {}).get('total', 0)} |")
    out.append(f"| drift repair commits | {health.get('drift_repair_commits', {}).get('count', 0)} |")
    out.append("")

    out.append("## 커버리지/신뢰도")
    out.append("")
    out.append("| 항목 | 값 |")
    out.append("|------|-----|")
    out.append(f"| parse failures | {coverage.get('diagnostics', {}).get('parse_failure_count', 0)} |")
    out.append(f"| exclusions | {coverage.get('diagnostics', {}).get('exclusion_count', 0)} |")
    out.append(f"| invalid verdicts | {coverage.get('diagnostics', {}).get('invalid_verdict_count', 0)} |")
    out.append(f"| Arbiter marker 미출현율 | {pct(coverage.get('marker_missing_rates', {}).get('arbiter_marker_missing_rate'), 100)} |")
    out.append(f"| Intensity marker 미출현율 | {pct(coverage.get('marker_missing_rates', {}).get('intensity_marker_missing_rate'), 100)} |")
    out.append(f"| health warnings | {len(coverage.get('health_warnings', []))} |")
    out.append("")
    out.append("| host | status | analyzed sessions | warnings | excluded (size cap) |")
    out.append("|------|--------|-------------------|----------|---------------------|")
    for host, info in sorted(coverage.get("host_collection", {}).items()):
        out.append(
            f"| {esc(host)} | {esc(info.get('status'))} | {info.get('analyzed_sessions', 0)} "
            f"| {len(info.get('warnings', []))} | {info.get('excluded_files', 0)} |"
        )
    out.append("")

    out.append("## M-1: 검토 강도 verdict 분포")
    out.append("")
    out.extend(render_distribution_table(m1.get("distribution", {}), m1.get("percentages", {})))
    out.append("")
    out.extend(render_mermaid_pie("검토 강도 verdict 분포", m1.get("distribution", {})))
    out.append("")

    out.append("## M-2: 판정자 verdict 분포")
    out.append("")
    out.extend(render_distribution_table(m2.get("distribution", {}), m2.get("percentages", {})))
    out.append("")
    out.extend(render_mermaid_pie("판정자 verdict 분포", m2.get("distribution", {})))
    out.append("")
    out.append("| source | confidence | count |")
    out.append("|--------|------------|-------|")
    for source, info in sorted(m2.get("source_distribution", {}).items()):
        out.append(f"| {esc(source)} | {esc(info.get('confidence'))} | {info.get('count', 0)} |")
    out.append("")

    out.append("## M-3: reviewer 묶음별 confirmed-rate")
    out.append("")
    out.append("| 묶음 | total | confirmed | confirmed-rate |")
    out.append("|------|-------|-----------|----------------|")
    for bundle, info in m3_items(metrics["M-3"].get("by_bundle", {})):
        out.append(
            f"| {esc(bundle)} | {info.get('total', 0)} | {info.get('confirmed', 0)} | {pct(info.get('confirmed_rate'), 100)} |"
        )
    out.append("")

    out.append("## M-4: 동일 세션 max severity 전이")
    out.append("")
    m4 = metrics["M-4"]
    out.append(f"round key: `{esc(m4.get('round_key'))}`")
    out.append(f"baseline: {esc(m4.get('baseline_note'))}")
    out.append("")
    out.append("| transition | count |")
    out.append("|------------|-------|")
    for transition, count in sorted(m4.get("transition_matrix", {}).items()):
        out.append(f"| {esc(transition)} | {count} |")
    if not m4.get("transition_matrix"):
        out.append("| 없음 | 0 |")
    out.append("")

    out.append("## M-6: persistence_key 비수렴")
    out.append("")
    out.append("| 항목 | 값 |")
    out.append("|------|-----|")
    out.append(f"| eligible_records | {m6.get('coverage', {}).get('eligible_records', 0)} |")
    out.append(f"| missing_persistence_components | {m6.get('coverage', {}).get('missing_persistence_components', 0)} |")
    out.append("")
    out.append("| block_count | key count |")
    out.append("|-------------|-----------|")
    for block_count, key_count in sorted(
        m6.get("key_block_count_distribution", {}).items(),
        key=lambda item: int(item[0]),
    ):
        out.append(f"| {block_count} | {key_count} |")
    if not m6.get("key_block_count_distribution"):
        out.append("| 없음 | 0 |")
    out.append("")

    out.append("## 건강 지표 추이")
    out.append("")
    out.append("| 지표 | 값 |")
    out.append("|------|-----|")
    out.append(f"| health_formula_version | {health.get('health_formula_version')} |")
    if health.get("formula_break"):
        out.append(f"| formula_break | {health.get('formula_break')} |")
    out.append(f"| markdown_file_count | {health.get('document_size', {}).get('markdown_file_count', 0)} |")
    out.append(f"| total_line_count | {health.get('document_size', {}).get('total_line_count', 0)} |")
    out.append(f"| drift_repair_commits | {health.get('drift_repair_commits', {}).get('count', 0)} |")
    out.append(f"| rule_total | {health.get('rule_counts', {}).get('total', 0)} |")
    out.append("")

    out.append("## 전주 delta")
    out.append("")
    if report.get("deltas", {}).get("items"):
        out.append("| metric | current | week | previous | delta | unit |")
        out.append("|--------|---------|------|----------|-------|------|")
        for item in report["deltas"]["items"]:
            for comparison in item.get("comparisons", []):
                out.append(
                    f"| {esc(item['metric'])} | {num(item.get('current'))} | {esc(comparison.get('week_id'))} | {num(comparison.get('previous'))} | {num(comparison.get('delta'))} | {esc(item.get('unit'))} |"
                )
    else:
        out.append("첫 회 또는 비교 가능한 직전 리포트 없음.")
    out.append("")

    out.append("## 소스 추적 링크")
    out.append("")
    out.append("| host | format | branch | session | cwd | refs | path |")
    out.append("|------|--------|--------|---------|-----|------|------|")
    for session in report.get("traceability", {}).get("sessions", []):
        refs = session.get("references", {})
        ref_text = []
        for label, key in (("PR", "prs"), ("issue", "issues"), ("#", "bare_numbers")):
            values = refs.get(key, [])
            if values:
                ref_text.append(label + ":" + ",".join(values[:5]))
        out.append(
            f"| {esc(session.get('host'))} | {esc(session.get('format'))} | {esc(session.get('git_branch'))} | {esc(session.get('session_id'))} | {esc(session.get('cwd'))} | {esc(' '.join(ref_text))} | {esc(session.get('path'))} |"
        )
    if report.get("traceability", {}).get("omitted_session_count", 0):
        out.append(
            f"| ... | ... | ... | ... | ... | omitted | {report['traceability']['omitted_session_count']} sessions |"
        )
    out.append("")

    out.append("## LLM 해설")
    out.append("")
    commentary = report.get("commentary", {})
    if commentary.get("text"):
        out.append(commentary["text"])
    else:
        out.append(f"해설 없음: {commentary.get('failure_reason')}")
    out.append("")

    warnings = coverage.get("warnings", []) + coverage.get("health_warnings", [])
    if warnings:
        out.append("---")
        out.append("Warnings:")
        for warning in warnings:
            out.append(f"- {warning}")
        out.append("")
    return "\n".join(out)


def m3_items(by_bundle: dict) -> list[tuple[str, dict]]:
    preferred = ["Correctness", "Design", "Regression", "Maintainability"]
    ordered = [(key, by_bundle[key]) for key in preferred if key in by_bundle]
    ordered.extend((key, value) for key, value in sorted(by_bundle.items()) if key not in preferred)
    return ordered


def load_previous_reports(paths: list[str]) -> list[dict]:
    reports = []
    for path in paths:
        try:
            report = load_json(path)
        except (OSError, json.JSONDecodeError):
            continue
        report.setdefault("provenance", {})["report_json_path"] = path
        reports.append(report)
    return reports


def append_publish_record(path: str, record: dict) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    payload = {**record, "recorded_at": utc_now_iso()}
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "a", encoding="utf-8") as fp:
        fp.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
    target.chmod(0o600)


def latest_publish_records(path: str | os.PathLike[str]) -> dict[str, dict[str, Any]]:
    """Return the latest stable publish record fields per target from an append-only log."""
    records: dict[str, dict[str, Any]] = {}
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return records

    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        target = record.get("target")
        status = record.get("status")
        if isinstance(target, str) and isinstance(status, str):
            records[target] = {
                key: record[key]
                for key in (
                    "target",
                    "status",
                    "message",
                    "url",
                    "week_id",
                    # writer(command_publish_record)가 기록하는 필드명과 동일해야 한다
                    # — reader/writer 어휘가 갈리면 --format json 출력에서 경로가 탈락한다.
                    "report_json_path",
                    "report_markdown_path",
                )
                if key in record
            }
    return records


def publish_target_records(
    path: str | os.PathLike[str],
    targets: list[str] | tuple[str, ...],
) -> list[dict[str, Any]]:
    latest = latest_publish_records(path)
    records = []
    for target in targets:
        latest_record = latest.get(target, {"target": target})
        status = latest_record.get("status")
        pending = status is None or status in RETRYABLE_PUBLISH_STATUSES
        records.append({**latest_record, "target": target, "pending": pending})
    return records


def notification_body(report: dict) -> str:
    analysis = report["analysis"]
    metrics = analysis["metrics"]
    health = report["health"]
    return "\n".join([
        f"DA weekly {report['week']['id']}",
        f"sessions {analysis.get('session_counts', {}).get('total', 0)} / arbiter {analysis.get('session_counts', {}).get('arbiter_marker_sessions', 0)}",
        f"confirmed {metrics['M-2'].get('distribution', {}).get('CONFIRMED_ISSUE', 0)} ({metrics['M-2'].get('percentages', {}).get('CONFIRMED_ISSUE', 0.0):.1f}%)",
        f"run-da docs {health.get('document_size', {}).get('total_line_count', 0)} lines / rules {health.get('rule_counts', {}).get('total', 0)}",
        f"partial {report.get('coverage', {}).get('partial')} / warnings {len(report.get('coverage', {}).get('warnings', [])) + len(report.get('coverage', {}).get('health_warnings', []))}",
    ])


def command_build(args: argparse.Namespace) -> int:
    sidecar = load_json(args.analysis_sidecar)
    if bool(args.week_start) != bool(args.week_end):
        # 하나만 지정된 채 조용히 기본 주로 대체되면 의도치 않은 주 경계로
        # 리포트가 생성된다 — 부분 지정은 명시적 에러로 fail-fast.
        print("ERROR: --week-start and --week-end must be provided together", file=sys.stderr)
        return 2
    if args.week_start and args.week_end:
        week_start = parse_datetime(args.week_start)
        week_end = parse_datetime(args.week_end)
    else:
        week_start, week_end = default_week_bounds()
    week_id = week_id_for(week_start)
    # health(drift repair 커밋)는 발행 주차가 아니라 직전 7일을 센다 — 창은 collect_health_metrics가
    # week_start에서 유도한다 (measurement_window docstring, #1237).
    health = collect_health_metrics(args.repo_root, week_start)
    previous_paths = previous_report_paths(args.state_dir, current_week_id=week_id)
    previous_reports = load_previous_reports(previous_paths)
    # build는 draft-only다. commentary 주입은 sanitize 게이트를 소유한 finalize가
    # 유일한 경로 — build에 commentary 입력을 열면 게이트를 우회하는 CLI 표면이 된다.
    commentary_text = None
    provenance = {
        "analysis_sidecar_path": os.path.abspath(args.analysis_sidecar),
        "publish_log_path": os.path.abspath(args.publish_log_path),
        "repo_root": os.path.abspath(args.repo_root),
        "report_json_path": os.path.abspath(args.output_json),
        "report_markdown_path": os.path.abspath(args.output_md) if args.output_md else None,
    }
    report = build_weekly_report(
        sidecar=sidecar,
        health=health,
        week_start=week_start,
        week_end=week_end,
        previous_reports=previous_reports,
        commentary_text=commentary_text,
        commentary_failure=args.commentary_error,
        provenance=provenance,
        analyze_exit_code=args.analyze_exit_code,
    )
    if args.output_md:
        atomic_write_report_pair(args.output_json, report, args.output_md)
    else:
        atomic_write_json(args.output_json, report)
    return 0


def command_finalize(args: argparse.Namespace) -> int:
    report = load_json(args.input_json)
    commentary_text, commentary_error = read_sanitized_commentary(
        args.commentary_file,
        args.commentary_error,
        args.secret_source or [],
    )
    report["commentary"] = commentary_object(commentary_text, commentary_error)
    provenance = report.setdefault("provenance", {})
    provenance["report_json_path"] = os.path.abspath(args.output_json)
    provenance["report_markdown_path"] = os.path.abspath(args.output_md)
    provenance["generated_at"] = utc_now_iso()
    atomic_write_report_pair(args.output_json, report, args.output_md)
    return 0


def command_render_projection(args: argparse.Namespace) -> int:
    if os.path.realpath(args.report_json) == os.path.realpath(args.output):
        print("ERROR: bounded projection unavailable", file=sys.stderr)
        return 2
    try:
        report = load_json(args.report_json)
        if args.projection == "commentary":
            rendered = render_commentary_input(report)
        else:
            rendered = render_github_markdown(report)
        atomic_write_text(args.output, rendered)
    except (OSError, UnicodeError, json.JSONDecodeError, ProjectionError, TypeError, ValueError):
        try:
            Path(args.output).unlink(missing_ok=True)
        except OSError:
            pass
        print("ERROR: bounded projection unavailable", file=sys.stderr)
        return 2
    return 0


def command_render_full_markdown(args: argparse.Namespace) -> int:
    if os.path.realpath(args.report_json) == os.path.realpath(args.output):
        print("ERROR: full Markdown unavailable", file=sys.stderr)
        return 2
    try:
        report = load_json(args.report_json)
        atomic_write_text(args.output, render_markdown(report) + "\n")
    except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        try:
            Path(args.output).unlink(missing_ok=True)
        except OSError:
            pass
        print("ERROR: full Markdown unavailable", file=sys.stderr)
        return 2
    return 0


def command_publish_github_guarded(args: argparse.Namespace) -> int:
    try:
        result = publish_github_guarded(
            report_json=args.report_json,
            issue=args.issue,
            repo_root=args.repo_root,
            token_source=args.token_source,
            secret_sources=args.secret_source or [],
            output_body=args.output_body,
        )
    except Exception:
        result = guarded_publish_result(GITHUB_PUBLISH_REASON_PROJECTION)
    print(f"{result.status}\t{result.reason}\t{result.url}")
    return 0


def command_publish_record(args: argparse.Namespace) -> int:
    append_publish_record(args.publish_log, {
        "week_id": args.week_id,
        "target": args.target,
        "status": args.status,
        "message": args.message,
        "url": args.url,
        "report_json_path": args.report_json,
        "report_markdown_path": args.report_md,
    })
    return 0


def parse_target_list(value: str) -> list[str]:
    targets: list[str] = []
    seen: set[str] = set()
    for raw in value.split(","):
        target = raw.strip()
        if not target or target in seen:
            continue
        targets.append(target)
        seen.add(target)
    return targets


def command_pending_publish_targets(args: argparse.Namespace) -> int:
    targets = parse_target_list(args.targets)
    records = publish_target_records(args.publish_log, targets)
    if args.format == "json":
        print(json.dumps(records, ensure_ascii=False, sort_keys=True))
    elif args.format == "tsv":
        for record in records:
            print("\t".join([
                str(record["target"]),
                "1" if record["pending"] else "0",
                str(record.get("status") or ""),
                str(record.get("url") or ""),
            ]))
    else:
        for record in records:
            if record["pending"]:
                print(record["target"])
    return 0


def command_notification(args: argparse.Namespace) -> int:
    report = load_json(args.report_json)
    print(notification_body(report))
    return 0


def command_week_id(_: argparse.Namespace) -> int:
    start, _ = default_week_bounds()
    print(week_id_for(start))
    return 0


def command_attempt_state_path(args: argparse.Namespace) -> int:
    print(attempt_state_path(args.state_dir, args.week_id))
    return 0


def command_deadline_reached(args: argparse.Namespace) -> int:
    try:
        start_hour, deadline_hour = validate_retry_window(args.start_hour, args.deadline_hour)
        window_weekday = validate_window_weekday(args.window_weekday)
        timezone = timezone_for_name(args.timezone)
        now = parse_datetime(args.now, timezone) if args.now else dt.datetime.now(timezone)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0 if deadline_reached_at(
        now,
        deadline_hour,
        args.timezone,
        window_weekday=window_weekday,
        start_hour=start_hour,
    ) else 1


def command_claim_attempt_alert(args: argparse.Namespace) -> int:
    try:
        claimed = claim_attempt_state_key(args.state_file)
    except OSError as exc:
        print(f"ERROR: attempt state update failed: {exc}", file=sys.stderr)
        return 2
    return 0 if claimed else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Assemble DA weekly report JSON and markdown")
    sub = parser.add_subparsers(dest="command", required=True)

    build = sub.add_parser("build")
    build.add_argument("--analysis-sidecar", required=True)
    build.add_argument("--state-dir", required=True)
    build.add_argument("--repo-root", required=True)
    build.add_argument("--output-json", required=True)
    build.add_argument("--output-md")
    build.add_argument("--publish-log-path", required=True)
    build.add_argument("--week-start")
    build.add_argument("--week-end")
    build.add_argument("--commentary-error")
    build.add_argument("--analyze-exit-code", type=int, default=0)
    build.set_defaults(func=command_build)

    finalize = sub.add_parser("finalize")
    finalize.add_argument("--input-json", required=True)
    finalize.add_argument("--output-json", required=True)
    finalize.add_argument("--output-md", required=True)
    finalize.add_argument("--commentary-file")
    finalize.add_argument("--commentary-error")
    finalize.add_argument(
        "--secret-source",
        action="append",
        help="file containing literal secret values that must not appear in commentary",
    )
    finalize.set_defaults(func=command_finalize)

    commentary_projection = sub.add_parser("render-commentary-input")
    commentary_projection.add_argument("--report-json", required=True)
    commentary_projection.add_argument("--output", required=True)
    commentary_projection.set_defaults(
        func=command_render_projection,
        projection="commentary",
    )

    github_projection = sub.add_parser("render-github-markdown")
    github_projection.add_argument("--report-json", required=True)
    github_projection.add_argument("--output", required=True)
    github_projection.set_defaults(func=command_render_projection, projection="github")

    full_markdown = sub.add_parser("render-full-markdown")
    full_markdown.add_argument("--report-json", required=True)
    full_markdown.add_argument("--output", required=True)
    full_markdown.set_defaults(func=command_render_full_markdown)

    guarded_publish = sub.add_parser("publish-github-guarded")
    guarded_publish.add_argument("--report-json", required=True)
    guarded_publish.add_argument("--issue", required=True)
    guarded_publish.add_argument("--repo-root", required=True)
    guarded_publish.add_argument("--token-source", required=True)
    guarded_publish.add_argument("--secret-source", action="append")
    guarded_publish.add_argument("--output-body", required=True)
    guarded_publish.set_defaults(func=command_publish_github_guarded)

    publish = sub.add_parser("publish-record")
    publish.add_argument("--publish-log", required=True)
    publish.add_argument("--week-id", required=True)
    publish.add_argument("--target", required=True)
    publish.add_argument(
        "--status",
        required=True,
        choices=["success", "failed", "blocked", "skipped"],
    )
    publish.add_argument("--message", default="")
    publish.add_argument("--url")
    publish.add_argument("--report-json")
    publish.add_argument("--report-md")
    publish.set_defaults(func=command_publish_record)

    pending = sub.add_parser("pending-publish-targets")
    pending.add_argument("--publish-log", required=True)
    pending.add_argument(
        "--targets",
        required=True,
        help="comma-separated publish target list",
    )
    pending.add_argument(
        "--format",
        choices=["names", "tsv", "json"],
        default="names",
    )
    pending.set_defaults(func=command_pending_publish_targets)

    notify = sub.add_parser("notification")
    notify.add_argument("--report-json", required=True)
    notify.set_defaults(func=command_notification)

    week_id = sub.add_parser("week-id")
    week_id.set_defaults(func=command_week_id)

    attempt_state = sub.add_parser("attempt-state-path")
    attempt_state.add_argument("--state-dir", required=True)
    attempt_state.add_argument("--week-id", required=True)
    attempt_state.set_defaults(func=command_attempt_state_path)

    deadline = sub.add_parser("deadline-reached")
    deadline.add_argument("--window-weekday", default="Mon")
    deadline.add_argument("--start-hour", type=int, default=0)
    deadline.add_argument("--deadline-hour", type=int, required=True)
    deadline.add_argument("--timezone", default=KST_NAME)
    deadline.add_argument("--now")
    deadline.set_defaults(func=command_deadline_reached)

    claim_alert = sub.add_parser("claim-attempt-alert")
    claim_alert.add_argument("--state-file", required=True)
    claim_alert.set_defaults(func=command_claim_attempt_alert)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
