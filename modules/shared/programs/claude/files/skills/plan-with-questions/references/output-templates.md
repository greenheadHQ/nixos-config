# Output Templates

사용자에게 보여주는 메시지·체크리스트·상태 보고 템플릿. progressive disclosure로 본문에서 분리한 보일러플레이트.

## for_issue Step I-3 블랙박스 체크리스트 카테고리

체크리스트는 카테고리별로 구분한다:

- **A. 요구사항**: 해석이 여러 가지 가능한 부분
- **B. 설계 결정**: 사용자의 선호도/우선순위가 필요한 선택
- **C. 트레이드오프**: 접근법이 2개 이상인 경우
- **D. 사이드이펙트**: 사용자가 인지해야 할 영향
- **E. 기타**: 위 카테고리에 속하지 않는 사항

사용자에게 체크리스트를 보여주고, 모든 항목이 ✅가 될 때까지 또는 사용자가 "충분하다"고 판단할 때까지 스무고개를 반복한다.

## Step 4 / Step I-4 질문 패턴

**라운드당 1개 질문 강제 (D1, FR-1)**: 질문 도구 호출 시 `questions` 배열 길이는 1로 고정한다 (for_action Step 4 / for_issue Step I-4 / for_prd 차용 동일). 사용자가 한 결정에 집중할 수 있게 하고, 메인 LLM이 user_facing layer를 충분히 풀어 설명할 cognitive room을 확보한다. 이전 정책 "한번에 모아서" 또는 "라운드당 최대 4개"는 폐기됨 (turn_abort 회귀 방지). 한 라운드에 하나의 질문만 던지고, 답변 도착 후 새 라운드(여전히 길이 1)로 이어간다.

질문 카테고리별 표현 가이드:

- **사이드이펙트 인지 확인**: "이렇게 변경하면 ...에도 영향이 갑니다. 인지하고 계셨나요?"
- **트레이드오프 선택**: "A 방식은 ...이 장점이고, B 방식은 ...이 장점입니다. 어느 쪽을 선호하시나요?" (옵션 본문은 user_facing layer 사용 — 아래 표시 규칙 참조)
- **판단 기준 요청**: "이 부분은 판단 기준이 필요합니다: ..."
- **범위 확인**: "이 이슈의 범위에 ...도 포함되나요, 아니면 별도 이슈로 분리할까요?"
- **XY Problem 검증**: "해결하려는 근본 문제가 무엇인가요?"

### 사용자 노출은 user_facing layer만 (D2, FR-2)

Step 3.5 자문 결과를 사용자에게 표시할 때는 [`consulting-step.md`](./consulting-step.md)의 두 layer schema 중 `user_facing` layer만 사용한다 (label / description / analogy / plain_disqualifier 4 필드). `technical_matrix`(7키 평가 매트릭스: 요구충족·구현비용·되돌리기쉬움·운영위험·검증가능성·주요unknown·비용시간추정)와 raw `disqualifiers`는 메인 LLM 내부 D4 합의 알고리즘 입력 전용이며 사용자에게 절대 노출하지 않는다.

