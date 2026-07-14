"""Hermetic regression tests for the weekly report shell orchestration."""

from __future__ import annotations

import hashlib
import json
import os
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from fixture_builders import projection_stress_report, sample_sidecar


HERE = Path(__file__).resolve().parent
FILES_DIR = HERE.parent / "files"
REPORT_SCRIPT = FILES_DIR / "da-weekly-report.sh"
WEEKLY_REPORT_PY = FILES_DIR / "weekly_report.py"


@dataclass
class ExistingFinalFixture:
    """Typed handles for one hermetic existing-final shell scenario."""

    env: dict[str, str]
    week_id: str
    report: dict[str, Any]
    report_json: Path
    report_md: Path
    publish_log: Path
    gh_calls: Path
    gh_body: Path
    gh_path: Path
    analyzer_called: Path
    llm_called: Path
    pushover_cred: Path
    push_capture: Path
    state_dir: Path
    network_called: Path


def _write_executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _append_record(path: Path, *, week_id: str, target: str, status: str) -> None:
    record = {
        "recorded_at": "2026-07-13T00:00:00+00:00",
        "week_id": week_id,
        "target": target,
        "status": status,
        "message": "fixture",
        "url": None,
    }
    with path.open("a", encoding="utf-8") as fp:
        fp.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")


def _latest_record(path: Path, target: str) -> dict:
    records = [
        json.loads(line)
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    return [record for record in records if record.get("target") == target][-1]


def _target_count(path: Path, target: str) -> int:
    return sum(
        json.loads(line).get("target") == target
        for line in path.read_text(encoding="utf-8").splitlines()
        if line.strip()
    )


def _reset_publish_records(
    fixture: ExistingFinalFixture,
    *,
    github: str,
    pushover: str,
) -> None:
    fixture.publish_log.write_text("", encoding="utf-8")
    _append_record(
        fixture.publish_log,
        week_id=fixture.week_id,
        target="github",
        status=github,
    )
    _append_record(
        fixture.publish_log,
        week_id=fixture.week_id,
        target="pushover",
        status=pushover,
    )


def _existing_final_fixture(
    tmp_path: Path,
    weekly_report_module,
) -> ExistingFinalFixture:
    # Reuse the unit-test fixture so the shell path exercises all six metrics,
    # 10,000 raw path warnings, and multibyte commentary.
    home = tmp_path / "home"
    state_dir = tmp_path / "state"
    bin_dir = tmp_path / "bin"
    scratch = tmp_path / "scratch"
    for directory in (home, state_dir, bin_dir, scratch):
        directory.mkdir(mode=0o700)

    network_called = tmp_path / "network-called"
    _write_executable(
        bin_dir / "uname",
        "#!/usr/bin/env bash\nprintf '%s\\n' Linux\n",
    )
    _write_executable(
        bin_dir / "ssh",
        f"#!{sys.executable}\nimport pathlib\npathlib.Path({str(network_called)!r}).write_text('called')\nraise SystemExit(97)\n",
    )

    week_id = subprocess.check_output(
        [sys.executable, str(WEEKLY_REPORT_PY), "week-id"],
        text=True,
    ).strip()
    report = projection_stress_report(weekly_report_module)
    report["week"]["id"] = week_id

    report_json = state_dir / f"weekly-{week_id}.json"
    report_md = state_dir / f"weekly-{week_id}.md"
    publish_log = state_dir / f"weekly-{week_id}-publish.json"
    report_json.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    report_md.write_text(weekly_report_module.render_markdown(report) + "\n", encoding="utf-8")
    report_json.chmod(0o600)
    report_md.chmod(0o600)
    _append_record(publish_log, week_id=week_id, target="github", status="failed")
    _append_record(publish_log, week_id=week_id, target="pushover", status="success")

    gh_calls = tmp_path / "gh-calls"
    gh_body = tmp_path / "gh-body.md"
    _write_executable(
        bin_dir / "gh",
        f"""#!{sys.executable}
import os
import pathlib
import sys

if os.environ.get("GH_TOKEN") != "ghp_fixture_token":
    raise SystemExit(93)
if any(name in os.environ for name in ("PUSHOVER_TOKEN", "PUSHOVER_USER", "GH_PAT_PATH")):
    raise SystemExit(94)
calls = pathlib.Path({str(gh_calls)!r})
count = int(calls.read_text() or "0") if calls.exists() else 0
calls.write_text(str(count + 1))
args = sys.argv[1:]
body_arg = args[args.index("--body-file") + 1]
body = sys.stdin.buffer.read() if body_arg == "-" else pathlib.Path(body_arg).read_bytes()
pathlib.Path({str(gh_body)!r}).write_bytes(body)
print("https://github.com/greenheadHQ/nixos-config/issues/1095#issuecomment-guarded")
""",
    )

    analyzer_called = tmp_path / "analyzer-called"
    _write_executable(
        tmp_path / "fake-analyze",
        f"#!/usr/bin/env bash\ntouch {analyzer_called}\nexit 91\n",
    )
    llm_called = tmp_path / "llm-called"
    _write_executable(
        bin_dir / "codex-exec-supervised",
        f"#!/usr/bin/env bash\ntouch {llm_called}\nexit 92\n",
    )

    push_capture = tmp_path / "push-body"
    pushover_lib = tmp_path / "pushover-lib.sh"
    pushover_lib.write_text(
        """PUSHOVER_SEND_REASON="fixture pushover result"
send_pushover_fail_soft() {
  printf '%s' "$4" >> "$FAKE_PUSH_CAPTURE"
  return "${FAKE_PUSH_STATUS:-0}"
}
""",
        encoding="utf-8",
    )

    gh_token = tmp_path / "github-token"
    gh_token.write_text("ghp_fixture_token\n", encoding="utf-8")
    gh_token.chmod(0o600)
    pushover_cred = tmp_path / "pushover-cred"
    pushover_cred.write_text(
        "PUSHOVER_TOKEN='fixture-pushover-token'\nPUSHOVER_USER='fixture-user'\n",
        encoding="utf-8",
    )
    pushover_cred.chmod(0o600)

    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "STATE_DIR": str(state_dir),
            "TMPDIR": str(scratch),
            "REPO_ROOT": str(HERE.parents[4]),
            "WEEKLY_REPORT_PY": str(WEEKLY_REPORT_PY),
            "ANALYZE_PY": str(tmp_path / "fake-analyze"),
            "GH_PAT_PATH": str(gh_token),
            "PUSHOVER_SHARE_CRED": str(pushover_cred),
            "PUSHOVER_LIB": str(pushover_lib),
            "PUSHOVER_HELPER": str(tmp_path / "unused-pushover-helper"),
            "TRACKING_ISSUE_NUMBER": "1095",
            "FAKE_PUSH_CAPTURE": str(push_capture),
            "PATH": f"{bin_dir}{os.pathsep}{env['PATH']}",
        }
    )
    return ExistingFinalFixture(
        env=env,
        week_id=week_id,
        report=report,
        report_json=report_json,
        report_md=report_md,
        publish_log=publish_log,
        gh_calls=gh_calls,
        gh_body=gh_body,
        gh_path=bin_dir / "gh",
        analyzer_called=analyzer_called,
        llm_called=llm_called,
        pushover_cred=pushover_cred,
        push_capture=push_capture,
        state_dir=state_dir,
        network_called=network_called,
    )


