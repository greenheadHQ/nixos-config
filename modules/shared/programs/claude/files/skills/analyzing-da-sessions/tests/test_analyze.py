"""algorithm + run-da contract fixture 회귀 검증 — analyzing-da-sessions."""
import io
import json
import os
import subprocess
import tarfile

import pytest

from conftest import load_fixture_pair


FIXTURE_NAMES = [
    "01-skill-doc",
    "02-xxxxxx-template",
    "03-json-unmarked",
    "04-kv-arbiter-window",
    "05-nl-summary-dedup",
    "08-template-exclusions",
    "09-invalid-verdicts",
]

CONTRACT_FIXTURE_NAMES = [
    "06-claude-contract",
    "07-codex-rollout-contract",
]


@pytest.mark.parametrize("fixture_name", FIXTURE_NAMES)
def test_extraction_count(fixtures_dir, analyze_module, fixture_name):
    """각 fixture의 4-tier verdict extraction 결과가 expected와 일치하는지 검증."""
    text, expected = load_fixture_pair(fixtures_dir, fixture_name)

    strict = analyze_module.extract_strict_verdicts(text)
    unmarked = analyze_module.extract_unmarked_json_verdicts(text)
    kv = analyze_module.extract_kv_verdicts(text, arbiter_window_only=True)
    nl_signal, _ = analyze_module.extract_nl_summary(text)

    finding_level = strict + unmarked + kv

    assert len(strict) == expected.get("strict_count", 0), (
        f"strict count mismatch in {fixture_name}: got {len(strict)}, "
        f"expected {expected.get('strict_count', 0)}"
    )
    assert len(unmarked) == expected.get("unmarked_count", 0), (
        f"unmarked count mismatch in {fixture_name}: got {len(unmarked)}, "
        f"expected {expected.get('unmarked_count', 0)}"
    )
    assert len(kv) == expected.get("kv_count", 0), (
        f"kv count mismatch in {fixture_name}: got {len(kv)}, "
        f"expected {expected.get('kv_count', 0)}"
    )
    assert nl_signal == expected.get("nl_signal", False), (
        f"nl_signal mismatch in {fixture_name}: got {nl_signal}, "
        f"expected {expected.get('nl_signal', False)}"
    )
    assert len(finding_level) == expected.get("finding_level_count", 0), (
        f"finding-level total mismatch in {fixture_name}"
    )


def assert_partial_dict(actual, expected):
    for key, expected_value in expected.items():
        if expected_value == "__NON_NULL__":
            assert actual.get(key) not in (None, ""), f"{key} should be non-null"
        else:
            assert actual.get(key) == expected_value, (
                f"{key} mismatch: got {actual.get(key)!r}, expected {expected_value!r}"
            )


@pytest.mark.parametrize("fixture_name", ["08-template-exclusions", "09-invalid-verdicts"])
def test_extraction_diagnostics(fixtures_dir, analyze_module, fixture_name):
    """템플릿 제외/invalid verdict는 VerdictRecord가 아니라 diagnostic으로 남긴다."""
    text, expected = load_fixture_pair(fixtures_dir, fixture_name)
    diagnostics = []
    parse_failures = []

    records = analyze_module.extract_strict_verdicts(
        text,
        parse_failures=parse_failures,
        diagnostics=diagnostics,
        context=analyze_module.PayloadContext(
            session_path=f"fixture:{fixture_name}",
            jsonl_line_no=1,
            payload_traversal_path="$.text",
            payload_hash=analyze_module.sha256_text(text),
            block_index=0,
            block_kind="first_pass",
        ),
    )

    assert records == expected["expected_verdict_records"]
    assert parse_failures == []
    actual = [d.to_dict() if hasattr(d, "to_dict") else d for d in diagnostics]
    assert len(actual) == len(expected["expected_diagnostics"])
    for actual_diag, expected_diag in zip(actual, expected["expected_diagnostics"]):
        assert_partial_dict(actual_diag, expected_diag)


