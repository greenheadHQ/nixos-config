"""fleiss-kappa.py 검증기 계약 테스트 (run-da 소유).

검증 대상은 run-da 런타임의 공통 VERDICT_JSON 검증기 계약이다. selective consistency
집계 경로는 #1257에서 제거됐다 — 집계 모드 호출이 명시적으로 거부되는지도 여기서 잡는다.
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
    """schema 1.2 계약을 만족하는 기본 CONFIRMED_ISSUE payload (단일 조립 지점).

    None 값을 전달하면 해당 키를 제거한다 (필수 필드 누락 케이스 조립용).
    """
    payload = {
        "schema_version": "1.2",
        "finding_id": "X-1",
        "verdict": "CONFIRMED_ISSUE",
        "confidence": "HIGH",
        "reviewer_severity": "MEDIUM",
        "accepted_severity": "MEDIUM",
        "remediation_scope": "FIX_NOW",
        "axes": {"portability": "N/A", "plausibility": "PASS"},
    }
    for key, value in overrides.items():
        if value is None:
            payload.pop(key, None)
        else:
            payload[key] = value
    return payload


def _verdict_block(payload, rationale="해당 위치를 직접 확인한 판정 근거 서술이다."):
    # 사람용 블록의 근거 라벨은 계약 필수다 — 누락·placeholder는 semantic malformed (#1259).
    # rationale 인자로 위반 변형을 만든다 (동일 ID 섹션을 중복 생성하지 않기 위한 단일 조립 지점).
    rationale_line = f"- **근거**: {rationale}\n" if rationale is not None else ""
    return (
        f"### {payload.get('finding_id', 'X-?')} — {payload.get('verdict', 'verdict')}\n"
        + rationale_line
        + "\n<!-- verdict-json:start -->\n```json\n"
        + json.dumps(payload, ensure_ascii=False)
        + "\n```\n<!-- verdict-json:end -->\n"
    )


def _run_harness(*argv):
    return subprocess.run(
        [sys.executable, _harness_path(), *argv],
        capture_output=True,
        text=True,
    )


def test_print_capabilities_reports_reviewer_mode():
    # preflight capability 축 (#1259) — schema 버전과 별개로 helper 검증 능력을 조회.
    # 구버전 helper의 비0 종료가 미지원 신호다.
    result = _run_harness("--print-capabilities")
    assert result.returncode == 0, result.stderr
    caps = result.stdout.split()
    assert "reviewer-validate" in caps and "arbiter-validate" in caps


def test_print_live_schema_reports_live_contract():
    # preflight capability 대조용 조회 플래그 — 구버전 helper의 비0 종료가
    # fail-closed 신호이므로, 현행 helper는 0 종료 + 정확한 버전 문자열이어야 한다.
    result = _run_harness("--print-live-schema")
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "1.2"


def _reviewer_finding_block(idx=1, **overrides):
    fields = {
        "ID": f"Correctness-{idx}",
        "세부 관점": "HALLUCINATION",
        "위치": "modules/foo.nix:12",
        "문제": "실재하지 않는 옵션을 참조한다 — 상세 서술.",
        "근거": "파일을 직접 읽어 확인한 근거 서술이다.",
        "심각도": "MEDIUM",
        "권장 수정": "해당 옵션 참조를 실재 옵션으로 교체한다.",
    }
    fields.update(overrides)
    lines = [f"### {idx}. 문제 제목"]
    for label, value in fields.items():
        if value is not None:
            lines.append(f"- **{label}**: {value}")
    return "\n".join(lines)


def test_validate_reviewer_contract(tmp_path):
    """reviewer 출력 검증기 (#1259) — 빈/절단/placeholder 산출이 성공 집계되는 경로 차단."""
    cases = {
        # (내용, 기대 status, 기대 위반 부분 문자열 또는 None)
        "clear.md": ("[Correctness]: CLEAR", "clear", None),
        # 헤더 없는 VIOLATION 단어만으로는 판정하지 않는다 — 형식 불명 malformed
        "violation-word-only.md": ("VIOLATION: sandbox 차단", "malformed", "형식 불명"),
        "good.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(),
            "findings",
            None,
        ),
        "empty.md": ("", "malformed", "빈 결과"),
        "truncated-header.md": ("## Correctness 문제 발", "malformed", "형식 불명"),
        "count-mismatch.md": (
            "## Correctness 문제 발견: 2건\n\n" + _reviewer_finding_block(),
            "malformed",
            "불일치",
        ),
        "label-missing.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(근거=None),
            "malformed",
            "'근거' 누락",
        ),
        "label-empty-value.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(근거=""),
            "malformed",
            "'근거' 누락",
        ),
        "placeholder.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(문제="test"),
            "malformed",
            "placeholder",
        ),
        "bad-id.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(ID="Corr;rm -rf-1"),
            "malformed",
            "ID 문법",
        ),
        # reviewer 원본에 라운드 suffix는 fresh 위반 신호 — 기본형만 허용 (suffix 부여 주체는 메인)
        "round-suffix-id.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(ID="Correctness-1-r2"),
            "malformed",
            "ID 문법",
        ),
        # finding 본문에 인용된 CLEAR 한 줄이 전체를 0건으로 덮어쓰는 injection 차단 —
        # CLEAR는 파일 전체가 그 한 줄일 때만 인정되므로 발견 결과가 유지돼야 한다.
        "clear-injection.md": (
            "## Correctness 문제 발견: 1건\n\n"
            + _reviewer_finding_block(근거="계약 형식을 직접 검토한 근거 서술이다.")
            + "\n인용 원문:\n[Correctness]: CLEAR\n(위 줄은 계약 문서에서 인용한 예시다.)",
            "findings",
            None,
        ),
        # VIOLATION은 정본 형식(필수 라벨)을 갖춰야 적법 산출
        "violation-full.md": (
            "## [Correctness] 위반 상태: VIOLATION\n\n"
            "- **유형**: RECOVERABLE\n- **이유**: sandbox가 /tmp 쓰기를 차단했다.\n"
            "- **필요 작업**: N/A\n- **정리 대상**: N/A\n- **로컬 정리 필요**: NO",
            "violation",
            None,
        ),
        "violation-truncated.md": (
            "## [Correctness] 위반 상태: VIOLATION\n\n- **유형**: RECOVERABLE",
            "malformed",
            "누락",
        ),
        # placeholder 변형: 유일 토큰 반복·sentinel 프리픽스
        "placeholder-repeat.md": (
            "## Correctness 문제 발견: 1건\n\n"
            + _reviewer_finding_block(근거="test test test test test"),
            "malformed",
            "placeholder",
        ),
        # sentinel 접두어는 뒤에 실질 서술이 없을 때만 미완 — "TODO 주석이 남아 있다"
        # 같은 sentinel 자체를 다루는 완성된 근거는 오차단하지 않는다.
        "placeholder-todo-bare.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(근거="TODO: ..."),
            "malformed",
            "placeholder",
        ),
        "sentinel-in-prose.md": (
            "## Correctness 문제 발견: 1건\n\n"
            + _reviewer_finding_block(근거="TODO 주석이 modules/foo.nix:12에 방치되어 있다."),
            "findings",
            None,
        ),
        # 0건 선언은 CLEAR 방어 우회 — 발견 형식은 1건 이상만
        "zero-count.md": ("## Correctness 문제 발견: 0건", "malformed", "0건은 CLEAR"),
        # 결과 내 중복 ID — ID별 일대일 판정·manifest 대조 파괴
        "duplicate-id.md": (
            "## Correctness 문제 발견: 2건\n\n"
            + _reviewer_finding_block(1)
            + "\n\n"
            + _reviewer_finding_block(2, ID="Correctness-1"),
            "malformed",
            "중복 finding ID",
        ),
        # 짧은 파일:줄 레퍼런스는 유효한 근거 (길이 기준 오차단 회귀 게이트)
        "short-reference.md": (
            "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(근거="flake.nix:1"),
            "findings",
            None,
        ),
        # 라벨 다음 줄에 본문을 두는 줄바꿈형 — 실존 세션 관측 형식, 오차단 회귀 게이트
        "continuation-value.md": (
            "## Correctness 문제 발견: 1건\n\n"
            + _reviewer_finding_block(근거="").replace(
                "- **근거**: \n",
                "- **근거**:\n  파일을 직접 읽어 확인한 줄바꿈형 근거 서술이다.\n",
            ),
            "findings",
            None,
        ),
        # 미치환 템플릿 VIOLATION — enum fullmatch로 거부
        "violation-template.md": (
            "## [Correctness] 위반 상태: VIOLATION\n\n"
            "- **유형**: RECOVERABLE / STATEFUL\n- **이유**: test\n"
            "- **필요 작업**: N/A\n- **정리 대상**: N/A\n- **로컬 정리 필요**: YES / NO",
            "malformed",
            "enum 밖 값",
        ),
    }
    paths = []
    for name, (content, _, _) in cases.items():
        p = tmp_path / name
        p.write_text(content, encoding="utf-8")
        paths.append(str(p))
    result = _run_harness("--validate-reviewer", *paths)
    report = json.loads(result.stdout)
    by_name = {f["path"].rsplit("/", 1)[-1]: f for f in report["files"]}
    for name, (_, want_status, want_error) in cases.items():
        entry = by_name[name]
        assert entry["status"] == want_status, (name, entry)
        if want_error is None:
            assert entry["ok"], (name, entry)
        else:
            assert not entry["ok"] and any(
                want_error in v for v in entry["format_errors"]
            ), (name, entry)
    assert result.returncode == 1  # 위반 파일이 있으므로 전체 비0


