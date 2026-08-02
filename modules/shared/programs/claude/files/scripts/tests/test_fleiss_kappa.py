"""fleiss-kappa.py harness 계약 테스트 (run-da 소유).

검증 대상은 run-da 런타임의 공통 검증기/집계기 계약이다 — analyzing-da-sessions
analyzer는 이 aggregate 경로를 소비하지 않으므로 (SKILL.md v1 미연결 선언),
harness 자체 계약 테스트는 analyzer 테스트 모듈이 아니라 이 파일이 소유한다.
analyzer 소유 검증(canonical hash 등)은 종전대로 analyzing-da-sessions/tests에 있다.

드라이버: tests/run-fleiss-kappa-tests.sh (lefthook pre-push · run-all-tests 공용).
"""

import json
import os
import subprocess
import sys


def _harness_path():
    tests_dir = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(os.path.dirname(tests_dir), "fleiss-kappa.py")


def _verdict_payload(**overrides):
    """schema 1.1 계약을 만족하는 기본 CONFIRMED_ISSUE payload (단일 조립 지점).

    None 값을 전달하면 해당 키를 제거한다 (필수 필드 누락 케이스 조립용).
    """
    payload = {
        "schema_version": "1.1",
        "finding_id": "X-1",
        "verdict": "CONFIRMED_ISSUE",
        "confidence": "HIGH",
        "reviewer_severity": "MEDIUM",
        "accepted_severity": "MEDIUM",
        "axes": {"portability": "N/A", "plausibility": "PASS"},
    }
    for key, value in overrides.items():
        if value is None:
            payload.pop(key, None)
        else:
            payload[key] = value
    return payload


def _verdict_block(payload):
    return (
        f"### {payload.get('finding_id', 'X-?')} — {payload.get('verdict', 'verdict')}\n\n"
        "<!-- verdict-json:start -->\n```json\n"
        + json.dumps(payload, ensure_ascii=False)
        + "\n```\n<!-- verdict-json:end -->\n"
    )


def _write_arbiter_results(tmp_path, payload, n=3):
    """동일 payload 블록을 담은 N개 Arbiter 결과 파일을 만들고 경로 목록을 반환한다."""
    paths = []
    for i in range(n):
        p = tmp_path / f"arbiter-{i + 1}-result.md"
        p.write_text(_verdict_block(payload))
        paths.append(str(p))
    return paths


def _run_harness(*argv):
    return subprocess.run(
        [sys.executable, _harness_path(), *argv],
        capture_output=True,
        text=True,
    )


def test_harness_exists():
    assert os.path.isfile(_harness_path()), _harness_path()


def test_aggregate_preserves_additive_verdict_fields(tmp_path):
    """N=3 aggregate가 entries에 accepted_severity와 axes.plausibility를 그대로
    보존하는지 검증한다 (protocol.md accepted severity 집계의 관측 지점)."""
    paths = _write_arbiter_results(tmp_path, _verdict_payload())

    proc = _run_harness("--expect-findings", "X-1", *paths)
    assert proc.returncode == 0, proc.stderr
    aggregate = json.loads(proc.stdout)
    assert not aggregate.get("partial_failure")
    per_finding = aggregate["per_finding"]
    assert len(per_finding) == 1
    entries = per_finding[0]["entries"]
    assert len(entries) == 3
    for entry in entries:
        assert entry["accepted_severity"] == "MEDIUM"
        assert entry["reviewer_severity"] == "MEDIUM"
        assert entry["axes"]["plausibility"] == "PASS"


def test_validate_only_flags_semantic_malformed(tmp_path):
    """--validate-only 모드가 schema 1.1 semantic 계약 위반(정합 행렬·rejection_basis·
    구버전 자칭)을 검출하고 정상 결과는 통과시키는지 검증한다."""
    valid = _verdict_payload(
        verdict="NOT_AN_ISSUE",
        accepted_severity=None,
        rejection_basis="PLAUSIBILITY_FAIL",
        evidence_scope="FROZEN_SURFACE",
        axes={"portability": "N/A", "plausibility": "FAIL"},
    )
    confirmed = _verdict_payload()
    cases = {
        "valid.md": (valid, True),
        # verdict 정합 행렬 위반: CONFIRMED + plausibility FAIL
        "matrix.md": ({**valid, "verdict": "CONFIRMED_ISSUE"}, False),
        # NOT_AN_ISSUE인데 rejection_basis 누락
        "basis.md": ({k: v for k, v in valid.items() if k != "rejection_basis"}, False),
        # 실시간 경로에서 1.0 자칭
        "downgrade.md": ({**valid, "schema_version": "1.0"}, False),
        # axes가 객체가 아니어도 예외 없이 malformed로 집계돼야 한다
        "axes-shape.md": ({**valid, "axes": "PASS"}, False),
        # 정확히 1.1만 허용 — 상한 밖·비정형 버전 거부
        "future.md": ({**valid, "schema_version": "2.0"}, False),
        "garbage.md": ({**valid, "schema_version": "garbage"}, False),
        # confidence 누락도 위반이다
        "no-confidence.md": ({k: v for k, v in valid.items() if k != "confidence"}, False),
        # 확정/기각 verdict에 confidence=N/A 금지 (NEEDS_MORE_INFO 전용)
        "na-confidence.md": ({**valid, "confidence": "N/A"}, False),
        # stability_status는 aggregate 전용 — 개별 entry에 있으면 값과 무관하게 위반
        "agg-status.md": ({**valid, "stability_status": "stable"}, False),
        "na-status.md": ({**valid, "stability_status": "N/A"}, False),
        # PLAUSIBILITY_FAIL에는 evidence_scope 필수 (ledger 영속 판정 근거)
        "no-scope.md": ({k: v for k, v in valid.items() if k != "evidence_scope"}, False),
        "bad-scope.md": ({**valid, "evidence_scope": "SOMETHING_ELSE"}, False),
        "env-scope.md": ({**valid, "evidence_scope": "ENVIRONMENT_WORKLOAD"}, True),
        # 다른 기각 근거·verdict에는 evidence_scope 금지
        "scope-on-factual.md": (
            {**valid, "rejection_basis": "FACTUAL_FAIL",
             "axes": {"portability": "N/A", "plausibility": "N/A"}}, False
        ),
        "scope-on-confirmed.md": (
            {**confirmed, "evidence_scope": "FROZEN_SURFACE"}, False
        ),
    }
    for name, (payload, expected_ok) in cases.items():
        path = tmp_path / name
        path.write_text(_verdict_block(payload))
        proc = _run_harness("--validate-only", "--expect-findings", "X-1", str(path))
        report = json.loads(proc.stdout)
        assert report["ok"] is expected_ok, (name, proc.stderr)
        assert (proc.returncode == 0) is expected_ok, name


