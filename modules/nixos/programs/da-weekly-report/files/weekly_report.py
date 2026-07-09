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
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
HEALTH_FORMULA_VERSION = 1
KST = dt.timezone(dt.timedelta(hours=9), "KST")
KST_NAME = "Asia/Seoul"
RUN_DA_PATH = "modules/shared/programs/claude/files/skills/run-da/"
RUN_DA_SKILL_PATH = RUN_DA_PATH + "SKILL.md"
WEEKLY_REPORT_RE = re.compile(r"^weekly-\d{4}-W\d{2}\.json$")
DRIFT_SUBJECT_RE = re.compile(r"(fix|refactor|chore)", re.I)
DRIFT_BODY_RE = re.compile(r"(drift|참조|사본|dangling|동기화|SSOT)", re.I)
REMOTE_PREFLIGHT_ALERT_KEY = "remote_preflight_alert_attempted"
RETRYABLE_PUBLISH_STATUSES = {"failed"}
SECRET_ASSIGNMENT_NAMES = {
    "GH_PAT",
    "GH_TOKEN",
    "GITHUB_PAT",
    "GITHUB_TOKEN",
    "PUSHOVER_TOKEN",
    "PUSHOVER_USER",
}


def utc_now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def parse_datetime(value: str) -> dt.datetime:
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=KST)
    return parsed


def default_week_bounds(now: dt.datetime | None = None) -> tuple[dt.datetime, dt.datetime]:
    base = now or dt.datetime.now(KST)
    base = base.astimezone(KST)
    start_date = base.date() - dt.timedelta(days=base.weekday())
    start = dt.datetime.combine(start_date, dt.time.min, tzinfo=KST)
    return start, start + dt.timedelta(days=7)


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


def deadline_reached_at(now: dt.datetime, deadline_hour: int) -> bool:
    validate_deadline_hour(deadline_hour)
    return now.astimezone(KST).hour >= deadline_hour


def parse_attempt_state(text: str) -> dict[str, str]:
    state = {}
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        state[key.strip()] = value.strip()
    return state


def load_attempt_state(path: str | os.PathLike[str]) -> dict[str, str]:
    try:
        return parse_attempt_state(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}


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


