# Algorithm SSOT

PR #670 정정 코멘트에서 안정화된 알고리즘 v2를 정식 Skill 형태로 영속화한다. 분모 정정 + 4-tier fallback + source/confidence 라벨링이 v1 기본 계약이다.

## Metric Catalog (M-1 ~ M-6)

| ID | metric 이름 | 산식 | source (analyze.py) |
|----|------------|------|---------------------|
| M-1 | 검토 강도 verdict 분포 | Intensity marker 출현 세션 분모 위에서 인라인 체크리스트 출력의 SKIP/LITE/FULL 카운트 | `extract_intensity_verdicts` |
| M-2 | 판정자 verdict 분포 | Arbiter marker 출현 세션 분모 위에서 4-tier fallback으로 회수된 verdict의 CONFIRMED_ISSUE/NOT_AN_ISSUE/NEEDS_MORE_INFO 카운트 | `extract_strict_verdicts` + `extract_unmarked_json_verdicts` + `extract_kv_verdicts` + `extract_nl_summary` (아래 4-tier 섹션) |
| M-3 | reviewer 묶음별 confirmed-rate | M-2 결과를 finding_id의 reviewer 묶음 prefix(correctness/design/regression/maintainability)로 그룹핑 → 각 묶음의 CONFIRMED_ISSUE 비율 | `get_bundle` + `BUNDLE_MAP` (아래 bundle normalize 섹션) |
| M-4 | 동일 세션 max severity 전이 | 같은 세션 내 result block N → N+1 confirmed finding 집합의 max severity 전이 매트릭스 | `VerdictRecord.block_index` + `find_severity_for_finding` + `severity_rank` + `compute_severity_transitions` (아래 severity 섹션) |
| M-5 | selective consistency stability_status 분포 | round summary `selective:` 라인 카운트 (stable/split/fragmented). 부재 시 unavailable. | `resolve_stability_status_from_round_summary` (아래 StabilitySource 섹션) |
| M-6 | persistence_key 비수렴 지표 | 동일 `(perspective, location_identity, finding_fingerprint)`가 서로 다른 result block에 반복되는 횟수 분포 + 세션별 top offenders | `compute_persistence_metrics` |

참고: `analyze.py`의 함수/상수 이름이 본 문서의 source SoT다. 임시 스크립트(`/tmp/extraction-v2.py` 등)는 historical reference이며 정식 SoT가 아니다.

이슈 #671 본문 PHASE-EXTENDED 6번째 metric "FULL 후 finding 0건 분석"은 v1 measure list에 포함하지 않는다. 본 문서의 derived statistic 섹션에서 비율로 보고한다.

## run-da 건강 지표 (health_formula_version: 1)

주간 리포트 파이프라인(`modules/nixos/programs/da-weekly-report/files/weekly_report.py`)은
`analyze.py` sidecar와 별도로 git 기반 건강 지표를 수집한다. 산식 변경 시
`health_formula_version`을 증가시키고, 주간 리포트에 baseline 단절을 명시한다.

| 지표 | 산식 (v1) |
|------|-----------|
| 문서 크기 | `git -C "$REPO_ROOT" ls-tree -r HEAD --name-only -- modules/shared/programs/claude/files/skills/run-da/` 결과 중 `*.md` 파일을 세고, `/evals/` path segment가 있는 파일은 제외한다. 라인 수는 `git show HEAD:<path>` 내용 기준 총 line count 합계다. |
| drift 수리 커밋 빈도 | `git -C "$REPO_ROOT" log --since=<KST 주 시작> --until=<KST 주 끝> --first-parent main --format='%H%x00%s%x00%B%x1e' -- modules/shared/programs/claude/files/skills/run-da/`를 record 단위로 파싱한다. subject가 `/fix\|refactor\|chore/i`에 매치하고, subject+body가 `/drift\|참조\|사본\|dangling\|동기화\|SSOT/i`에 매치하는 commit 수다. `--oneline` 금지 — body 매칭을 위해 `%B`를 포함한다. |
| 규칙 수 | run-da `SKILL.md`의 `## 핵심 invariants` 번호 항목 수 + `## 주의사항` bullet 수 + `## Non-goals` 번호 항목 수. 개별 카운트와 total을 병기한다. |

week boundary는 KST 월요일 00:00부터 다음 월요일 00:00까지다. merge commit은
`--first-parent main` 흐름에서 대표한다.