def test_manifest_argument_rejects_duplicate_and_empty(tmp_path):
    """--expect-findings의 중복 ID·빈 항목·전체 빈 문자열은 인자 오류로 즉시 거부된다.

    특히 빈 문자열("")은 셸 변수 유실로 현실적으로 발생하는 입력이며, 이를
    "옵션 미지정"으로 처리하면 manifest 검증 전체가 조용히 비활성화된다."""
    valid_path = tmp_path / "valid.md"
    valid_path.write_text(_verdict_block(_verdict_payload()))

    for manifest, needle in (("X-1,X-1", "중복"), ("", "빈 항목"), ("X-1,,X-2", "빈 항목")):
        proc = _run_harness("--validate-only", "--expect-findings", manifest, str(valid_path))
        assert proc.returncode == 1, manifest
        assert needle in proc.stderr, (manifest, proc.stderr)

    # 집계 경로도 같은 인자 검증을 거친다 (빈 문자열이 무검증 집계로 새지 않는다)
    proc = _run_harness("--expect-findings", "", str(valid_path))
    assert proc.returncode == 1
    assert "빈 항목" in proc.stderr


def test_manifest_is_required_unless_explicitly_opted_out(tmp_path):
    """--expect-findings 생략은 "검증 없음"이 아니라 인자 오류다.

    옵션이 선택적이면 finding이 누락된 결과도 ok=true로 통과해 조기 수렴으로 샌다.
    관측 목적의 우회는 --no-manifest 명시적 opt-out으로만 가능하다."""
    valid_path = tmp_path / "valid.md"
    valid_path.write_text(_verdict_block(_verdict_payload()))

    # 두 모드 모두 manifest 없는 호출을 거부한다
    for argv in (
        ("--validate-only", str(valid_path)),
        (str(valid_path),),
    ):
        proc = _run_harness(*argv)
        assert proc.returncode == 1, argv
        assert "--expect-findings" in proc.stderr, (argv, proc.stderr)

    # 명시적 opt-out은 통과한다 (관측 전용 경로)
    proc = _run_harness("--validate-only", "--no-manifest", str(valid_path))
    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["ok"] is True

    # 상호 배타 — 둘을 함께 주면 의도가 모순이므로 거부한다
    proc = _run_harness(
        "--validate-only", "--no-manifest", "--expect-findings", "X-1", str(valid_path)
    )
    assert proc.returncode == 1
    assert "함께 쓸 수 없다" in proc.stderr


def test_validate_only_manifest_catches_missing_and_unknown(tmp_path):
    """--expect-findings manifest: 누락·미지 ID를 위반으로 잡는다 (finding 소실 차단)."""
    valid_path = tmp_path / "valid.md"
    valid_path.write_text(_verdict_block(_verdict_payload()))

    for manifest, expected_ok in (("X-1", True), ("X-1,X-2", False), ("Y-9", False)):
        proc = _run_harness(
            "--validate-only", "--expect-findings", manifest, str(valid_path)
        )
        assert json.loads(proc.stdout)["ok"] is expected_ok, manifest


def test_aggregate_manifest_catches_uniform_omission(tmp_path):
    """세 Arbiter가 모두 같은 finding을 누락해도 --expect-findings manifest가
    partial_failure로 잡는지, manifest 밖 ID도 위반인지 검증한다."""
    # X-2는 세 파일 모두에서 누락
    paths = _write_arbiter_results(tmp_path, _verdict_payload())

    proc = _run_harness("--expect-findings", "X-1,X-2", *paths)
    aggregate = json.loads(proc.stdout)
    assert aggregate.get("partial_failure") is True
    assert aggregate.get("manifest_violations")
    assert "X-2" in json.dumps(aggregate["manifest_violations"])

    # manifest 밖 finding(미지 ID)도 위반
    proc = _run_harness("--expect-findings", "Y-9", *paths)
    aggregate = json.loads(proc.stdout)
    assert aggregate.get("partial_failure") is True