def test_same_payload_hash_at_different_paths_is_not_preparse_deduped(
    analyze_module,
    tmp_path,
):
    """Pre-parse skip key must preserve traversal-path identity."""
    payload = """### Correctness-1 — CONFIRMED_ISSUE
**심각도**: HIGH
**위치**: `foo.py:1`
**문제**: 동일 payload가 다른 JSON path에 존재한다.
<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-1","verdict":"CONFIRMED_ISSUE","confidence":"HIGH","stability_status":"N/A"}
```
<!-- verdict-json:end -->
"""
    session_path = tmp_path / "same-payload-different-paths.jsonl"
    session_path.write_text(json.dumps({"first": payload, "second": payload}) + "\n")

    result = analyze_module.analyze_session(str(session_path))

    assert result is not None
    records = result["verdicts"]
    assert len(records) == 2
    assert {record["payload_traversal_path"] for record in records} == {"$.first", "$.second"}
    assert len({record["payload_hash"] for record in records}) == 1


def test_exclusion_manifest_count_labels(fixtures_dir):
    """Phase 0 raw parse failure 61건과 exclusion fixture 62건 라벨을 분리 고정."""
    with open(os.path.join(fixtures_dir, "u1-exclusion-manifest.json"), "r") as fp:
        manifest = json.load(fp)

    assert manifest["phase0_parse_failure_raw_count"] == 61
    assert manifest["exclusion_fixture_count_at_capture"] == 62
    assert manifest["phase0_parse_failure_raw_count"] != manifest["exclusion_fixture_count_at_capture"]


@pytest.mark.parametrize("fixture_name", CONTRACT_FIXTURE_NAMES)
def test_verdict_record_contract(fixtures_dir, analyze_module, tmp_path, fixture_name):
    """run-da 산출 형식과 analyze.py VerdictRecord 중간 모델의 정합 검증."""
    text, expected = load_fixture_pair(fixtures_dir, fixture_name)
    session_path = tmp_path / f"{fixture_name}.jsonl"
    session_path.write_text(text)

    result = analyze_module.analyze_session(str(session_path))
    assert result is not None
    assert result["has_arbiter_marker"] is True

    records = result["verdicts"]
    assert len(records) == len(expected["expected_verdict_records"])
    for actual, expected_record in zip(records, expected["expected_verdict_records"]):
        assert actual["session_path"] == str(session_path)
        assert_partial_dict(actual, expected_record)

    warnings = []
    aggregate = analyze_module.build_aggregate(
        [result],
        ["minipc"],
        f"fixture:{fixture_name}",
        warnings,
        "/tmp/analyze-da-sessions-fixture.json",
    )
    expected_aggregate = expected["expected_aggregate"]
    for metric_id, metric_expected in expected_aggregate.items():
        actual_metric = aggregate["metrics"][metric_id]
        for key, expected_value in metric_expected.items():
            if isinstance(expected_value, dict):
                assert expected_value.items() <= actual_metric[key].items()
            else:
                assert actual_metric[key] == expected_value


def test_arbiter_marker_filter(analyze_module):
    """XXXXXX 템플릿 marker는 매치하지 않아야 함."""
    template_text = "예: /tmp/da-c4a35fc4-arbiter-XXXXXX 디렉토리에 결과를 저장한다."
    real_text = "결과는 /tmp/da-c4a35fc4-arbiter-AbCdEf 에 저장됨."
    assert analyze_module.ARBITER_DIR_MARKER.search(template_text) is None
    assert analyze_module.ARBITER_DIR_MARKER.search(real_text) is not None


