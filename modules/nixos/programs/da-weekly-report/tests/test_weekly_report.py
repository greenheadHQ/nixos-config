import datetime as dt
import json


def sample_sidecar():
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


def sample_health():
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


def build_report(weekly_report_module, previous_reports=None):
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


def test_parse_drift_log_uses_subject_and_body(weekly_report_module):
    output = (
        "aaa\x00fix: repair prompt\x00body without keyword\x1e"
        "bbb\x00docs: update\x00SSOT drift reference in body\x1e"
        "ccc\x00chore: weekly maintenance\x00본문 참조 동기화\x1e"
        "ddd\x00refactor: cleanup\x00dangling 사본 제거\x1e"
    )

    commits = weekly_report_module.parse_drift_log(output)

    assert [item["hash"] for item in commits] == ["ccc", "ddd"]


def test_count_rules_from_text(weekly_report_module):
    text = """
## 핵심 invariants

1. one
2. two

## 주의사항

- a
* b

## Non-goals

1. no
2. nope
"""

    counts = weekly_report_module.count_rules_from_text(text)

    assert counts == {
        "core_invariants_numbered": 2,
        "cautions_bullets": 2,
        "non_goals_numbered": 2,
        "total": 6,
    }


def test_previous_report_glob_excludes_publish_json(weekly_report_module, tmp_path):
    for name in [
        "weekly-2026-W27.json",
        "weekly-2026-W26.json",
        "weekly-2026-W25.json",
        "weekly-2026-W28-publish.json",
        "weekly-2026-W28.draft.json",
    ]:
        (tmp_path / name).write_text("{}")

    paths = weekly_report_module.previous_report_paths(str(tmp_path), current_week_id="2026-W28")

    assert [path.split("/")[-1] for path in paths] == [
        "weekly-2026-W27.json",
        "weekly-2026-W26.json",
    ]


def test_attempt_state_path_uses_iso_week_id(weekly_report_module, tmp_path):
    start = dt.datetime(2026, 7, 6, tzinfo=weekly_report_module.KST)
    week_id = weekly_report_module.week_id_for(start)

    assert week_id == "2026-W28"
    assert weekly_report_module.attempt_state_filename(week_id) == "attempt-2026-W28.state"
    assert weekly_report_module.attempt_state_path(tmp_path, week_id) == str(
        tmp_path / "attempt-2026-W28.state"
    )


def test_deadline_reached_uses_kst_hour(weekly_report_module):
    before_deadline = dt.datetime(2026, 7, 13, 4, 59, tzinfo=dt.timezone.utc)
    at_deadline = dt.datetime(2026, 7, 13, 5, 0, tzinfo=dt.timezone.utc)

    assert weekly_report_module.deadline_reached_at(before_deadline, 14) is False
    assert weekly_report_module.deadline_reached_at(at_deadline, 14) is True


def test_deadline_reached_command_statuses(weekly_report_module):
    assert weekly_report_module.main([
        "deadline-reached",
        "--deadline-hour",
        "14",
        "--now",
        "2026-07-13T13:59:00+09:00",
    ]) == 1
    assert weekly_report_module.main([
        "deadline-reached",
        "--deadline-hour",
        "14",
        "--now",
        "2026-07-13T14:00:00+09:00",
    ]) == 0


def test_claim_attempt_alert_only_claims_once(weekly_report_module, tmp_path):
    state_file = tmp_path / "attempt-2026-W28.state"

    assert weekly_report_module.main([
        "claim-attempt-alert",
        "--state-file",
        str(state_file),
    ]) == 0
    assert weekly_report_module.main([
        "claim-attempt-alert",
        "--state-file",
        str(state_file),
    ]) == 1

    state = weekly_report_module.load_attempt_state(state_file)
    assert set(state) == {weekly_report_module.REMOTE_PREFLIGHT_ALERT_KEY}


def test_build_weekly_report_schema_and_deltas(weekly_report_module):
    previous = build_report(weekly_report_module)
    previous["week"]["id"] = "2026-W27"
    previous["analysis"]["metrics"]["M-2"]["percentages"]["CONFIRMED_ISSUE"] = 50.0
    previous["health"]["rule_counts"]["total"] = 5
    previous["provenance"]["report_json_path"] = "/state/weekly-2026-W27.json"

    report = build_report(weekly_report_module, previous_reports=[previous])

    assert report["schema_version"] == 1
    assert set(report) == {
        "schema_version",
        "week",
        "analysis",
        "health",
        "coverage",
        "traceability",
        "deltas",
        "commentary",
        "provenance",
    }
    assert "publish_results" not in report
    assert report["coverage"]["partial"] is True
    assert report["traceability"]["coverage"]["complete_sessions"] == 2

    delta_by_metric = {item["metric"]: item for item in report["deltas"]["items"]}
    confirmed_delta = delta_by_metric[
        "analysis.metrics.M-2.percentages.CONFIRMED_ISSUE"
    ]["comparisons"][0]
    assert confirmed_delta == {
        "week_id": "2026-W27",
        "previous": 50.0,
        "delta": 16.7,
    }
    rule_delta = delta_by_metric["health.rule_counts.total"]["comparisons"][0]
    assert rule_delta["delta"] == 1.0


