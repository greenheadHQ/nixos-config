# Phase 1: Schema and Anchoring

Parent PRD: [PRD: plan-with-questions Question UX](../prd-pwq-question-ux.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

`references/consulting-step.md`를 본 PRD의 가장 큰 변경점으로 다룬다 — 출력 schema에 `user_facing` layer 추가, D4 fallback enum(A/B/C/C_MULTI) 정의, D4 합의 알고리즘 정의, Anti-anchoring 1번 규칙(라벨 금지)을 "라벨 허용 + 합의 조건"으로 재작성, 4번(judgment-first) 라운드 라벨 금지 명시. **본 phase가 후속 phase의 SSOT를 만든다** — Phase 2 (SKILL/modes flow)와 Phase 3 (output-templates)가 본 phase의 schema/규칙을 인용한다.

본 spec 작성 시점의 표현은 "D4 합의 알고리즘 5단계" + "fallback A/B/C/D" + 라벨 prefix `[FALLBACK_*]`이었다. 후속 자동 검토 결과 D4가 schema 한계 내 보수적 합의 정의(4단계)로 단순화되고 fallback enum이 D4_FALLBACK_A/B/C/C_MULTI + D2_FALLBACK_USER_FACING으로 정정되었으며, fallback 라벨은 내부 Decision Log 전용으로 격하되어 사용자 노출은 평이 한국어 문구만 사용하도록 변경되었다. **본 spec은 작업 시점 표현 이력으로 보존하고, 정본은 `consulting-step.md` SSOT를 따른다** (정정 결정 트레일은 본 phase Discoveries / Phase Change Log + PRD master Change Log).

## Context From Master PRD

- Goals covered: G-2, G-3, G-4
- Success Criteria: SC-2, SC-3
- Requirements covered: FR-2, FR-3, FR-4, FR-5, FR-6, FR-7
- Key scenarios touched: Scenario 1 (트레이드오프 라운드), Scenario 2 (자문 timeout fallback), Scenario 3 (judgment-first)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] 관련 코드/파일: `modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md`
- [x] 관련 docs/spec/외부 참조: 본 PRD master, `~/.claude/skills/plan-with-questions/SKILL.md` (Invariant 7), `~/.claude/skills/plan-with-questions/references/output-templates.md` (Step 4 패턴)
- [x] 관련 command 또는 도구: `rg` (grep), `jq` (JSON validation)
- [x] Master PRD의 assumption A-1, A-2, A-3이 여전히 유효함
- [x] 발견 사항이 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신 (Phase 2/3 spec 미세조정 불필요 — 기존 spec이 본 phase 변경 인용을 이미 가정)

## Scope

### In Scope

- `references/consulting-step.md` 출력 JSON schema에 `technical_matrix` + `user_facing` 두 layer 추가, 1-shot 예시 (dummy decision) 포함.
- `references/consulting-step.md`에 D2 backward compat fallback 4단계 알고리즘 명시.
- `references/consulting-step.md` Anti-anchoring 4 규칙 재작성:
  - 1번 (라벨 금지) → "라벨 허용 + 합의 조건" + D4 합의 알고리즘 5단계.
  - 2번 (셔플) 보존.
  - 3번 (disqualifier) 보존.
  - 4번 (judgment-first) 보존 + judgment-first 라운드 라벨 부착 절대 금지 명시.
- `references/consulting-step.md` Step 3.5 자문 prompt에 신규 섹션 "현 상황 적합성 컨텍스트" 추가.
- `references/consulting-step.md`에 fallback A/B/C/D 정의 + 4 라벨 (`[FALLBACK_USER_FACING]`, `[FALLBACK_TECHNICAL_INVALID]`, `[FALLBACK_NO_CONSENSUS]`, `[FALLBACK_DISAGREE]`).

### Out of Scope

