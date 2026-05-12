# Plan File Template (`.claude/plans/<slug>.md`)

`for_action` 모드 산출물의 표준 형식. 14 metadata 필드 + Decision Log + 본문 구조. [`./prd/prd-master-template.md`](./prd/prd-master-template.md)의 Document Status를 차용했지만 plan-with-questions 단일 파일에 맞게 압축한다.

## 적용 범위

- for_action: 14필드를 모두 작성한다. PRD 전용 필드(`Current Phase`, `Phase Progress`, `Active Phase File`)는 `N/A`로 명시한다.
- for_prd 모드: 본 template은 미적용한다. PRD의 단일 SSOT는 for_prd 모드가 [`./prd/prd-master-template.md`](./prd/prd-master-template.md) 를 따라 `.claude/prds/` 에 직접 작성하는 것이다 (두 SSOT 병존 회피). Resume From enum (`for_prd.*`) 은 PRD 작성 직전까지의 진행 단계 추적 용도로만 쓴다.
- for_issue: 산출물이 이슈이므로 본 template 미적용. plan 파일이 없으므로 Resume From 메커니즘은 issue body에 inline (write-handoff가 처리).

## 14 Metadata 필드 (plan 상단 — Document Status 표)

```markdown
## Document Status

| 필드 | 값 |
|------|-----|
| Status | <Status enum> |
| Mode | for_action |
| Source | <이슈 ref 또는 텍스트 설명> |
| Plan File | <self-referential path> |
| Resume From | <Resume From enum 값> |
| Last Completed Step | <마지막 완료 단계 식별자> |
| Current Phase | <Phase N> 또는 N/A |
| Phase Progress | <X/Y 완료> 또는 N/A |
| Active Phase File | <split mode일 때 phase 파일 링크> 또는 N/A |
| Last Updated | YYYY-MM-DD |
| Baseline | branch=<name>, HEAD=<자연어 anchor>, dirty=<clean 또는 자연어 요약> |
| External Consult | <Step 3.5 자문 회차 자연어 요약 + decision_id list + verdict 요약. 임시 경로 리터럴 박제 금지> |
| DA State | <PRE_DA | RUNNING | APPLYING | CONFIRMED | SKIPPED | BLOCKED | NEEDS_USER> |
| Pending User Questions | <count> (link to high-impact) |
```

### Step 4.5 초기값 (for_action)

`for_action` Step 4.5에서 공식 plan 파일을 처음 만들 때 다음 값을 채운다:

| 필드 | 초기값 |
|------|--------|
| Status | `Draft` |
| Mode | `for_action` |
| Source | resolve된 이슈 ref 또는 URL |
| Plan File | self-referential path (`.claude/plans/<slug>.md`) |
| Resume From | `for_action.step5_da` |
| Last Completed Step | `for_action.step4_user_questions` |
| Current Phase | `N/A` |
| Phase Progress | `N/A` |
| Active Phase File | `N/A` |
| Last Updated | 현재 날짜 (`YYYY-MM-DD`) |
| Baseline | `branch=<name>, HEAD=<자연어 anchor>, dirty=<clean 또는 자연어 요약>` |
| External Consult | Step 3.5 자문 회차 자연어 요약 + decision_id list + verdict 요약 또는 `N/A` (임시 경로 리터럴 박제 금지) |
| DA State | `PRE_DA` |
| Pending User Questions | `0` |

### Status enum

- `Draft` — 작성 시작, 사용자 승인 전
- `Clarifying` — Step 3-4 사용자 질문 진행 중
- `Waiting On User` — 사용자 답변 대기
- `Approved` — Step 9 승인 완료, Post-Implementation 진입
- `Implementing` — Post-Implementation 1-2 진행 중
- `Validating` — Post-Implementation 3-5 진행 중 (DA / parallel-audit / 10-pass)
- `Blocked` — 하위 스킬 BLOCKED 또는 사용자 stop
- `Complete` — Post-Implementation 7 완료, PR 생성됨
- `Superseded` — 이 plan이 다른 plan으로 대체됨 (`Superseded By: <path>` 필드 추가)

### Mode 값

`for_action` 전용. `for_prd` 는 본 template 미적용이며, PRD의 단일 SSOT는 [`./prd/prd-master-template.md`](./prd/prd-master-template.md) 다. for_prd 자동 트리거 시 plan-with-questions는 `.claude/prds/` 에 직접 작성하고 본 template 산출물은 만들지 않는다.

### Resume From / Last Completed Step

기계적 식별자. 카탈로그·enum은 [`resume-state.md`](./resume-state.md) SSOT.

