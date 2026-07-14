"""Shared canonical report builders for weekly report regression tests."""

from __future__ import annotations

import datetime as dt
from typing import Any


def sample_sidecar() -> dict[str, Any]:
    return {
        "schema_version": "1.0",
        "captured_at": "2026-07-09T00:00:00+00:00",
        "hosts": ["mac", "minipc"],
        "corpus": "live",
        "session_counts": {
            "total": 4,
            "arbiter_marker_sessions": 2,
            "intensity_marker_sessions": 1,
        },
        "metrics": {
            "M-1": {
                "denominator": "intensity_marker_sessions",
                "n": 1,
                "distribution": {"FULL": 1},
                "percentages": {"FULL": 100.0},
            },
            "M-2": {
                "denominator": "arbiter_marker_sessions_findings_high_medium",
                "n": 3,
                "distribution": {"CONFIRMED_ISSUE": 2, "NOT_AN_ISSUE": 1},
                "percentages": {"CONFIRMED_ISSUE": 66.7, "NOT_AN_ISSUE": 33.3},
                "source_distribution": {
                    "verdict_json": {"count": 2, "confidence": "high"},
                    "kv": {"count": 1, "confidence": "medium"},
                },
            },
            "M-3": {
                "by_bundle": {
                    "Correctness": {"total": 2, "confirmed": 1, "confirmed_rate": 0.5},
                    "Design": {"total": 1, "confirmed": 1, "confirmed_rate": 1.0},
                }
            },
            "M-4": {
                "round_key": "(session_path, block_index)",
                "baseline_note": "baseline",
                "transition_matrix": {"HIGH->LOW": 1},
            },
            "M-5": {
                "source": "unavailable",
                "n": 0,
                "distribution": {},
            },
            "M-6": {
                "name": "persistence_key non-convergence",
                "persistence_key": "(perspective, location_identity, finding_fingerprint)",
                "key_block_count_distribution": {"2": 1},
                "coverage": {
                    "eligible_records": 3,
                    "missing_persistence_components": 1,
                },
            },
        },
        "derived": {"intensity_full_finding_zero_rate": 0.25},
        "diagnostics": {
            "summary": {
                "parse_failure": 1,
                "exclusion": 2,
                "invalid_verdict": 1,
                "missing_persistence_component": 1,
            },
            "sessions": [],
        },
        "traceability": {
            "coverage": {
                "sessions_total": 4,
                "complete_sessions": 2,
                "unknown_format_sessions": 1,
                "format_distribution": {"claude": 1, "codex": 2, "unknown": 1},
                "host_distribution": {"mac": 1, "minipc": 2, "unknown": 1},
            },
            "sessions": [
                {
                    "path": "/home/greenhead/.codex/sessions/2026/07/09/rollout-2026-07-09T00-00-00-abc123.jsonl",
                    "host": "minipc",
                    "format": "codex",
                    "cwd": "/repo",
                    "git_branch": "issue_1064",
                    "session_id": "abc123",
                    "rollout_date": "2026-07-09",
                    "complete": True,
                    "missing_fields": [],
                    "fallback_fields": ["rollout_directory.date"],
                    "references": {"prs": ["77"], "issues": ["1064"], "bare_numbers": []},
                }
            ],
        },
        "warnings": ["host mac: ssh find timeout for ~/.codex/sessions — partial result"],
    }


def sample_health() -> dict[str, Any]:
    return {
        "health_formula_version": 1,
        "formula_break": None,
        "run_da_path": "modules/shared/programs/claude/files/skills/run-da/",
        "document_size": {"markdown_file_count": 10, "total_line_count": 1000, "files": []},
        "drift_repair_commits": {"count": 1, "commit_hashes": ["abc"], "commits": []},
        "rule_counts": {
            "core_invariants_numbered": 3,
            "cautions_bullets": 2,
            "non_goals_numbered": 1,
            "total": 6,
        },
        "warnings": [],
    }


def build_report(
    weekly_report_module,
    previous_reports: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    start = dt.datetime(2026, 7, 6, tzinfo=weekly_report_module.KST)
    end = start + dt.timedelta(days=7)
    return weekly_report_module.build_weekly_report(
        sidecar=sample_sidecar(),
        health=sample_health(),
        week_start=start,
        week_end=end,
        previous_reports=previous_reports or [],
        commentary_text=None,
        commentary_failure="codex unavailable",
        provenance={
            "analysis_sidecar_path": "/state/analyze-2026-W28.json",
            "publish_log_path": "/state/weekly-2026-W28-publish.json",
            "repo_root": "/repo",
            "report_json_path": "/state/weekly-2026-W28.json",
            "report_markdown_path": "/state/weekly-2026-W28.md",
        },
        analyze_exit_code=0,
    )


def projection_stress_report(weekly_report_module) -> dict[str, Any]:
    report = build_report(weekly_report_module)
    raw_warnings = [
        (
            "host mac: remote collection warning "
            f"/Users/greenhead/.codex/raw-warning-marker-{index:05d}.jsonl"
        )
        for index in range(10_000)
    ]
    report["analysis"]["warnings"] = list(raw_warnings)
    report["coverage"]["warnings"] = list(raw_warnings)
    report["coverage"]["health_warnings"] = [
        "health warning with /home/greenhead/private-health-path"
    ]
    report["coverage"]["host_collection"]["mac"]["warnings"] = list(raw_warnings)
    report["commentary"] = {
        "text": "다국어 해설 🚦 | <script> ```mermaid\npie title hostile``` & 완료",
        "failure_reason": None,
    }
    report["deltas"] = {
        "previous_reports": [
            {
                "path": "/home/greenhead/private-delta-marker/weekly-2026-W27.json",
                "week_id": "2026-W27",
            }
        ],
        "items": [
            {
                "metric": "analysis.metrics.M-2.percentages.CONFIRMED_ISSUE",
                "unit": "%p",
                "current": 66.7,
                "comparisons": [
                    {"week_id": "2026-W27", "previous": 50.0, "delta": 16.7}
                ],
            }
        ],
    }
    return report