- `SKILL.md`/`modes/*` 변경 (Phase 2).
- `output-templates.md`/`runtime-boundaries.md` 변경 (Phase 3).
- `bias-measurement.md`/`scripts/measure-anchoring-bias.sh` 변경 (Phase 4).
- 다른 인터뷰 스킬 본문 수정 (NG-2, Phase 5 follow-up issue).

## Implementation Checklist

- [x] `references/consulting-step.md` "## 출력 JSON schema (고정)" 섹션 — schema에 `user_facing` 필드 추가 (description + 비유 + 평이 disqualifier). `technical_matrix`는 기존 `evaluation_matrix`를 명시적으로 재명명/표시. 1-shot dummy 예시 포함.
- [x] `references/consulting-step.md` "## Anti-anchoring 4 규칙" 섹션 — 1번 규칙 재작성: "라벨 허용 + 합의 조건". D4 합의 알고리즘 5단계 명시 (자문 정상 → schema 검증 → 후보 선정 → 합의 판정 → 부착).
- [x] `references/consulting-step.md` Anti-anchoring 4번(judgment-first) 단락 — judgment-first 라운드 라벨 부착 절대 금지 단락 추가.
- [x] `references/consulting-step.md` "## 입력 (codex exec 프롬프트 구조)" 섹션 — 신규 섹션 "현 상황 적합성 컨텍스트" 추가 (FR-6).
- [x] `references/consulting-step.md` D2 backward compat fallback 4단계 알고리즘 (FR-3) — 신규 단락. 4 라벨 정의.
- [x] `references/consulting-step.md` 결과 검증 부분 — schema-level 검증 (7키 + disqualifiers + user_facing 존재) 명시 (FR-5 알고리즘 Step 2).
- [x] `references/consulting-step.md` D4 hard rule (도구 default 무시 + 합의 미달 옵션 라벨 절대 금지) 명시 (FR-7).

## Validation Strategy

본 phase는 schema 변경이 핵심이라 정적 검증 + dummy round-trip이 risk-appropriate. browser/UI E2E 등은 N/A.

- 정적 grep: `rg "user_facing" modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md` (등장 ≥ 1).
- 정적 grep: `rg "Anti-anchoring 1번" modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md`로 재작성 흔적 확인.
- JSON schema sanity: 1-shot 예시 dummy decision JSON을 `jq -e .` 통과 확인.
- (선택, Phase 5에서 본격 실행) 자문 round-trip dummy decision 1개로 새 schema 출력 확인.

## Validation Checklist

- [x] Static check 통과: `rg "user_facing" modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md` ≥ 1건 (실측 19건)
- [x] Static check 통과: `rg "fallback A" modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md` ≥ 1건 (실측 4건)
- [x] Static check 통과: `rg "현 상황 적합성 컨텍스트" modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md` ≥ 1건 (실측 2건)
- [x] dummy 1-shot 예시가 `jq -e .` 통과 (1-shot dummy 예시 섹션의 JSON 블록 추출 후 jq -e . 통과)
- [x] 자동 test 추가/갱신: 본 phase는 인스트럭션 문서 수정만이라 자동 test 추가 N/A
- [x] API/CLI workflow 검증: N/A (Phase 5에서 자문 round-trip 통합 검증)
- [x] Browser/UI E2E: N/A
- [x] Mobile/app simulator: N/A
- [x] Visual/screenshot: N/A
- [x] Observability/logging: N/A
- [x] Manual smoke check: schema 변경 부분 read 후 인간 가독성 확인 — 두 layer 분리 + 1-shot 예시 + fallback 표로 가독성 확보
- [x] error/empty/loading/permission/retry/rollback 상태 검증: fallback A/B/C/D 4 시나리오를 D4 알고리즘 5단계 + 4 라벨 표로 모두 다룸. D2 fallback 4단계 graceful degrade는 user_facing 누락 시 별도 흐름

## Exit Criteria