## Weekly coverage 지표

`weekly_report.py`는 `analyze.py` sidecar의 diagnostics/traceability와 health collection
결과를 `coverage` top-level object로 정규화한다. renderer와 delta 계산은 이 weekly
coverage object를 읽으며, sidecar diagnostics를 직접 재해석하지 않는다.

| 필드 | 산식 / 의미 |
|------|-------------|
| `partial` | `analyze.py` warnings, health warnings, 또는 analyze exit code non-zero 중 하나라도 있으면 `true`. SSH 실패가 있어도 sidecar가 있으면 weekly report는 partial로 발행된다. |
| `analyze_exit_code` | `da-weekly-report.sh`가 캡처한 `analyze.py` 종료 코드. sidecar 부재만 hard fail이다. |
| `diagnostics.parse_failure_count` | sidecar `diagnostics.summary.parse_failure` 값. |
| `diagnostics.exclusion_count` | sidecar `diagnostics.summary.exclusion` 값. 템플릿/placeholder 제외 카운트다. |
| `diagnostics.invalid_verdict_count` | sidecar `diagnostics.summary.invalid_verdict` 값. |
| `diagnostics.missing_persistence_component_count` | sidecar `diagnostics.summary.missing_persistence_component` 값. M-6 coverage와 같은 원천이다. |
| `diagnostic_rates.*_per_session` | 해당 diagnostic count / `session_counts.total`. total 0이면 0.0. |
| `marker_missing_rates` | `(total_sessions - marker_sessions) / total_sessions`. Arbiter/Intensity marker 각각 계산한다. |
| `m2_source_distribution` | sidecar `metrics.M-2.source_distribution` pass-through. |
| `m5_source_distribution` | sidecar `metrics.M-5.source` 값을 단일 key distribution으로 승격 (`{"round_summary_fallback": 1}` 등). |
| `host_collection` | sidecar `traceability.coverage.host_distribution`과 warnings prefix(`host <name>:`)를 결합한 host별 상태. warning이 있으면 `partial`, 분석 세션 0이고 warning도 없으면 `unknown`, 그 외 `ok`. |
| `warnings` / `health_warnings` | 분석 단계 warnings와 git 기반 health 수집 warnings를 분리 보존한다. |

## Session source traceability (S2-9)

`analyze.py`는 verdict record 자체의 finding-level provenance와 별개로 세션 단위
`traceability` sidecar를 emit한다. 알 수 없는 포맷이나 필드 부재는 오류가 아니라 coverage
카운트로만 남긴다.

| 포맷 | primary extraction | fallback |
|------|--------------------|----------|
| Claude Code jsonl | top-level `cwd`, `gitBranch`, `sessionId` | 없음. 부재 시 `missing_fields`에 기록 |
| Codex rollout jsonl | `payload.cwd`, `payload.git.branch`, `payload.id` | path basename `rollout-<ISO>-<id>.jsonl`에서 `session_id`, path directory `/<YYYY>/<MM>/<DD>/`에서 `rollout_date` |
| unknown | primary field 미검출 + rollout filename 미매칭 | 링크/branch/session id 미표기, `unknown_format_sessions` 증가 |

세션 본문 내 `PR #N`, `issue #N`, bare `#N` grep은 best-effort다. 실패하거나 없으면 빈
배열로 둔다. 주간 리포트는 sidecar의 `traceability.coverage`를 1급 coverage로 승격하고,
렌더링용 세션 목록은 stable subset만 사용한다.

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

각 finding-level record는 아래 `VerdictRecord` 중간 모델로 정규화한다. 기존 소비자 하위호환을 위해
`analyze_session()["verdicts"]`는 여전히 `list[dict]`이지만, dict 내용은 `VerdictRecord` 필드를
그대로 담는다.

| 기존 필드 | 유지 여부 | 신규 모델 매핑 |
|-----------|-----------|----------------|
| `finding_id` | 유지 | Arbiter/legacy finding ID 원문 |
| `verdict` | 유지 + validation | `CONFIRMED_ISSUE` / `NOT_AN_ISSUE` / `NEEDS_MORE_INFO` 외 값은 record 제외 + diagnostic |
| `confidence` | 의미 고정 | Arbiter 판정 신뢰도 (`HIGH`/`MEDIUM`/`LOW`/`N/A`) |
| `source_confidence` | 유지 | extraction tier 신뢰도 (`high`/`medium`/`low`), `confidence`와 별개 |
| `source` | 유지 | `verdict_json` / `md_header` / `json_unmarked` / `kv` |
| `bundle` | 유지 | `get_bundle(finding_id)` 결과 |