`user_facing` 누락 시 D2 backward-compat fallback 4단계를 [`consulting-step.md`](./consulting-step.md#d2-backward-compat-fallback-4단계-user_facing-누락-시) SSOT에 따라 graceful degrade한다.

### 라벨 부착 조건 — D4 합의 알고리즘 호출 (FR-5, FR-7 hard rule)

`(Recommended)` 라벨 부착은 [`consulting-step.md`](./consulting-step.md)의 D4 합의 알고리즘 4단계에서 후보가 정확히 1개로 좁혀진 합의 PASS 옵션에만 허용된다. 합의 미달 시 fallback enum(D4_FALLBACK_A/B/C/C_MULTI)으로 격하되며 어떤 옵션에도 라벨이 부착되지 않는다 (사용자에게는 enum 라벨 대신 평이 한국어 문구만 노출 — 정확한 문구는 consulting-step.md "Fallback enum" 표 SSOT).

**hard rule (FR-7)**:
- AskUserQuestion 도구 description의 추천 라벨 자동 권장은 본 스킬 컨텍스트에서 무시한다.
- 사용자 노출 직전 옵션 dict에서 합의 미달 옵션의 `(Recommended)` 문자열 또는 등가 표시가 발견되면 강제 제거한다.
- 본 hard rule의 정본은 [`consulting-step.md`](./consulting-step.md)의 D4 hard rule 단락 + SKILL.md Invariant 8이며, 본 patterns 섹션은 그 SSOT를 callsite로 강제한다.

### judgment-first 라운드 라벨 부착 절대 금지 (FR-4)

옵션 보이기 전 "어떤 기준이 가장 중요한가?" 먼저 묻는 judgment-first 사전 라운드는 D4 합의 알고리즘을 **실행하지 않는다**. 어떤 옵션에도 `(Recommended)` 라벨을 부착하지 않으며, `user_facing.label`만으로 기준을 평이하게 표시한다 (자문 출력의 합의 결과와 무관). anti-anchoring 효과를 source에서부터 보호하기 위함이다.

### Step 3.5 자문 결과 표시 시 anti-anchoring 규칙 (필수)

- 라벨 부착은 D4 합의 PASS인 단일 옵션에만 허용 (위 "라벨 부착 조건" 단락 SSOT). 합의 미달 옵션에는 어떤 부착도 금지 (`(Recommended)` 강제 제거).
- 옵션 순서를 `decision_id`로 seed한 stable shuffle (같은 decision_id면 같은 순서, 다른 decision_id면 다른 순서).
- 각 옵션에 `user_facing.plain_disqualifier`("틀릴 수 있는 조건")를 평이한 한국어로 명시 (`disqualifiers` raw는 메인 LLM 내부 사용).
- 옵션 보이기 전 "어떤 기준이 가장 중요한가?" 먼저 묻는 judgment-first 패턴.
- 옵션 description은 `user_facing.description` + `user_facing.analogy`를 그대로 사용하여 사용자가 도메인 모르더라도 트레이드오프를 직관할 수 있게 함.

### 라운드별 룰 매트릭스 (D4 라벨 부착 결정 흐름)

본 표는 D4 합의 알고리즘의 결과로 라벨 부착 여부와 묶음 정책을 결정한다. user_facing 텍스트 출처(자문 원본 vs D2 메인 LLM 자체 작성)는 D2 텍스트 복구 흐름의 별개 축이며 아래 "D2 텍스트 복구 (D4와 별개 축)" 단락에서 별도로 다룬다. **fallback 사용자 노출 평이 문구는 [`consulting-step.md`](./consulting-step.md) "Fallback enum (내부 Decision Log 전용, 사용자 노출 금지)" 표가 단일 진실 원천**이며 본 매트릭스는 그 표를 복제하지 않는다.

| 라운드 종류 | 묶음 | user_facing 텍스트 사용 여부 | (Recommended) 라벨 부착 |
|---|---|---|---|
| 일반 (단순 요구사항/사이드이펙트) | 1개 (D1) | 옵션 표시 시 사용 | 미적용 (옵션이 단순 또는 yes/no) |
| 트레이드오프 — 합의 PASS (후보 정확히 1개) | 1개 (D1) | 사용 (D2) | **허용** — 그 단일 옵션에만 |
| 트레이드오프 — fallback (`D4_FALLBACK_A/B/C/C_MULTI`) | 1개 | D2 텍스트 복구 사용 또는 자문 user_facing 그대로 (단계별 동작은 consulting-step.md SSOT) | **절대 금지** — 모든 옵션 라벨 없이 표시 |
| judgment-first 사전 라운드 | 1개 (D1) | 사용 (D2) — 기준 평이 라벨 | **절대 금지** (FR-4) — D4 미실행 |

### D2 텍스트 복구 (D4와 별개 축)

자문 출력에 `user_facing` layer가 누락(또는 부분 누락)된 경우 메인 LLM은 [`consulting-step.md`](./consulting-step.md)의 D2 fallback 4단계로 텍스트 복구를 시도한다. Stage 3에서 메인 LLM이 description/analogy/plain_disqualifier를 자체 작성한 경우 사용자에게는 평이한 한국어 문구로 출처를 표기한다 (정확한 문구는 [`consulting-step.md`](./consulting-step.md) "Fallback enum" 표의 `D2_FALLBACK_USER_FACING` 행 SSOT). 사용자에게는 enum 라벨 자체를 노출하지 않는다. D2 fallback이 텍스트를 복구해도 D4 라벨 부착 여부와는 다른 축이다 — D4 Step 2가 schema 검증 fail로 D4_FALLBACK_B를 유지하므로 `(Recommended)` 라벨은 부착되지 않는다.

상세 schema/algorithm은 [`consulting-step.md`](./consulting-step.md) 참조.

## for_issue Step I-6 전환 제안 메시지

이슈 생성 완료 후, 질문 도구로 사용자에게 묻는다. 메시지 본문과 첫 옵션은 **사용자 입력 시점의 자연어 trigger 카테고리**에 따라 달라진다.

trigger 카테고리 정의 (키워드 목록 + 권장 transition 모드)는 [`../SKILL.md`](../SKILL.md#모드-판별)의 "자연어 trigger → transition 매핑" 표 (SSOT)를 참조한다. 본 섹션은 각 카테고리의 사용자 메시지 문안과 옵션 본문만 정의한다. 모든 카테고리는 옵션을 **3개로 통일**한다 (`request_user_input`의 max-3 제약 준수).

### PRD 작성 의도 trigger 매칭 시

> "이슈 등록이 완료되었습니다. 입력에 PRD 작성 의도가 포함되어 있어, 바로 **for_prd 모드로 PRD 작성**을 시작할 수 있습니다. 어떻게 진행할까요?"

옵션 (3개):
- **Yes (for_prd 진입)** → 생성된 이슈 URL(create-issue Step 5의 `ISSUE_URL`)로 `for_prd <ISSUE_URL>` 진입.
- **No (write-handoff로 마무리)** → 이슈 URL을 인자로 `/write-handoff` 실행 후 종료.
- **No (여기서 종료)** → 이슈 URL 반환 후 종료. (사용자가 for_action 우회를 원하면 별도 메시지로 `for_action <ISSUE_URL>` 명시 호출 가능.)

### review-impl 의도 trigger 매칭 시

> "이슈 등록이 완료되었습니다. 입력에 구현 감사·문서 대비 리뷰 의도가 포함되어 있어, **for_action 모드로 진입 후 Post-Implementation 5번 Final review**에서 PRD 10-pass(`references/prd/multi-pass-review.md`) + review-impl overlay(`references/review-impl/implementation-review.md` — 6-classification 라벨링 + overbuilt 우선 분류)를 적용합니다. 어떻게 진행할까요?"

옵션 (3개):
- **Yes (for_action 진입)** → 생성된 이슈 URL로 `for_action <ISSUE_URL>` 진입.
- **No (write-handoff로 마무리)** → 이슈 URL을 인자로 `/write-handoff` 실행 후 종료.
- **No (여기서 종료)** → 이슈 URL 반환 후 종료.

### 일반 텍스트 (위 카테고리 매칭 없음)

> "이슈 등록이 완료되었습니다. 바로 for_action으로 전환하여 작업을 진행하시겠습니까?"

옵션 (3개):
- **Yes** → 생성된 이슈 URL로 `for_action <ISSUE_URL>` 진입.
- **No (write-handoff로 마무리)** → 이슈 URL을 인자로 `/write-handoff` 실행 후 종료 (bare 번호 대신 URL을 전달해 cwd-dependent bare-number 모호성을 회피).
- **No (여기서 종료)** → 이슈 URL 반환 후 종료.

## for_prd 모드 자동 트리거 알림 메시지

자동 PRD 후보가 감지되면 1회 알림 + opt-out:

> "이 작업은 phase 추적·재개 상태가 필요해 보이는 장기 작업입니다. **Living PRD 모드**로 진행하고, 간단한 plan으로 줄이려면 알려주세요.
>
> 트리거 신호: [Phase ≥4 / 다중 도메인 / 어느 쪽인지 명시]"

옵션 (질문 도구):
- **PRD 모드로 진행 (default)** → for_prd 모드 진입.
- **간단한 plan으로** → for_action 모드 fallback.

상세는 [`task-size-routing.md`](./task-size-routing.md) 참조.

## Step 9 승인 요청 시 Post-Implementation 범위 표시

plan 파일 Step 8에 다음 중 하나를 명시 (사용자에게 노출):

- 생략 단계 없음: "Post-Implementation 1~7 자동 수행 (default)"
- 일부 생략: "Post-Implementation 자동 수행: 1~5만 (`/create-pr` 생략 — 사용자 명시 요청)"

이 항목은 승인 요청 도구 호출 시 사용자에게 노출되어 tracked write·commit·GitHub PR write 포함 자동 진행 범위에 대한 사용자 동의 근거가 된다.
