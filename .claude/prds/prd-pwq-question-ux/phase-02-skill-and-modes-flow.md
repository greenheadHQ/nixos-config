# Phase 2: SKILL and Modes Flow

Parent PRD: [PRD: plan-with-questions Question UX](../prd-pwq-question-ux.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

`SKILL.md` Invariant 7 재작성 + `modes/for_action.md` Step 4 본문 재작성(D1, D2, D4 합의 알고리즘 호출) + `modes/for_issue.md` Step I-4의 라운드당 4개 → 1개 통일 + `modes/for_prd.md` 차용 부분 갱신. Phase 1에서 만든 `consulting-step.md`의 합의 알고리즘/fallback을 modes 흐름으로 연결한다.

## Context From Master PRD

- Goals covered: G-1 (라운드당 1개), G-2 (user_facing 사용 의무), G-3 (라벨 부착 조건), G-4 (judgment-first + D2)
- Success Criteria: SC-1, SC-3
- Requirements covered: FR-1, FR-2 (사용자 노출), FR-4 (judgment-first), FR-5 (합의 알고리즘 호출), FR-7 (hard rule)
- Key scenarios touched: Scenario 1, 2, 3 모두

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] 관련 코드/파일: `modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md` (Invariant 7), `modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_action.md` (Step 4), `modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_issue.md` (Step I-4), `modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_prd.md` (차용 부분)
- [x] Phase 1 산출물: `modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md` (schema 두 layer + fallback + D4 합의 알고리즘)
- [x] 관련 docs/spec: 본 PRD master, `modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` (Phase 3에서 갱신)
- [x] 관련 command 또는 도구: `rg`
- [x] Master PRD assumption 유효
- [x] Phase 1 결과로 modes의 Step 4 합의 알고리즘 호출 부분이 변경되어야 한다면 본 phase에서 반영

## Scope

### In Scope

- `SKILL.md` Invariant 7 재작성 — "한번에 모아서 왕복 횟수 최소화" 폐기, 라운드당 1개 강제, for_action·for_issue 통일 명시 (FR-1).
- `SKILL.md`에 D2/D4 hard rule 인용 추가 (FR-7).
- `modes/for_action.md` Step 4 본문 재작성:
  - "한번에 모아서" 폐기, 라운드당 questions 배열 길이 1 강제 (FR-1).
  - 사용자 노출 시 user_facing layer 사용 의무 (FR-2).
  - D4 합의 알고리즘 호출 (Phase 1 schema 인용, FR-5).
  - judgment-first 라운드 라벨 부착 절대 금지 명시 (FR-4).
- `modes/for_issue.md` Step I-4 — "라운드당 최대 4개" → "라운드당 1개"로 통일 (FR-1).
- `modes/for_prd.md` for_action·for_issue 차용 부분에 D1/D2/D4 적용 명시.

### Out of Scope

- `references/consulting-step.md` (Phase 1).
- `references/output-templates.md` (Phase 3).
- `references/runtime-boundaries.md` (Phase 3).
- `references/bias-measurement.md` 또는 scripts (Phase 4).
- 다른 인터뷰 스킬 본문 수정 (NG-2).

## Implementation Checklist

- [x] `SKILL.md` Invariant 7 (현재 "단 한번에 모아서 왕복 횟수는 최소화한다 (Step 4) 또는 라운드당 최대 4개 (Step I-4)") 재작성 — "라운드당 질문 1개 강제. for_action·for_issue 모두 적용. 사용자 인지 부하 최소화 + 1개일 때 메인 LLM 충분한 설명 보장 (관심사 분리)."
- [x] `SKILL.md`에 D4 hard rule 한 줄 추가 — "AskUserQuestion 도구 description의 추천 라벨 권장은 plan-with-questions 컨텍스트에서 무시. 합의 미달 옵션에 라벨 절대 금지."
- [x] `modes/for_action.md` Step 4 — "수집한 질문(Step 3) + 외부 자문 매트릭스(Step 3.5)를 질문 도구로 한번에 모아서 사용자에게 제시한다" → "라운드당 1개 질문씩 제시. 트레이드오프 라운드는 Phase 1의 합의 알고리즘 호출. 사용자 노출은 user_facing layer만."
- [x] `modes/for_action.md` Step 4 — judgment-first 라운드 처리 단락 추가 (FR-4).
- [x] `modes/for_action.md` Step 4 — fallback A/B/C/D 발생 시 사용자 보고 형식 명시 ("자문 미수행으로 추천 라벨 없음" 등).
- [x] `modes/for_issue.md` Step I-4 (현재 "한 라운드에 최대 4개 질문") → "라운드당 1개 질문. for_action Step 4와 동일 정책."
- [x] `modes/for_prd.md` 차용 부분 — D1/D2/D4 적용 명시. for_prd가 for_action Step 1-4를 차용한다는 부분에서 라운드 정책 통일.

## Validation Strategy

본 phase는 modes 흐름 변경이라 정적 grep + 본 PRD self-test (Phase 5에서)이 핵심.