추가 필드:

| 필드 | 의미 |
|------|------|
| `session_path` | 분석한 JSONL 파일 path |
| `jsonl_line_no` | JSONL line 번호, 1부터 시작 |
| `payload_traversal_path` | string payload까지의 JSON traversal path (`$.message...`, `$.payload...`) |
| `payload_hash` | payload string 원문 SHA-256 |
| `block_index` | 같은 세션 안 result block index, 0부터 시작 |
| `block_kind` | `first_pass` / `selective` / `summary` |
| `severity` | finding block 인접 `**심각도**` 라벨 |
| `perspective` | finding ID 또는 finding block의 관점 |
| `location_identity` | finding block의 위치 식별자 (`path:line` 등) |
| `finding_fingerprint` | finding 요약 정규화 텍스트 SHA-256 |
| `stability_status` | schema 1.1 개별 VERDICT_JSON에는 이 필드가 없다 (aggregate 전용). analyzer가 누락 시 호환값 `N/A`를 합성해 채운다 |
| `canonical_verdict_hash` | canonical verdict object hash. verdict 단위 dedupe key 입력 |

aggregate 결과의 `metrics["M-2"]["source_distribution"]` 필드에 source별 추출률을 출력해 low-confidence fallback 비율을 가시화한다.

### VerdictRecord derivation table

| 파생값 | 정의 |
|--------|------|
| `payload_hash` 입력 | JSONL decode 후 추출한 string payload 원문. newline/공백을 재정규화하지 않고 UTF-8 replacement encoding으로 SHA-256 계산 |
| `jsonl_line_no` | 파일 첫 줄을 1로 하는 물리 line 번호 |
| `payload_traversal_path` | JSON root `$`에서 dict key는 `.key`, list index는 `[n]`로 표기. Claude Code는 보통 `$.message.content[...]`, Codex rollout은 `$.payload.*` 경로가 된다 |
| `block_index` | 같은 line 또는 직전 result line의 다음 line에 있는 verdict group은 같은 block. 중간에 non-result line이 끼면 새 block |
| `block_kind` | payload text에 `selective:`/`selective consistency`/`fleiss-kappa`가 있으면 `selective`, round summary marker가 있으면 `summary`, 그 외 `first_pass` |
| verdict dedupe key | `(session_path, jsonl_line_no, payload_traversal_path, finding_id, source, match_offset, canonical_verdict_hash)` |
| `payload_hash` 역할 | `jsonl_line_no`, `payload_traversal_path`와 함께 동일 payload 재방문 방지용 pre-parse key. 같은 hash라도 서로 다른 JSONL line 또는 traversal path면 별도 provenance로 보존한다. 한 payload가 여러 finding의 VERDICT_JSON을 담는 것은 정상이라 record dedupe key로 단독 사용 금지 |
| excluded match 보관 | `VerdictRecord`가 아니라 `ExtractionDiagnostic` sidecar (`diagnostics.sessions[].exclusions`) |

### ExtractionDiagnostic

템플릿 제외, invalid verdict, parse failure, persistence component 추출 실패는 verdict가 아니다.
따라서 `VerdictRecord`에 pseudo-record로 섞지 않고 `ExtractionDiagnostic` 목록에만 보관한다.
JSON sidecar의 `diagnostics.summary`와 `diagnostics.sessions[]`가 소비한다.

문서/템플릿 제외 조건:

- outer fenced example 안의 VERDICT_JSON 예시
- placeholder 문자열 (`"{finding ID 원문}"` 등)
- enum union 문자열 (`CONFIRMED_ISSUE | NOT_AN_ISSUE`)
- 한국어 `또는` 패턴
- Arbiter 프롬프트 템플릿 문맥

수치 라벨 주의: "parse failure raw 61건"은 Phase 0 최초 실측의 원시 parse failure 수이고,
"exclusion fixture 62건"은 live corpus 재측정 시점의 템플릿 exclusion capture 수다. 두 값은
서로 다른 측정 시점/분류 기준이며 `u1-exclusion-manifest.json`에 별도 필드로 남긴다.