def test_bundle_normalization(analyze_module):
    """finding_id의 reviewer 묶음 매핑 검증."""
    cases = [
        ("Correctness-1", "Correctness"),
        ("Design-2", "Design"),
        ("Regression-3", "Regression"),
        ("Maintainability-4", "Maintainability"),
        ("YAGNI-1", "Design"),
        ("SECURITY-1", "Correctness"),
        ("HALLUCINATION-2", "Correctness"),
        ("SIDE_EFFECT-1", "Regression"),
        ("CONSISTENCY-1", "Regression"),
        ("READABILITY-1", "Maintainability"),
        ("CLEAN_CODE-1", "Maintainability"),
        ("Correctness Finding 1", "Correctness"),
    ]
    for finding_id, expected_bundle in cases:
        assert analyze_module.get_bundle(finding_id) == expected_bundle, (
            f"{finding_id} should map to {expected_bundle}"
        )


def test_severity_rank(analyze_module):
    """severity 라벨 순위 정렬 검증 (M-4 전이 매트릭스 기반)."""
    assert analyze_module.severity_rank("CRITICAL") > analyze_module.severity_rank("HIGH")
    assert analyze_module.severity_rank("HIGH") > analyze_module.severity_rank("MEDIUM")
    assert analyze_module.severity_rank("MEDIUM") > analyze_module.severity_rank("LOW")
    assert analyze_module.severity_rank("LOW") > analyze_module.severity_rank(None)
    assert analyze_module.severity_rank(None) == 0


def test_host_validation(analyze_module):
    """--hosts whitelist reject-fast 검증 (plan D-5)."""
    import pytest as _pt
    with _pt.raises(ValueError):
        analyze_module._validate_host("evil-host")
    with _pt.raises(ValueError):
        analyze_module._validate_host("mac; rm -rf")
    # valid는 통과
    analyze_module._validate_host("mac")
    analyze_module._validate_host("minipc")


def test_hostile_path_rejection(analyze_module):
    """`_allowed_remote_path` boundary check가 다음 4 시나리오를 모두 거부함을 검증.

    1. 외부 절대 경로 (`/etc/passwd`).
    2. traversal (`/Users/greenhead/.claude/projects/../../../etc/shadow`).
    3. sibling-prefix (`/Users/greenhead/.claude/projects-evil/x.jsonl`).
    4. relative path (find stdout이 비정상으로 relative line을 내보낸 경우).
    """
    cases = [
        ("mac", "/etc/passwd"),
        ("mac", "/Users/greenhead/.claude/projects/../../../etc/shadow"),
        ("mac", "/Users/greenhead/.claude/projects-evil/x.jsonl"),
        ("mac", "Users/greenhead/.claude/projects/a.jsonl"),
        # 추가 시나리오: shell metacharacter 거부 (기존 계약 회귀 가드)
        ("mac", "/Users/greenhead/.claude/projects/a.jsonl;rm -rf /"),
        # 추가 시나리오: .jsonl 확장자 부재 거부
        ("mac", "/Users/greenhead/.claude/projects/notes.txt"),
    ]
    for host, path in cases:
        assert analyze_module._allowed_remote_path(host, path) is False, (
            f"hostile path should be rejected: host={host} path={path!r}"
        )


def test_allowed_remote_path_boundary_check(analyze_module):
    """정상 child path는 통과하고, sibling-prefix와 traversal은 거부됨을 검증.

    posixpath.commonpath boundary 비교가 startswith의 sibling-prefix false positive를
    차단하는지 unit-level로 확인한다.
    """
    # 정상 child path는 통과
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/greenhead/.claude/projects/abc/sess.jsonl"
    ) is True
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/greenhead/.codex/sessions/2026/05/10/rollout-x.jsonl"
    ) is True
    assert analyze_module._allowed_remote_path(
        "minipc", "/home/greenhead/.claude/projects/x/y.jsonl"
    ) is True
    # sibling-prefix는 startswith로는 통과하지만 commonpath로는 거부
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/greenhead/.claude/projects-evil/x.jsonl"
    ) is False
    # base 자체는 .jsonl이 아니므로 거부 + commonpath path_norm != base_norm 가드
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/greenhead/.claude/projects"
    ) is False
    # mac path를 minipc host로 검증 시 거부 (host별 base 분리)
    assert analyze_module._allowed_remote_path(
        "minipc", "/Users/greenhead/.claude/projects/x.jsonl"
    ) is False


