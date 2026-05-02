# Master PRD Template

Single-file mode에서는 아래 구조 전체를 단일 파일에 둔다. Split-file mode에서는 master PRD에 phase index만 두고, phase 상세는 [`phase-template.md`](./phase-template.md) 기반의 phase 파일에 둔다.

경로: `.claude/prds/prd-[feature-name].md` (split mode의 phase 파일은 `.claude/prds/prd-[feature-name]/phase-NN-[phase-name].md`).

```markdown
# PRD: [Feature Name]

## Document Status
- Status: Draft | In Progress | Complete
- File Mode: Single | Split
- Current Phase: Not Started | Phase N | Complete
- Active Phase File: [Phase N](./prd-[feature-name]/phase-NN-[phase-name].md) <!-- split only -->
- Context File: [context.md](./prd-[feature-name]/context.md) <!-- 생성 시에만 -->
- Last Updated: YYYY-MM-DD
- PRD File: `.claude/prds/prd-[feature-name].md`
- Purpose: Living PRD / 실행 source of truth. 여기에서 작업을 체크 off 하고, 구현 중 새 사실이 드러나면 이 문서를 갱신하고, 계획이 바뀌면 진행 전에 후속 phase를 수정한다.

## Problem
[어떤 문제가 존재하며, 누가 영향을 받고, 왜 중요한가.]

## Goals
- G-1: ...

## Non-Goals
- NG-1: ...

## Success Criteria
- SC-1: [관측 가능한 outcome 또는 acceptance 조건]

## Key Scenarios
### Scenario 1: [Name]
- Actor:
- Trigger:
- Expected outcome:

## Discovery Summary
- Reviewed: [중요 코드/docs/tests/configs/외부 docs, 또는 context 파일 링크]
- Current system: [관련 시스템이 현재 어떻게 동작하는가]
- Validation surface: [가용 검증 도구/gap — 상세 가이드는 plan-with-questions의 references/validation-paths.md 참조]
- Design implications: [이 PRD를 형성한 사실들]
- Confidence / gaps: [아직 불확실한 항목 + 이유]

## Requirements
### Functional Requirements
- FR-1: ...

### Non-Functional Requirements
- NFR-1: ...

## Assumptions
- A-1: ...

## Dependencies / Constraints
- ...

## Risks / Edge Cases
- ...

## Execution Rules
- 본 PRD가 명시적으로 수정되지 않는 한 phase는 순서대로 완료한다.
- 어떤 phase든 시작 전에 master PRD + active phase file + 관련 context note를 읽는다.
- PRD 파일만 active plan으로 사용한다. 경쟁하는 별도 체크리스트를 만들지 않는다.
- 사소한 애매함은 가장 합리적인 옵션을 고르고 assumption으로 기록한 뒤 계속 진행한다.
- 다음 항목에 한해서만 진행을 멈추고 도움을 요청한다: 접근 권한 부재, 비가역적 파괴 변경, 주요 요구사항 충돌, 보안/법률 관련 의미 있는 risk.
- 목표를 만족하는 최소·가역적 변경을 선호한다.
- 명백한 사유가 없는 한 기존 코드 패턴을 보존한다.
- 검증 방법은 risk와 가용 도구에 맞춰 선택한다. 모든 phase에 동일 tool을 기본값으로 사용하지 않는다 (plan-with-questions의 references/validation-paths.md 참조).
- 각 phase 종료 시 본 PRD를 갱신하고 학습 결과에 따라 후속 phase를 수정한다.

## Phase Index
| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: [Name] | Not Started | ... | ... | [phase-01-[name].md](./prd-[feature-name]/phase-01-[name].md) |

<!-- Single-file mode: 아래 Phase Plan 섹션에 각 phase의 전체 템플릿을 둔다. Split-file mode: 위 인덱스만 남기고 상세는 별도 phase 파일로 분리. -->

## Phase Plan

### Phase 1: [Name]
[Single-file mode일 때만 phase-template.md 구조를 여기 인라인으로 포함.]

## Final Multi-Pass Review After All Phases
plan-with-questions의 references/prd/multi-pass-review.md 체크리스트를 여기 인라인으로 복제하거나, 해당 파일을 참조 문자열로만 둔다.

## Open Questions
- ...

## Change Log
- YYYY-MM-DD: Initial PRD created.
```

## 작성 규칙

- 경로는 `.claude/prds/...`로 고정 (nixos-config `.claude/` 규약). upstream 원본의 `tasks/...` 경로는 본 정본에서 사용하지 않는다.
- `[feature-name]` slug와 split phase path는 [`file-mode-selection.md`](./file-mode-selection.md#경로-slug-안전-규칙)의 basename/canonical containment 규칙을 따른다.
- `Last Updated`와 change log는 실제 오늘 날짜로 기록한다.
- Split-file mode라면 master PRD의 `Phase Plan` 섹션은 제거하고 Phase Index만 남긴다.
- 완료된 체크박스(`- [x]`)와 사용자 수정은 revision 시 보존한다.
- 중요 범위를 조용히 삭제하지 않는다. Non-goal로 이동하거나, follow-up으로 deferred하거나, Change Log로 이유를 기록한다.
