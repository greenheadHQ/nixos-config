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
    rejected = _verdict_payload(
        verdict="NOT_AN_ISSUE",
        accepted_severity=None,
        rejection_basis="PLAUSIBILITY_FAIL",
        evidence_scope="FROZEN_SURFACE",
        axes={"portability": "N/A", "plausibility": "FAIL"},
    )
    factual = _verdict_payload(
        verdict="NOT_AN_ISSUE",
        accepted_severity=None,
        rejection_basis="FACTUAL_FAIL",
        axes={"portability": "N/A", "plausibility": "N/A"},
    )
    confirmed = _verdict_payload()

    # 각 케이스는 정확히 하나의 invariant만 위반하고, 그 invariant를 가리키는
    # violation 메시지를 확인한다 — payload 하나가 여러 규칙을 동시에 어기면
    # 검사 대상 규칙이 삭제돼도 다른 위반 때문에 테스트가 계속 통과한다.
    cases = {
        # (payload, 기대 violation 조각 또는 None=통과)
        "valid-plausibility.md": (rejected, None),
        "valid-factual.md": (factual, None),
        "valid-confirmed.md": (confirmed, None),
        "valid-env-scope.md": ({**rejected, "evidence_scope": "ENVIRONMENT_WORKLOAD"}, None),
        # schema 버전: 정확히 live 버전만
        "downgrade.md": ({**rejected, "schema_version": "1.0"}, "schema_version"),
        "future.md": ({**rejected, "schema_version": "2.0"}, "schema_version"),
        "garbage.md": ({**rejected, "schema_version": "garbage"}, "schema_version"),
        # verdict 정합 행렬 — CONFIRMED에 plausibility FAIL (다른 필드는 CONFIRMED 계약 충족)
        "matrix.md": (
            {**confirmed, "axes": {"portability": "N/A", "plausibility": "FAIL"}},
            "정합 행렬",
        ),
        # confidence
        "no-confidence.md": (
            {k: v for k, v in rejected.items() if k != "confidence"}, "confidence"
        ),
        "na-confidence.md": ({**rejected, "confidence": "N/A"}, "confidence=N/A"),
        # axes 구조 — 이 케이스만 연쇄 위반이 불가피하다 (axes가 객체가 아니면
        # 그 안의 값을 읽을 수 없어 하위 축 검사도 함께 실패한다). 기대 메시지로
        # 최상위 원인을 지정해 다른 위반에 가려지지 않게 한다.
        "axes-shape.md": ({**rejected, "axes": "PASS"}, "axes가 객체가 아님"),
        "no-portability.md": ({**rejected, "axes": {"plausibility": "FAIL"}}, "portability"),
        # severity
        "no-reviewer-severity.md": (
            {k: v for k, v in confirmed.items() if k != "reviewer_severity"},
            "reviewer_severity",
        ),
        "no-accepted-severity.md": (
            {k: v for k, v in confirmed.items() if k != "accepted_severity"},
            "accepted_severity",
        ),
        # stability_status는 aggregate 전용 — 값과 무관하게 존재 자체가 위반
        "agg-status.md": ({**rejected, "stability_status": "stable"}, "aggregate 전용"),
        "na-status.md": ({**rejected, "stability_status": "N/A"}, "aggregate 전용"),
        # rejection_basis (FACTUAL 기반이라 evidence_scope가 없어 단일 위반이다)
        "no-basis.md": (
            {k: v for k, v in factual.items() if k != "rejection_basis"}, "rejection_basis"
        ),
        "basis-on-confirmed.md": (
            {**confirmed, "rejection_basis": "FACTUAL_FAIL"}, "rejection_basis 출력 금지"
        ),
        # evidence_scope
        "no-scope.md": (
            {k: v for k, v in rejected.items() if k != "evidence_scope"}, "evidence_scope"
        ),
        "bad-scope.md": ({**rejected, "evidence_scope": "SOMETHING_ELSE"}, "evidence_scope"),
        "scope-on-factual.md": (
            {**factual, "evidence_scope": "FROZEN_SURFACE"}, "PLAUSIBILITY_FAIL 전용"
        ),
        "scope-on-confirmed.md": (
            {**confirmed, "evidence_scope": "FROZEN_SURFACE"}, "PLAUSIBILITY_FAIL 전용"
        ),
    }
    for name, (payload, expected_violation) in cases.items():
        path = tmp_path / name
        path.write_text(_verdict_block(payload))
        proc = _run_harness("--validate-only", "--expect-findings", "X-1", str(path))
        report = json.loads(proc.stdout)
        expected_ok = expected_violation is None
        assert report["ok"] is expected_ok, (name, proc.stderr)
        assert (proc.returncode == 0) is expected_ok, name
        if expected_violation is not None:
            # 검증기는 위반 사유를 stderr에 남긴다 — 의도한 invariant가 잡혔는지 확인한다.
            assert expected_violation in proc.stderr, (name, proc.stderr)


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


def test_manifest_is_required(tmp_path):
    """--expect-findings 생략은 "검증 없음"이 아니라 인자 오류다.

    옵션이 선택적이면 finding이 누락된 결과도 ok=true로 통과해 조기 수렴으로 샌다."""
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
    """세 Arbiter가 모두 같은 finding을 누락해도 manifest가 잡는지 검증한다.

    집계 경로에서 누락은 finding 단위 `missing`으로만 전달되고 파일 단위
    `manifest_violations`에는 오르지 않는다 — 그래야 finding 하나가 빠졌을 때
    나머지 정상 finding까지 수집 단위 전체 폐기로 끌려가지 않는다."""
    # X-2는 세 파일 모두에서 누락
    paths = _write_arbiter_results(tmp_path, _verdict_payload())

    proc = _run_harness("--expect-findings", "X-1,X-2", *paths)
    aggregate = json.loads(proc.stdout)
    assert aggregate.get("partial_failure") is True
    assert "X-2" in aggregate.get("missing", {})
    assert not aggregate.get("manifest_violations")
    # 누락되지 않은 finding은 정상 분류되어 남는다 (finding 단위 차단)
    assert [f["finding_id"] for f in aggregate["per_finding"]] == ["X-1"]

    # manifest 밖 finding(미지 ID)은 파일 단위 위반이다
    proc = _run_harness("--expect-findings", "Y-9", *paths)
    aggregate = json.loads(proc.stdout)
    assert aggregate.get("partial_failure") is True
    assert aggregate.get("manifest_violations")
    assert "X-1" in json.dumps(aggregate["manifest_violations"])
