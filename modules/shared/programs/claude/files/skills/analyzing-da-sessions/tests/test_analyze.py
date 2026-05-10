"""algorithm fixture 5종 회귀 검증 — analyzing-da-sessions 정식화 (plan D-3)."""
import pytest

from conftest import load_fixture_pair


FIXTURE_NAMES = [
    "01-skill-doc",
    "02-xxxxxx-template",
    "03-json-unmarked",
    "04-kv-arbiter-window",
    "05-nl-summary-dedup",
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
    2. traversal (`/Users/green/.claude/projects/../../../etc/shadow`).
    3. sibling-prefix (`/Users/green/.claude/projects-evil/x.jsonl`).
    4. relative path (find stdout이 비정상으로 relative line을 내보낸 경우).
    """
    cases = [
        ("mac", "/etc/passwd"),
        ("mac", "/Users/green/.claude/projects/../../../etc/shadow"),
        ("mac", "/Users/green/.claude/projects-evil/x.jsonl"),
        ("mac", "Users/green/.claude/projects/a.jsonl"),
        # 추가 시나리오: shell metacharacter 거부 (기존 계약 회귀 가드)
        ("mac", "/Users/green/.claude/projects/a.jsonl;rm -rf /"),
        # 추가 시나리오: .jsonl 확장자 부재 거부
        ("mac", "/Users/green/.claude/projects/notes.txt"),
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
        "mac", "/Users/green/.claude/projects/abc/sess.jsonl"
    ) is True
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/green/.codex/sessions/2026/05/10/rollout-x.jsonl"
    ) is True
    assert analyze_module._allowed_remote_path(
        "minipc", "/home/greenhead/.claude/projects/x/y.jsonl"
    ) is True
    # sibling-prefix는 startswith로는 통과하지만 commonpath로는 거부
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/green/.claude/projects-evil/x.jsonl"
    ) is False
    # base 자체는 .jsonl이 아니므로 거부 + commonpath path_norm != base_norm 가드
    assert analyze_module._allowed_remote_path(
        "mac", "/Users/green/.claude/projects"
    ) is False
    # mac path를 minipc host로 검증 시 거부 (host별 base 분리)
    assert analyze_module._allowed_remote_path(
        "minipc", "/Users/green/.claude/projects/x.jsonl"
    ) is False


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
    fail_path = "/Users/green/.claude/projects/fail.jsonl"
    ok_path = "/Users/green/.claude/projects/ok.jsonl"

    def fake_fetch(host, path, w):
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
