# Algorithm SSOT

PR #670 정정 코멘트에서 안정화된 알고리즘 v2를 정식 Skill 형태로 영속화한다. 분모 정정 + 4-tier fallback + source/confidence 라벨링이 v1 기본 계약이다.

## Metric Catalog (M-1 ~ M-5)

| ID | metric 이름 | 산식 | source (analyze.py) |
|----|------------|------|---------------------|
| M-1 | 검토 강도 verdict 분포 | Intensity marker 출현 세션 분모 위에서 인라인 체크리스트 출력의 SKIP/LITE/FULL 카운트 | `extract_intensity_verdicts` |
| M-2 | 판정자 verdict 분포 | Arbiter marker 출현 세션 분모 위에서 4-tier fallback으로 회수된 verdict의 CONFIRMED_ISSUE/NOT_AN_ISSUE/NEEDS_MORE_INFO 카운트 | `extract_strict_verdicts` + `extract_unmarked_json_verdicts` + `extract_kv_verdicts` + `extract_nl_summary` (아래 4-tier 섹션) |
| M-3 | reviewer 묶음별 confirmed-rate | M-2 결과를 finding_id의 reviewer 묶음 prefix(correctness/design/regression/maintainability)로 그룹핑 → 각 묶음의 CONFIRMED_ISSUE 비율 | `get_bundle` + `BUNDLE_MAP` (아래 bundle normalize 섹션) |
| M-4 | 동일 세션 max severity 전이 | 같은 세션 내 round N → N+1 confirmed finding 집합의 max severity 전이 매트릭스 | `find_severity_for_finding` + `severity_rank` + `compute_severity_transitions` (아래 severity 섹션) |
| M-5 | selective consistency stability_status 분포 | round summary `selective:` 라인 카운트 (stable/split/fragmented). 부재 시 unavailable. | `resolve_stability_status_from_round_summary` (아래 StabilitySource 섹션) |

참고: `analyze.py`의 함수/상수 이름이 본 문서의 source SoT다. 임시 스크립트(`/tmp/extraction-v2.py` 등)는 historical reference이며 정식 SoT가 아니다.

이슈 #671 본문 PHASE-EXTENDED 6번째 metric "FULL 후 finding 0건 분석"은 v1 measure list에 포함하지 않는다. 본 문서의 derived statistic 섹션에서 비율로 보고한다.

## 분모 정의 (의무)

| metric | 분모 |
|--------|------|
| M-1 | `intensity_marker_sessions` (Intensity dir marker 출현 세션) |
| M-2 | `arbiter_marker_sessions` (Arbiter dir marker 출현 세션) |
| M-3 | M-2 결과의 finding 단위 합계, reviewer 묶음별 분리 |
| M-4 | round 쌍 (N, N+1)의 confirmed finding 합집합 |
| M-5 | selective consistency 발동 라운드의 finding 단위 합계 |

keyword 분모 금지: 본문에 `arbiter` 단어가 있다고 분모에 포함하지 않는다 (skill 문서 LLM context 로드 시 false positive 다수). marker 정규식은 [`data-sources.md`](data-sources.md) SSOT.

## 4-tier fallback pipeline (M-2)

| Tier | source | confidence | 패턴 |
|------|--------|-----------|------|
| 1 | `verdict_json` | high | `<!-- verdict-json:start -->` ~ `<!-- verdict-json:end -->` 사이 fenced JSON |
| 2 | `md_header` | high | `### <finding_id> — <VERDICT>` (`<reviewer 묶음> Finding <순번>` normalize 포함) |
| 3 | `json_unmarked` | high | marker 없는 fenced JSON object/array에 `verdict` 필드 존재 |
| 4 | `kv` | medium | `**판정**: VERDICT` (Arbiter 결과 헤더 window 안만) |
| 5 (session-only) | `nl_summary` | low | `CONFIRMED N건` / `Arbiter 검증 결과 N건` — finding-level 분포에는 미포함 |

각 verdict record에 다음 필드를 부여한다:
- `source`: `verdict_json` / `md_header` / `json_unmarked` / `kv` / `nl_summary` 중 하나
- `source_confidence`: `high` / `medium` / `low`

aggregate 결과의 `metrics["M-2"]["source_distribution"]` 필드에 source별 추출률을 출력해 low-confidence fallback 비율을 가시화한다.

### JSONL decode 의무

raw blob에 직접 regex를 적용하지 않는다. JSONL parse → string payload extraction → regex 적용 순서를 강제한다.

```python
def extract_text_payloads(obj, accumulator):
    if isinstance(obj, str):
        accumulator.append(obj)
    elif isinstance(obj, dict):
        for v in obj.values():
            extract_text_payloads(v, accumulator)
    elif isinstance(obj, list):
        for v in obj:
            extract_text_payloads(v, accumulator)
```

## reviewer 묶음 normalize (M-3)

`analyze.py`의 `BUNDLE_MAP` 상수가 단일 SoT다. finding_id의 prefix를 lowercase로 추출하여 BUNDLE_MAP 키 조회 (legacy 세부 도메인 prefix `YAGNI`/`SECURITY` 등도 동일 매핑). 매핑 변경 시 `BUNDLE_MAP`만 수정한다 — 본 문서는 의도/이유만 기록한다.