def test_render_markdown_uses_only_pie_mermaid_and_json_view(weekly_report_module):
    report = build_report(weekly_report_module)

    markdown = weekly_report_module.render_markdown(report)

    assert "```mermaid\npie title" in markdown
    assert "xychart" not in markdown
    assert "## 소스 추적 링크" in markdown
    assert "issue:1064" in markdown
    assert "해설 없음: codex unavailable" in markdown
    assert "round key: `(session_path, block_index)`" in markdown
    assert "baseline: baseline" in markdown


def test_publish_record_is_append_only_json_lines(weekly_report_module, tmp_path):
    path = tmp_path / "weekly-2026-W28-publish.json"

    weekly_report_module.append_publish_record(path, {"target": "github", "status": "skipped"})
    weekly_report_module.append_publish_record(path, {"target": "pushover", "status": "success"})

    lines = path.read_text().splitlines()
    assert len(lines) == 2
    assert [json.loads(line)["target"] for line in lines] == ["github", "pushover"]


def test_pending_publish_targets_uses_latest_status_per_target(weekly_report_module, tmp_path):
    path = tmp_path / "weekly-2026-W28-publish.json"

    weekly_report_module.append_publish_record(path, {"target": "github", "status": "failed"})
    weekly_report_module.append_publish_record(path, {"target": "pushover", "status": "success"})
    weekly_report_module.append_publish_record(path, {"target": "matrix", "status": "skipped"})

    assert weekly_report_module.latest_publish_statuses(path) == {
        "github": "failed",
        "matrix": "skipped",
        "pushover": "success",
    }
    assert weekly_report_module.pending_publish_targets(
        path,
        ["github", "pushover", "matrix", "missing"],
    ) == ["github", "missing"]

    weekly_report_module.append_publish_record(path, {"target": "github", "status": "success"})

    assert weekly_report_module.pending_publish_targets(path, ["github", "pushover"]) == []


def test_pending_publish_targets_command_skips_terminal_statuses(
    weekly_report_module,
    tmp_path,
    capsys,
):
    path = tmp_path / "weekly-2026-W28-publish.json"
    weekly_report_module.append_publish_record(path, {"target": "github", "status": "skipped"})

    rc = weekly_report_module.main([
        "pending-publish-targets",
        "--publish-log",
        str(path),
        "--targets",
        "github,pushover",
    ])

    assert rc == 0
    assert capsys.readouterr().out.splitlines() == ["pushover"]


def test_finalize_injects_commentary_without_recomputing_report(weekly_report_module, tmp_path):
    draft = build_report(weekly_report_module)
    draft["health"]["rule_counts"]["total"] = 123
    draft_path = tmp_path / "weekly-2026-W28.draft.json"
    final_path = tmp_path / "weekly-2026-W28.json"
    final_md = tmp_path / "weekly-2026-W28.md"
    commentary = tmp_path / "commentary.txt"
    draft_path.write_text(json.dumps(draft), encoding="utf-8")
    commentary.write_text("해설 본문", encoding="utf-8")

    rc = weekly_report_module.main([
        "finalize",
        "--input-json",
        str(draft_path),
        "--output-json",
        str(final_path),
        "--output-md",
        str(final_md),
        "--commentary-file",
        str(commentary),
    ])

    assert rc == 0
    final = json.loads(final_path.read_text())
    assert final["health"]["rule_counts"]["total"] == 123
    assert final["commentary"] == {"text": "해설 본문", "failure_reason": None}
    assert final["provenance"]["report_json_path"] == str(final_path.resolve())
    assert "해설 본문" in final_md.read_text()


def test_finalize_discards_commentary_containing_secret_values(
    weekly_report_module,
    tmp_path,
):
    draft = build_report(weekly_report_module)
    draft_path = tmp_path / "weekly-2026-W28.draft.json"
    final_path = tmp_path / "weekly-2026-W28.json"
    final_md = tmp_path / "weekly-2026-W28.md"
    commentary = tmp_path / "commentary.txt"
    gh_pat = tmp_path / "github-pat"
    pushover_cred = tmp_path / "pushover-share"
    draft_path.write_text(json.dumps(draft), encoding="utf-8")
    gh_pat.write_text("ghp_plain_secret\n", encoding="utf-8")
    pushover_cred.write_text(
        "PUSHOVER_TOKEN='pushover token secret'\nPUSHOVER_USER='pushover user secret'\n",
        encoding="utf-8",
    )
    commentary.write_text("요약 중 pushover token secret 노출", encoding="utf-8")

    rc = weekly_report_module.main([
        "finalize",
        "--input-json",
        str(draft_path),
        "--output-json",
        str(final_path),
        "--output-md",
        str(final_md),
        "--commentary-file",
        str(commentary),
        "--secret-source",
        str(gh_pat),
        "--secret-source",
        str(pushover_cred),
    ])

    assert rc == 0
    final = json.loads(final_path.read_text())
    assert final["commentary"] == {
        "text": None,
        "failure_reason": "sanitize gate: secret-like content",
    }
    assert not commentary.exists()
    assert "sanitize gate: secret-like content" in final_md.read_text()
