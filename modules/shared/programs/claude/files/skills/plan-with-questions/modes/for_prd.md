# Mode: for_prd

`plan-with-questions`의 인터뷰·검증·자동 트리거 흐름을 거친 뒤, **PRD 작성을 `/prd` 스킬에 위임하는 handoff wrapper 모드**다. 자체 PRD 산출물을 만들지 않는다.

핵심 설계: PRD 정본 owner는 `/prd` 스킬과 `.claude/prds/` 디렉토리다. plan-with-questions는 (a) 자동 트리거 + opt-out, (b) Step 1-6 인터뷰·자문·DA, (c) PRD 작성 직전 handoff를 담당한다. `.claude/plans/` 사본을 만들지 않는다 — 두 SSOT 병존 회귀 방지.

## 진입 조건

1. **자동 트리거**: `for_action` Step 1-2 진행 중 [`../references/task-size-routing.md`](../references/task-size-routing.md) 트리거 알고리즘이 후보로 판정 → 사용자 1회 알림 + opt-out 통과. 이슈 ref가 이미 resolve된 상태에서 진입한다.
2. **명시 호출**: `$ARGUMENTS` 첫 토큰이 `for_prd`이고 두 번째 토큰이 **이슈 ref(URL/번호/이슈키)**. for_action과 동일하게 이슈 resolve 전제 — 텍스트 설명만으로는 진입할 수 없다 (이슈 없는 PRD 작성은 `for_issue`로 이슈 등록 후 transition 또는 `/prd` 직접 호출).
3. **재개**: 기존 `.claude/prds/prd-<feature>.md` 파일이 있고 사용자가 동일 이슈 ref로 재호출 → `/prd` 스킬의 갱신 흐름으로 위임.

## 차용 reference (직접 복제 금지)

| Reference | 용도 |
|-----------|------|
| [`../../prd/SKILL.md`](../../prd/SKILL.md) | PRD 작성·갱신·split-file mode·phase 추적 — **정본 owner** |
| [`../../prd/references/prd-master-template.md`](../../prd/references/prd-master-template.md) | Document Status + Phase Index + 본문 구조 — `/prd`가 적용 |
| [`../../prd/references/phase-template.md`](../../prd/references/phase-template.md) | Phase Discovery Gate / Implementation / Validation / Exit Criteria — `/prd`가 적용 |
| [`../../prd/references/file-mode-selection.md`](../../prd/references/file-mode-selection.md) | Single vs Split 자동 판정 |
| [`../../prd/references/validation-paths.md`](../../prd/references/validation-paths.md) | 10 validation path catalog (모든 모드 공통) |
| [`../../prd/references/multi-pass-review.md`](../../prd/references/multi-pass-review.md) | Final 10-pass review (Post-Implementation 5번) |
| [`../../review-implementation/`](../../review-implementation/) | phase 종료 시 6-classification + Final 9-pass review-only (auto-fix 미사용) |

## 산출물 경로

`/prd` 스킬 규약 그대로 — plan-with-questions가 별도 사본 만들지 않음:

- **Single**: `.claude/prds/prd-<feature>.md`
- **Split**: master `.claude/prds/prd-<feature>.md` + phase 파일 `.claude/prds/prd-<feature>/phase-NN-<name>.md` (master는 디렉토리 옆에 sibling으로 위치 — `/prd/references/file-mode-selection.md` 정본 그대로)

