# 자동 run-da preflight gate

`plan-with-questions` 의 자동 호출 지점은 `/run-da` 를 invoke 하기 직전에 `run-da` 의 Review Intensity 체크리스트를 적용할 수 있다. 본 gate는 자동 워크플로우 단계에만 적용되는 caller-side gate 다. 자유로운 review 면제 수단이 아니다.

## 적용 call site

- for_action의 Step 5: `.claude/plans/<slug>.md` 의 plan에 대한 plan-mode review.
- for_prd의 P6: PRD draft 또는 context에 대한 plan-mode review.
- Post-Implementation의 Step 3: 구현 diff에 대한 code review.

`/run-da` 를 단순히 언급만 하는 incidental guidance는 본 gate를 상속하지 않는다.

## SSOT

본 gate는 `run-da` 정책을 복제하지 않고 재사용한다:

- 체크리스트 절차: 단일 SSOT는 [`../../run-da/references/intensity-procedure.md`](../../run-da/references/intensity-procedure.md) 다.
- 규칙 표: 단일 SSOT는 [`../../run-da/references/intensity-rules.md`](../../run-da/references/intensity-rules.md) 다.
- 질문 도구 미지원 fallback: 단일 SSOT는 [`../../run-da/references/arbiter-scaling.md`](../../run-da/references/arbiter-scaling.md#질문-도구-미지원-대응) 다.

위 SSOT가 변경되면 본 gate는 그 변경을 그대로 따른다. call-site 문서는 본 gate를 link만 하고 정책을 복제하지 않는다.

## 절차

1. `/run-da` 가 사용할 입력을 동일하게 수집한다:
   - plan-mode: plan 요약과 변경 파일 목록.
   - PRD mode: PRD draft 또는 context, 후보 phase 구조, 변경 파일 목록.
   - post-implementation: `git diff --stat main...HEAD`, 필요 시 실제 diff fact.
2. `run-da` 가 정의한 Review Intensity 체크리스트를 그대로 적용한다.
3. 전체 체크리스트 표와 first-match verdict를 활성 plan / PRD context 또는 conversation state에 기록한다.
   - durable 기록에는 sanitized evidence만 사용한다. raw diff hunk 텍스트, secret으로 보이는 값, 토큰, credential, 기타 민감 literal을 plan / PRD markdown에 복사하지 않는다.
   - freshness 검증에만 필요한 raw fact는 이미 안전하게 persist 가능한 경우가 아니면 transient handoff context에 둔다.
4. verdict가 `SKIP` 이면 질문 도구로 사용자에게 묻고 skip 한다.
5. verdict가 `LITE` 또는 `FULL` 이면 체크리스트 handoff와 함께 `/run-da` 를 invoke 하여 그 intensity로 진행한다.

## SKIP outcome

verdict가 `SKIP` 일 때의 세 가지 분기:

### 사용자가 SKIP 승인

- Action: `/run-da` 를 invoke 하지 않는다. 자동 gate를 완료된 것으로 취급한다.
- Durable state — for_action: plan의 DA 상태를 다음으로 기록한다:
  - `DA State=SKIPPED`
  - `Resume From=for_action.step7_plan_mode_entry`
  - `Last Completed Step=for_action.step6_da_apply`
- Durable state — for_prd: P6 outcome을 transient context에 기록한다. PRD 작성 후에는 PRD master의 `Change Log` 에도 기록한다.
- Durable state — post-implementation: Step 3 outcome을 활성 plan의 `Change Log` 또는 PRD master의 `Change Log` 에 기록한다.
  - `Last Completed Step=post_impl.run_da_for_pr`
  - `Resume From=post_impl.parallel_audit`
  - plan-mode의 `DA State` 는 덮어쓰지 않는다.

### 사용자가 SKIP 거부

- Action: `SKIP rejected` handoff와 함께 `/run-da` 를 invoke 한다. `/run-da` 는 같은 SKIP 질문을 다시 묻지 않고 post-refusal escalation 경로로 진입한다.
- Durable state: escalation을 기록하며 `SKIPPED` 는 기록하지 않는다.

### 질문 도구 미지원

- Action: skip 하지 않는다. `run-da` 의 fallback 정책을 따른다. 본 case의 SKIP은 LITE로 escalation 된다.
- Durable state: escalation을 기록하며 `SKIPPED` 는 기록하지 않는다.

## Handoff to `/run-da`

preflight 통과 후 gate가 `/run-da` 를 invoke 할 때 체크리스트 표와 outcome을 context로 전달한다. 본 섹션이 handoff schema의 단일 SSOT 다.

valid handoff에 포함되어야 하는 항목:

- `mode` — `for_plan` 또는 `for_pr`.
- 체크리스트에 사용된 input summary.
- 모든 rule 결과와 evidence.
- 최종 intensity verdict.
- verdict가 `SKIP` 이었을 때의 사용자 승인 상태.
- freshness 필드: 다음을 포함한다:
  - verdict 도달에 사용된 모든 체크리스트 input fact. verdict가 파일명 이상의 정보를 사용했으면 그 plan / diff / PRD fact도 비교 가능한 형태로 handoff에 포함한다.
  - `for_plan` mode — target plan path와, 체크리스트에 사용된 plan 요약 또는 content fact, 변경 파일 목록.
  - `for_prd` mode — PRD target path 또는 draft / context label, 후보 phase 요약, PRD 또는 draft fact, 변경 파일 목록.
  - `for_pr` mode — `git diff --stat main...HEAD` 의 정확한 텍스트, 체크리스트에 사용된 diff hunk fact 또는 `change_summary` fact.

handoff가 누락되거나, malformed 거나, freshness 필드가 현재 input과 다르거나, verdict에 사용된 체크리스트 input fact가 handoff에서 빠진 경우, `/run-da` 는 현재 input에서 체크리스트를 다시 실행하고 자체 절차에 따라 fail-closed 한다.