def test_remote_tar_argv_uses_portable_stdin_list(analyze_module):
    """원격 tar는 GNU tar/bsdtar 공통 옵션으로 stdin path list를 받는다."""
    assert analyze_module._build_remote_tar_argv("mac") == [
        "ssh",
        "mac",
        "tar",
        "-C",
        "/",
        "-cf",
        "-",
        "-T",
        "-",
    ]


def test_remote_tar_entries_revalidate_and_relative_paths(analyze_module):
    """tar list 직전에도 HOST_PATH_MAP boundary 검증 후 -C / 기준 상대화한다."""
    warnings: list[str] = []

    entries = analyze_module._prepare_remote_tar_entries(
        "mac",
        [
            "/Users/greenhead/.claude/projects/a/sess.jsonl",
            "/Users/greenhead/.codex/sessions/2026/07/09/rollout-x.jsonl",
            "/Users/greenhead/.claude/projects-evil/nope.jsonl",
            "/Users/greenhead/.claude/projects/has space.jsonl",
        ],
        warnings,
    )

    assert entries == [
        (
            "/Users/greenhead/.claude/projects/a/sess.jsonl",
            "Users/greenhead/.claude/projects/a/sess.jsonl",
        ),
        (
            "/Users/greenhead/.codex/sessions/2026/07/09/rollout-x.jsonl",
            "Users/greenhead/.codex/sessions/2026/07/09/rollout-x.jsonl",
        ),
    ]
    assert sum("remote tar path excluded by validation" in w for w in warnings) == 2


def test_remote_tar_entries_exclude_newline_paths_with_warning(analyze_module):
    """tar -T는 newline 구분이므로 개행 포함 path는 제외하고 warning을 남긴다."""
    warnings: list[str] = []

    entries = analyze_module._prepare_remote_tar_entries(
        "mac",
        [
            "/Users/greenhead/.claude/projects/ok.jsonl",
            "/Users/greenhead/.claude/projects/bad\nname.jsonl",
        ],
        warnings,
    )

    assert entries == [
        (
            "/Users/greenhead/.claude/projects/ok.jsonl",
            "Users/greenhead/.claude/projects/ok.jsonl",
        )
    ]
    assert any("contains newline" in w for w in warnings)


def test_remote_tar_stdin_is_newline_delimited(analyze_module):
    """tar -T - 입력은 상대 path newline list이며 마지막 newline을 포함한다."""
    entries = [
        (
            "/Users/greenhead/.claude/projects/a.jsonl",
            "Users/greenhead/.claude/projects/a.jsonl",
        ),
        (
            "/Users/greenhead/.codex/sessions/rollout-x.jsonl",
            "Users/greenhead/.codex/sessions/rollout-x.jsonl",
        ),
    ]

    assert analyze_module._build_remote_tar_stdin(entries) == (
        b"Users/greenhead/.claude/projects/a.jsonl\n"
        b"Users/greenhead/.codex/sessions/rollout-x.jsonl\n"
    )


def test_remote_tar_extracts_expected_members(analyze_module, tmp_path):
    """remote tar stdout은 검증된 member만 tempdir에 추출한다."""
    entries = [
        (
            "/Users/greenhead/.claude/projects/a.jsonl",
            "Users/greenhead/.claude/projects/a.jsonl",
        )
    ]
    payload = b'{"type":"user","uuid":"x","timestamp":"2026-07-09"}\n'
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w") as tf:
        info = tarfile.TarInfo(entries[0][1])
        info.size = len(payload)
        tf.addfile(info, io.BytesIO(payload))

    warnings: list[str] = []

    assert analyze_module._extract_tar_bytes_to_dir(
        "mac",
        tar_buffer.getvalue(),
        entries,
        str(tmp_path),
        warnings,
    ) is True
    extracted_path = tmp_path / "Users/greenhead/.claude/projects/a.jsonl"
    assert extracted_path.read_bytes() == payload
    assert warnings == []


