# Task Size Routing — for_prd 자동 트리거

`for_action` 진입 후 Step 1-2(이슈 유효성 + 코드베이스 탐색) 결과를 분석하여 PRD 모드 후보를 자동 감지하고, 사용자에게 1회 알림 + opt-out 옵션을 제공한다.

`for_prd` 모드는 PRD 규약을 따라 **`.claude/prds/`에 PRD 파일을 직접 작성**한다 — 본 plan-with-questions는 인터뷰·검증·자동 트리거 + PRD 작성을 모두 담당하며 별도 plan 사본은 만들지 않는다. 상세 흐름은 [`../modes/for_prd.md`](../modes/for_prd.md).

## 자동 트리거 신호

가장 큰 변화: **단독 트리거 신호 하나만으로 트리거하지 않는다**. `Phase ≥4`는 단독으로 트리거하지만, "다중 도메인"은 보조 신호 1+와 결합될 때만 승격한다 (over-triggering 방지 — small config change가 Living PRD로 무거워지는 회귀 차단).

### 단독 트리거 신호 (혼자만 있어도 트리거)

- **Phase ≥4**: 의존성 순서 phase가 4개 이상 필요. [`./prd/file-mode-selection.md`](./prd/file-mode-selection.md)의 Single/Split 판정 룰과 일치. 단독으로 PRD 트리거.
- **명시적 PRD/spec 요청**: 사용자가 `for_prd`, `PRD`, `spec`, `명세`, `phase plan` 같은 PRD-naming을 명시 사용한 경우. 단독 트리거.

### 다중 도메인 (보조 신호 1+ 와 결합 시 트리거)

다음 도메인 중 2+ 동시 변경이 감지되면 후보로 표시하되, **즉시 트리거하지 않고 보조 신호 1개 이상 추가 매치를 요구**한다:

- data model (DB schema, migration)
- backend (route, service, job)
- frontend (component, screen, routing)
- infrastructure (config, deployment, container)
- permission / security (auth, RBAC, secret)
- observability (log, metric, trace)
- billing / external API integration

### 보조 신호 (다중 도메인과 결합용)

- **예상 소요일 ≥1일**: Step 1-2 분석에서 추정 작업 시간이 single-day 초과.
- **키워드**: 이슈 제목/본문에 `overhaul`, `재설계`, `redesign`, `아키텍처 변경`, `architecture change`, `migration plan`, `epic` 포함.
- **파일 변경 수 ≥10**: Step 1-2에서 식별한 수정 대상 파일이 10개 이상.
- **이슈 라벨**: `epic`, `meta`, `roadmap`, `tracking-issue` (이슈 트래커에서 확인 가능 시).
- **계획 변동 가능성 높음**: Step 1-2 discovery에서 unknown이 많거나 외부 의존성이 큰 경우.

### 약한 신호 (정보용 — 단독으론 트리거 안 함)

- 사용자 요청 본문에 "phase", "단계별", "stages" 같은 표현.
- Step 2 로컬 재현에서 비결정적 동작 발견.

## 트리거 알고리즘 (의사코드)

```
def should_trigger_prd(step12_result):
    if step12_result.user_explicitly_named_prd:
        return "trigger"
    if step12_result.estimated_phases >= 4:
        return "trigger"
    multi_domain = step12_result.distinct_domain_count >= 2
    auxiliary_signal_hits = count_auxiliary_signals(step12_result)
    if multi_domain and auxiliary_signal_hits >= 1:
        return "trigger"
    return "no_trigger"
```

핵심 차이 (이전 버전 대비):
- 이전: `phase>=4 OR multi_domain >= 2` → 단일 hit으로 트리거 (over-trigger 위험).
- 현재: `phase>=4` 단독 OR (`multi_domain` AND `보조 신호 >= 1`) — 다중 도메인은 항상 보조 신호와 결합.

메인 LLM이 Step 1-2 결과를 보고 위 알고리즘을 적용. 단독 트리거 신호는 명확하므로 직접 식별. 보조 신호 중 "예상 소요일"은 메인 LLM의 추정으로, **보수적 기각**(under-trigger보다 명시적 사용자 요청 시 PRD 진입을 신뢰).

## opt-out 알림 메시지