- [x] Phase objective 달성 — schema 두 layer + fallback + D4 합의 알고리즘 + Anti-anchoring 재작성 모두 `consulting-step.md`에 반영
- [x] FR-2, FR-3, FR-5, FR-6, FR-7 (consulting-step.md 부분) 모두 구현
- [x] Validation checklist 완료 또는 gap이 근거와 함께 기록됨
- [x] Phase 2 시작을 막는 blocker 없음

## Phase-End Multi-Pass Review

다음 phase로 이동하기 전 순서대로 완료한다:
- [x] 1. Intent/coverage review — schema 두 layer + fallback + 합의 알고리즘 + judgment-first 라벨 금지 모두 다룸
- [x] 2. Correctness review — fallback A/B/C/D 4 시나리오 + judgment-first 보호 + schema 검증 시나리오 처리
- [x] 3. Simplicity review — D2 fallback과 D4 hard rule이 description 강화 이상의 unique 가치 (graceful degrade vs 라벨 결정 알고리즘) 제공
- [x] 4. Code quality review — JSON schema 명시성, 1-shot dummy 예시 자명성(dummy-cache-strategy), fallback 알고리즘 단계 표로 분명함
- [x] 5. Duplication/cleanup review — `technical_matrix`는 기존 `evaluation_matrix`를 명시적으로 재명명(의미 동일), `user_facing`은 별도 layer로 SSOT 분리
- [x] 6. Security/privacy review — 셸 호출 3 jq schema-level 검증으로 untrusted 자문 출력에 대한 trust boundary 유지 (DL-4)
- [x] 7. Performance/load review — Codex 자문 30분 budget 내 두 layer 출력 가능 (A-3 — 추가 텍스트 ~수백 토큰)
- [x] 8. Validation review — 정적 grep + jq dummy round-trip이 phase risk에 적절. 통합 round-trip은 Phase 5 통합 검증
- [x] 9. Future-phase review — Phase 2 (SKILL.md/modes Step 4 합의 알고리즘 호출)와 Phase 3 (output-templates judgment-first 평이 라벨)이 본 phase 변경에 의존. Phase 2/3 spec은 본 phase 산출물 인용을 이미 가정하므로 spec 미세 조정 불필요
- [x] 10. PRD sync review — master PRD Phase Index Status `Not Started` → `Complete`, `Active Phase File`을 phase-02로 갱신, Last Updated 갱신, Change Log 갱신 모두 완료

## Discoveries / Decisions

- D2 fallback과 D4 알고리즘은 별개의 시스템임을 명시: D2 fallback은 user_facing layer 누락 시 메인 LLM의 graceful degrade(4단계), D4 알고리즘은 라벨 부착 결정 흐름(작업 시점에는 5단계로 spec 작성, 후속 자동 검토에서 D4를 schema 한계 내 보수적 합의 정의로 단순화하여 4단계로 정정 — 본 phase Spec 본문은 작업 시점 표현 보존, 정본은 `consulting-step.md` SSOT). [FALLBACK_USER_FACING] 라벨은 D2 Stage 3(메인 LLM 자체 작성)에서 사용되며, D4_FALLBACK_* enum은 별개 축으로 사용자 노출은 평이 한국어 문구만 (후속 정정).
- 셸 호출 3의 schema 검증을 jq 표현식으로 elevation. fallback A/B 분기를 셸 출력 메시지로 명시하여 메인 LLM이 fallback 라벨로 매핑할 수 있게 함.

## Phase Change Log

- 2026-05-05: Phase file created.
- 2026-05-05: Phase 1 Complete. consulting-step.md 7개 변경 완료(두 layer schema + 1-shot dummy + Anti-anchoring 1번 재작성 + D4 합의 알고리즘 5단계 + judgment-first 라벨 금지 + 신규 "현 상황 적합성 컨텍스트" 섹션 + D2 fallback 4단계 + 4 fallback 라벨 표 + 셸 호출 3 jq schema 검증 + D4 hard rule 단락). Validation rg/jq 모두 통과. Discovery Gate / Implementation Checklist / Validation Checklist / Exit Criteria / Multi-Pass Review 모두 [x] 처리. Active Phase → Phase 2.
