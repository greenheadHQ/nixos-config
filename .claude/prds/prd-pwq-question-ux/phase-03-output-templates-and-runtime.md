# Phase 3: Output Templates and Runtime

Parent PRD: [PRD: plan-with-questions Question UX](../prd-pwq-question-ux.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

`references/output-templates.md` Step 4 / Step I-4 질문 패턴을 라운드당 1개 + user_facing layer 사용 의무 + 라벨 부착 조건 + hard rule + 라운드별 룰 매트릭스 인용으로 재작성한다. `references/runtime-boundaries.md`에 for_action·for_issue 라운드 정책 통일 단락 추가.

## Context From Master PRD

- Goals covered: G-1 (라운드당 1개), G-2 (user_facing), G-4 (judgment-first 평이)
- Success Criteria: SC-1, SC-2, SC-3
- Requirements covered: FR-1, FR-2 (사용자 노출 패턴), FR-4 (judgment-first 라벨 금지), FR-7 (hard rule)
- Key scenarios touched: Scenario 1, 2, 3

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] 관련 코드/파일: `modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md`, `modules/shared/programs/claude/files/skills/plan-with-questions/references/runtime-boundaries.md`
- [x] Phase 1, 2 산출물: `references/consulting-step.md` (schema, fallback, 합의 알고리즘), `SKILL.md` Invariant 7, `modes/for_action.md` Step 4 흐름
- [x] 관련 docs/spec: 본 PRD master "라운드별 룰 매트릭스" 섹션 (Phase 1/2 결과 통합)
- [x] 관련 command: `rg`
- [x] Master PRD assumption 유효
- [x] Phase 1/2 결과로 output-templates 패턴이 영향받으면 본 phase에서 반영

## Scope

### In Scope

- `references/output-templates.md` Step 4 / Step I-4 질문 패턴:
  - 라운드당 1개 강제 (FR-1).
  - user_facing layer 사용 의무 표시 규칙 (FR-2).
  - 라벨 부착 조건 + hard rule (FR-7).
  - judgment-first 라운드 라벨 부착 절대 금지 (FR-4).
  - 라운드별 룰 매트릭스 7행 (일반 / 트레이드오프 정상 / fallback A/B/C/C_MULTI / judgment-first) 인용.
- `references/runtime-boundaries.md`에 for_action·for_issue 라운드 정책 통일 단락 추가 (FR-1).

### Out of Scope

- `references/consulting-step.md` (Phase 1).
- `SKILL.md`, `modes/*` (Phase 2).
- `references/bias-measurement.md` (Phase 4).
- 다른 인터뷰 스킬 (NG-2).

## Implementation Checklist

- [x] `references/output-templates.md` Step 4 / Step I-4 질문 패턴 섹션 — 라운드당 1개 강제 명시 + 단일 question 도구 호출 예시.
- [x] `references/output-templates.md` 라벨 부착 조건 단락 — Phase 1 합의 알고리즘 인용 + hard rule (도구 default 무시 + 합의 미달 옵션 라벨 절대 금지).
- [x] `references/output-templates.md` user_facing 표시 규칙 단락 — Phase 1 schema의 user_facing layer 인용. evaluation_matrix raw 값을 사용자에게 노출하지 않는다는 명시 규칙.
- [x] `references/output-templates.md` judgment-first 라운드 단락 — 라벨 부착 절대 금지 + user_facing 평이 라벨만 사용.
- [x] `references/output-templates.md` 라운드별 룰 매트릭스 (일반/트레이드오프/judgment-first/fallback) 표 인라인 또는 master PRD 인용.
- [x] `references/runtime-boundaries.md` for_action·for_issue 라운드 정책 통일 단락 추가 — "두 모드 모두 라운드당 1개 강제. modes/* 본문 SSOT 따름."

## Validation Strategy

본 phase는 output-templates 패턴 + runtime-boundaries 규칙 변경이라 정적 grep + Phase 5 self-test가 적절.

- 정적 grep: `rg "라운드당 1개" modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` ≥ 1건.
- 정적 grep: `rg "user_facing" modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` ≥ 2건 (표시 규칙 + judgment-first 인용).
- 정적 grep: `rg "judgment-first 라운드 라벨" modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` ≥ 1건 (FR-4 명시).
- 정적 grep: `rg "Recommended" modules/shared/programs/claude/files/skills/plan-with-questions/` → "허용 조건" 컨텍스트만 매칭, label에 직접 추가 없음 (SC-2).

## Validation Checklist