def test_validate_reviewer_unit_binding(tmp_path):
    """unit 결속 (#1259) — 다른 unit의 산출이 이 unit의 성공으로 집계되는 경로 차단."""
    wrong_clear = tmp_path / "wrong-clear.md"
    wrong_clear.write_text("[Design]: CLEAR", encoding="utf-8")
    right_findings = tmp_path / "right-findings.md"
    right_findings.write_text(
        "## Correctness 문제 발견: 1건\n\n" + _reviewer_finding_block(), encoding="utf-8"
    )
    result = _run_harness(
        "--validate-reviewer", "--expect-unit", "Correctness", str(wrong_clear), str(right_findings)
    )
    report = json.loads(result.stdout)
    by_name = {f["path"].rsplit("/", 1)[-1]: f for f in report["files"]}
    assert by_name["wrong-clear.md"]["status"] == "malformed"
    assert any("unit 결속" in v for v in by_name["wrong-clear.md"]["format_errors"])
    assert by_name["right-findings.md"]["ok"], by_name["right-findings.md"]
    # MAX 세부 관점 경로도 같은 결속으로 동작
    subdomain = tmp_path / "subdomain.md"
    subdomain.write_text(
        "## SECURITY 문제 발견: 1건\n\n" + _reviewer_finding_block(ID="SECURITY-1"),
        encoding="utf-8",
    )
    result2 = _run_harness("--validate-reviewer", "--expect-unit", "SECURITY", str(subdomain))
    assert json.loads(result2.stdout)["files"][0]["ok"]