- 정적 grep: `rg "한번에 모아서" modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md modules/shared/programs/claude/files/skills/plan-with-questions/modes/` → 0건 또는 "폐기됨" 컨텍스트만 (SC-1).
- 정적 grep: `rg "라운드당 최대 4개" modules/shared/programs/claude/files/skills/plan-with-questions/modes/` → 0건.
- 정적 grep: `rg "라운드당 1개" modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md modules/shared/programs/claude/files/skills/plan-with-questions/modes/` → 등장 (양적 매핑).
- Phase 5 dogfooding에서 본 PRD self-test로 검증 (다음 PWQ 호출 시 questions 배열 길이 1 확인).

## Validation Checklist

- [x] Static check 통과: `rg "한번에 모아서" modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md modules/shared/programs/claude/files/skills/plan-with-questions/modes/` → 0건 또는 "폐기됨" 컨텍스트만
- [x] Static check 통과: `rg "라운드당 최대 4개" modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_issue.md` → 0건
- [x] Static check 통과: `rg "라운드당 1개" modules/shared/programs/claude/files/skills/plan-with-questions/` ≥ 3건 (SKILL + for_action + for_issue)
- [x] Static check 통과: `rg "합의 알고리즘" modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_action.md` ≥ 1건 (Phase 1 호출)
- [x] 자동 test: N/A (인스트럭션 문서)
- [x] API/CLI workflow 검증: Phase 5에서 본 PRD self-test
- [x] Browser/UI E2E: N/A
- [x] Manual smoke check: SKILL.md/modes/* read 후 modes 흐름 일관성 확인 (다음 LLM이 흐름을 추적 가능?)
- [x] error/empty/loading 상태: fallback A/B/C/D 처리 단락이 modes Step 4에 명시되어 사용자 보고 형식 누락 없음 확인

## Exit Criteria

- [x] Phase objective 달성 — SKILL.md + modes 4개 파일 모두 D1/D2/D4 적용 + Phase 1 합의 알고리즘 호출
- [x] FR-1, FR-4, FR-5 (modes 부분) + FR-7 (hard rule) 구현
- [x] Validation checklist 완료 또는 gap 기록
- [x] Phase 3 시작을 막는 blocker 없음

## Phase-End Multi-Pass Review

- [x] 1. Intent/coverage — D1 (라운드당 1개) + D4 hard rule + D2 user_facing 호출 + judgment-first 보호 모두 modes에 반영
- [x] 2. Correctness — fallback A/B/C/D 4 시나리오의 사용자 보고 형식 명시
- [x] 3. Simplicity — modes 흐름 변경이 phase 1 schema 인용으로 단순화 (SSOT 분리)
- [x] 4. Code quality — Invariant 7 재작성문이 명확, modes Step 4 흐름이 다음 LLM에게 자명
- [x] 5. Duplication/cleanup — Step 4 본문에 합의 알고리즘 사본을 넣지 않고 phase 1 schema/refs 인용
- [x] 6. Security/privacy — D4 hard rule이 trust boundary 보존 (DL-4 mitigation)
- [x] 7. Performance/load — 라운드당 1개로 turn 수 증가하나 사용자 명시 수용 (D1 trade-off)
- [x] 8. Validation — 정적 grep + Phase 5 self-test가 risk에 적절
- [x] 9. Future-phase review — Phase 3 (output-templates Step 4/I-4 패턴)이 본 phase의 modes Step 4 호출에 의존, 본 phase 결과로 phase 3 implementation 미세 조정 가능
- [x] 10. PRD sync review — master PRD Phase Index Status `Phase 2` → `Complete`, `Active Phase File`을 phase-03으로 갱신, Last Updated, Change Log 갱신

## Discoveries / Decisions

- SKILL.md 실제 구조에는 Invariant 6까지만 있어 phase spec의 "Invariant 7"은 새 Invariant **8**로 추가했다 (기존 Invariant 7은 Living checkbox 갱신 의무로 점유). PRD spec의 "Invariant 7" 라벨은 source-of-truth와 정합하지 않아 본 phase에서 Invariant 8로 정정. PRD master는 spec 수준 표기를 유지하고 phase Discoveries에 source 차이를 기록한다 (path는 같은 SKILL.md, 번호만 다름).
- for_action Step 4 fallback 보고 형식을 표 형태로 정리해 메인 LLM이 fallback 라벨 → 사용자 메시지 매핑을 lookup으로 사용하도록 했다. for_issue/for_prd는 별도 사본을 두지 않고 for_action callsite를 인용하여 SSOT drift 방지.
- for_prd 차용 단락에는 "PRD가 multi-phase여도 D1 라운드당 1개는 유지"를 명시 — phase 단위 인터뷰가 묶음 회귀로 빠지지 않도록 명시.

## Phase Change Log

- 2026-05-05: Phase file created.
- 2026-05-05: Phase 2 Complete. SKILL.md Invariant 8 추가 + 주의사항 line 정정, for_action.md Step 4 D1/D2/D4 재작성, for_issue.md Step I-4 1개 통일, for_prd.md 차용 D1/D2/D4 명시 모두 반영. Validation rg 4건 모두 통과 (한번에 모아서 폐기 2 / 라운드당 최대 4개 폐기 1 / 라운드당 1개 합산 5 / 합의 알고리즘 3). Active Phase → Phase 3.
