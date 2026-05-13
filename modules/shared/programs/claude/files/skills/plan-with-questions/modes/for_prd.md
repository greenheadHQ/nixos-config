# Mode: for_prd

`plan-with-questions` 의 인터뷰, 검증, 자동 트리거 흐름을 거친 뒤 PRD 규약을 따라 `.claude/prds/` 에 PRD 파일을 직접 작성하는 모드다.

핵심 설계: PRD의 단일 SSOT는 `.claude/prds/` 디렉토리다. 본 모드가 (a) 자동 트리거와 opt-out, (b) P1-P5 인터뷰 / 자문과 P6-P7 DA, (c) PRD 작성과 갱신을 모두 담당한다. `.claude/plans/` 사본은 만들지 않는다 (단일 SSOT 유지).

## 진입 조건

세 가지 진입 경로가 있다:

1. 자동 트리거: `for_action` 의 Step 1-2 진행 중 [`../references/task-size-routing.md`](../references/task-size-routing.md) 의 트리거 알고리즘이 후보로 판정한다. 사용자 1회 알림 + opt-out을 통과하면 진입한다. 이슈 ref가 이미 resolve 된 상태에서 진입한다.
2. 명시 호출: `$ARGUMENTS` 첫 토큰이 `for_prd` 이고 두 번째 토큰이 이슈 ref (URL / 번호 / 이슈키) 인 경우다. for_action과 동일하게 이슈 resolve를 전제한다. 텍스트 설명만으로는 진입할 수 없다 (이슈 없는 PRD 작성은 for_issue로 이슈 등록 후 transition).
3. 재개: 기존 `.claude/prds/prd-<feature>.md` 파일이 있고 사용자가 동일 이슈 ref로 재호출하는 경우다. for_prd 모드가 기존 파일을 read 한 뒤 갱신 흐름을 따른다 (아래 "자연어 입력 처리" 섹션 참조).

## 차용 reference (직접 복제 금지)

| Reference | 용도 |
|-----------|------|
| [`../references/prd/prd-master-template.md`](../references/prd/prd-master-template.md) | Document Status + Phase Index + 본문 구조 |
| [`../references/prd/phase-template.md`](../references/prd/phase-template.md) | Phase Discovery Gate / Implementation / Validation / Exit Criteria |
| [`../references/prd/file-mode-selection.md`](../references/prd/file-mode-selection.md) | Single vs Split 자동 판정 |
| [`../references/validation-paths.md`](../references/validation-paths.md) | validation-path catalog (모든 모드 공통, 평면 위치) |
| [`../references/prd/multi-pass-review.md`](../references/prd/multi-pass-review.md) | Final 10-pass review (Post-Implementation 5번) |
| [`../references/review-impl/requirement-status.md`](../references/review-impl/requirement-status.md) | phase 종료 시 6-classification taxonomy (requirement → 구현 매핑, auto-fix 미적용) |
| [`../references/review-impl/implementation-review.md`](../references/review-impl/implementation-review.md) | Final review 시 PRD 10-pass에 얹는 review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류 delta) |

## 산출물 경로

- Single: `.claude/prds/prd-<feature>.md` 한 파일.
- Split: master `.claude/prds/prd-<feature>.md` + phase 파일 `.claude/prds/prd-<feature>/phase-NN-<name>.md`. master는 디렉토리 옆에 sibling으로 위치한다.