### Baseline

재개 시 drift 검증용. plan 파일은 durable artifact이므로 짧은 commit 식별자나 diff digest를 직접 박지 않는다. `HEAD`는 사람이 git log와 작업 맥락으로 다시 해석할 수 있는 자연어 anchor로 쓴다. 예: `branch=feat/foo, HEAD=PR #123 머지 직후, dirty=clean` 또는 `branch=issue/659, HEAD=작업 시작 직전 main, dirty=uncommitted: PRD draft only`. anchor나 dirty 상태를 안전하게 비교할 수 없으면 [`resume-state.md`](./resume-state.md)에 따라 Step 1-2를 다시 실행하거나 사용자 판단을 요청한다.

### External Consult

Step 3.5 자문 결과의 자문 회차 자연어 요약(예: "1차 자문(전체 N결정)") + 핵심 `decision_id` list + verdict 요약. plan 파일은 자문 raw output을 인라인 복제하지 않으며, temporary scratch consult output 리터럴도 박지 않는다. 임시 경로는 세션 종료 시 사라지는 ephemeral identifier이며, durable output 적합성은 작성자가 본 prose 가이드와 CLAUDE.md `Durable output pinning policy`를 직접 따르는 형태로 보장한다 — `pinning-patterns.sh`의 hard-fail enforcement는 라운드 카운터·DA finding ID·DA 키워드만 잡고 임시 경로 hex는 잡지 않는다. 셸 호출 사이의 `CONSULT_DIR` 리터럴 재사용은 runtime 요구이지만 durable plan에는 기록하지 않는다는 경계를 분리해 적용한다.

### DA State 값

- `PRE_DA`: Step 4.5 초기 상태. 아직 Step 5 DA를 시작하지 않음.
- `RUNNING`: Step 5 외부 검토를 시작했으나 durable verdict가 plan 파일에 반영되지 않음. 이 상태에서는 `Change Log`에 외부 검토 시작 상태를 자연어로 기록해야 하며, 개별 run 상관관계 값은 durable output에 쓰지 않는다.
- `APPLYING`: Step 5 verdict를 수신했고 Step 6 반영 중. 이 상태에서는 `Resume From=for_action.step6_da_apply`와 durable verdict summary 또는 stable artifact name이 `Change Log`에 있어야 한다.
- `CONFIRMED`: Step 6 반영이 완료되고 다음 단계로 진행 가능.
- `SKIPPED`: plan-mode Step 5에서 `run-da` Review Intensity 체크리스트가 SKIP을 판정했고 질문 도구 사용자 승인이 기록됨. 질문 도구 미지원 또는 사용자 거부로 승격한 경우는 `SKIPPED`가 아니다.
- `BLOCKED`: DA 또는 selective consistency 상태가 BLOCKED.
- `NEEDS_USER`: DA 결과 반영에 사용자 판단이 필요함.

알 수 없는 값은 안전하게 해석하지 않고 `NEEDS_USER` 또는 `BLOCKED`로 처리한다.

## 본문 구조

```markdown
# Plan: <one-line title>

## Document Status
<14필드 표>

## Problem (배경)
<측정된 pain points / 이슈 요약 / 정량 통계>

## Goals
- G-1: ...

## Non-Goals
- NG-1: ...

## Success Criteria
- SC-1: <관측 가능한 outcome>

## Decisions
<주요 결정 + 근거. Step 4 사용자 답변 + Step 3.5 자문 + Step 5/6 DA 반영>

### D-N: <decision>
- 결정: ...
- 근거: ...

## 변경 대상 파일
| 파일 | 라인 수 | 수정 범위 |
|------|--------|-----------|

## 실행 순서
<의존 관계 고려한 작업 순서>

## Validation Strategy
<risk-appropriate mix — `~/.claude/skills/plan-with-questions/references/validation-paths.md` catalog 인용>

## 사이드이펙트 + 대응
| 영향 | 대응 |
|------|------|

## 롤백 가능성
<git revert 단위, force push 금지 명시>

## Open Questions
- [ ] <stub status / unresolved>

## Decision Log (ADR 미니)
<중요 방향 전환만. 형식은 아래 섹션>

## Change Log
- YYYY-MM-DD: ...
```

## Decision Log (ADR 미니, plan 하단 별도 섹션)

`Decision Log`는 `Change Log`와 다르다:

- Change Log: 모든 plan 갱신을 날짜별 append-only로 기록 (가벼움).
- Decision Log: 중요한 방향 전환만 ADR 미니 형식으로 기록 (불변, superseded 보존).