[`output-templates.md`](./output-templates.md#for_prd-모드-자동-트리거-알림-메시지) SSOT.

요약:
- default: PRD 모드 진행 (단 over-trigger 방지를 위해 다중 도메인 단독은 후보 단계에서 보조 신호 검증 후에만 알림 표시)
- opt-out: `for_action` 모드 fallback (Phase plan 없는 단일 plan)
- 사용자가 명시적 거부 시점에는 아직 Step 4.5 plan 파일이 없을 수 있으므로 즉시 `.claude/plans/` 파일을 만들지 않는다. 거부 사유를 PRD-trigger pending note로 세션/context에 보존하고, `for_action`으로 계속 진행해 Step 4.5 plan 파일을 만들 때 아래 `Decision Log` 항목으로 이관한다:

```markdown
### DL-N: PRD auto-trigger declined

- Status: accepted
- Context: Step 1-2 결과 PRD 후보로 감지(`Phase ≥4` 또는 `다중 도메인 + 보조 신호 N개`).
- Decision: 사용자 opt-out → `for_action` 모드 fallback.
- Consequences: phase 추적 없음. 작업 큰 경우 재개·decision 추적 한계 발생 가능.
```

## PRD 모드 산출물 경로

`for_prd` 트리거 + 사용자 동의 시, 산출물은 **PRD 규약을 따라 `.claude/prds/`에 직접 작성**된다. plan-with-questions는 `.claude/plans/` 사본을 만들지 않고, `.claude/prds/`가 단일 SSOT다.

### Single vs Split 자동 판정

자동 판정 플로우와 split 조건은 [`./prd/file-mode-selection.md`](./prd/file-mode-selection.md#자동-판정-플로우)가 단일 SSOT다. plan-with-questions가 이를 따르며 본 reference에 복제하지 않는다 (drift 방지).

산출물 경로:
- **Single**: `.claude/prds/prd-<feature>.md`
- **Split**: master `.claude/prds/prd-<feature>.md` + phase 파일 `.claude/prds/prd-<feature>/phase-NN-<name>.md` (master는 phase 디렉토리 옆 sibling)

자동 트리거 조건이 `Phase ≥4`이면 보통 split이 자연스럽다. 사용자가 "single로 유지해" 또는 "split으로 나눠줘"라고 명시하면 그 지시를 우선한다.

file-mode-selection 규약을 plan-with-questions가 직접 적용한다. 본 모드는 트리거 + P1-P5 인터뷰·자문 + P6-P7 DA 완료 후 `.claude/prds/`에 직접 작성한다. `for_action` Step 4.5 plan 파일 초기화는 건너뛰며, plan-with-questions는 `.claude/plans/` 사본을 만들지 않는다.

## review-impl 통합 시점

Post-Impl 5번 Final Multi-Pass Review는 **`for_action` / `for_prd` 모드에서 mandatory**다 ([`./post-implementation.md`](./post-implementation.md) Step 5). `for_issue` 모드에는 Post-Implementation 7단계 자체가 적용되지 않으므로 Final review도 호출되지 않는다 ([`./post-implementation.md`](./post-implementation.md) 첫 단락 SSOT). PRD/spec 산출물 부재 같은 mode-specific 조건은 일부 항목을 `N/A`로 skip할 수 있을 뿐, 단계 자체를 생략하지 않는다.

| 모드 | Phase-end 10-pass (prd) | 6-classification 적용 시점 | Post-Impl 5번 Final review 구성 | auto-fix |
|------|--------------------------|----------------------------|---------------------------------|----------|
| **for_action** (단순 작업, PRD 산출물 없음) | 적용 안 함 | 적용 안 함 | PRD 10-pass 단독 수행 (PRD closeout 항목은 `N/A` skip + 근거 기록, 나머지 9개 항목은 그대로 수행) | 적용 안 함 |
| **for_action** (review-impl 의도 trigger 진입, PRD/spec 입력 있음) | 적용 안 함 | Post-Impl 5번 Final overlay에서 라벨링 (phase-end 호출하지 않음 — for_action에 phase 단위 없음) | PRD 10-pass + review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류) | 적용 안 함 |
| **for_prd** | **phase-template 10-pass 수행** | Phase-end + Post-Impl 5번 Final 둘 다 (대체 아님) | PRD 10-pass + review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류) | **적용하지 않음 (NG-2)** |

**Phase-end 10-pass + 6-classification 동시 수행**: [`./prd/phase-template.md`](./prd/phase-template.md)의 Phase-End 10-pass(intent/correctness/simplicity/code quality/cleanup/security/performance/validation/future-phase/PRD sync)를 그대로 수행하고, 추가로 [`./review-impl/requirement-status.md`](./review-impl/requirement-status.md)의 6-classification(satisfied/partial/missing/conflicting/overbuilt/deferred)을 보조 layer로 적용한다.

**Final review (PRD 10-pass + review-impl overlay)**: 모든 phase 완료 후 Post-Impl 5번에서 [`./prd/multi-pass-review.md`](./prd/multi-pass-review.md)의 PRD 10-pass를 canonical checklist로 수행 (input: PRD master + phase 파일 + 구현 코드). 결과 위에 [`./review-impl/implementation-review.md`](./review-impl/implementation-review.md) overlay를 얹어 각 finding에 [`./review-impl/requirement-status.md`](./review-impl/requirement-status.md) 6-classification 라벨을 부여하고 `overbuilt` 우선 분류를 적용한다 (별도 9-pass checklist 미수행, overlay 자체가 review-impl delta).

`overbuilt` 발견 시 review-impl reference는 보고만 산출한다 (`Decision Log` 권장 기록 + 제거/문서 보강 방향 권장). 적용·정렬·제거는 메인 에이전트가 사용자 승인된 remediation 단계에서 수행한다 (review-only 정책, NG-2).

**auto-fix 차용 안 함**: review-impl의 fix 경로(auto-apply)는 채택하지 않는다 (NG-2). 발견된 issue는 메인 에이전트가 별도 승인 단계에서 처리하거나 다음 phase로 deferred 기록.

## 적용 단계 매핑

| Step | 동작 |
|------|------|
| `for_action.step1_validity` 종료 후 | 강한 신호(Phase ≥4, 명시 PRD 요청) 1차 평가 |
| `for_action.step2_exploration` 종료 후 | 다중 도메인 + 보조 신호 종합 평가 → 트리거 결정 |
| 트리거 시 | 사용자 알림(질문 도구) → opt-out 확인 |
| 사용자 동의 시 | Mode 갱신 (`for_action` → `for_prd`) + 전환 사유를 PRD draft/context에 기록(작성 후 master `Change Log`로 이관) → [`../modes/for_prd.md`](../modes/for_prd.md) P1-P5 + P6-P7 진행 (for_action Step 4.5는 skip) → P8 명시 승인 게이트 → P9 `.claude/prds/`에 PRD 작성 |
| 사용자 거부 시 | `for_action` 모드 유지 + PRD-trigger pending note 기록 → Step 4.5 plan 초기화 시 Decision Log "PRD auto-trigger declined"로 이관 |

이후 흐름은 [`../modes/for_prd.md`](../modes/for_prd.md)로 분기.
