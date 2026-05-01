# Plan File Template (`.claude/plans/<slug>.md`)

`for_action` 모드 산출물의 표준 형식. 14 metadata 필드 + Decision Log + 본문 구조. `/prd` master template의 Document Status를 차용했지만 plan-with-questions 단일 파일에 맞게 압축한다.

## 적용 범위

- **for_action**: 14필드 중 PRD 전용 필드(`Current Phase`, `Phase Progress`, `Active Phase File`)는 N/A 또는 생략.
- **for_prd**: 본 template **미적용**. PRD 정본은 `/prd` 스킬이 작성하며 `prd/references/prd-master-template.md`의 Document Status가 정본이다 (두 SSOT 병존 회피). plan-with-questions의 Resume From enum (`for_prd.*`)은 `/prd` 호출 직전까지의 진행 단계 추적 용도로만 쓴다.
- **for_issue**: 산출물이 이슈이므로 본 template 미적용. plan 파일이 없으므로 Resume From 메커니즘은 issue body에 inline (write-handoff가 처리).

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
| Baseline | branch=<name>, HEAD=<sha7>, dirty=<clean|hash> |
| External Consult | <Step 3.5 result.json 경로 또는 요약> |
| DA State | <Pre-DA | Round N | CONFIRMED | NEEDS_MORE_INFO> |
| Pending User Questions | <count> (link to high-impact) |
```

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

`for_action` 전용. `for_prd`는 본 template 미적용 (`/prd` 스킬이 정본 owner) — for_prd 자동 트리거 시 plan-with-questions는 `/prd`로 handoff하고 본 template 산출물을 만들지 않는다.

### Resume From / Last Completed Step

기계적 식별자. 카탈로그·enum은 [`resume-state.md`](./resume-state.md) SSOT.

### Baseline

재개 시 drift 검증용. 형식 예: `branch=feat/foo, HEAD=abc1234, dirty=clean` 또는 `dirty=<sha1 of git diff>`. 알고리즘은 [`resume-state.md`](./resume-state.md) 참조.

### External Consult

Step 3.5 자문 결과의 `result.json` 경로 또는 핵심 decision_id list. plan 파일은 자문 raw output을 인라인 복제하지 않는다 (별도 path 또는 git ignored 임시 파일).

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
<risk-appropriate mix — `prd/references/validation-paths.md` catalog 인용>

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

- **Change Log**: 모든 plan 갱신을 날짜별 append-only로 기록 (가벼움).
- **Decision Log**: **중요한 방향 전환**만 ADR 미니 형식으로 기록 (불변, superseded 보존).

### 형식

```markdown
### DL-N: <decision summary>

- **Status**: proposed | accepted | superseded
- **Context**: 왜 이 결정이 필요했는가 (1-3 문장).
- **Decision**: 무엇을 결정했는가 (1-2 문장).
- **Consequences**: 의도된 영향 + 예측되는 trade-off (2-4 bullet).
- **External Consult**: <Step 3.5 result.json 경로 또는 요약 — 자문이 결정에 영향을 준 경우만>
- **Superseded By**: DL-M (해당 시)
```

### 사용처 (필수 기록)

1. **사용자 선택 번복** — Step 4에서 사용자가 옵션 A를 골랐다가 Step 6 DA 또는 후속 단계에서 옵션 B로 바뀐 경우.
2. **DA Round 큰 설계 변경** — `CONFIRMED_ISSUE`로 핵심 메커니즘 재설계.
3. **재개 시 baseline drift 감지** — git HEAD 변경으로 Step 1-2 재실행이 트리거된 경우.
4. **mode 전환** — `for_action` → `for_prd` 자동 후보 알림 + 사용자 승인 또는 거부 (승인 시 `/prd`로 handoff하고 본 template 사용 중단).
5. **Step 3.5 자문 결과로 옵션 변경** — 메인 LLM 1차 후보가 자문 disqualifier로 폐기된 경우.

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

- **Step 8 (계획 작성)**: 14필드 + 본문 + 초기 Decision Log (D-1~D-N) + Change Log 첫 줄.
- **Step 9 승인 후**: Status `Approved` → `Implementing`. Last Updated 갱신.
- **Post-Impl 각 단계 완료 시**: Last Completed Step / Resume From / DA State 갱신.
- **재개 시**: Baseline 비교 → drift 시 DL 추가 + Status `Implementing`로 복원.
