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


def test_kv_same_verdict_repeats_are_counted_in_session_and_aggregate(
    fixtures_dir,
    analyze_module,
    tmp_path,
):
    """KV fallback dedupe keeps occurrence identity for repeated verdict values."""
    text, _ = load_fixture_pair(fixtures_dir, "04-kv-arbiter-window")
    session_path = tmp_path / "kv-repeat.jsonl"
    session_path.write_text(json.dumps({"text": text}, ensure_ascii=False) + "\n")

    result = analyze_module.analyze_session(str(session_path))

    assert result is not None
    records = result["verdicts"]
    assert [record["verdict"] for record in records] == [
        "CONFIRMED_ISSUE",
        "NOT_AN_ISSUE",
        "CONFIRMED_ISSUE",
    ]
    assert len({record["match_offset"] for record in records}) == 3

    warnings = []
    aggregate = analyze_module.build_aggregate(
        [result],
        ["minipc"],
        "fixture:kv-repeat",
        warnings,
        "/tmp/analyze-da-sessions-kv-repeat.json",
    )
    m2 = aggregate["metrics"]["M-2"]
    assert m2["n"] == 3
    assert m2["distribution"] == {"CONFIRMED_ISSUE": 2, "NOT_AN_ISSUE": 1}
    assert m2["source_distribution"]["kv"] == {"count": 3, "confidence": "medium"}


def test_diagnostic_only_payload_does_not_advance_result_block_fsm(
    analyze_module,
    tmp_path,
):
    """Diagnostic-only payloads keep diagnostic context but do not join verdict blocks."""
    first_verdict = """### Correctness-1 — CONFIRMED_ISSUE
**심각도**: HIGH
**위치**: `foo.py:1`
**문제**: 첫 번째 실제 verdict.
<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-1","verdict":"CONFIRMED_ISSUE","confidence":"HIGH","stability_status":"N/A"}
```
<!-- verdict-json:end -->
"""
    diagnostic_only = """<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-2","verdict":"REGISTER","confidence":"HIGH","stability_status":"N/A"}
```
<!-- verdict-json:end -->
"""
    second_verdict = """### Correctness-3 — NOT_AN_ISSUE
**심각도**: MEDIUM
**위치**: `bar.py:2`
**문제**: diagnostic-only line 뒤의 두 번째 실제 verdict.
<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-3","verdict":"NOT_AN_ISSUE","confidence":"MEDIUM","stability_status":"N/A"}
```
<!-- verdict-json:end -->
"""
    session_path = tmp_path / "diagnostic-only-between-verdicts.jsonl"
    session_path.write_text(
        json.dumps({"text": first_verdict}, ensure_ascii=False) + "\n"
        + json.dumps({"text": diagnostic_only}, ensure_ascii=False) + "\n"
        + json.dumps({"text": second_verdict}, ensure_ascii=False) + "\n"
    )

    result = analyze_module.analyze_session(str(session_path))

    assert result is not None
    assert [record["finding_id"] for record in result["verdicts"]] == [
        "Correctness-1",
        "Correctness-3",
    ]
    assert [record["block_index"] for record in result["verdicts"]] == [0, 1]
    assert [diagnostic["block_index"] for diagnostic in result["diagnostics"]] == [0]
    assert result["diagnostics"][0]["match_kind"] == "invalid_verdict"


