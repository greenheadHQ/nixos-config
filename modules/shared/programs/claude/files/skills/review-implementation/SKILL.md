---
name: review-implementation
argument-hint: "[.md file paths | PRD phase file | spec doc]"
description: |
  Review implementation against markdown requirements/specs/PRD/phase docs;
  optionally apply focused fixes. 6-classification (satisfied/partial/missing/
  conflicting/overbuilt/deferred) + Implementation 9-pass review.
  Trigger: '문서 대비 구현 리뷰', '스펙 대비 감사', 'overbuilt 검사',
  'PRD phase 완료 확인', '구현 감사'.
  NOT for PR 코멘트 (use review-pr-feedback). NOT for 범용 DA (use run-da).
  NOT for 전수조사 (use parallel-audit). NOT for PRD 작성 (use prd).
---

# Review Implementation

코드를 markdown requirement/spec/PRD/phase 문서에 대비하여 리뷰하고 evidence-backed findings를 산출한다. 사용자가 fix를 요청하면 문서에 맞춰 구현을 정렬하되 scope를 확장하지 않는 범위에서 targeted 수정을 수행한다.

## Modes

- **review-only mode**: 사용자가 리뷰, 감사, 검증, 이슈 찾기를 요청할 때.
- **fix mode**: 사용자가 수정, 업데이트, 리팩터, 완성, 변경 적용, 문서 정렬을 요청할 때. 변경은 최소·가역적으로 유지하고 문서로 정당화되지 않는 기능은 추가하지 않는다.

## 빠른 참조

| 항목 | 위치 |
|---|---|
| Requirement 6분류 정의 + classification 룰 + overbuilt 감지 체크리스트 | [./references/requirement-status.md](./references/requirement-status.md) |
| Validation-path catalog (공용) | [../prd/references/validation-paths.md](../prd/references/validation-paths.md) |
| Evidence 라벨 체계 (`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`) | [../write-handoff/references/llm-friendly-checklist.md](../write-handoff/references/llm-friendly-checklist.md) |

## main-agent-only 경계