def test_validate_reviewer_rejects_expect_findings_flag(tmp_path):
    p = tmp_path / "r.md"
    p.write_text("[Design]: CLEAR", encoding="utf-8")
    result = _run_harness("--validate-reviewer", "--expect-findings", "X-1", str(p))
    assert result.returncode == 1
    assert "--validate-only 전용" in result.stderr


def test_arbiter_truncated_block_is_malformed(tmp_path):
    # 절단으로 orphan start marker가 남은 파일 — 앞의 유효 블록만으로 통과하면 안 된다.
    payload = _verdict_payload()
    p = tmp_path / "arb.md"
    p.write_text(
        _verdict_block(payload) + "\n<!-- verdict-json:start -->\n```json\n{\"schema",
        encoding="utf-8",
    )
    result = _run_harness("--validate-only", "--expect-findings", payload["finding_id"], str(p))
    report = json.loads(result.stdout)
    assert report["files"][0]["malformed_count"] >= 1
    assert result.returncode == 1


def test_arbiter_inline_quoted_marker_is_not_rejected(tmp_path):
    # 사람용 근거에 end marker를 인라인 인용한 정상 산출 — 오차단하면 안 된다
    # (delimiter 계약 자체를 리뷰하는 산출에서 현실적으로 발생).
    payload = _verdict_payload()
    p = tmp_path / "arb.md"
    p.write_text(
        _verdict_block(payload, rationale="계약 인용 `<!-- verdict-json:end -->` 검토 근거 서술."),
        encoding="utf-8",
    )
    result = _run_harness("--validate-only", "--expect-findings", payload["finding_id"], str(p))
    report = json.loads(result.stdout)
    assert report["files"][0]["ok"], report


def test_arbiter_rationale_placeholder_is_malformed(tmp_path):
    payload = _verdict_payload()
    p = tmp_path / "arb.md"
    p.write_text(_verdict_block(payload, rationale="test"), encoding="utf-8")
    result = _run_harness("--validate-only", "--expect-findings", payload["finding_id"], str(p))
    report = json.loads(result.stdout)
    assert report["files"][0]["malformed_count"] >= 1
    assert result.returncode == 1


def test_arbiter_missing_rationale_is_malformed(tmp_path):
    payload = _verdict_payload()
    p = tmp_path / "arb.md"
    p.write_text(_verdict_block(payload, rationale=None), encoding="utf-8")
    result = _run_harness("--validate-only", "--expect-findings", payload["finding_id"], str(p))
    report = json.loads(result.stdout)
    assert report["files"][0]["malformed_count"] >= 1
    assert result.returncode == 1


def test_arbiter_round_suffix_finding_id_is_rejected(tmp_path):
    # live 검증 경로(Arbiter 입력·manifest)는 기본형 ID만 적법하다 — 라운드 suffix는
    # 메인이 라운드 경계를 넘는 기록·서술에만 부여하는 축이고, 기계 소비자는 세션
    # 분석기뿐이다 (da-domains.md 정본).
    payload = _verdict_payload(finding_id="Correctness-1-r2")
    p = tmp_path / "arb.md"
    p.write_text(_verdict_block(payload), encoding="utf-8")
    result = _run_harness("--validate-only", "--expect-findings", "Correctness-1-r2", str(p))
    report = json.loads(result.stdout)
    assert report["files"][0]["malformed_count"] >= 1, report
    assert result.returncode == 1