def test_remote_tar_fetch_fallbacks_on_nonzero_exit(analyze_module, monkeypatch, tmp_path):
    """tar command nonzero exit은 per-file cat fallback 신호를 반환한다."""
    entries = [
        (
            "/Users/greenhead/.claude/projects/a.jsonl",
            "Users/greenhead/.claude/projects/a.jsonl",
        )
    ]
    warnings: list[str] = []

    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args=args[0], returncode=2, stderr=b"tar failed")

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)

    assert analyze_module._fetch_remote_files_tar_to_dir(
        "mac",
        entries,
        str(tmp_path),
        warnings,
    ) is False
    assert any("ssh tar failed" in w and "falling back to per-file cat" in w for w in warnings)


def test_remote_tar_fetch_fallbacks_on_empty_stream(analyze_module, monkeypatch, tmp_path):
    """tar command 0 exit이라도 stdout archive가 비어 있으면 fallback한다."""
    entries = [
        (
            "/Users/greenhead/.claude/projects/a.jsonl",
            "Users/greenhead/.claude/projects/a.jsonl",
        )
    ]
    warnings: list[str] = []

    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args=args[0], returncode=0, stderr=b"")

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)

    assert analyze_module._fetch_remote_files_tar_to_dir(
        "mac",
        entries,
        str(tmp_path),
        warnings,
    ) is False
    assert any("empty stream" in w and "falling back to per-file cat" in w for w in warnings)


def test_remote_host_preflight_uses_connect_timeout_and_fast_fails(analyze_module, monkeypatch):
    """preflight 실패는 find/tar/cat 전에 host partial로 fast-fail한다."""
    calls = []

    def fake_run(argv, **kwargs):
        calls.append((argv, kwargs))
        return subprocess.CompletedProcess(argv, returncode=255, stdout="", stderr="offline")

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)
    warnings: list[str] = []

    assert analyze_module.check_remote_host_preflight("mac", warnings) is False
    assert calls == [
        (
            [
                "ssh",
                "-o",
                f"ConnectTimeout={analyze_module.SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS}",
                "mac",
                "true",
            ],
            {
                "capture_output": True,
                "text": True,
                "timeout": analyze_module.SSH_CONTROLMASTER_CHECK_TIMEOUT_SECONDS,
            },
        )
    ]
    assert any("ssh preflight failed" in w and "partial result" in w for w in warnings)


def test_host_fetch_budget_clamps_find_and_stops_after_budget_timeout(
    analyze_module,
    monkeypatch,
):
    """host budget 만료는 남은 find를 중단하고 partial warning으로 표시한다."""
    now = {"value": 0.0}
    monkeypatch.setattr(analyze_module.time, "monotonic", lambda: now["value"])
    budget = analyze_module.HostFetchBudget(host="mac", deadline=5.0)
    warnings: list[str] = []
    calls = []

    def fake_run(argv, **kwargs):
        calls.append((argv, kwargs["timeout"]))
        raise subprocess.TimeoutExpired(argv, kwargs["timeout"])

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)

    assert analyze_module.SSH_HOST_FETCH_BUDGET_SECONDS == 300
    assert analyze_module.collect_remote_files("mac", warnings, budget) == []
    assert calls == [
        (
            [
                "ssh",
                "mac",
                "find",
                "~/.claude/projects",
                "-type",
                "f",
                "-name",
                "'*.jsonl'",
            ],
            5.0,
        )
    ]
    assert any("budget 초과 (절전/무응답 가능성)" in w for w in warnings)


def test_controlmaster_check_uses_remaining_host_budget(analyze_module, monkeypatch):
    """find 이후 ControlMaster 확인도 host budget 잔여 시간으로 제한한다."""
    monkeypatch.setattr(analyze_module.time, "monotonic", lambda: 0.0)
    budget = analyze_module.HostFetchBudget(host="mac", deadline=3.0)
    warnings: list[str] = []
    calls = []

    def fake_run(argv, **kwargs):
        calls.append((argv, kwargs["timeout"]))
        raise subprocess.TimeoutExpired(argv, kwargs["timeout"])

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)

    assert analyze_module.check_controlmaster_active(
        "mac",
        warnings,
        preflight_already_ok=True,
        budget=budget,
    ) is False
    assert calls == [(["ssh", "-O", "check", "mac"], 3.0)]
    assert any("budget 초과 (절전/무응답 가능성)" in w for w in warnings)