def test_non_kv_repeated_verdicts_keep_match_offsets(
    analyze_module,
    tmp_path,
):
    """Strict/header/unmarked paths preserve repeated identical findings in one payload."""
    strict_payload = """### Correctness-1 — CONFIRMED_ISSUE
**심각도**: HIGH
**위치**: `strict.py:1`
**문제**: strict repeated.
<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-1","verdict":"CONFIRMED_ISSUE","confidence":"HIGH","stability_status":"N/A"}
```
<!-- verdict-json:end -->
<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-1","verdict":"CONFIRMED_ISSUE","confidence":"HIGH","stability_status":"N/A"}
```
<!-- verdict-json:end -->
"""
    header_payload = """### Design-2 — NOT_AN_ISSUE
**심각도**: MEDIUM
**위치**: `header.py:1`
**문제**: header repeated first.

### Design-2 — NOT_AN_ISSUE
**심각도**: HIGH
**위치**: `header.py:2`
**문제**: header repeated second.
"""
    unmarked_payload = """# Legacy JSON-only result
marker 없는 JSON array 안에서 같은 verdict가 반복된다.
```json
[
  {"finding_id":"Regression-3","verdict":"NEEDS_MORE_INFO","confidence":"N/A","stability_status":"N/A"},
  {"finding_id":"Regression-3","verdict":"NEEDS_MORE_INFO","confidence":"N/A","stability_status":"N/A"}
]
```
"""
    session_path = tmp_path / "non-kv-repeated.jsonl"
    session_path.write_text(
        json.dumps({"text": strict_payload}, ensure_ascii=False) + "\n"
        + json.dumps({"text": header_payload}, ensure_ascii=False) + "\n"
        + json.dumps({"text": unmarked_payload}, ensure_ascii=False) + "\n"
    )

    result = analyze_module.analyze_session(str(session_path))

    assert result is not None
    by_source = {}
    for record in result["verdicts"]:
        by_source.setdefault(record["source"], []).append(record)
    assert {source: len(records) for source, records in by_source.items()} == {
        "verdict_json": 2,
        "md_header": 2,
        "json_unmarked": 2,
    }
    for records in by_source.values():
        assert len({record["match_offset"] for record in records}) == 2

    # 반복 occurrence가 첫 위치의 persistence 필드를 공유하면 M-6이 서로 다른
    # finding을 "동일 finding 지속"으로 오분류한다 — 위치별 구분을 고정한다.
    header_locations = {record["location_identity"] for record in by_source["md_header"]}
    assert header_locations == {"header.py:1", "header.py:2"}
    header_fingerprints = {record["finding_fingerprint"] for record in by_source["md_header"]}
    assert len(header_fingerprints) == 2
    # severity도 occurrence별로 구분되어야 한다 — 첫 occurrence의 severity를
    # 물려받으면 M-4 전이가 틀어진다.
    header_severities = {record["severity"] for record in by_source["md_header"]}
    assert header_severities == {"MEDIUM", "HIGH"}


def test_unmarked_json_without_verdict_key_is_ignored(
    analyze_module,
):
    diagnostics = []
    text = """일반 JSON 예시는 verdict extraction 대상이 아니다.
```json
{"title":"not a verdict", "items":[1, 2, 3]}
```
"""

    records = analyze_module.extract_unmarked_json_verdicts(text, diagnostics=diagnostics)

    assert records == []
    assert diagnostics == []


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


def test_same_payload_hash_at_same_path_on_different_lines_is_not_preparse_deduped(
    analyze_module,
    tmp_path,
):
    """Pre-parse skip key must preserve JSONL line identity."""
    payload = """### Correctness-1 — CONFIRMED_ISSUE
**심각도**: HIGH
**위치**: `foo.py:1`
**문제**: 동일 payload가 다음 JSONL line에도 반복된다.
<!-- verdict-json:start -->
```json
{"finding_id":"Correctness-1","verdict":"CONFIRMED_ISSUE","confidence":"HIGH","stability_status":"N/A"}
```
<!-- verdict-json:end -->
"""
    session_path = tmp_path / "same-payload-same-path-different-lines.jsonl"
    session_path.write_text(
        json.dumps({"text": payload}) + "\n" + json.dumps({"text": payload}) + "\n"
    )

    result = analyze_module.analyze_session(str(session_path))

    assert result is not None
    records = result["verdicts"]
    assert len(records) == 2
    assert [record["jsonl_line_no"] for record in records] == [1, 2]
    assert {record["payload_traversal_path"] for record in records} == {"$.text"}
    assert len({record["payload_hash"] for record in records}) == 1


