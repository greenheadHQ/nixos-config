---
name: plan-with-questions
argument-hint: "[for_action|for_issue|for_prd] [issue-ref (for_action/for_prd) | task description (for_issue)]"
description: |
  Structured planning with requirements clarification via iterative Q&A.
  Three modes: for_action (issue ref → plan), for_issue (idea → issue creation), for_prd (Living PRD with phase tracking — auto-detect for Phase ≥4 or 다중 도메인 + 보조 신호).
  Sole user-facing entry for PRD authoring/updates and implementation review.
---

# 스무고개식 계획 수립

`$ARGUMENTS` 는 이슈 레퍼런스 또는 작업 설명으로 수신한다.

이 스킬은 인터뷰 기반 스킬이라 질문 도구가 필수다. 런타임 도구 매핑, 용어 정의, 미지원 런타임 대응 정책의 단일 SSOT는 [`references/runtime-boundaries.md`](./references/runtime-boundaries.md) 다.

## Invariants (예외 없이 적용)

### 1. 질문 도구 의무

사용자에게 질문할 때는 질문 도구를 사용한다. 질문 도구가 지원되지 않는 런타임에서는 BLOCKED 처리한다. 미지원 런타임 대응 정책의 단일 SSOT는 [`references/runtime-boundaries.md`](./references/runtime-boundaries.md#질문-도구-미지원-대응) 다.

### 2. Black-box zero

계획에 모호한 부분이 남아 있으면 완성이 아니다. 사용자에게 묻기 전에 코드베이스를 충분히 탐색하여, 스스로 답할 수 있는 질문은 걸러낸다.

### 3. YAGNI / NGMI 제1원칙

계획의 각 단계에서 "이게 정말 필요한가?" 를 반복 검증한다. 자동 `run-da` review gate는 [`references/run-da-preflight-gate.md`](./references/run-da-preflight-gate.md) 를 통해서만 SKIP 후보가 될 수 있다. 자유 추론이나 silent skip은 금지한다.

### 4. 선 계획 파일 초기화 / 후 계획 추적

모드별 동작:

- for_action 모드: Step 1-4 는 일반 모드에서 수행한다. Step 4.5 에서 공식 `.claude/plans/<slug>.md` 파일을 먼저 초기화한다. Step 5-6 의 DA는 그 파일을 입력과 반영 대상으로 사용한다. 계획 추적 도구 진입은 Step 7 에서만 수행한다.
- for_issue 모드: 계획 추적 도구를 사용하지 않는다 (산출물이 이슈 그 자체다).
- for_prd 모드: `.claude/plans/` 를 사용하지 않는다 (PRD 파일이 추적 대상이다).

### 5. Single-writer / main-agent-only

tracked write, branch mutation, commit / push, GitHub write, `wt` / `nrs` / rebuild 계열은 reviewer / auditor subagent가 직접 실행하지 않는다. 정책의 단일 SSOT는 [`run-da/references/hardening-contract.md`](../run-da/references/hardening-contract.md) 의 "Codex 세션 하드닝 계약" 절이다.

### 6. Step 3.5 → Step 4 순서

트레이드오프 옵션이 1개 이상일 때 적용되는 순서다:

- Step 3.5 에서 외부 자문을 사용자 질문 전에 호출한다.
- 자문 결과 도착 후 Step 4 에서 anti-anchoring 4 규칙을 적용해 옵션을 사용자에게 제시한다. 4 규칙은 (a) 추천 라벨 합의 조건부 부착, (b) 옵션 셔플, (c) `user_facing.plain_disqualifier` 표시, (d) judgment-first 다.

라벨 정책과 anti-anchoring 알고리즘의 단일 SSOT는 [`references/consulting-step.md`](./references/consulting-step.md) 다. 본 Invariant 본문은 SSOT 참조만 두고 정책을 복제하지 않는다. modes/* 파일도 마찬가지로 SSOT를 link 로만 참조한다 (정책 본문 복제 금지).

codex exec 호출 명령의 단일 SSOT는 [`references/consulting-step-shell.md`](./references/consulting-step-shell.md) 다 (`consulting-step.md` 의 codex exec 호출 코드블록을 분리한 후속 파일). SKILL.md 본문과 modes/* 파일은 명령을 복제하지 않는다.

### 7. Living checkbox 갱신 의무

각 단계 (Phase Discovery Gate, Implementation Checklist, Validation Checklist, Exit Criteria, Phase-end review) 완료 즉시 plan / PRD 본문의 `- [ ]` 를 `- [x]` 로 갱신한다.

추가 제약:

- lazy / end-of-session bulk update 금지: Status, Resume From, Phase Progress 같은 헤더 메타데이터만 갱신하고 본문 체크박스를 미루는 self-optimization은 dogfooding 추적성을 깬다.
- 메인 LLM이 "헤더 메타데이터만 갱신해도 충분" 이라고 자체 판단하지 않는다.
- for_prd 모드에서 PRD master + active phase 파일의 체크박스는 단계 완료 즉시 본 스킬이 갱신한다.

### 8. 라운드당 하나의 질문 + 추천 라벨 합의 규칙

- 사용자 질문 도구 호출 시 `questions` 배열 길이는 1 로 강제한다. for_action의 Step 4, for_issue의 Step I-4, for_prd의 차용 단계 모두 동일 정책이다.
- 한 라운드에 여러 질문을 묶어 인지 부하를 일으키지 않는다.

트레이드오프 라운드 정책의 단일 SSOT는 [`references/consulting-step.md`](./references/consulting-step.md) 다. 본 Invariant는 SSOT의 일부 결과만 요약한다:

- `(Recommended)` 라벨은 후보가 정확히 1개로 좁혀진 합의 통과 옵션에만 부착한다.
- 질문 도구의 자동 권장 convention은 본 스킬 컨텍스트에서 무시한다.
- judgment-first 사전 라운드는 합의 알고리즘을 실행하지 않으며 어떤 옵션에도 라벨을 부착하지 않는다 (anti-anchoring 효과 보호).

## 모드 판별

다음 우선순위 표를 위에서 아래로 적용한다:

| 우선순위 | 조건 | 모드 |
|----------|------|------|
| 1 | `$ARGUMENTS` 첫 토큰이 `for_action` / `for_issue` / `for_prd` | 명시된 모드 |
| 2 | URL 패턴 (`https://...`, `http://...`) 포함 | for_action |
| 3 | 이슈 번호 패턴 (`#NNN`, `NNN` 만 단독) 포함 | for_action |
| 4 | 이슈키 패턴 (`PREFIX-NNN`, 예: `DEV-123`) 포함 | for_action |
| 5 | for_action 진입 후 Step 1-2 에서 `Phase ≥4` 단독 또는 (`다중 도메인` + 보조 신호 1+) 감지 | for_prd 후보 (사용자 1회 알림 + opt-out) |
| 6 | 위 패턴 없음 (텍스트 설명 또는 빈 인자) | for_issue: 자연어 trigger 의도가 명확하면 Step I-6에서 매칭 모드로 transition |

우선순위 5 의 감지 알고리즘 의사코드 단일 SSOT는 [`references/task-size-routing.md`](./references/task-size-routing.md#트리거-알고리즘-의사코드) 다.

### 자연어 trigger → transition 매핑

우선순위 6 으로 for_issue에 진입한 뒤 Step I-6에서 분기 판정에 사용하는 표다:

| 자연어 trigger 카테고리 | Step I-6 transition 권장 |
|-------------------------|--------------------------|
| PRD 작성 의도 | for_prd 직접 진입 |
| review-impl 의도 | for_action 진입 + Final review에서 review-impl overlay |
| 일반 텍스트 (위 카테고리 미매칭) | for_action transition 또는 write-handoff / 종료 |

각 카테고리의 자연어 trigger 예시와 전환 시 적용되는 정책은 다음과 같다:

- PRD 작성 의도: trigger 예시는 `PRD 작성`, `Living PRD`, `phase 계획`, `기능 스펙 정리`, `Discovery Gate 있는 계획서`, `PRD 업데이트` 등이다. 이슈 ref와 PRD 의도가 결합하여 의도가 명확한 경우 for_prd 모드로 직접 진입한다. 또는 for_action 진입 후 Step 1-2 의 baseline 분석에서 Phase ≥4 가 감지되면 우선순위 5 의 자동 PRD 후보 알림이 발동된다.
- review-impl 의도: trigger 예시는 `구현 감사`, `문서 대비 구현 리뷰`, `스펙 대비 감사`, `overbuilt 검사`, `PRD phase 완료 확인` 등이다. for_action 모드로 진입하되 Post-Implementation의 5번 Final review에서 PRD 10-pass + review-impl overlay (6-classification + overbuilt 우선 분류) 를 적용한다.
- 일반 텍스트: 위 카테고리에 매칭되지 않는 텍스트다. Step I-6의 표준 옵션 (for_action transition, write-handoff, 종료) 에서 사용자 선택을 받는다.

이 매핑은 우선순위 6 의 후속 분기를 명시한다. 모드 판별 자체는 우선순위 1-5 가 담당한다. transition은 사용자 입력 시점의 자연어 trigger 카테고리만으로 결정한다. 이슈 본문에는 별도 marker를 추가하지 않는다 (for_action Step 1-2 의 Phase ≥4 감지가 baseline 분석 자체로 작동하기 때문이다).

### 이슈 레퍼런스 resolve

특정 이슈 트래커 CLI에 의존하지 않는다. 환경에서 사용 가능한 도구 (gh CLI, Linear API / MCP, 웹 검색 등) 를 활용한다.

### 자동 PRD 후보 알림

알림 메시지 본문과 opt-out 패턴의 단일 SSOT는 [`references/output-templates.md`](./references/output-templates.md#for_prd-모드-자동-트리거-알림-메시지) 다. 트리거 알고리즘 (단독 트리거 신호, 다중 도메인 / 보조 신호 조합, 의사코드), 산출물 경로 결정, review-impl 통합 시점의 단일 SSOT는 [`references/task-size-routing.md`](./references/task-size-routing.md) 다.

## 빠른 참조

각 모드의 입출력과 단계 흐름을 한 눈에 비교하는 표다:

| 항목 | for_action | for_issue | for_prd |
|------|------------|-----------|---------|
| 입력 | 이슈 레퍼런스 (URL / ID / 이슈키) | 텍스트 설명 또는 빈 인자 | 이슈 레퍼런스 (for_action과 동일) |
| 출력 | 사용자 승인을 받은 계획 파일 (`.claude/plans/<slug>.md`) | 등록된 이슈 (+ 선택적 LLM 이행 가이드) | Living PRD (`.claude/prds/prd-<feature>.md` 또는 split) |
| 단계 흐름 | [`modes/for_action.md`](./modes/for_action.md) | [`modes/for_issue.md`](./modes/for_issue.md) | [`modes/for_prd.md`](./modes/for_prd.md) |
| DA | preflight gate 후 for_plan 실행 또는 승인된 SKIP (Step 5) | 생략 | preflight gate 후 for_plan 실행 또는 승인된 SKIP. phase 별 6-classification. Final PRD 10-pass + review-impl overlay |
| Step 3.5 외부 자문 | 트레이드오프 1+ 항목 시 | 트레이드오프 1+ 항목 시 | 트레이드오프 1+ 항목 시 (PRD 작성 전 1회) |
| 계획 추적 도구 | 사용 (Step 7-9. Step 4.5 에서 공식 plan 파일 선초기화) | 사용 안 함 (산출물이 이슈) | 사용 안 함 (PRD 파일이 추적 대상) |
| 제1원칙 | YAGNI / NGMI | YAGNI / NGMI | YAGNI / NGMI |

for_prd의 입력 정의 보충: 자동 후보 진입과 명시 호출 모두 이슈 ref를 전제로 한다.

## 단계 흐름 — 모드별 분리

상세 단계 흐름은 모드 파일에서 정의한다 (1-depth 원칙). 본 SKILL.md에서는 각 모드의 단계 시퀀스를 요약만 한다:

- for_action 모드: [`modes/for_action.md`](./modes/for_action.md) 가 SSOT 다. 시퀀스는 Step 1 (이슈 유효성) → Step 2 (탐색 + 재현) → Step 3 (질문 수집) → Step 3.5 (트레이드오프 1+ 시 외부 자문, background 병렬) → Step 4 (사용자 질문) → Step 4.5 (공식 plan 파일 초기화) → Step 5-6 (DA + 같은 파일 반영) → Step 7 (계획 추적 진입 + 기존 파일 바인딩) → Step 8 (계획 파일 review / refine) → Step 9 (승인 요청) 이다.
- for_issue 모드: [`modes/for_issue.md`](./modes/for_issue.md) 가 SSOT 다. 시퀀스는 Step I-1 (fan-out) → Step I-2 (fan-in) → Step I-3 (블랙박스 체크리스트) → Step I-3.5 (외부 자문, 트레이드오프 있을 시) → Step I-4 (스무고개 루프) → Step I-5 (이슈 생성) → Step I-6 (for_action 전환 제안) 이다.
- for_prd 모드: [`modes/for_prd.md`](./modes/for_prd.md) 가 SSOT 다. for_action의 인터뷰 / 자문 / DA 흐름을 차용하되 단계 식별자를 P-enum으로 시프트한다.

for_prd의 단계 매핑은 다음과 같다:

- P1 = Step 1
- P2 = Step 2
- P3 = Step 3
- P4 = Step 3.5
- P5 = Step 4
- Step 4.5 (plan 파일 초기화) 는 for_prd에서 skip 된다
- P6 = Step 5
- P7 = Step 6
- P8 = 사용자 승인 게이트 (for_prd 전용)
- P9 = `.claude/prds/` 에 PRD 파일 직접 작성 (for_prd 전용)

Implementation 단계에서는 phase 종료 시 6-classification을 적용한다. Final 단계에서는 PRD 10-pass와 review-impl overlay (6-classification + overbuilt 우선) 를 적용한다.

승인 후 자동 절차의 단일 SSOT는 [`references/post-implementation.md`](./references/post-implementation.md) 의 1번 ~ 7번이다. 사용자 stop 또는 하위 스킬 BLOCKED 외에는 자유 생략을 금지한다 (#453 / #569 회귀 방지).

## Reference Index (progressive disclosure)

핵심 reference 파일과 용도:

| 파일 | 용도 |
|------|------|
| [`references/runtime-boundaries.md`](./references/runtime-boundaries.md) | 지원 런타임 / 용어 / 도구 매핑 / 미지원 대응 SSOT |
| [`references/fanout-fanin.md`](./references/fanout-fanin.md) | 역할 카탈로그 + 런타임 분기 + fan-in 통합 전략 |
| [`references/run-da-preflight-gate.md`](./references/run-da-preflight-gate.md) | 자동 run-da 호출 전 SKIP gate + 질문 도구 승인 / 승격 규칙 |
| [`references/da-integration.md`](./references/da-integration.md) | Step 5 호출 계약 + Step 6 결과 반영 상태표 |
| [`references/post-implementation.md`](./references/post-implementation.md) | 7단계 자동 진행 + 자유 생략 금지 신뢰 경계 |
| [`references/output-templates.md`](./references/output-templates.md) | 사용자 메시지 / 체크리스트 / 질문 패턴 / anti-anchoring 규칙 |
| [`references/consulting-step.md`](./references/consulting-step.md) | Step 3.5 입출력 schema + anti-anchoring 4 규칙 + 추천 라벨 합의 알고리즘 (단일 SSOT) |
| [`references/consulting-step-shell.md`](./references/consulting-step-shell.md) | Step 3.5 codex exec 호출 명령 (단일 SSOT, consulting-step.md에서 분리한 코드블록) |
| [`references/plan-file-template.md`](./references/plan-file-template.md) | 14 metadata 필드 + Decision Log SSOT |
| [`references/resume-state.md`](./references/resume-state.md) | Resume From enum 카탈로그 + baseline drift 검증 |
| [`references/task-size-routing.md`](./references/task-size-routing.md) | for_prd 자동 트리거 알고리즘 + 산출물 경로 + review-impl 통합 시점 |

PRD / review-impl reference (모든 모드 공용 또는 for_prd 전용):

| 파일 | 사용처 |
|------|--------|
| [`./references/validation-paths.md`](./references/validation-paths.md) | 검증 수단 선택 (모든 모드) |
| [`./references/prd/multi-pass-review.md`](./references/prd/multi-pass-review.md) | Post-Implementation 5번 Final review |
| [`./references/prd/prd-master-template.md`](./references/prd/prd-master-template.md) | for_prd 모드 PRD master 구조 |
| [`./references/prd/phase-template.md`](./references/prd/phase-template.md) | for_prd 모드 phase 단위 |
| [`./references/prd/file-mode-selection.md`](./references/prd/file-mode-selection.md) | for_prd Single vs Split |
| [`./references/review-impl/requirement-status.md`](./references/review-impl/requirement-status.md) | review-impl 6-classification taxonomy (requirement → 구현 매핑) |
| [`./references/review-impl/implementation-review.md`](./references/review-impl/implementation-review.md) | review-impl overlay (PRD 10-pass에 얹는 6-classification 라벨링 + overbuilt 우선 분류 delta. auto-fix는 적용하지 않음) |

## 주의사항

- 블랙박스 제로 원칙: Invariant 2 를 따른다.
- 자유 생략 금지: 메인 LLM은 Post-Implementation 1번 ~ 7번 중 어떤 단계도 자유 판단으로 생략하지 않는다. 자동 `/run-da` gate의 SKIP은 [`references/run-da-preflight-gate.md`](./references/run-da-preflight-gate.md) 의 체크리스트 + 질문 도구 승인 경로에서만 가능하다. "범위 대비 비용 과도" 같은 메인 LLM 자체 판단은 사용자 stop이 아니다 (#453 회귀 방지).
- 승인 의미 명확화: 계획 승인은 Post-Implementation 자동 진행 동의로 간주된다. 그 범위 (tracked write, commit, PR write) 를 plan의 Step 8 에 명시한다 (#569 회귀 방지).
- 기존 패턴 존중: 코드베이스에 이미 확립된 패턴을 먼저 파악한다. 계획은 기존 패턴과 일관되도록 작성한다.
- 질문은 빠짐없이, 단 라운드당 하나만: "사용자가 귀찮아하지 않을까" 를 걱정하지 않는다. 발견한 모든 불명확 점을 누락 없이 묻는다. 다만 Invariant 8 에 따라 한 라운드에 하나의 질문만 둔다. 이유는 인지 부하와 turn_abort 위험을 줄이기 위해서다.