def test_fetch_remote_file_skips_when_host_budget_already_expired(
    analyze_module,
    monkeypatch,
):
    """budget 소진 후 fallback cat은 새 SSH subprocess를 시작하지 않는다."""
    monkeypatch.setattr(analyze_module.time, "monotonic", lambda: 10.0)
    budget = analyze_module.HostFetchBudget(host="mac", deadline=5.0)
    warnings: list[str] = []

    def fake_run(*args, **kwargs):
        raise AssertionError("ssh cat should not run after host budget expires")

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)

    result = analyze_module.fetch_remote_file(
        "mac",
        "/Users/greenhead/.claude/projects/a.jsonl",
        warnings,
        budget,
    )

    assert result is None
    assert any("budget 초과 (절전/무응답 가능성)" in w for w in warnings)


def test_host_home_override(analyze_module):
    """--host-home override는 validation/corpus base prefix를 갱신한다."""
    original = {host: paths.copy() for host, paths in analyze_module.HOST_PATH_MAP.items()}
    try:
        overrides = analyze_module.parse_host_home_arg("mac=/tmp/example-home")
        analyze_module.apply_host_home_overrides(overrides)
        assert analyze_module._allowed_remote_path(
            "mac", "/tmp/example-home/.claude/projects/a.jsonl"
        ) is True
        assert analyze_module._allowed_remote_path(
            "mac", "/Users/greenhead/.claude/projects/a.jsonl"
        ) is False
    finally:
        analyze_module.HOST_PATH_MAP.clear()
        analyze_module.HOST_PATH_MAP.update(original)


def test_claude_session_traceability(analyze_module, tmp_path):
    """Claude Code top-level cwd/gitBranch/sessionId와 PR/issue grep을 sidecar meta에 남긴다."""
    session_path = tmp_path / "claude-session.jsonl"
    session_path.write_text(
        json.dumps({
            "type": "assistant",
            "cwd": "/repo",
            "gitBranch": "issue_1064",
            "sessionId": "claude-session-1",
            "message": {
                "content": [
                    {"type": "text", "text": "PR #77에서 issue #1064를 확인했다."}
                ]
            },
        })
        + "\n"
    )

    result = analyze_module.analyze_session(str(session_path))

    meta = result["session_meta"]
    assert meta["format"] == "claude"
    assert meta["cwd"] == "/repo"
    assert meta["git_branch"] == "issue_1064"
    assert meta["session_id"] == "claude-session-1"
    assert meta["complete"] is True
    assert meta["references"]["prs"] == ["77"]
    assert meta["references"]["issues"] == ["1064"]


def test_codex_session_traceability_payload_precedes_rollout_fallback(analyze_module, tmp_path):
    """Codex payload.cwd/payload.git.branch/payload.id를 우선하고 파일명/date fallback을 기록한다."""
    session_dir = tmp_path / "2026" / "07" / "09"
    session_dir.mkdir(parents=True)
    session_path = session_dir / "rollout-2026-07-09T00-00-00-fallbackid.jsonl"
    session_path.write_text(
        json.dumps({
            "payload": {
                "id": "payloadid",
                "cwd": "/repo",
                "git": {"branch": "issue_1064"},
                "content": [{"type": "output_text", "text": "issue #1064"}],
            }
        })
        + "\n"
    )

    result = analyze_module.analyze_session(str(session_path))

    meta = result["session_meta"]
    assert meta["format"] == "codex"
    assert meta["cwd"] == "/repo"
    assert meta["git_branch"] == "issue_1064"
    assert meta["session_id"] == "payloadid"
    assert meta["rollout_date"] == "2026-07-09"
    assert "rollout_filename.session_id" not in meta["fallback_fields"]
    assert "rollout_directory.date" in meta["fallback_fields"]
    assert meta["complete"] is True

    fallback_path = session_dir / "rollout-2026-07-09T00-00-00-id-with-hyphen.jsonl"
    fallback_path.write_text(
        json.dumps({
            "payload": {
                "cwd": "/repo",
                "git": {"branch": "issue_1064"},
                "content": [{"type": "output_text", "text": "fallback id only"}],
            }
        })
        + "\n"
    )

    fallback_result = analyze_module.analyze_session(str(fallback_path))
    fallback_meta = fallback_result["session_meta"]
    assert fallback_meta["session_id"] == "id-with-hyphen"
    assert "rollout_filename.session_id" in fallback_meta["fallback_fields"]