def test_extract_text_payloads_legacy_wrapper_is_removed(analyze_module):
    assert not hasattr(analyze_module, "extract_text_payloads")


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


def test_remote_tar_argv_disables_copyfile_only_on_mac(analyze_module):
    """macOS tar는 AppleDouble metadata를 억제하고 stdin path list를 받는다."""
    assert analyze_module._build_remote_tar_argv("mac") == [
        "ssh",
        "mac",
        "env",
        "COPYFILE_DISABLE=1",
        "tar",
        "-C",
        "/",
        "-cf",
        "-",
        "-T",
        "-",
    ]

    assert analyze_module._build_remote_tar_argv("minipc") == [
        "ssh",
        "minipc",
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


def test_remote_tar_rejects_appledouble_and_unknown_members(analyze_module, tmp_path):
    """AppleDouble/unknown member는 payload로 채택하지 않고 warning으로 남긴다."""
    expected = "Users/greenhead/.claude/projects/a.jsonl"
    entries = [(f"/{expected}", expected)]
    payload = b'{"type":"user"}\n'
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w") as tf:
        expected_info = tarfile.TarInfo(expected)
        expected_info.size = len(payload)
        tf.addfile(expected_info, io.BytesIO(payload))

        appledouble = tarfile.TarInfo(
            "Users/greenhead/.claude/projects/._a.jsonl"
        )
        appledouble.size = len(payload)
        tf.addfile(appledouble, io.BytesIO(payload))

        unknown = tarfile.TarInfo(
            "Users/greenhead/.claude/projects/unknown.jsonl"
        )
        unknown.size = len(payload)
        tf.addfile(unknown, io.BytesIO(payload))

    warnings: list[str] = []
    assert analyze_module._extract_tar_bytes_to_dir(
        "mac", tar_buffer.getvalue(), entries, str(tmp_path), warnings
    ) is True

    assert (tmp_path / expected).read_bytes() == payload
    assert not (tmp_path / "Users/greenhead/.claude/projects/._a.jsonl").exists()
    assert not (tmp_path / "Users/greenhead/.claude/projects/unknown.jsonl").exists()
    assert sum("tar member skipped by validation" in item for item in warnings) == 2
    assert any("._a.jsonl" in item for item in warnings)
    assert any("unknown.jsonl" in item for item in warnings)


def test_remote_tar_rejects_traversal_and_non_regular_members(
    analyze_module,
    tmp_path,
):
    """정규화로 allowlist에 축약되는 raw traversal과 non-regular member를 거부한다."""
    expected = "Users/greenhead/.claude/projects/a.jsonl"
    entries = [(f"/{expected}", expected)]
    payload = b'{"type":"hostile"}\n'
    tar_buffer = io.BytesIO()
    with tarfile.open(fileobj=tar_buffer, mode="w") as tf:
        traversal = tarfile.TarInfo(f"ignored/../{expected}")
        traversal.size = len(payload)
        tf.addfile(traversal, io.BytesIO(payload))

        root_escape = tarfile.TarInfo("../escape.jsonl")
        root_escape.size = len(payload)
        tf.addfile(root_escape, io.BytesIO(payload))

        non_regular = tarfile.TarInfo(expected)
        non_regular.type = tarfile.DIRTYPE
        tf.addfile(non_regular)

    warnings: list[str] = []
    assert analyze_module._extract_tar_bytes_to_dir(
        "mac", tar_buffer.getvalue(), entries, str(tmp_path), warnings
    ) is False

    assert not (tmp_path / expected).exists()
    assert sum("tar member skipped by validation" in item for item in warnings) == 2
    assert any("tar member is not a regular file" in item for item in warnings)


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

    assert analyze_module.SSH_HOST_FETCH_BUDGET_SECONDS == 600
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
                "-size",
                analyze_module.REMOTE_FIND_SIZE_INCLUDE,
            ],
            5.0,
        )
    ]
    assert any("ssh fetch budget 초과" in w for w in warnings)