### JSONL decode 의무

raw blob에 직접 regex를 적용하지 않는다. JSONL parse → string payload extraction → regex 적용 순서를 강제한다.

```python
def extract_text_payloads_with_paths(obj, accumulator, path="$"):
    if isinstance(obj, str):
        accumulator.append((path, obj))
    elif isinstance(obj, dict):
        for key, value in obj.items():
            extract_text_payloads_with_paths(value, accumulator, f"{path}.{key}")
    elif isinstance(obj, list):
        for idx, value in enumerate(obj):
            extract_text_payloads_with_paths(value, accumulator, f"{path}[{idx}]")
```

## reviewer 묶음 normalize (M-3)

`analyze.py`의 `BUNDLE_MAP` 상수가 단일 SoT다. finding_id의 prefix를 lowercase로 추출하여 BUNDLE_MAP 키 조회 (legacy 세부 도메인 prefix `YAGNI`/`SECURITY` 등도 동일 매핑). 매핑 변경 시 `BUNDLE_MAP`만 수정한다 — 본 문서는 의도/이유만 기록한다.

## severity 추출 + 전이 매트릭스 (M-4)

`analyze.py`의 `VerdictRecord.block_index` + `find_severity_for_finding` +
`compute_severity_transitions`가 SoT다. 알고리즘 요약:

- `SEV_LINE` 정규식이 `**심각도**: <라벨>` 패턴을 추출한다.
- `severity_rank`는 `SEVERITY_RANK` 상수 (`CRITICAL=4`, `HIGH=3`, `MEDIUM=2`, `LOW=1`) 매핑.
- 같은 세션 내 result block N의 confirmed finding 집합 max severity와 block N+1 confirmed finding 집합 max severity의 (from, to) 쌍을 카운트한다.
- severity 라벨이 finding 본문에서 추출되지 않은 경우 rank 0으로 처리하여 `NONE → ...` 전이로 분류.
- round key는 `(session_path, block_index)`다. 기존 "finding_id가 재등장하면 새 round" 휴리스틱은 폐기한다.

수치 변경 시 `SEVERITY_RANK` 상수만 수정한다 — 본 문서는 의도만 기록한다. v1 첫 리포트는
result block 기반 새 baseline이며, 이전 휴리스틱 기반 M-4 수치와 직접 비교하지 않는다.

## persistence_key 비수렴 지표 (M-6)

`persistence_key = (perspective, location_identity, finding_fingerprint)`다. 이는
`run-da/references/dismissal-ledger.md`의 dismissal key에서 세션 경계를 넘는 정량 분석에
부적합한 필드를 뺀 lossful grouping key다.

| dismissal ledger 필드 | persistence_key 포함 | 사유 |
|-----------------------|----------------------|------|
| `changeset_key` | 제외 | 세션 간 시계열 비교에서는 changeset 경계가 달라질 수 있어 지속성 분석을 끊는다 |
| `review_unit` | 제외 | reviewer bundle 개편 시 시계열이 단절된다 |
| `perspective` | 포함 | 같은 위치라도 관점이 다르면 다른 failure mode |
| `location_identity` | 포함 | 지속 여부의 위치 축 |
| `finding_fingerprint` | 포함 | 같은 관점+위치라도 요약 fingerprint가 다르면 다른 finding |
| `scope` | 제외 | ledger suppression 범위용 필드라 corpus 시계열 grouping에 부적합 |

키 원천은 Arbiter VERDICT_JSON schema가 아니라 DA reviewer finding block 텍스트다. schema 확장은
v1 범위 밖이다. 세 component가 모두 non-null인 record만 M-6이 소비한다. 하나라도 null이면
metric에서 제외하고 `ExtractionDiagnostic(match_kind=missing_persistence_component)`와
`metrics["M-6"]["coverage"]["missing_persistence_components"]`에 집계한다.

출력:

- `key_block_count_distribution`: 동일 persistence_key가 걸친 서로 다른 result block 수의 분포
- `top_offenders_by_session`: 세션별 반복 key 상위 5개

## StabilitySource resolver (M-5, v1)

selective consistency stability_status 측정은 verdict extraction pipeline과 분리한다.