def test_traceability_coverage_in_aggregate(analyze_module, tmp_path):
    """aggregate sidecar는 traceability coverage를 1급 섹션으로 제공한다."""
    claude_path = tmp_path / "claude.jsonl"
    claude_path.write_text(
        json.dumps({
            "cwd": "/repo",
            "gitBranch": "main",
            "sessionId": "s1",
            "message": {"content": "no metrics"},
        })
        + "\n"
    )
    unknown_path = tmp_path / "unknown.jsonl"
    unknown_path.write_text(json.dumps({"message": {"content": "no meta"}}) + "\n")

    sessions = [
        analyze_module.analyze_session(str(claude_path)),
        analyze_module.analyze_session(str(unknown_path)),
    ]
    warnings = []
    aggregate = analyze_module.build_aggregate(
        sessions,
        ["minipc"],
        "fixture:traceability",
        warnings,
        "/tmp/analyze-da-sessions-traceability.json",
    )

    coverage = aggregate["traceability"]["coverage"]
    assert coverage["sessions_total"] == 2
    assert coverage["complete_sessions"] == 1
    assert coverage["unknown_format_sessions"] == 1
    assert coverage["field_presence"] == {
        "cwd": 1,
        "git_branch": 1,
        "session_id": 1,
    }


def test_analyze_remote_session_partial_fetch_result(analyze_module, monkeypatch):
    """`analyze_remote_session()`이 SSH cat 실패 시 None + warning, 성공 시 분석 dict를
    반환하는 partial result 단위 계약을 검증한다.

    `fetch_remote_file`을 monkeypatch하여 일부 path는 None (실패), 일부는 더미 jsonl
    내용을 반환하도록 한 뒤 `analyze_remote_session()`을 직접 호출한다.

    참고: 본 테스트는 `analyze_remote_session()`의 단위 계약만 검증하며, `main()`의
    `concurrent.futures.ThreadPoolExecutor` worker pool dispatch 경로는 통과하지
    않는다. dispatch 경로 자체는 V-1 live 측정과 코드 review로 검증한다.
    """
    warnings: list[str] = []
    fail_path = "/Users/greenhead/.claude/projects/fail.jsonl"
    ok_path = "/Users/greenhead/.claude/projects/ok.jsonl"

    def fake_fetch(host, path, w, budget=None):
        if path == fail_path:
            w.append(f"host {host}: ssh cat failed for {path}")
            return None
        # 정상 dummy jsonl 내용 (verdict 분포에 영향 없는 빈 line)
        return '{"type": "user", "uuid": "x", "timestamp": "2026-05-10"}\n'

    monkeypatch.setattr(analyze_module, "fetch_remote_file", fake_fetch)

    # 두 path 각각 호출
    fail_result = analyze_module.analyze_remote_session("mac", fail_path, warnings)
    ok_result = analyze_module.analyze_remote_session("mac", ok_path, warnings)

    assert fail_result is None, "failed fetch should return None"
    assert ok_result is not None, "successful fetch should return analysis dict"
    assert any("ssh cat failed" in w for w in warnings), (
        "failed fetch should accumulate a warning"
    )
