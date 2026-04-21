---
name: prd
argument-hint: "[feature-name or PRD file path (optional)]"
description: |
  Use this skill when the user wants to create or update a feature PRD, product/technical spec, or phase-based execution plan stored under `.claude/prds/`. Covers intents like "PRD 만들어", "이 기능 스펙 정리", "기능 명세 작성", "phase 계획", "Discovery Gate 있는 계획서", evidence-backed living spec, or turning a feature idea into a junior-executable document with discovery, phases, validation, and multi-pass review.

  Trigger whenever the user frames the work as writing or revising a structured feature document — whether they call it PRD, spec, 명세, 기획서, phase plan, or execution plan — especially when phases, discovery gates, or validation criteria are mentioned.

  NOT for quick one-off implementation plans without spec structure (use plan-with-questions). NOT for Devil's Advocate review (use run-da). NOT for auditing implementation against an existing spec (use review-implementation).
---

# Evidence-Backed Living PRD

기존 시스템 위에서 근거로 뒷받침된 compact PRD를 만들거나 갱신한다. 주니어 개발자 또는 fresh AI agent가 실행 가능한 수준으로 명시적이며, living source of truth로 설계한다. 작업은 PRD 안에서 체크 off 되고, 구현이 새 정보를 드러내면 뒤 phase가 수정되며, 모든 phase는 구조적 validation + review로 끝난다.

사용자가 명시적으로 요청하지 않는 한 기능 자체를 구현하지 않는다. 본 스킬은 PRD / context / phase 파일을 생성·갱신하는 데만 쓴다.

## 빠른 참조

| 항목 | 위치 |
|------|------|
| Master PRD 템플릿 | [./references/prd-master-template.md](./references/prd-master-template.md) |
| Phase 템플릿 (Discovery Gate + Implementation + Validation + Exit + Phase-End 10-pass) | [./references/phase-template.md](./references/phase-template.md) |
| Final 10-pass Review | [./references/multi-pass-review.md](./references/multi-pass-review.md) |
| File mode (Single / Split) 자동 선택 | [./references/file-mode-selection.md](./references/file-mode-selection.md) |
| Validation-path catalog (공용) | [./references/validation-paths.md](./references/validation-paths.md) |

## 경로 규약

- 저장 경로: `.claude/prds/prd-[feature-name].md` (Single) 또는 `.claude/prds/prd-[feature-name]/` 디렉토리 (Split).
- upstream agent-skills 원본의 `tasks/...` 경로는 본 정본에서 사용하지 않는다 (nixos-config `.claude/` 규약에 정렬).
- `.claude/prds/` 디렉토리는 본 스킬이 PRD 파일을 처음 쓸 때 자동 생성한다. 빈 `.gitkeep`은 커밋하지 않는다.

## main-agent-only 경계

본 스킬은 `.claude/prds/` 하위 파일에 대한 tracked write(신규 생성·갱신)를 수행한다. 따라서 메인 에이전트 전용이다. 서브에이전트(run-da reviewer/Arbiter/Intensity, parallel-audit auditor, review-implementation review subprocess)에 PRD 작성·수정을 위임하지 않는다. `nrs`/`verify-ai-compat.sh`/commit/push/GitHub write 역시 메인 에이전트가 직접 수행한다.

상세 계약은 [`../run-da/SKILL.md`](../run-da/SKILL.md)의 `Codex 세션 하드닝 계약` 섹션을 따른다.

## Core Rules

- 항상 `.claude/prds/` 하위 마크다운 파일을 생성하거나 갱신한다. chat만으로 답하지 않는다.
- **Evidence에서 시작한다.** 설계 전에 관련 코드·test·docs·config·API·공식 외부 참조를 관찰한다.
- 실행 구조는 **phase**를 쓴다. 시나리오/유저 스토리는 product context용으로만 쓴다.
- Master PRD는 compact하게 유지한다. 큰 plan은 linked context와 phase 파일로 분리한다 (자동 선택 룰: [`./references/file-mode-selection.md`](./references/file-mode-selection.md)).
- discovery, implementation, validation, review, 완료에 markdown 체크박스(`- [ ]`, `- [x]`)를 사용한다.
- 모든 요구사항·체크리스트 항목은 구체적이고 검증 가능하며 하나의 focused 실행 task가 될 만큼 작게 쪼갠다.
- 자율 진행을 선호한다. 본질적 unknown만 질문한다. 그 외는 합리적 판단 + assumption 기록 + 계속 진행.
- 기존 PRD를 갱신할 때 완료 체크박스와 사용자 수정을 보존한다.
- `Last Updated`와 change log에는 오늘 날짜를 기록한다.

## Discovery Policy

좋은 PRD는 빠르되 진지한 discovery로 시작한다. 프로젝트 context가 있으면 프롬프트만으로 계획을 지어내지 않는다.

PRD 작성 또는 실질적 갱신 전에:

1. 관련 PRD, task, issue, README, 아키텍처 note, API docs, product note, 구현 note를 읽는다.
2. 영향을 받는 코드 표면을 관찰한다: route, screen, component, service, model, schema, migration, job, permission, config, test, fixture, observability, 기존 pattern.
3. 현재 동작, extension point, 네이밍 규약, 데이터 흐름, 통합 경계, 의존/프레임워크 버전, 예상 영향 범위를 식별한다.
4. 가용 validation path를 확인한다: [`./references/validation-paths.md`](./references/validation-paths.md).
5. 서드파티 API/프레임워크 동작/플랫폼 제한/최신 규칙/현재 product 동작이 설계에 영향을 주면 공식 외부 docs를 참조한다.
6. 검토한 것, 검토할 수 없던 것, 중대한 제약, risk, unknown, 설계 함의를 기록한다.
7. discovery 후에도 실질적 모호함이 남으면 그때만 사용자에게 질문한다.