| v1 source | 비고 |
|-----------|------|
| round summary `selective:` 라인 | `selective: trigger P건 → stable Q건, split R건, fragmented S건, partial_failure T건` 패턴 매치 시 stable/split/fragmented 카운트 누적. SoT는 `analyze.py`의 `SELECTIVE_LINE` 정규식 + `resolve_stability_status_from_round_summary`. |
| unavailable | round summary 라인 부재 시. 추정 금지. |

금지: 개별 Arbiter VERDICT_JSON에는 `stability_status` 필드가 없으므로(schema 1.1에서 aggregate 전용으로 고정) 절대 source로 사용하지 않는다 — 추출 시 보이는 값은 analyzer가 누락에 합성한 호환값 `N/A`일 뿐이다 (`run-da/references/arbiter-prompt.md` SSOT).

v1에서 미사용 source — `fleiss-kappa.py` aggregate envelope: 본 문서 초기 draft에는 1차 source로 `fleiss-kappa.py` aggregate envelope의 `per_finding[].stability_status`가 명시됐으나, 호출하려면 selective consistency arbiter result 디렉토리(예: `/tmp/da-*-arbiter-selective-*/arbiter-{1,2,3}-result.md`)를 session-level에서 직접 추적해야 하는데, 본 Skill의 corpus 전체 스캔 모델에서는 그 경계가 자연스럽게 결합되지 않는다. 따라서 v1은 round summary fallback만 사용하고, 1차 source 통합은 follow-up 범위로 둔다.

## Phase 1c MiniPC 진짜 추출 실패 2건 inspection 결과

PR #670 정정 코멘트에서 식별된 v2 알고리즘 회수 실패 MiniPC 세션 2건을 본 Skill 구현 단계에서 직접 inspect했다. 두 세션 모두 자기가 Arbiter를 실행한 세션이 아니라, ARBITER_DIR path가 cleanup 대화 / dispatcher 컨텍스트에 단순 인용된 케이스였다 (한 건은 어떤 워크플로 스킬 진입 후 `INTENSITY_DIR` / `DA_DIR` / `ARBITER_DIR` 경로 prepare 단계에서 marker가 본문에 박힌 케이스, 다른 한 건은 이전 라운드 작업물 정리 여부를 묻는 cleanup prompt에 marker 경로가 인용된 케이스). 실제 Arbiter 결과 출력은 외부 codex exec subprocess 또는 다른 세션에 있다.

결론: 이는 진짜 verdict 회수 대상이 아니라 marker name 인용에 의한 "false positive arbiter marker" 케이스다. 6번째 fallback 패턴 도입 불필요. 4-tier fallback이 충분.

향후 정확도 개선 follow-up이 필요하면 marker context 분석 (cleanup 키워드 인접 시 분모 제외) 추가를 고려할 수 있다.

식별된 두 세션의 jsonl path는 본 Skill 호출 시 `--debug-failed-extraction` 같은 옵션으로 동적으로 재식별 가능하다 (path 자체를 본 문서에 박지 않는다 — 세션 ID는 ephemeral 식별자이며 시간이 지나면 archive 위치 변경 가능).

## derived statistics

M-1~M-6 외에 출력에 포함되는 보조 statistic:

- `intensity_full_finding_zero_rate`: M-1 결과가 FULL인 세션 중 finding 0건 (CLEAR) 세션 비율. 이슈 #671 본문 PHASE-EXTENDED 6번째 항목에 대응. M-1과 M-2 결과 cross-join으로 계산.
- `metrics["M-2"]["source_distribution"]`: 4-tier fallback 각 source의 추출률 (high vs medium vs low confidence 비율).

## 한계

- `INTENSITY_DIR_MARKER`는 Review Intensity 외부 호출 경로에서만 출현. PR #670 이후 인라인 체크리스트 도입으로 marker 출현 감소 → M-1 분모 줄어들 수 있음. 인라인 체크리스트 출력의 보조 grep을 algorithm 보강 대상으로 두되 v1은 marker 우선.
- selective consistency 발동 라운드는 N=3 재판정만 있는 finding만 over-represented. M-5 분포는 전체 finding이 아니라 selective consistency 발동 finding 한정.
- live 전체 home log 모드는 시간이 지남에 따라 분모가 커진다. PR #670 ±5% 회귀 게이트는 `--corpus` pinned manifest 모드에서만 사용한다.