def test_collect_remote_files_records_exclusions_outside_warnings(
    analyze_module,
    monkeypatch,
):
    """size cap 제외는 실패가 아니므로 warnings가 아닌 corpus_exclusions로 기록한다.

    warnings에 넣으면 `host <name>:` prefix가 weekly coverage의 host partial 판정
    입력이 되어, 수집이 정상인 주에도 mac이 영구 partial로 표시된다.
    """
    monkeypatch.setattr(analyze_module.time, "monotonic", lambda: 0.0)
    warnings: list[str] = []
    exclusions: list[dict] = []
    calls = []

    def fake_run(argv, **kwargs):
        calls.append(argv)
        base = argv[argv.index("find") + 1]
        size_arg = argv[argv.index("-size") + 1]
        if base != "~/.claude/projects":
            return subprocess.CompletedProcess(argv, 0, stdout="", stderr="")
        if size_arg.startswith("+"):
            stdout = (
                "/Users/greenhead/.claude/projects/p/big-a.jsonl\n"
                "/Users/greenhead/.claude/projects/p/big-b.jsonl\n"
                # subagents 하위는 수집 대상 정의 밖이므로 제외 건수에도 들어가면 안 된다.
                "/Users/greenhead/.claude/projects/p/subagents/big-c.jsonl\n"
            )
        else:
            stdout = "/Users/greenhead/.claude/projects/p/s.jsonl\n"
        return subprocess.CompletedProcess(argv, 0, stdout=stdout, stderr="")

    monkeypatch.setattr(analyze_module.subprocess, "run", fake_run)

    files = analyze_module.collect_remote_files(
        "mac", warnings, budget=None, corpus_exclusions=exclusions
    )
    assert files == ["/Users/greenhead/.claude/projects/p/s.jsonl"]
    # base 2곳 × (목록 find + oversized find) = 4회
    assert len(calls) == 4
    assert warnings == []
    assert exclusions == [
        analyze_module._corpus_exclusion_entry("mac", "~/.claude/projects", 2)
    ]


def test_collect_local_files_applies_same_size_cap(analyze_module, tmp_path, monkeypatch):
    """corpus 정의는 실행 위치에 따라 달라지지 않는다 — 로컬 경로도 같은 cap을 쓴다."""
    claude_dir = tmp_path / "claude"
    codex_dir = tmp_path / "codex"
    claude_dir.mkdir()
    codex_dir.mkdir()
    small = claude_dir / "small.jsonl"
    small.write_text("{}\n")
    big = claude_dir / "big.jsonl"
    big.write_bytes(b"x" * (analyze_module.REMOTE_FILE_SIZE_CAP_BYTES + 1))
    # cap 경계값 자체는 수집 대상이다 (원격 find `c` suffix 분할과 같은 경계).
    edge = claude_dir / "edge.jsonl"
    edge.write_bytes(b"x" * analyze_module.REMOTE_FILE_SIZE_CAP_BYTES)

    monkeypatch.setitem(
        analyze_module.HOST_PATH_MAP,
        "mac",
        {"claude": str(claude_dir), "codex": str(codex_dir)},
    )
    exclusions: list[dict] = []
    files = analyze_module.collect_local_files("mac", exclusions)

    assert sorted(files) == sorted([str(small), str(edge)])
    assert exclusions == [
        analyze_module._corpus_exclusion_entry("mac", str(claude_dir), 1)
    ]


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
    assert any("ssh fetch budget 초과" in w for w in warnings)


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
    assert any("ssh fetch budget 초과" in w for w in warnings)


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


def test_host_home_override_reuses_remote_path_forbidden_chars(analyze_module):
    with pytest.raises(Exception, match="disallowed shell metacharacter"):
        analyze_module.parse_host_home_arg("mac=/tmp/example home")


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


