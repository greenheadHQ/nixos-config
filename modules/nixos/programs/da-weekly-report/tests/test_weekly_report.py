import copy
import datetime as dt
import json
import os
from pathlib import Path

import pytest

from fixture_builders import (
    build_report,
    projection_stress_report,
    sample_health,
    sample_sidecar,
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


def test_deadline_reached_uses_configured_timezone(weekly_report_module):
    before_utc_deadline = dt.datetime(2026, 7, 13, 13, 59, tzinfo=dt.timezone.utc)
    at_utc_deadline = dt.datetime(2026, 7, 13, 14, 0, tzinfo=dt.timezone.utc)

    assert weekly_report_module.deadline_reached_at(
        before_utc_deadline,
        14,
        "UTC",
    ) is False
    assert weekly_report_module.deadline_reached_at(
        at_utc_deadline,
        14,
        "UTC",
    ) is True


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
    assert weekly_report_module.main([
        "deadline-reached",
        "--deadline-hour",
        "14",
        "--timezone",
        "UTC",
        "--now",
        "2026-07-13T13:59:00+00:00",
    ]) == 1
    assert weekly_report_module.main([
        "deadline-reached",
        "--deadline-hour",
        "14",
        "--timezone",
        "UTC",
        "--now",
        "2026-07-13T14:00:00+00:00",
    ]) == 0


def test_deadline_reached_tuesday_catchup_after_monday_window(
    weekly_report_module,
):
    before_configured_weekday = dt.datetime(2026, 7, 13, 15, 0, tzinfo=weekly_report_module.KST)
    tuesday_morning = dt.datetime(2026, 7, 14, 9, 0, tzinfo=weekly_report_module.KST)

    assert weekly_report_module.deadline_reached_at(
        before_configured_weekday,
        14,
        "Asia/Seoul",
        window_weekday="Tue",
        start_hour=9,
    ) is False
    assert weekly_report_module.deadline_reached_at(
        tuesday_morning,
        14,
        "Asia/Seoul",
        window_weekday="Mon",
        start_hour=9,
    ) is True
    assert weekly_report_module.main([
        "deadline-reached",
        "--window-weekday",
        "Mon",
        "--start-hour",
        "9",
        "--deadline-hour",
        "14",
        "--timezone",
        "Asia/Seoul",
        "--now",
        "2026-07-14T09:00:00+09:00",
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
    assert "host mac: ssh find timeout" in markdown


def test_publish_record_is_append_only_json_lines(weekly_report_module, tmp_path):
    path = tmp_path / "weekly-2026-W28-publish.json"

    weekly_report_module.append_publish_record(path, {"target": "github", "status": "skipped"})
    weekly_report_module.append_publish_record(path, {"target": "pushover", "status": "success"})

    lines = path.read_text().splitlines()
    assert len(lines) == 2
    assert [json.loads(line)["target"] for line in lines] == ["github", "pushover"]


def test_pending_publish_targets_uses_latest_status_per_target(weekly_report_module, tmp_path):
    path = tmp_path / "weekly-2026-W28-publish.json"

    weekly_report_module.append_publish_record(
        path,
        {"target": "github", "status": "failed", "url": "https://example.invalid/old"},
    )
    weekly_report_module.append_publish_record(
        path,
        {"target": "pushover", "status": "success", "url": "https://example.invalid/comment"},
    )
    weekly_report_module.append_publish_record(path, {"target": "matrix", "status": "skipped"})

    assert weekly_report_module.latest_publish_records(path) == {
        "github": {
            "target": "github",
            "status": "failed",
            "url": "https://example.invalid/old",
        },
        "matrix": {"target": "matrix", "status": "skipped"},
        "pushover": {
            "target": "pushover",
            "status": "success",
            "url": "https://example.invalid/comment",
        },
    }
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


def test_pending_publish_targets_command_can_emit_latest_records_for_retry_url(
    weekly_report_module,
    tmp_path,
    capsys,
):
    path = tmp_path / "weekly-2026-W28-publish.json"
    weekly_report_module.append_publish_record(
        path,
        {
            "target": "github",
            "status": "success",
            "url": "https://github.com/org/repo/issues/1#issuecomment-1",
        },
    )
    weekly_report_module.append_publish_record(path, {"target": "pushover", "status": "failed"})

    rc = weekly_report_module.main([
        "pending-publish-targets",
        "--publish-log",
        str(path),
        "--targets",
        "github,pushover",
        "--format",
        "tsv",
    ])

    assert rc == 0
    assert capsys.readouterr().out.splitlines() == [
        "github\t0\tsuccess\thttps://github.com/org/repo/issues/1#issuecomment-1",
        "pushover\t1\tfailed\t",
    ]


def test_pending_publish_targets_retries_blocked_but_skipped_is_terminal(
    weekly_report_module,
    tmp_path,
):
    path = tmp_path / "weekly-2026-W28-publish.json"

    weekly_report_module.append_publish_record(path, {"target": "github", "status": "blocked"})
    weekly_report_module.append_publish_record(path, {"target": "matrix", "status": "skipped"})
    weekly_report_module.append_publish_record(path, {"target": "pushover", "status": "success"})

    assert weekly_report_module.pending_publish_targets(
        path,
        ["github", "matrix", "pushover", "missing"],
    ) == ["github", "missing"]


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


def test_publish_record_command_accepts_blocked_status(weekly_report_module, tmp_path):
    path = tmp_path / "weekly-2026-W28-publish.json"

    rc = weekly_report_module.main([
        "publish-record",
        "--publish-log",
        str(path),
        "--week-id",
        "2026-W28",
        "--target",
        "github",
        "--status",
        "blocked",
        "--message",
        "GH token path not readable",
    ])

    assert rc == 0
    assert weekly_report_module.latest_publish_statuses(path) == {"github": "blocked"}


def test_build_command_allows_omitting_output_markdown(
    weekly_report_module,
    tmp_path,
    monkeypatch,
):
    sidecar_path = tmp_path / "analyze-2026-W28.json"
    output_json = tmp_path / "weekly-2026-W28.draft.json"
    publish_log = tmp_path / "weekly-2026-W28-publish.json"
    sidecar_path.write_text(json.dumps(sample_sidecar()), encoding="utf-8")
    monkeypatch.setattr(
        weekly_report_module,
        "collect_health_metrics",
        lambda *args: sample_health(),
    )

    rc = weekly_report_module.main([
        "build",
        "--analysis-sidecar",
        str(sidecar_path),
        "--state-dir",
        str(tmp_path),
        "--repo-root",
        "/repo",
        "--output-json",
        str(output_json),
        "--publish-log-path",
        str(publish_log),
        "--week-start",
        "2026-07-06T00:00:00+09:00",
        "--week-end",
        "2026-07-13T00:00:00+09:00",
    ])

    assert rc == 0
    report = json.loads(output_json.read_text())
    assert report["provenance"]["report_markdown_path"] is None


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


def test_warning_category_classifies_fetch_budget_as_remote_collection(
    weekly_report_module,
):
    """budget 초과 warning은 remote_collection으로 분류돼야 한다.

    구 문구("fetch budget 초과 (절전/무응답 가능성)")가 ssh/tar/find 토큰이 없어
    other로 분류된 탓에, mac 수집 4주 연속 0건(issue #1067 W30~W33)이 카테고리 표에서
    보이지 않았다. 신 문구와 구 문구 모두 remote_collection이어야 한다.
    """
    new_style = "host mac: ssh fetch budget 초과 — remote 수집 중단, partial result"
    old_style = "host mac: fetch budget 초과 (절전/무응답 가능성) — partial result"
    assert weekly_report_module._warning_category(new_style) == "remote_collection"
    assert weekly_report_module._warning_category(old_style) == "remote_collection"


def test_commentary_projection_is_bounded_without_raw_warnings(weekly_report_module):
    report = projection_stress_report(weekly_report_module)

    rendered = weekly_report_module.render_commentary_input(report)
    payload = json.loads(rendered.split("\n\n", 1)[1])

    assert len(rendered.encode("utf-8")) <= 262_144
    assert payload["week"]["id"] == "2026-W28"
    assert payload["session_counts"]["total"] == 4
    assert set(payload["metrics"]) == {"M-1", "M-2", "M-3", "M-4", "M-6"}
    assert payload["warnings"]["total_count"] == 10_001
    assert payload["warnings"]["omitted_count"] == 10_001
    assert "commentary" not in payload
    assert "raw-warning-marker" not in rendered
    assert "private-health-path" not in rendered
    assert "private-delta-marker" not in rendered


def test_github_projection_is_bounded_and_structurally_complete(weekly_report_module):
    report = projection_stress_report(weekly_report_module)

    source = weekly_report_module.build_github_projection_source(report)
    rendered = weekly_report_module.render_github_markdown(report)

    assert len(rendered.encode("utf-8")) <= 60_000
    for heading in [
        "## 핵심 요약",
        "## 커버리지",
        "## M-1",
        "## M-2",
        "## M-3",
        "## M-4",
        "## M-6",
        "## 전주 delta",
        "## Warning 요약",
        "## LLM 해설",
    ]:
        assert heading in rendered
    assert rendered.count("<pre>") == rendered.count("</pre>") == 1
    assert rendered.count("```") % 2 == 0
    assert all(line.endswith("|") for line in rendered.splitlines() if line.startswith("|"))
    assert "다국어 해설 🚦" in rendered
    assert "omitted raw warnings" in rendered
    warning_summary = source["summary"]["warnings"]
    assert warning_summary == {
        "total_count": 10_001,
        "category_counts": {
            "remote_collection": 10_000,
            "validation": 0,
            "analysis": 0,
            "health": 1,
            "other": 0,
        },
        "host_counts": {"mac": 10_000, "minipc": 0, "unattributed": 1},
        "omitted_count": 10_001,
    }
    metrics = source["summary"]["metrics"]
    assert metrics["M-1"]["distribution"]["FULL"] == 1
    assert metrics["M-2"]["distribution"]["CONFIRMED_ISSUE"] == 2
    assert metrics["M-3"]["by_bundle"]["Correctness"]["total"] == 2
    assert metrics["M-4"]["transition_matrix"]["HIGH->LOW"] == 1
    assert "M-5" not in metrics
    assert metrics["M-6"]["coverage"]["eligible_records"] == 3
    assert "| remote_collection | 10000 |" in rendered
    assert "| health | 1 |" in rendered
    assert "| mac | 10000 |" in rendered
    assert "| unattributed | 1 |" in rendered
    assert "omitted raw warnings: 10001" in rendered
    assert "raw-warning-marker" not in rendered
    assert "private-health-path" not in rendered
    assert "private-delta-marker" not in rendered


def test_projection_does_not_mutate_canonical_report(weekly_report_module):
    report = projection_stress_report(weekly_report_module)
    before = copy.deepcopy(report)

    weekly_report_module.render_commentary_input(report)
    weekly_report_module.render_github_markdown(report)

    assert report == before
    assert report["schema_version"] == 1


def test_projection_cli_writes_atomically_with_0600(weekly_report_module, tmp_path):
    report = projection_stress_report(weekly_report_module)
    report_path = tmp_path / "weekly-2026-W28.json"
    report_path.write_text(json.dumps(report), encoding="utf-8")
    cases = [
        (
            "render-commentary-input",
            "commentary-input.txt",
            weekly_report_module.render_commentary_input,
        ),
        (
            "render-github-markdown",
            "github-body.md",
            weekly_report_module.render_github_markdown,
        ),
    ]
    for command, filename, renderer in cases:
        output_path = tmp_path / filename
        output_path.write_text("stale", encoding="utf-8")
        output_path.chmod(0o644)

        rc = weekly_report_module.main([
            command,
            "--report-json",
            str(report_path),
            "--output",
            str(output_path),
        ])

        assert rc == 0
        assert output_path.read_text(encoding="utf-8") == renderer(report)
        assert os.stat(output_path).st_mode & 0o777 == 0o600
        assert not list(tmp_path.glob(f".{filename}.*.tmp"))


def test_github_projection_uses_only_sanitized_commentary(weekly_report_module):
    report = build_report(weekly_report_module)
    report["commentary"] = {"text": "검증된 해설", "failure_reason": None}
    report["provenance"]["raw_commentary"] = "노출되면 안 되는 원문 해설"
    report["coverage"]["warnings"].append("노출되면 안 되는 warning 원문")

    rendered = weekly_report_module.render_github_markdown(report)

    assert "검증된 해설" in rendered
    assert "노출되면 안 되는 원문 해설" not in rendered
    assert "노출되면 안 되는 warning 원문" not in rendered


def test_github_projection_drops_non_allowlisted_dynamic_keys(weekly_report_module):
    report = build_report(weekly_report_module)
    report["analysis"]["metrics"]["M-2"]["source_distribution"]["verdict_json"][
        "raw-secret-key"
    ] = 99
    report["analysis"]["metrics"]["M-3"]["by_bundle"]["Correctness"][
        "raw-secret-key"
    ] = 99
    report["analysis"]["metrics"]["M-6"]["key_block_count_distribution"][
        "raw-secret-key"
    ] = 99

    source = weekly_report_module.build_github_projection_source(report)
    rendered = weekly_report_module.render_github_markdown_source(source)

    assert "raw-secret-key" not in json.dumps(source, ensure_ascii=False)
    assert "raw-secret-key" not in rendered


def test_guarded_publisher_checks_rendered_body_after_escape(
    weekly_report_module,
    tmp_path,
):
    report = build_report(weekly_report_module)
    report["commentary"] = {"text": "escape source & marker", "failure_reason": None}
    report_json = tmp_path / "weekly.json"
    report_json.write_text(json.dumps(report), encoding="utf-8")
    token_source = tmp_path / "github-token"
    token_source.write_text("ghp_fixture\n", encoding="utf-8")
    secret_source = tmp_path / "secrets"
    secret_source.write_text("PUSHOVER_TOKEN='&amp;'\n", encoding="utf-8")
    output = tmp_path / "github-body.md"

    result = weekly_report_module.publish_github_guarded(
        report_json=str(report_json),
        issue="1095",
        repo_root=str(tmp_path),
        token_source=str(token_source),
        secret_sources=[str(secret_source)],
        output_body=str(output),
    )

    assert result == ("blocked", "outbound_secret", "")
    assert not output.exists()


def test_existing_final_guard_rechecks_source_unreadable_during_finalize(
    weekly_report_module,
    tmp_path,
):
    secret = "late-readable-secret"
    commentary_file = tmp_path / "commentary.txt"
    commentary_file.write_text(f"해설 {secret}", encoding="utf-8")
    late_source = tmp_path / "late-secrets"

    text, error = weekly_report_module.read_sanitized_commentary(
        str(commentary_file),
        None,
        [str(late_source)],
    )
    assert text == f"해설 {secret}"
    assert error is None

    report = build_report(weekly_report_module)
    report["commentary"] = weekly_report_module.commentary_object(text, error)
    report_json = tmp_path / "weekly.json"
    report_json.write_text(json.dumps(report), encoding="utf-8")
    token_source = tmp_path / "github-token"
    token_source.write_text("ghp_fixture\n", encoding="utf-8")
    late_source.write_text(f"PUSHOVER_TOKEN='{secret}'\n", encoding="utf-8")

    result = weekly_report_module.publish_github_guarded(
        report_json=str(report_json),
        issue="1095",
        repo_root=str(tmp_path),
        token_source=str(token_source),
        secret_sources=[str(late_source)],
        output_body=str(tmp_path / "github-body.md"),
    )

    assert result == ("blocked", "outbound_secret", "")


def test_strict_secret_snapshot_reads_each_path_once(
    weekly_report_module,
    tmp_path,
    monkeypatch,
):
    token_source = tmp_path / "github-token"
    token_source.write_text("ghp_fixture\n", encoding="utf-8")
    secret_source = tmp_path / "secrets"
    secret_source.write_text("PUSHOVER_TOKEN='fixture-secret'\n", encoding="utf-8")
    original_read_text = Path.read_text
    reads: dict[str, int] = {}

    def tracked_read_text(path, *args, **kwargs):
        resolved = str(path.resolve())
        reads[resolved] = reads.get(resolved, 0) + 1
        return original_read_text(path, *args, **kwargs)

    monkeypatch.setattr(Path, "read_text", tracked_read_text)

    token, values = weekly_report_module.strict_secret_snapshot(
        str(token_source),
        [str(secret_source), str(secret_source), str(token_source)],
    )

    assert token == "ghp_fixture"
    assert values == ["ghp_fixture", "fixture-secret"]
    assert reads == {
        str(token_source.resolve()): 1,
        str(secret_source.resolve()): 1,
    }


def test_strict_secret_snapshot_guards_unknown_assignments_and_rejects_partial_parse(
    weekly_report_module,
    tmp_path,
):
    token_source = tmp_path / "github-token"
    token_source.write_text("ghp_fixture\n", encoding="utf-8")
    secret_source = tmp_path / "secrets"
    secret_source.write_text(
        "PUSHOVER_TOKEN='known'\nFUTURE_SECRET='future-value'\n",
        encoding="utf-8",
    )

    token, values = weekly_report_module.strict_secret_snapshot(
        str(token_source), [str(secret_source)]
    )

    assert token == "ghp_fixture"
    assert values == ["ghp_fixture", "known", "future-value"]

    for invalid in (
        "PUSHOVER_TOKEN='known'\nmalformed secret line\n",
        "PUSHOVER_TOKEN=\nPUSHOVER_USER='known'\n",
        "FIRST=known\nSECOND value\n",
        "PUSHOVER_TOKEN='future-secret",
        "PUSHOVER_TOKEN=future-secret\\",
    ):
        secret_source.write_text(invalid, encoding="utf-8")
        with pytest.raises(weekly_report_module.SecretSnapshotError):
            weekly_report_module.strict_secret_snapshot(
                str(token_source), [str(secret_source)]
            )


def test_atomic_report_pair_uses_json_as_commit_marker_and_recovers_markdown(
    weekly_report_module,
    tmp_path,
    monkeypatch,
):
    old_report = build_report(weekly_report_module)
    new_report = copy.deepcopy(old_report)
    new_report["commentary"] = {"text": "new commentary", "failure_reason": None}
    report_json = tmp_path / "weekly.json"
    report_md = tmp_path / "weekly.md"
    weekly_report_module.atomic_write_report_pair(report_json, old_report, report_md)
    original_replace = weekly_report_module.replace_staged_text

    def fail_json_replace(staged, target):
        if Path(target) == report_json:
            raise OSError("injected JSON replace failure")
        return original_replace(staged, target)

    monkeypatch.setattr(weekly_report_module, "replace_staged_text", fail_json_replace)
    with pytest.raises(OSError, match="injected JSON replace failure"):
        weekly_report_module.atomic_write_report_pair(report_json, new_report, report_md)

    assert json.loads(report_json.read_text(encoding="utf-8")) == old_report
    assert "new commentary" in report_md.read_text(encoding="utf-8")
    assert not list(tmp_path.glob(".*.tmp"))

    monkeypatch.setattr(weekly_report_module, "replace_staged_text", original_replace)
    assert weekly_report_module.main([
        "render-full-markdown",
        "--report-json",
        str(report_json),
        "--output",
        str(report_md),
    ]) == 0
    assert report_md.read_text(encoding="utf-8") == (
        weekly_report_module.render_markdown(old_report) + "\n"
    )