자동 판정은 `/prd/references/file-mode-selection.md` 차용 (상세는 [`../references/task-size-routing.md`](../references/task-size-routing.md#single-vs-split-자동-판정)).

## 흐름

`for_prd`는 `for_action`의 Step 1-6를 그대로 거친 후, Step 7(계획 추적 도구 진입) 시점에서 `/prd` 스킬에 handoff한다.

### Step 1-6 (for_action 동일)

[`for_action.md`](./for_action.md) Step 1-6 그대로 따른다. 차이점:
- **Step 1**: tier-1/aux 신호 1차 평가 (자동 트리거 가능성 검토).
- **Step 2**: 트리거 결정 시 사용자에게 알림 + opt-out 확인. 사용자 동의 시 Mode 전환 (`for_action` → `for_prd`).
- **Step 3.5**: 자문 입력에 phase 구조 후보를 포함 (PRD는 phase 단위 결정이 핵심).
- **Step 5 DA**: 기본은 `/run-da for_plan` 호출 — `run-da`의 독립 Intensity agent가 SKIP/LITE/FULL을 자동 판정한다. phase 4+ 복잡 plan에서 사용자가 명시적으로 exhaustive review를 원하면 `/run-da for_plan full` 사용 (full modifier는 Intensity 판단을 우회하고 8 도메인 강제). 두 의미는 다르다.

### Step 7: 사용자 승인 게이트

**`/prd` handoff 전에 명시 승인 게이트 필수** (`for_action` Step 9와 등가). 자동 PRD opt-out 동의가 곧장 commit/PR write 동의로 확장되는 회귀를 방지한다 (#569 류 회귀):

1. 메인 에이전트가 Step 1-6 결과를 사용자에게 요약 제시:
   - PRD 후보 신호 (트리거된 tier-1/aux 신호)
   - Resolved evidence + 사용자 답변 + Step 3.5 자문 매트릭스 요약
   - DA findings + Arbiter 판정 핵심
   - 후보 phase 구조 (3-6개) + 산출물 경로 (`.claude/prds/...`)
   - **Post-Implementation 자동 수행 범위** ([`../references/post-implementation.md`](../references/post-implementation.md) 1~7 — 변경 구현·구현 커밋·`/run-da for_pr`·`/parallel-audit`·Final review·반영 커밋·`/create-pr`).
2. 승인 요청 도구로 사용자 승인 요청. 사용자가 수정 요청하면 plan 갱신 후 다시 요청.
3. **승인이 곧 Post-Implementation 자동 수행 동의**다 (tracked write·commit·PR write 포함). plan-with-questions의 신뢰 경계는 [`../references/post-implementation.md#신뢰-경계-569-회귀-방지`](../references/post-implementation.md)에 정의된 것과 동일하게 적용된다.

### Step 8: `/prd` handoff

승인이 통과한 경우에만 `/prd` 스킬 호출로 분기한다:

1. plan-with-questions가 Step 1-6에서 수집한 정보 + 승인된 후보 phase 구조를 정리한다.
2. `/prd` 스킬을 호출하여 위 정보를 입력으로 전달한다.
3. `/prd`가 `.claude/prds/prd-<feature>.md` (또는 split) 작성을 수행한다.

plan-with-questions는 `/prd` 호출 후 추가 plan 파일을 만들지 않는다. PRD 갱신·phase 진행·Phase Discovery Gate 적용은 모두 `/prd` 스킬 책임.

### Post-Implementation 흐름 변형

PRD가 작성된 후 구현 단계는 [`../references/post-implementation.md`](../references/post-implementation.md) 7단계를 따르되 다음 추가:

- 상세 review 흐름 (phase-end / Final / overbuilt 처리)은 [`../references/task-size-routing.md#review-implementation-통합-시점`](../references/task-size-routing.md#review-implementation-통합-시점)이 SSOT다. 본 mode 파일은 link만 두고 절차를 복제하지 않는다 (drift 방지).

PRD Closeout 조건은 `.claude/prds/`에 작성됐으므로 자동 활성화 (이전 버전의 `.claude/plans/` mismatch는 본 변경으로 해소).

## 메타데이터

PRD 자체 메타데이터는 `/prd/references/prd-master-template.md`의 Document Status 표가 정본 (`/prd`가 적용). plan-with-questions의 [`../references/plan-file-template.md`](../references/plan-file-template.md) 14필드는 `for_action` 모드 전용이며, `for_prd`에는 적용되지 않는다 — 두 SSOT 병존 회피.

Resume From enum의 `for_prd.*` 항목 ([`../references/resume-state.md`](../references/resume-state.md))은 plan-with-questions가 `/prd` 호출 직전까지 도달한 단계를 기록할 때 사용한다. `/prd` 스킬 진입 후의 phase 진행은 `/prd`가 자체 추적한다.

## main-agent-only 경계

PRD 파일·phase 파일은 모두 tracked write이므로 메인 에이전트 전용. fan-out·subagent 위임 금지. 6-classification + 9-pass review 수행자도 read-only이며 적용은 메인이 수행. [`../../run-da/SKILL.md`](../../run-da/SKILL.md)의 `Codex 세션 하드닝 계약` SSOT를 따른다.

## /prd 모드 vs `/prd` 직접 호출 차이

| 항목 | `for_prd` 모드 (plan-with-questions 진입) | `/prd` 직접 호출 |
|------|-------------------------------------------|------------------|
| 입력 | 인터뷰 결과 + Step 3.5 자문 + DA 판정 | 사용자 직접 입력 |
| 자동 트리거 | task-size-routing 알고리즘으로 후보 감지 | 사용자가 명시 호출 |
| Step 3.5 외부 자문 | 트레이드오프 1+ 항목 시 (`/prd` handoff 전 1회) | 자체 흐름에 자문 단계 없음 |
| DA `/run-da for_plan` | Step 5에서 무조건 호출 | `/prd` 자체에서는 호출 안 함 (사용자 의도) |
| 산출물 | `.claude/prds/prd-<feature>.md` | `.claude/prds/prd-<feature>.md` (동일) |

→ `for_prd` 모드는 인터뷰·anti-anchoring·DA 검증을 거친 뒤 `/prd`에 handoff하는 **front-door**다. 산출물 형식은 동일.