## severity 추출 + 전이 매트릭스 (M-4)

`analyze.py`의 `find_severity_for_finding` + `compute_severity_transitions`가 SoT다. 알고리즘 요약:

- `SEV_LINE` 정규식이 `**심각도**: <라벨>` 패턴을 추출한다.
- `severity_rank`는 `SEVERITY_RANK` 상수 (`CRITICAL=4`, `HIGH=3`, `MEDIUM=2`, `LOW=1`) 매핑.
- 같은 세션 내 round N의 confirmed finding 집합 max severity와 round N+1 confirmed finding 집합 max severity의 (from, to) 쌍을 카운트한다.
- severity 라벨이 finding 본문에서 추출되지 않은 경우 rank 0으로 처리하여 `NONE → ...` 전이로 분류.

수치 변경 시 `SEVERITY_RANK` 상수만 수정한다 — 본 문서는 의도만 기록한다.

## StabilitySource resolver (M-5, v1)

selective consistency stability_status 측정은 verdict extraction pipeline과 분리한다.

| v1 source | 비고 |
|-----------|------|
| round summary `selective:` 라인 | `selective: trigger P건 → stable Q건, split R건, fragmented S건, partial_failure T건` 패턴 매치 시 stable/split/fragmented 카운트 누적. SoT는 `analyze.py`의 `SELECTIVE_LINE` 정규식 + `resolve_stability_status_from_round_summary`. |
| unavailable | round summary 라인 부재 시. 추정 금지. |

금지: 개별 Arbiter VERDICT_JSON의 `stability_status` 필드는 항상 `N/A`이므로 절대 source로 사용하지 않는다 (`run-da/references/arbiter-prompt.md` SSOT).

v1에서 미사용 source — `fleiss-kappa.py` aggregate envelope: 본 문서 초기 draft에는 1차 source로 `fleiss-kappa.py` aggregate envelope의 `per_finding[].stability_status`가 명시됐으나, 호출하려면 selective consistency arbiter result 디렉토리(예: `/tmp/da-*-arbiter-selective-*/arbiter-{1,2,3}-result.md`)를 session-level에서 직접 추적해야 하는데, 본 Skill의 corpus 전체 스캔 모델에서는 그 경계가 자연스럽게 결합되지 않는다. 따라서 v1은 round summary fallback만 사용하고, 1차 source 통합은 follow-up 범위로 둔다.

## Phase 1c MiniPC 진짜 추출 실패 2건 inspection 결과

PR #670 정정 코멘트에서 식별된 v2 알고리즘 회수 실패 MiniPC 세션 2건을 본 Skill 구현 단계에서 직접 inspect했다. 두 세션 모두 자기가 Arbiter를 실행한 세션이 아니라, ARBITER_DIR path가 cleanup 대화 / dispatcher 컨텍스트에 단순 인용된 케이스였다 (한 건은 어떤 워크플로 스킬 진입 후 `INTENSITY_DIR` / `DA_DIR` / `ARBITER_DIR` 경로 prepare 단계에서 marker가 본문에 박힌 케이스, 다른 한 건은 이전 라운드 작업물 정리 여부를 묻는 cleanup prompt에 marker 경로가 인용된 케이스). 실제 Arbiter 결과 출력은 외부 codex exec subprocess 또는 다른 세션에 있다.

결론: 이는 진짜 verdict 회수 대상이 아니라 marker name 인용에 의한 "false positive arbiter marker" 케이스다. 6번째 fallback 패턴 도입 불필요. 4-tier fallback이 충분.

향후 정확도 개선 follow-up이 필요하면 marker context 분석 (cleanup 키워드 인접 시 분모 제외) 추가를 고려할 수 있다.

식별된 두 세션의 jsonl path는 본 Skill 호출 시 `--debug-failed-extraction` 같은 옵션으로 동적으로 재식별 가능하다 (path 자체를 본 문서에 박지 않는다 — 세션 ID는 ephemeral 식별자이며 시간이 지나면 archive 위치 변경 가능).

## derived statistics

위 5 metric 외에 출력에 포함되는 보조 statistic:

- `intensity_full_finding_zero_rate`: M-1 결과가 FULL인 세션 중 finding 0건 (CLEAR) 세션 비율. 이슈 #671 본문 PHASE-EXTENDED 6번째 항목에 대응. M-1과 M-2 결과 cross-join으로 계산.
- `metrics["M-2"]["source_distribution"]`: 4-tier fallback 각 source의 추출률 (high vs medium vs low confidence 비율).

## 한계

- `INTENSITY_DIR_MARKER`는 Review Intensity 외부 호출 경로에서만 출현. PR #670 이후 인라인 체크리스트 도입으로 marker 출현 감소 → M-1 분모 줄어들 수 있음. 인라인 체크리스트 출력의 보조 grep을 algorithm 보강 대상으로 두되 v1은 marker 우선.
- selective consistency 발동 라운드는 N=3 재판정만 있는 finding만 over-represented. M-5 분포는 전체 finding이 아니라 selective consistency 발동 finding 한정.
- live 전체 home log 모드는 시간이 지남에 따라 분모가 커진다. PR #670 ±5% 회귀 게이트는 `--corpus` pinned manifest 모드에서만 사용한다.
