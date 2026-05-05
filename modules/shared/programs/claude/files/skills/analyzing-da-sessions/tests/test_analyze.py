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