def test_find_severity_prefers_ahead_across_all_occurrences(analyze_module):
    """근접 occurrence(판정 블록)의 behind에 앞 finding severity가 있어도,
    다른 occurrence(서술 블록)의 ahead 정답을 먼저 채택해야 한다 (2-pass)."""
    text = (
        "### Other-9\n"
        "**심각도**: LOW\n"
        "**위치**: `other.py:9`\n\n"
        "### Target-1 — CONFIRMED_ISSUE\n"
        "- **판정**: CONFIRMED_ISSUE\n\n"
        + "필러 문단.\n" * 160  # 판정 블록의 lookahead(1000자) 밖으로 서술 블록을 밀어낸다
        + "### Target-1\n"
        "**심각도**: HIGH\n"
        "**위치**: `target.py:1`\n"
    )
    # match_offset = 판정 블록 occurrence 위치 (근접 1순위가 판정 블록이 되게)
    verdict_offset = text.index("Target-1 — CONFIRMED_ISSUE")
    severity = analyze_module.find_severity_for_finding(text, "Target-1", verdict_offset)
    assert severity == "HIGH"


def _mutate_verdict_json_blocks(analyze_module, session_text, mutate):
    """fixture jsonl의 모든 VERDICT_JSON 객체를 구조 파싱해 mutate 콜백(제자리 변경)을 적용한 재직렬화 결과를 반환한다.

    delimiter 문법은 production 파서(`analyze_module.VERDICT_JSON_BLOCK`)를 그대로
    재사용한다 — 정규식을 복사하면 사본이 원본보다 좁아지거나(공백·개행 유연성 상실)
    형식 변경 시 함께 갱신할 지점이 하나 늘어난다.
    """
    pattern = analyze_module.VERDICT_JSON_BLOCK

    def _rewrite_payload(payload_text):
        def _sub(m):
            obj = json.loads(m.group(1))
            mutate(obj)
            # 캡처 그룹 밖의 delimiter·fence는 원문 그대로 두고 body만 교체한다.
            start, end = m.span(1)
            return m.group(0)[: start - m.start()] + json.dumps(obj, ensure_ascii=False) + m.group(0)[end - m.start() :]

        return pattern.sub(_sub, payload_text)

    out_lines = []
    for line in session_text.splitlines():
        if not line.strip():
            out_lines.append(line)
            continue
        record = json.loads(line)

        def _walk(node):
            if isinstance(node, dict):
                return {k: _walk(v) for k, v in node.items()}
            if isinstance(node, list):
                return [_walk(v) for v in node]
            if isinstance(node, str) and "verdict-json:start" in node:
                return _rewrite_payload(node)
            return node

        out_lines.append(json.dumps(_walk(record), ensure_ascii=False))
    return "\n".join(out_lines) + "\n"


def test_additive_axes_plausibility_reflected_in_canonical_hash(
    fixtures_dir, analyze_module, tmp_path
):
    """VERDICT_JSON additive 필드 중 axes.plausibility가 canonical_verdict_hash에
    반영되는지 검증한다 (analyzer 경로의 관측 지점 — protocol.md 수렴 판정 계약)."""
    text, _ = load_fixture_pair(fixtures_dir, "06-claude-contract")

    with_field = tmp_path / "with-plausibility.jsonl"
    with_field.write_text(text)
    without_field = tmp_path / "without-plausibility.jsonl"
    without_field.write_text(
        _mutate_verdict_json_blocks(
            analyze_module, text, lambda obj: obj.get("axes", {}).pop("plausibility", None)
        )
    )

    result_with = analyze_module.analyze_session(str(with_field))
    result_without = analyze_module.analyze_session(str(without_field))
    assert result_with is not None and result_without is not None

    hashes_with = [r["canonical_verdict_hash"] for r in result_with["verdicts"]]
    hashes_without = [r["canonical_verdict_hash"] for r in result_without["verdicts"]]
    assert len(hashes_with) == len(hashes_without) == 2
    for h_with, h_without in zip(hashes_with, hashes_without):
        assert h_with != h_without, (
            "plausibility must participate in canonical hash"
        )