def atomic_write_text(path: str | os.PathLike[str], text: str) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(f".{target.name}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fp:
        fp.write(text)
    tmp.chmod(0o600)
    os.replace(tmp, target)
    target.chmod(0o600)


def atomic_write_json(path: str | os.PathLike[str], obj: dict) -> None:
    atomic_write_text(path, json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True) + "\n")


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
    week_start: dt.datetime,
    week_end: dt.datetime,
    warnings: list[str],
) -> dict:
    git_format = "%H%x00%s%x00%B%x1e"
    proc = run_git(repo_root, [
        "log",
        f"--since={week_start.isoformat()}",
        f"--until={week_end.isoformat()}",
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
        "since": week_start.isoformat(),
        "until": week_end.isoformat(),
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


def collect_health_metrics(repo_root: str, week_start: dt.datetime, week_end: dt.datetime) -> dict:
    warnings: list[str] = []
    return {
        "health_formula_version": HEALTH_FORMULA_VERSION,
        "formula_break": None,
        "run_da_path": RUN_DA_PATH,
        "document_size": collect_document_size(repo_root, warnings),
        "drift_repair_commits": collect_drift_repair_commits(
            repo_root, week_start, week_end, warnings
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
        "M-5": {
            "source": metrics.get("M-5", {}).get("source", "unavailable"),
            "n": metrics.get("M-5", {}).get("n", 0),
            "distribution": metrics.get("M-5", {}).get("distribution", {}),
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
        }

    arbiter_sessions = session_counts.get("arbiter_marker_sessions", 0) or 0
    intensity_sessions = session_counts.get("intensity_marker_sessions", 0) or 0
    m5_source = sidecar.get("metrics", {}).get("M-5", {}).get("source", "unavailable")
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
        "m5_source_distribution": {m5_source: 1},
        "host_collection": host_collection,
        "warnings": warnings,
        "health_warnings": health.get("warnings", []),
    }


def build_traceability(sidecar: dict, limit: int = 50) -> dict:
    raw = sidecar.get("traceability", {})
    sessions = raw.get("sessions", [])
    def session_score(item: dict) -> tuple[int, str]:
        refs = item.get("references", {})
        ref_count = sum(len(refs.get(key, [])) for key in ("prs", "issues", "bare_numbers"))
        return (1 if ref_count else 0, item.get("path") or "")

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
        except OSError as exc:
            return None, f"commentary file read failed: {exc}"
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
    report = {
        "schema_version": SCHEMA_VERSION,
        "week": {
            "id": week_id,
            "start": week_start.isoformat(),
            "end": week_end.isoformat(),
            "tz": KST_NAME,
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


def render_distribution_table(distribution: dict, percentages: dict | None = None) -> list[str]:
    rows = ["| 항목 | 카운트 | 비율 |", "|------|--------|------|"]
    for key in sorted(distribution):
        count = distribution.get(key, 0)
        percent = percentages.get(key, 0.0) if percentages else 0.0
        rows.append(f"| {esc(key)} | {count} | {percent:.1f}% |")
    return rows


def render_mermaid_pie(title: str, distribution: dict) -> list[str]:
    nonzero = [(key, value) for key, value in distribution.items() if value]
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
    out.append(f"| 기간 | {report['week']['start']} ~ {report['week']['end']} ({report['week']['tz']}) |")
    out.append(f"| 호스트 | {', '.join(analysis.get('hosts', []))} |")
    out.append(f"| corpus | {analysis.get('corpus')} |")
    out.append(f"| partial | {coverage.get('partial')} |")
    out.append("")

    out.append("## 핵심 수치 요약")
    out.append("")
    m1 = metrics["M-1"]
    m2 = metrics["M-2"]
    m5 = metrics["M-5"]
    m6 = metrics["M-6"]
    out.append("| 지표 | 값 |")
    out.append("|------|-----|")
    out.append(f"| 분석 세션 | {analysis.get('session_counts', {}).get('total', 0)} |")
    out.append(f"| M-1 FULL | {m1.get('distribution', {}).get('FULL', 0)} ({m1.get('percentages', {}).get('FULL', 0.0):.1f}%) |")
    out.append(f"| M-2 CONFIRMED_ISSUE | {m2.get('distribution', {}).get('CONFIRMED_ISSUE', 0)} ({m2.get('percentages', {}).get('CONFIRMED_ISSUE', 0.0):.1f}%) |")
    out.append(f"| M-5 source | {m5.get('source')} / n={m5.get('n', 0)} |")
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
    out.append("| host | status | analyzed sessions | warnings |")
    out.append("|------|--------|-------------------|----------|")
    for host, info in coverage.get("host_collection", {}).items():
        out.append(
            f"| {esc(host)} | {esc(info.get('status'))} | {info.get('analyzed_sessions', 0)} | {len(info.get('warnings', []))} |"
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
    for source, info in m2.get("source_distribution", {}).items():
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

    out.append("## M-5: selective consistency stability_status 분포")
    out.append("")
    out.append(f"source: `{esc(m5.get('source'))}`")
    out.append("")
    out.append("| stability_status | count |")
    out.append("|------------------|-------|")
    for status, count in sorted(m5.get("distribution", {}).items()):
        out.append(f"| {esc(status)} | {count} |")
    if not m5.get("distribution"):
        out.append("| unavailable | 0 |")
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


def latest_publish_statuses(path: str | os.PathLike[str]) -> dict[str, str]:
    """Return the last valid status for each publish target in an append-only JSONL log."""
    statuses: dict[str, str] = {}
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        return statuses

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
            statuses[target] = status
    return statuses


def pending_publish_targets(
    path: str | os.PathLike[str],
    targets: list[str] | tuple[str, ...],
) -> list[str]:
    latest = latest_publish_statuses(path)
    pending = []
    for target in targets:
        status = latest.get(target)
        if status is None or status in RETRYABLE_PUBLISH_STATUSES:
            pending.append(target)
    return pending


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
    if args.week_start and args.week_end:
        week_start = parse_datetime(args.week_start)
        week_end = parse_datetime(args.week_end)
    else:
        week_start, week_end = default_week_bounds()
    week_id = week_id_for(week_start)
    health = collect_health_metrics(args.repo_root, week_start, week_end)
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
        "report_markdown_path": os.path.abspath(args.output_md),
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
    atomic_write_json(args.output_json, report)
    atomic_write_text(args.output_md, render_markdown(report) + "\n")
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
    atomic_write_json(args.output_json, report)
    atomic_write_text(args.output_md, render_markdown(report) + "\n")
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
    for target in pending_publish_targets(args.publish_log, targets):
        print(target)
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
        deadline_hour = validate_deadline_hour(args.deadline_hour)
        now = parse_datetime(args.now) if args.now else dt.datetime.now(KST)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    return 0 if deadline_reached_at(now, deadline_hour) else 1


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
    build.add_argument("--output-md", required=True)
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

    publish = sub.add_parser("publish-record")
    publish.add_argument("--publish-log", required=True)
    publish.add_argument("--week-id", required=True)
    publish.add_argument("--target", required=True)
    publish.add_argument("--status", required=True, choices=["success", "failed", "skipped"])
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
    deadline.add_argument("--deadline-hour", type=int, required=True)
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