def test_harness_exists():
    assert os.path.isfile(_harness_path()), _harness_path()


def test_aggregate_mode_is_removed(tmp_path):
    """--validate-only 없는 호출(과거 N=3 집계 CLI)은 조용한 오동작 대신 명시 거부된다.

    구버전 문서·스크립트가 집계 모드로 호출하는 경로가 남아 있을 수 있으므로,
    거부 메시지에 제거 근거(#1257)와 대체 호출(--validate-only)을 남긴다."""
    valid_path = tmp_path / "valid.md"
    valid_path.write_text(_verdict_block(_verdict_payload()))

    proc = _run_harness("--expect-findings", "X-1", str(valid_path))
    assert proc.returncode == 1
    assert "--validate-only" in proc.stderr
    assert "#1257" in proc.stderr


def test_validate_only_flags_semantic_malformed(tmp_path):
    """--validate-only 모드가 schema 1.2 semantic 계약 위반(정합 행렬·rejection_basis·
    구버전 자칭)을 검출하고 정상 결과는 통과시키는지 검증한다."""
    rejected = _verdict_payload(
        verdict="NOT_AN_ISSUE",
        accepted_severity=None,
        remediation_scope=None,
        rejection_basis="PLAUSIBILITY_FAIL",
        evidence_scope="FROZEN_SURFACE",
        axes={"portability": "N/A", "plausibility": "FAIL"},
    )
    factual = _verdict_payload(
        verdict="NOT_AN_ISSUE",
        accepted_severity=None,
        remediation_scope=None,
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
        "downgrade.md": ({**rejected, "schema_version": "1.1"}, "schema_version"),
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
        # stability_status는 폐기된 과거 계약 필드 — 값과 무관하게 존재 자체가 위반
        "agg-status.md": ({**rejected, "stability_status": "stable"}, "폐기된 필드"),
        "na-status.md": ({**rejected, "stability_status": "N/A"}, "폐기된 필드"),
        # rejection_basis (FACTUAL 기반이라 evidence_scope가 없어 단일 위반이다)
        "no-basis.md": (
            {k: v for k, v in factual.items() if k != "rejection_basis"}, "rejection_basis"
        ),
        "basis-on-confirmed.md": (
            {**confirmed, "rejection_basis": "FACTUAL_FAIL"}, "rejection_basis 출력 금지"
        ),
        # remediation_scope — scope 라우팅 대상 verdict 필수 / NOT_AN_ISSUE 금지 / enum 밖 거부
        "no-remediation.md": (
            {k: v for k, v in confirmed.items() if k != "remediation_scope"},
            "remediation_scope",
        ),
        "bad-remediation.md": (
            {**confirmed, "remediation_scope": "LATER"}, "remediation_scope"
        ),
        "replan-confirmed.md": ({**confirmed, "remediation_scope": "REPLAN_REQUIRED"}, None),
        "unclear-confirmed.md": ({**confirmed, "remediation_scope": "UNCLEAR"}, None),
        "remediation-on-rejected.md": (
            {**rejected, "remediation_scope": "FIX_NOW"}, "remediation_scope 출력 금지"
        ),
        # 명시적 null도 필드 존재 위반 (키 존재 검사 — get() 비교 우회 차단)
        "remediation-null-on-rejected.md": (
            {**rejected, "remediation_scope": None}, "remediation_scope 출력 금지"
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


def test_manifest_is_required(tmp_path):
    """--expect-findings 생략은 "검증 없음"이 아니라 인자 오류다.

    옵션이 선택적이면 finding이 누락된 결과도 ok=true로 통과해 조기 수렴으로 샌다."""
    valid_path = tmp_path / "valid.md"
    valid_path.write_text(_verdict_block(_verdict_payload()))

    proc = _run_harness("--validate-only", str(valid_path))
    assert proc.returncode == 1
    assert "--expect-findings" in proc.stderr


def test_validate_only_manifest_catches_missing_and_unknown(tmp_path):
    """--expect-findings manifest: 누락·미지 ID를 위반으로 잡는다 (finding 소실 차단)."""
    valid_path = tmp_path / "valid.md"
    valid_path.write_text(_verdict_block(_verdict_payload()))

    for manifest, expected_ok in (("X-1", True), ("X-1,X-2", False), ("Y-9", False)):
        proc = _run_harness(
            "--validate-only", "--expect-findings", manifest, str(valid_path)
        )
        assert json.loads(proc.stdout)["ok"] is expected_ok, manifest