자동 판정의 단일 SSOT는 [`../references/prd/file-mode-selection.md`](../references/prd/file-mode-selection.md) 다. 상세 규칙은 [`../references/task-size-routing.md`](../references/task-size-routing.md#single-vs-split-자동-판정) 를 참조한다.

## 자연어 입력 처리

자연어로 PRD 작성, 갱신, review-only 작업을 요청하면 아래 흐름을 따른다. trigger 키워드 정의의 단일 SSOT는 [`../SKILL.md`](../SKILL.md#모드-판별) 의 "자연어 trigger → transition 매핑" 표다. 본 섹션은 mode-specific 동작만 명시한다:

- PRD 작성 의도 카테고리 — 신규 PRD: 기존 `.claude/prds/prd-<feature>.md` 가 없으면 본 모드 P1-P9 전체 흐름을 따른다 (인터뷰 / 자문 / DA → 사용자 승인 → P9에서 신규 PRD 작성).
- PRD 작성 의도 카테고리 — 기존 PRD 갱신: `.claude/prds/prd-<feature>.md` 가 있으면 기존 파일을 read 한 뒤 갱신 흐름을 따른다 (Discovery 결과로 영향받는 phase 또는 section만 수정. 완료 체크박스와 사용자 수정은 보존한다).
- review-impl 의도 카테고리: 세 가지 sub-case가 있다:
  - 이슈 ref가 있으면 for_action 모드로 진입한다. for_action 승인 후 Post-Implementation 5번 Final review 단계에서 [`../references/prd/multi-pass-review.md`](../references/prd/multi-pass-review.md) 의 PRD 10-pass + [`../references/review-impl/implementation-review.md`](../references/review-impl/implementation-review.md) overlay (6-classification 라벨링 + overbuilt 우선 분류) 를 적용한다 (auto-fix 미적용, NG-2).
  - 텍스트 설명만 있으면 for_issue 모드로 진입하여 이슈를 생성한다. for_issue 자체에는 Post-Implementation 7단계가 적용되지 않으므로 Final review가 즉시 실행되지 않는다. Step I-6에서 사용자가 후속으로 for_action 진입을 선택하면 그 사이클의 Post-Implementation 5번에서 PRD 10-pass + review-impl overlay가 적용된다.
  - for_prd의 phase-end review는 phase-template의 10-pass와 통합 적용한다.

## 흐름

`for_prd` 는 `for_action` 모드의 인터뷰 / 자문 / DA 흐름 (for_action의 Step 1-4 + Step 5-6) 을 차용하되, `for_action` 전용 plan 파일 초기화 단계 (for_action의 Step 4.5) 는 건너뛴다. P8 (승인 게이트) 통과 후 P9에서 PRD 규약 ([`../references/prd/prd-master-template.md`](../references/prd/prd-master-template.md) + [`../references/prd/phase-template.md`](../references/prd/phase-template.md)) 을 따라 `.claude/prds/` 에 직접 작성한다.

### P1-P5 + P6-P7 (for_action Step 1-4 + Step 5-6 차용)

[`for_action.md`](./for_action.md) 의 Step 1-4 와 Step 5-6 핵심 절차를 따른다. for_prd 단계 식별자는 `P1` ~ `P9` 로 순차 시프트한다 (for_action의 `Step 7` 과 식별자 충돌 방지). 단계별 차이는 다음과 같다:

- P1 (for_action Step 1 차용): 단독 트리거 신호와 보조 신호의 1차 평가다 (자동 트리거 가능성 검토).
- P2 (for_action Step 2 차용): 트리거 결정 시 사용자에게 알림과 opt-out 확인을 제공한다. 사용자 동의 시 Mode 전환 (`for_action` → `for_prd`).
- P3 (for_action Step 3 차용): 질문 수집과 불명확 점 정리다. for_action의 Step 3 과 동일 정책을 적용한다 (요구사항 불명확 점, 트레이드오프, 사이드이펙트, 인지 상태, XY Problem). PRD 컨텍스트에서는 phase 구조 후보도 함께 모은다.
- P4 (for_action Step 3.5 차용): 자문 입력에 phase 구조 후보를 포함한다 (PRD는 phase 단위 결정이 핵심이다). 자문 출력의 두 layer schema (`technical_matrix` + `user_facing`) 와 텍스트 복구 규칙의 단일 SSOT는 [`../references/consulting-step.md`](../references/consulting-step.md) 다.
- P5 (for_action Step 4 차용, 질문 정책 동일 적용): for_action의 Step 4 정책을 그대로 차용한다. 본 mode 파일은 정책 본문을 복제하지 않고 [`for_action.md` 의 트레이드오프 라운드 정책 절](./for_action.md#트레이드오프-라운드-정책) 을 callsite로 인용한다. `user_facing` layer 만 사용자에게 노출 + 옵션 표시 정책 (`plain_disqualifier` 표시) + 텍스트 복구 4단계의 단일 SSOT는 [`../references/consulting-step.md`](../references/consulting-step.md) 다. PRD가 multi-phase 여도 라운드당 하나의 질문은 유지한다.
- for_action Step 4.5 (plan 파일 초기화) 는 for_prd에서 skip 된다: `for_prd` 는 `.claude/plans/` 파일과 plan-file-template의 14 metadata를 만들지 않는다. for_prd는 정수 P-enum만 사용하며 `.5` suffix를 도입하지 않는다.
- P6 DA (for_action Step 5 차용): 기본은 [`../references/run-da-preflight-gate.md`](../references/run-da-preflight-gate.md) 를 적용한 후 `/run-da for_plan` 을 호출한다. preflight gate가 `run-da` 의 Review Intensity 체크리스트를 기계적으로 적용하고, 승인된 SKIP이 아니면 `/run-da for_plan` 으로 진행한다. DA 입력은 PRD draft 또는 context, candidate phase structure, P1-P5의 evidence 다 (plan 파일 path가 아니다). phase 4+ 복잡 plan에서 사용자가 명시적으로 exhaustive review를 원하면 `/run-da for_plan full` 을 사용한다 (full modifier는 인라인 체크리스트를 우회하고 8 도메인을 강제한다). 두 의미는 다르다.
- P7 DA 반영 (for_action Step 6 차용): DA 결과는 PRD draft 또는 context와 후보 phase 구조에 반영한다. PRD 작성 후에는 PRD master의 `Change Log` 와, split mode에서 특정 phase가 영향받는 경우 해당 phase의 `Discoveries / Decisions` 에 반영 이력을 남긴다.
- P6 / P7 resume: PRD 파일이 아직 없으면 DA draft 또는 context는 durable artifact가 아니다. 세션이 끊긴 뒤 재개하면 transient DA verdict를 신뢰하지 않고 `for_prd.p6_da` 부터 보수적으로 재실행한다. 재실행 사유는 PRD 작성 후 master의 `Change Log` 에 남긴다.

### P8: 사용자 승인 게이트

PRD 파일 작성 전에 명시 승인 게이트 필수 (`for_action` 의 Step 9 와 등가). 자동 PRD opt-out 동의가 곧장 commit 또는 PR write 동의로 확장되는 회귀를 방지한다 (#569 류 회귀).

승인 게이트의 절차:

1. 메인 에이전트가 P1-P5와 P6-P7 결과를 사용자에게 요약 제시한다:
   - PRD 후보 신호 (트리거 근거가 된 단독 트리거 신호 또는 보조 신호)
   - Resolved evidence + 사용자 답변 + P4 자문 매트릭스 요약
   - preflight 또는 DA outcome (승인된 SKIP이면 체크리스트 verdict + 사용자 승인. 아니면 DA findings + Arbiter 판정 핵심)
   - 후보 phase 구조 (3-6개) + 산출물 경로 (`.claude/prds/...`)
   - Post-Implementation 자동 수행 범위: [`../references/post-implementation.md`](../references/post-implementation.md) 의 1번 ~ 7번 (변경 구현, 구현 커밋, `/run-da for_pr`, `/parallel-audit`, Final review, 반영 커밋, `/create-pr`).
2. 승인 요청 도구로 사용자 승인을 요청한다. 사용자가 수정 요청하면 PRD draft 또는 context, 후보 phase 구조를 갱신한 뒤 다시 요청한다.
3. 승인이 곧 Post-Implementation 자동 수행 동의다 (tracked write, commit, PR write 포함). plan-with-questions의 신뢰 경계 SSOT는 [`../references/post-implementation.md#신뢰-경계-569-회귀-방지`](../references/post-implementation.md#신뢰-경계-569-회귀-방지) 다.

### P9: PRD 작성

승인이 통과한 경우에만 PRD 파일 작성으로 분기한다:

1. P1-P5에서 수집한 정보, P6-P7의 DA 결과, 승인된 후보 phase 구조를 정리한다.
2. [`../references/prd/prd-master-template.md`](../references/prd/prd-master-template.md) 를 따라 `.claude/prds/prd-<feature>.md` 에 master PRD를 작성한다. `<feature>` slug 안전 규칙의 단일 SSOT는 [`../references/prd/file-mode-selection.md`](../references/prd/file-mode-selection.md#경로-slug-안전-규칙) 다.
3. Split mode이면 [`../references/prd/phase-template.md`](../references/prd/phase-template.md) 를 따라 phase 파일들도 동일 실행에서 생성한다 (`.claude/prds/prd-<feature>/phase-NN-<name>.md`). `<name>` slug 안전 규칙도 같은 SSOT를 따른다.

PRD 작성과 갱신, phase 진행, Phase Discovery Gate 적용을 모두 본 모드가 책임진다. 별도 plan 파일 (`.claude/plans/`) 은 만들지 않는다.

### Post-Implementation 흐름 변형

PRD가 작성된 후 구현 단계는 [`../references/post-implementation.md`](../references/post-implementation.md) 의 7단계를 따른다. 추가 사항:

- 상세 review 흐름 (phase-end / Final / overbuilt 처리) 의 단일 SSOT는 [`../references/task-size-routing.md#review-impl-통합-시점`](../references/task-size-routing.md#review-impl-통합-시점) 이다. 본 mode 파일은 link만 두고 절차를 복제하지 않는다 (drift 방지).

PRD Closeout 조건은 `.claude/prds/` 에 작성됐으므로 자동 활성화된다 (이전 버전의 `.claude/plans/` mismatch는 본 변경으로 해소됨).

## 메타데이터

PRD 자체 메타데이터의 단일 SSOT는 [`../references/prd/prd-master-template.md`](../references/prd/prd-master-template.md) 의 Document Status 표다 (for_prd 모드가 적용한다). plan-with-questions의 [`../references/plan-file-template.md`](../references/plan-file-template.md) 의 14필드는 `for_action` 모드 전용이며, `for_prd` 에는 적용되지 않는다 (두 SSOT 병존 회피).

Resume From enum의 `for_prd.*` 항목 SSOT는 [`../references/resume-state.md`](../references/resume-state.md) 다. plan-with-questions가 PRD 작성 직전까지 도달한 단계를 기록할 때 사용한다. PRD 작성 후의 phase 진행은 PRD master의 Document Status가 추적한다.

## main-agent-only 경계

PRD 파일과 phase 파일은 모두 tracked write 이므로 메인 에이전트 전용이다. fan-out과 subagent 위임은 금지한다. PRD 10-pass + review-impl overlay 수행자도 read-only이며 적용은 메인이 수행한다. 단일 SSOT는 [`../../run-da/references/hardening-contract.md`](../../run-da/references/hardening-contract.md) 의 "Codex 세션 하드닝 계약" 절이다.

## for_prd 모드 특징

| 항목 | 값 |
|------|----|
| 입력 | 인터뷰 결과 + P4 자문 + PRD draft / context + 후보 phase 구조 + DA 판정 |
| 자동 트리거 | task-size-routing 알고리즘으로 후보 감지 |
| P4 외부 자문 | 트레이드오프 1+ 항목 시 (PRD 작성 전 1회) |
| DA `/run-da for_plan` | P6 preflight gate 후 호출 또는 승인된 SKIP |
| 산출물 | `.claude/prds/prd-<feature>.md` (split mode 면 phase 파일 추가) |

본 모드는 인터뷰, 외부 자문, DA 검증을 거쳐 `.claude/prds/` 에 PRD를 작성하는 단일 흐름이다.