def _run_report(fixture: ExistingFinalFixture) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(REPORT_SCRIPT)],
        env=fixture.env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_existing_final_retry_uses_compact_github_body_without_reanalysis(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    canonical_hash = hashlib.sha256(fixture.report_json.read_bytes()).hexdigest()
    pushover_count = _target_count(fixture.publish_log, "pushover")

    proc = _run_report(fixture)

    assert proc.returncode == 0, proc.stderr
    body = fixture.gh_body.read_text(encoding="utf-8")
    assert fixture.gh_calls.read_text() == "1"
    assert len(body.encode("utf-8")) <= 60_000
    assert "## 핵심 요약" in body
    assert "## Warning 요약" in body
    assert "raw-warning-marker" not in body
    assert "private-health-path" not in body
    assert hashlib.sha256(fixture.report_json.read_bytes()).hexdigest() == canonical_hash
    assert _target_count(fixture.publish_log, "pushover") == pushover_count
    assert not fixture.analyzer_called.exists()
    assert not fixture.llm_called.exists()
    latest = _latest_record(fixture.publish_log, "github")
    assert latest["status"] == "success"
    assert latest["message"] == "ok"
    assert latest["url"].endswith("#issuecomment-guarded")


def test_existing_final_retry_blocks_secret_in_exact_github_body(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    secret = "exact-secret-a&b"
    report = fixture.report
    report["commentary"] = {"text": f"검증된 해설 {secret}", "failure_reason": None}
    fixture.report_json.write_text(
        json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    fixture.report_md.write_text(
        weekly_report_module.render_markdown(report) + "\n",
        encoding="utf-8",
    )
    fixture.pushover_cred.write_text(
        f"PUSHOVER_TOKEN='{secret}'\nPUSHOVER_USER='fixture-user'\n",
        encoding="utf-8",
    )
    stale_body = fixture.state_dir / f"weekly-{fixture.week_id}-github-body.md"
    stale_body.write_text("stale outbound body", encoding="utf-8")

    proc = _run_report(fixture)

    combined_output = proc.stdout + proc.stderr
    assert proc.returncode == 0, proc.stderr
    assert not fixture.gh_calls.exists()
    assert not fixture.gh_body.exists()
    latest = _latest_record(fixture.publish_log, "github")
    assert latest["status"] == "blocked"
    assert latest["message"] == "outbound_secret"
    assert secret not in combined_output
    assert secret not in fixture.publish_log.read_text(encoding="utf-8")
    assert not list(fixture.state_dir.glob("*github-body*"))
    assert not fixture.analyzer_called.exists()
    assert not fixture.llm_called.exists()


def test_github_nonzero_does_not_expose_captured_stderr(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    marker = "publisher-stderr-secret /sensitive/publisher/path"
    _write_executable(
        fixture.gh_path,
        f"""#!{sys.executable}
import pathlib
import sys

pathlib.Path({str(fixture.gh_calls)!r}).write_text("1")
sys.stdin.buffer.read()
print({marker!r}, file=sys.stderr)
raise SystemExit(7)
""",
    )

    proc = _run_report(fixture)

    assert proc.returncode == 0, proc.stderr
    assert marker not in proc.stdout + proc.stderr
    assert marker not in fixture.publish_log.read_text(encoding="utf-8")
    latest = _latest_record(fixture.publish_log, "github")
    assert latest["status"] == "failed"
    assert latest["message"] == "gh_nonzero"
    assert not list(fixture.state_dir.glob("*github-body*"))
    assert not list(fixture.state_dir.glob("*gh.out"))
    assert not list(fixture.state_dir.glob("*gh.err"))


def test_github_success_then_pushover_retry_reuses_url_without_reposting(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    _reset_publish_records(fixture, github="failed", pushover="failed")
    fixture.env["FAKE_PUSH_STATUS"] = "1"

    first = _run_report(fixture)

    assert first.returncode == 0, first.stderr
    assert _latest_record(fixture.publish_log, "github")["status"] == "success"
    assert _latest_record(fixture.publish_log, "pushover")["status"] == "failed"
    assert fixture.gh_calls.read_text() == "1"

    fixture.env["FAKE_PUSH_STATUS"] = "0"
    second = _run_report(fixture)

    assert second.returncode == 0, second.stderr
    assert fixture.gh_calls.read_text() == "1"
    assert _latest_record(fixture.publish_log, "pushover")["status"] == "success"
    assert (
        "GitHub: https://github.com/greenheadHQ/nixos-config/issues/1095#issuecomment-guarded"
        in fixture.push_capture.read_text(encoding="utf-8")
    )


def test_existing_final_guard_block_still_attempts_pending_pushover(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    _reset_publish_records(fixture, github="failed", pushover="failed")
    secret = "guard-block-secret"
    fixture.report["commentary"] = {
        "text": f"해설 {secret}",
        "failure_reason": None,
    }
    fixture.report_json.write_text(
        json.dumps(fixture.report, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    fixture.pushover_cred.write_text(
        f"PUSHOVER_TOKEN='{secret}'\nPUSHOVER_USER='fixture-user'\n",
        encoding="utf-8",
    )

    proc = _run_report(fixture)

    assert proc.returncode == 0, proc.stderr
    assert _latest_record(fixture.publish_log, "github")["status"] == "blocked"
    assert _latest_record(fixture.publish_log, "github")["message"] == "outbound_secret"
    assert _latest_record(fixture.publish_log, "pushover")["status"] == "success"
    assert fixture.push_capture.exists()
    assert not fixture.gh_calls.exists()


def test_existing_final_missing_markdown_is_recovered_without_changing_json(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    canonical_hash = hashlib.sha256(fixture.report_json.read_bytes()).hexdigest()
    fixture.report_md.unlink()

    proc = _run_report(fixture)

    assert proc.returncode == 0, proc.stderr
    assert fixture.report_md.is_file()
    assert fixture.report_md.stat().st_mode & 0o777 == 0o600
    assert "raw-warning-marker-09999" in fixture.report_md.read_text(encoding="utf-8")
    assert "raw-warning-marker" not in fixture.gh_body.read_text(encoding="utf-8")
    assert hashlib.sha256(fixture.report_json.read_bytes()).hexdigest() == canonical_hash


def test_github_url_missing_is_terminal_and_not_retried(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    _write_executable(
        fixture.gh_path,
        f"""#!{sys.executable}
import pathlib
import sys

calls = pathlib.Path({str(fixture.gh_calls)!r})
count = int(calls.read_text() or "0") if calls.exists() else 0
calls.write_text(str(count + 1))
body_arg = sys.argv[sys.argv.index("--body-file") + 1]
body = sys.stdin.buffer.read() if body_arg == "-" else pathlib.Path(body_arg).read_bytes()
pathlib.Path({str(fixture.gh_body)!r}).write_bytes(body)
""",
    )

    first = _run_report(fixture)
    second = _run_report(fixture)

    assert first.returncode == second.returncode == 0
    assert fixture.gh_calls.read_text() == "1"
    latest = _latest_record(fixture.publish_log, "github")
    assert latest["status"] == "success"
    assert latest["message"] == "url_missing"
    assert latest["url"] == ""


def test_github_projection_failure_does_not_block_pending_pushover(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    _reset_publish_records(fixture, github="failed", pushover="failed")
    fixture.report["schema_version"] = 2
    fixture.report_json.write_text(
        json.dumps(fixture.report, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    proc = _run_report(fixture)

    assert proc.returncode == 0, proc.stderr
    latest_github = _latest_record(fixture.publish_log, "github")
    assert latest_github["status"] == "blocked"
    assert latest_github["message"] == "projection_or_staging"
    assert _latest_record(fixture.publish_log, "pushover")["status"] == "success"
    assert fixture.push_capture.exists()
    assert not fixture.gh_calls.exists()


def test_initial_run_passes_exact_bounded_projection_to_llm(
    weekly_report_module,
    tmp_path,
):
    fixture = _existing_final_fixture(tmp_path, weekly_report_module)
    fixture.report_json.unlink()
    fixture.report_md.unlink()
    fixture.publish_log.unlink()
    fixture.env["TRACKING_ISSUE_NUMBER"] = ""
    fixture.env["HOSTS"] = "minipc"
    fixture.env["HOST_HOME"] = "minipc=/home/fixture"

    analyzer = Path(fixture.env["ANALYZE_PY"])
    sidecar_json = json.dumps(sample_sidecar(), ensure_ascii=False)
    _write_executable(
        analyzer,
        f"""#!{sys.executable}
import pathlib
import sys

args = sys.argv[1:]
output_arg = args[args.index("--json") + 1]
pathlib.Path(output_arg.removeprefix("out=")).write_text({sidecar_json!r}, encoding="utf-8")
pathlib.Path({str(fixture.analyzer_called)!r}).write_text("called")
print("# fixture analysis")
""",
    )
    llm_input = tmp_path / "llm-input"
    llm_path = Path(fixture.env["PATH"].split(os.pathsep, 1)[0]) / "codex-exec-supervised"
    _write_executable(
        llm_path,
        f"""#!{sys.executable}
import pathlib
import sys

body = sys.stdin.buffer.read()
pathlib.Path({str(llm_input)!r}).write_bytes(body)
pathlib.Path({str(fixture.llm_called)!r}).write_text("called")
args = sys.argv[1:]
pathlib.Path(args[args.index("-o") + 1]).write_text("fixture LLM commentary", encoding="utf-8")
""",
    )

    proc = _run_report(fixture)

    assert proc.returncode == 0, proc.stderr
    final_report = json.loads(fixture.report_json.read_text(encoding="utf-8"))
    exact_input = llm_input.read_text(encoding="utf-8")
    assert exact_input == weekly_report_module.render_commentary_input(final_report)
    assert len(exact_input.encode("utf-8")) <= 262_144
    assert "ssh find timeout" not in exact_input
    assert "/home/greenhead" not in exact_input
    assert final_report["schema_version"] == 1
    assert final_report["commentary"]["text"] == "fixture LLM commentary"
    assert fixture.analyzer_called.exists()
    assert fixture.llm_called.exists()
    assert not fixture.network_called.exists()
    assert not (fixture.state_dir / f"weekly-{fixture.week_id}.draft.json").exists()
    assert not (fixture.state_dir / f"weekly-{fixture.week_id}-commentary.txt").exists()
    scratch_root = Path(fixture.env["TMPDIR"])
    assert not list(scratch_root.glob("da-weekly-report-llm.*"))