작은 PRD는 master PRD에 compact `Discovery Summary`를 둔다. 큰 plan은 `.claude/prds/prd-[feature-name]/context.md`를 만든다. Context 파일은 source map이지 code dump가 아니다.

모든 phase는 **Phase Discovery Gate**를 포함해야 한다 — 편집 전에 어떤 파일/docs/command/API/도구/assumption을 재확인해야 하는지 executor에게 알린다.

## Question Policy

최대 3개 질문, 답이 scope, architecture, 사용자 동작, 데이터 영향, 규정 준수, 보안, 비용, 비가역 결정을 실질적으로 바꿀 때만. Discovery 이후에 질문한다. agent가 합리적으로 결정 가능한 preference는 묻지 않는다. 번호 + 알파벳 옵션을 쓴다 (예: `1B, 2D, 3A`).

## Planning Method

작성 전에 사용자의 목표를 만족하는 최소 완결 plan을 추론한다:

1. Discovery를 수행하고 중요한 사실만 요약한다.
2. 남은 본질적 unknown을 명확히 한다.
3. 문제, 대상 사용자, 원하는 outcome, 목표, non-goal, 성공 기준을 식별한다.
4. 의도를 번호가 매겨진 functional / non-functional 요구사항으로 변환한다.
5. 제약, risk, 의존성, 데이터 영향, UX note, validation 옵션, 기술적 함의를 포착한다.
6. 의존성 순서의 phase (보통 3-6개)로 작업을 나눈다.
7. 각 phase에 Discovery Gate, implementation 체크리스트, validation 전략, exit criteria, phase-end multi-pass review를 부여한다.
8. 모든 phase 이후 Final Multi-Pass Review를 포함한다.

## Writing Rules

- 짧은 섹션, 구체적 bullet, 알려진 정확한 이름을 사용한다.
- "UX 개선", "정리", "robust하게" 같은 모호한 체크리스트 항목은 관측 가능한 결과가 명시되지 않는 한 피한다.
- 관련 시 permission, 실패 처리, empty state, loading state, edge case, migration, backfill, rollback, rollout, observability, debuggability를 포함한다.
- Phase 체크리스트 항목은 implementation-sized지 epic-sized가 아니다.
- 세부가 unknown이지만 blocker가 아니면 사용자에게 묻지 말고 합리적 assumption을 적는다.
- Test와 validation을 evidence로 다룬다 (ritual 아님). 변경이 동작함을 가장 잘 증명하는 evidence를 고른다.

## Updating Existing PRDs

기존 PRD를 수정할 때:

1. 먼저 현재 master PRD와 영향받는 phase 파일을 읽는다.
2. 체크된 항목과 의미 있는 사용자 수정을 보존한다.
3. 새 정보가 영향을 주는 섹션만 갱신한다.
4. 발견이 계획을 바꾸면 새 작업 추가 전에 후속 phase 파일을 먼저 수정한다.
5. File mode를 바꿔야 하면 [`./references/file-mode-selection.md`](./references/file-mode-selection.md)의 transition 절차를 따른다.
6. 중요 scope를 조용히 삭제하지 않는다. Non-Goals로 옮기거나 follow-up으로 deferred 하거나 Change Log에서 설명한다.
7. 상태, current phase, active phase file, last updated, change log를 관련 항목에 맞춰 갱신한다.

## Quality Bar Before Saving

저장 전에 확인한다:

- [ ] `.claude/prds/` 하위 파일이 생성되거나 갱신되었다.
- [ ] Discovery가 수행되었거나 접근 제약이 기록되었다.
- [ ] Split-file mode면 모든 phase link가 실제로 생성/갱신된 파일을 가리킨다.
- [ ] 실질적 필요 없는 질문은 생략되었다.
- [ ] Assumption이 기록되었다.
- [ ] Goals, non-goals, success criteria, FR, NFR이 명확하고 testable하다.
- [ ] File mode가 적절하다 (phase 4+ 또는 큰 plan은 split).
- [ ] Phase 순서가 의존성을 고려하고 각 phase에 exit criteria가 있다.
- [ ] 모든 phase에 discovery, implementation, validation, multi-pass review 체크리스트가 있다.
- [ ] Validation 전략이 tool-agnostic하고 risk에 적합하다 (단일 browser tool에 hard-code 되지 않음 — [`./references/validation-paths.md`](./references/validation-paths.md) 참조).
- [ ] Phase-end future-plan revision이 명시적으로 요구된다.
- [ ] Final 10-pass Review ([`./references/multi-pass-review.md`](./references/multi-pass-review.md)) 참조가 포함되었다.
- [ ] PRD가 compact하고 실행 가능하며 주니어 또는 AI agent에 적합하다.

저장 후 생성/갱신된 파일의 정확한 경로와 구조 요약으로 답한다.

## 후속 권장 스킬

본 스킬이 자동 호출하거나 강제하지 않는다. PRD 작성·갱신 완료 후 필요에 따라 사용:

- 단일 변경 계획이 필요할 때 → `plan-with-questions for_action`
- 계획 또는 코드에 Devil's Advocate 피드백 → `run-da`
- 전수조사 회귀 감사 → `parallel-audit`
- 문서 대비 구현 감사 + overbuilt 감지 → `review-implementation`