### 형식

```markdown
### DL-N: <decision summary>

- Status: proposed | accepted | superseded
- Context: 왜 이 결정이 필요했는가 (1-3 문장).
- Decision: 무엇을 결정했는가 (1-2 문장).
- Consequences: 의도된 영향 + 예측되는 trade-off (2-4 bullet).
- External Consult: <Step 3.5 자문 회차 자연어 요약 + decision_id list + verdict 요약 — 자문이 결정에 영향을 준 경우만. 임시 경로 리터럴 박제 금지>
- Superseded By: DL-M (해당 시)
```

### 사용처 (필수 기록)

1. 사용자 선택 번복: Step 4에서 사용자가 옵션 A를 골랐다가 Step 6 DA 또는 후속 단계에서 옵션 B로 바뀐 경우.
2. Step 5/6 DA 결과 반영: `CONFIRMED_ISSUE`로 핵심 메커니즘 재설계, DA로 인한 confirmed rejection, `BLOCKED`/`NEEDS_USER` 전이.
3. 재개 시 baseline drift 감지: git HEAD 변경으로 Step 1-2 재실행이 트리거된 경우.
4. mode 전환: `for_action` → `for_prd` 자동 후보 알림 + 사용자 승인 또는 거부 (승인 시 PRD 규약을 따라 `.claude/prds/`에 직접 작성, 본 template 사용 중단).
5. Step 3.5 자문 결과로 옵션 변경: 메인 LLM 1차 후보가 자문 disqualifier로 폐기된 경우.

### 사용처 (생략 가능)

- 사소한 wording 변경, 오타 수정, 의존성 없는 파일 추가.
- Validation 항목 한 줄 보강.
- Open Questions 정리.

생략 가능 항목은 `Change Log`에만 기록한다.

### 불변 원칙

- 기존 `DL-N` 본문을 덮어쓰지 않는다.
- 결정이 바뀌면 `DL-N.Status = superseded` + `Superseded By: DL-M` 추가, 새 `DL-M` 작성.
- `accepted` 상태 DL은 plan 파일 끝까지 보존한다 (이력 추적).

## 작성 규칙

- `Last Updated`와 `Change Log`는 동일 날짜로 동기화한다.
- 사용자 수정(체크박스 ✓, Status 변경 등)은 보존한다 — 메인 LLM이 자동으로 되돌리지 않는다.
- 중요 scope를 조용히 삭제하지 않는다. Non-Goals로 이동, Open Questions에 deferred로 명시, 또는 Decision Log에 supersede 기록.
- `[UNVERIFIED]` 라벨은 직접 확인하지 못한 사실에만 적용한다. 라벨 체계는 [`../../write-handoff/references/llm-friendly-checklist.md`](../../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) SSOT.

## 작성 시점

- Step 4.5 (공식 plan 파일 초기화): 14필드 초기값 + Step 1-4 evidence 기반 최소 본문 + Change Log 첫 줄.
- Step 5/6 외부 검토 실행/반영: 같은 plan 파일의 `DA State`, `Resume From`, 본문, `Decision Log`, `Change Log`를 갱신한다. 시작 직전 `RUNNING` + 자연어 시작 상태, verdict 수신 직후 `APPLYING` + `Resume From=for_action.step6_da_apply` + durable verdict summary 또는 stable artifact name, 반영 완료 시 `CONFIRMED`/`SKIPPED`/`BLOCKED`/`NEEDS_USER` 중 하나로 기록한다. 개별 run 상관관계 값은 runtime-only로 유지하고 durable output에는 남기지 않는다. 늦은 verdict는 stale result로 `Change Log`에만 남기고 반영하지 않는다.
- Step 7 계획 추적 진입: Step 4.5의 기존 plan 파일을 추적 상태에 바인딩한다. 새 파일을 만들지 않는다.
- Step 8 (계획 파일 review/refine): 기존 plan 파일의 본문, Decision Log, Post-Implementation 자동 수행 범위를 승인 가능한 수준으로 정리한다.
- Step 9 승인 후: Status `Approved` → `Implementing`. Last Updated 갱신.
- Post-Impl 각 단계 완료 시: Last Completed Step / Resume From / Change Log를 갱신한다. Post-Implementation `/run-da for_pr` 결과는 Change Log 또는 resume note에만 기록하고, plan-mode Step 5/6 상태인 `DA State`를 덮어쓰지 않는다.
- 재개 시: Baseline 비교 → drift 시 DL 추가 + Status `Implementing`로 복원.