- **fix 모드는 tracked write(코드 수정)를 수행하므로 메인 에이전트 전용.** 서브에이전트에 위임하지 않는다.
- **PRD status transition의 정본 owner는 `prd` 스킬.** 본 스킬은 **evidence-backed sync**로 한정한다:
  - 요청 입력에 PRD/phase 파일이 **명시적으로 포함된 경우에 한해서만** `.claude/prds/` 하위 해당 PRD/phase 파일(single mode: `prd-*.md`, split mode: `prd-*/phase-*.md` 포함)의 체크박스 / validation notes / change log를 갱신한다.
  - 체크박스 전환(`- [ ]` → `- [x]`)은 **Step 5 Validation이 성공한 항목에 한정** (upstream 규약 + sub-issue #509 Phase 3 제약).
- **review-only 모드 기본 경로**는 메인 에이전트 read-only. fan-out은 상위 워크플로(예: `parallel-audit`)에서 위임될 때만 수행.
- 상세 계약은 [`../run-da/SKILL.md`](../run-da/SKILL.md)의 `Codex 세션 하드닝 계약` 섹션을 따른다.

## Workflow

### Step 1: Intake and Discovery Gate

- 제공된 모든 `.md` 파일을 읽고 명시적 요구사항, 제약, acceptance 기준을 추출한다.
- 관련 있는 경우 repo 지침(`AGENTS.md`, `README`, 아키텍처 note, 기존 task/PRD 파일)을 읽는다.
- 영향받는 코드, test, fixture, route, schema, migration, service, component, permission, config, observability surface를 관찰한다.
- 현재 동작, 기대 동작, data flow, 통합 지점, validation 옵션, 예상 영향 범위를 식별한다.
- 본질적 결정이 discovery 이후에도 안전하지 않으면 질문한다.

### Step 2: Map Requirements to Evidence

- 내부 traceability map을 만든다: requirement → status → code evidence → gap → action.
- 각 requirement를 6분류 중 하나로 분류한다: `satisfied`, `partial`, `missing`, `conflicting`, `overbuilt`, `deferred`. 정의·룰·증거 기준은 [`./references/requirement-status.md`](./references/requirement-status.md)를 따른다.
- 중요 claim에는 파일:줄 증거를 사용한다. 코드를 관찰할 수 있는데 인상에 의존하지 않는다.

### Step 3: Run Implementation 9-pass Review

다음 순서로 9개 패스를 수행한다 (본 스킬 고유의 **Implementation 9-pass review**; `prd`의 Final 10-pass 및 Phase-End 10-pass와는 **다른 축**):

1. **Requirements coverage**: 모든 requirement가 satisfied 또는 명시적으로 해소 불가.
2. **Correctness**: happy path, edge case, error, empty state, permission, state transition, rollback.
3. **Integration**: 바뀐 모듈이 계약 깨짐, 소유권 중복, 숨은 가정 없이 맞물린다.
4. **Simplicity**: 솔루션이 필요 이상으로 복잡하지 않다.
5. **Cleanup**: 중복 로직, dead code, temporary code, 잡음 log, 사용되지 않는 파일/의존성이 제거.
6. **Security/privacy**: 인증, 인가, secret, 민감 데이터, injection risk, 감사 필요성이 안전.
7. **Performance**: 비싼 query, N+1, 불필요한 render, 중복 네트워크 호출, 블로킹 작업이 다루어짐.
8. **Validation**: 선택된 check가 risk에 적합 — 선택 근거는 [`../prd/references/validation-paths.md`](../prd/references/validation-paths.md)를 참조.
9. **Documentation/operability**: docs, release note, migration, rollback, monitoring, 지원 note가 필요에 따라 갱신.

문서가 요구하지 않는 기능·추상화·상태·의존성·workflow 경로가 코드에 추가되어 있으면 `overbuilt`로 분류하여 finding으로 기록한다.

### Step 4: Apply Focused Fixes (fix 모드에서만)

- 문제를 코드에서 직접 수정한다. 최소·타겟화된 변경.
- 지나치게 긴 파일/함수는 실제 리뷰/유지보수 risk가 감소할 때만 분리한다.
- 문서로 정당화되지 않는 overbuilt 코드를 제거하거나 단순화한다.
- 문서 또는 코드 evidence가 변경을 정당화하지 않는 한 기존 패턴을 보존한다.
- PRD/phase 파일이 요청 입력에 포함된 경우, main-agent-only 경계의 **evidence-backed sync** 제약 아래에서만 체크박스·validation notes·change log를 갱신한다 (Validation 성공 항목 한정).

### Step 5: Validate with Evidence

- risk에 맞는 최소 충분 validation을 고른다. 전체 경로 목록과 선택 가이드는 [`../prd/references/validation-paths.md`](../prd/references/validation-paths.md)의 catalog를 정본으로 따른다 (static / unit / integration / API-level E2E / browser-UI E2E / agent-dev browser / mobile-simulator / visual-screenshot / manual smoke / observability).
- 가용하고 적절한 check를 실행한다. 가용하지 않거나 비용이 맞지 않거나 허용되지 않으면 gap을 명시하고 차선 evidence를 사용한다.
- 좁은 check로 바뀐 동작을 증명할 수 있으면 넓고 비싼 validation을 반사적으로 실행하지 않는다.

## Report Format

가장 중요한 결과를 먼저 둔다.

- **review-only mode**: findings를 심각도 순서로 파일:줄 참조와 함께 나열 → coverage 요약 → validation 요약 → residual risk.
- **fix mode**: 적용된 fix 요약 → 수행된 validation → 남은 finding/risk.
- 이슈가 없으면 명확히 그렇게 보고하고 validation gap이 있으면 명시한다.
- critical blocker는 멈추고 묻는다. non-critical ambiguity는 최선의 합리적 결정 + assumption 기록 + 진행.

### Evidence 라벨

각 finding에는 evidence 수준을 라벨로 표시한다. 직접 확인된 사실은 라벨 없음. 그 외 라벨 정의(`[UNVERIFIED]`/`[INFERRED]`/`[CONFLICTING]`)는 [체크리스트 라벨 체계](../write-handoff/references/llm-friendly-checklist.md#라벨-체계-anti-hallucination) 참조.

6분류(requirement status 축)와 evidence 라벨은 별개 축이므로 함께 사용한다 — 예: `partial [INFERRED]`.

## 후속 권장 스킬

본 스킬이 자동 호출하거나 강제하지 않는다:

- PRD 자체 작성·갱신이 필요하면 → `prd`
- 변경 계획 수립 → `plan-with-questions for_action`
- 계획 또는 코드 Devil's Advocate 피드백 → `run-da`
- 전수조사 회귀 감사 → `parallel-audit`
- PR 코멘트 분류·처리 → `review-pr-feedback`