- [x] Static check 통과: `rg "라운드당 1개" modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` ≥ 1건
- [x] Static check 통과: `rg "user_facing" modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` ≥ 2건
- [x] Static check 통과: `rg "judgment-first" modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` 등장 + 라벨 금지 단락 명시
- [x] Static check 통과: `rg "Recommended" modules/shared/programs/claude/files/skills/plan-with-questions/` → 허용 조건 컨텍스트만 (SC-2 직접 검증)
- [x] Static check 통과: `rg "for_action.*for_issue.*통일" modules/shared/programs/claude/files/skills/plan-with-questions/references/runtime-boundaries.md` 또는 동등 단락 존재
- [x] 자동 test: N/A
- [x] API/CLI workflow 검증: Phase 5 self-test
- [x] Browser/UI E2E: N/A
- [x] Manual smoke check: output-templates 패턴 read 후 다음 LLM이 패턴을 따라 질문할 수 있는지 확인 — 라운드별 룰 매트릭스가 명료한가?

## Exit Criteria

- [x] Phase objective 달성 — output-templates Step 4/I-4 패턴 + runtime-boundaries 라운드 정책 통일
- [x] FR-1 (output-templates 부분), FR-2 (사용자 노출 패턴), FR-4 (judgment-first 라벨 금지), FR-7 (hard rule) 구현
- [x] Validation checklist 완료
- [x] Phase 4 시작을 막는 blocker 없음

## Phase-End Multi-Pass Review

- [x] 1. Intent/coverage — output-templates에 라운드당 1개 + user_facing + 라벨 조건 + judgment-first 라벨 금지 모두 반영
- [x] 2. Correctness — 라운드별 룰 매트릭스 7행 (일반/트레이드오프 정상/fallback A·B·C·C_MULTI/judgment-first) 모두 다룸 (spec 작성 시점 "5 종류"였으나 Discoveries 결정으로 7행 확장 — 정본은 `output-templates.md` SSOT)
- [x] 3. Simplicity — output-templates 패턴이 Phase 1 schema 인용으로 단순화
- [x] 4. Code quality — 패턴/표가 다음 LLM이 따라 적용 가능
- [x] 5. Duplication/cleanup — 합의 알고리즘 본문 재복사 없이 phase 1 인용
- [x] 6. Security/privacy — D4 hard rule + judgment-first 라벨 금지로 anti-anchoring 보호
- [x] 7. Performance/load — N/A (인스트럭션)
- [x] 8. Validation — 정적 grep + Phase 5 self-test 적절
- [x] 9. Future-phase review — Phase 4 (bias-measurement metric)가 본 phase의 SC-2 기준 ("허용 조건 컨텍스트만")에 의존, 본 phase 결과 반영
- [x] 10. PRD sync review — master PRD Phase Index Status `Phase 3` → `Complete`, `Active Phase File`을 phase-04로 갱신

## Discoveries / Decisions

- output-templates 라운드별 룰 매트릭스를 5종이 아닌 7행으로 확장 (일반/트레이드오프 정상/fallback A/B/C/C_MULTI/judgment-first). PRD spec은 "5 종류"라 표현했으나 실제로는 fallback이 4 종류이므로 표 행 수가 7개가 자연스럽다 (PRD master 본문의 "fallback 4단계" 정합).
- runtime-boundaries `request_user_input` 페이로드 가이드 line 35의 폐기 정책("for_issue 4개를 3개로 자동 축소")은 D1으로 무효화됨 — 본 phase에서 정정. line 36 "Recommended 라벨 금지"는 D4 합의 알고리즘 호출로 정정 (라벨 허용 + 합의 조건).
- bias-measurement.md L36의 "Recommended" anchor 키워드는 측정 metric 컨텍스트로 SC-2 검색에 매칭되지만 anchoring 측정용 키워드 catalog일 뿐 사용자 노출 라벨은 아니다 — Phase 4에서 metric 갱신 컨텍스트로 함께 검토.

## Phase Change Log

- 2026-05-05: Phase file created.
- 2026-05-05: Phase 3 Complete. output-templates.md Step 4/I-4 패턴 재작성(라운드당 1개 + user_facing layer 의무 + D4 합의 알고리즘 호출 + hard rule + judgment-first 라벨 금지 + 라운드별 룰 매트릭스 7행), runtime-boundaries.md 폐기 정책 정정 + 라운드 정책 통일 단락 추가. Validation rg 5건 모두 통과 (라운드당 1개 1 / user_facing 9 / judgment-first 라벨 금지 단락 명시 / Recommended SC-2 컨텍스트만 / runtime-boundaries 라운드 정책 통일 등장). Active Phase → Phase 4.
