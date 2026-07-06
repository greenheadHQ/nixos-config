# Phase 5: Dogfooding and Follow-up

Parent PRD: [PRD: plan-with-questions Question UX](../prd-pwq-question-ux.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

Phase 1~4 완료 후 본 PRD 자체로 self-test (dogfooding 5건) + issue #646 본문을 분석 결과로 통째 교체 + follow-up issue 2건 등록 (다른 인터뷰 스킬 + plan-file-template/pinning-guard 충돌). 본 phase가 PRD의 closeout이며 Final Multi-Pass Review를 수행한다.

## Context From Master PRD

- Goals covered: G-5 (PWQ만 + follow-up issue 즉시 등록)
- Success Criteria: SC-4 (수동 5건), SC-6 (follow-up issue 등록)
- Requirements covered: 모든 FR의 통합 검증
- Key scenarios touched: Scenario 1, 2, 3 모두 (수동 dogfooding)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] Phase 1~4 모두 Complete
- [x] Master PRD Status `Phase 4` → 본 phase 진입
- [x] 관련 코드/파일: 모든 PWQ skill 본문 (Phase 1~3 산출물) + bias-measurement (Phase 4 산출물) + 본 PRD master
- [x] 관련 docs/spec: `modules/shared/programs/claude/files/skills/plan-with-questions/references/prd/multi-pass-review.md` (Final 10-pass), `modules/shared/programs/claude/files/skills/plan-with-questions/references/review-impl/implementation-review.md` (review-impl overlay)
- [x] 관련 command 또는 도구: `gh issue create` (follow-up issue), `gh issue edit 646` (본문 교체), 사용자 직접 PWQ 호출 (dogfooding)
- [x] Master PRD assumption A-1 (메인 LLM 합의 알고리즘 안정 적용) 검증 가능 시점이 본 phase

## Scope

### In Scope

- 다음 PWQ 호출 5건 수동 dogfooding (SC-4):
  - 라운드당 questions 배열 길이 1 강제 확인.
  - 사용자 노출에 user_facing layer만 (evaluation_matrix raw 비노출).
  - 라벨 부착이 합의 알고리즘 통과 후만, 합의 미달은 라벨 미부착.
  - judgment-first 라운드는 라벨 절대 미부착.
  - fallback enum(D4_FALLBACK_A/B/C/C_MULTI) 시나리오가 발생하면 사용자 보고 형식 명시 (사용자에게는 enum 라벨 대신 평이 한국어 문구만 노출 — `consulting-step.md` "Fallback enum" 표 SSOT).
- issue #646 본문 통째 교체 (사용자 메타 인터뷰 답변 명시):
  - TL;DR + 비유.
  - 정량 통계 표 (3 머신).
  - mermaid timeline (사용자 호소 2.5개월).
  - raw quote 4-5건.
  - root cause flowchart (mermaid).
  - 변경 범위 표 (8개 파일).
  - 데이터 출처 (자연어 식별).
  - 데이터 한계 (transparency).
- follow-up issue 2건 등록 (gh issue create):
  - **이슈 A**: 다른 인터뷰 스킬(grill-me, create-issue, review-pr-feedback)에 같은 pain 적용 검토 (G-5, SC-6).
  - **이슈 B**: plan-file-template SSOT의 `HEAD=<sha7>` 권장과 `pinning-guard.sh` PATTERN_D 차단 충돌 (F-OQ-1).
- Final Multi-Pass Review 수행 (multi-pass-review.md 10-pass) + review-impl overlay (`.claude/prds/` 산출물이라 PRD Closeout 자동 활성화).

### Out of Scope

- 다른 인터뷰 스킬 본문 변경 (이슈 A로 follow-up).
- plan-file-template 또는 pinning-guard 변경 (이슈 B로 follow-up).
- F-OQ-2: D4 anchoring 효과 손상 정량 baseline 산출 (dogfooding 누적 후 별도 issue).

## Implementation Checklist

- [ ] 다음 PWQ 호출 5건을 수동 dogfooding 모니터링 — 5건 동안 발견 사항을 본 phase Discoveries에 기록. **(deferred — closeout 외부; 본 PRD 작업으로 즉시 충족 불가, 사용자 후속 PWQ 5건 누적 시 평가)**
- [x] dogfooding 결과 SC-1, SC-2, SC-3, SC-5 통과 확인은 본 phase Validation Checklist의 정적 grep + script로 산출. SC-4는 dogfooding 시간 의존 — closeout 외부 모니터링.
- [x] issue #646 본문 교체:
  - TL;DR + 비유 (의사-환자 또는 식당 메뉴판 비유).
  - 정량 통계 표 (Mac CC 142 / Mac Codex 169 / miniPC 35 PWQ session, 4개 묶기 17.9-20.3%, turn_aborted 34.3%, 라벨 노출 92.3%).
  - mermaid gantt (사용자 호소 2.5개월 timeline).
  - raw quote (2026-03-21 WTF, 2026-05-03 Codex retry, 2026-05-05 issue/671 args, 2026-03-02 awesome-anki 5회 반복).
  - mermaid flowchart (root cause: 한번에 모아서 + 미가공 노출 + 라벨 권장 → 인지 실패 → turn_abort/drift/args 우회).
  - 변경 범위 표 (Phase 1-5 + 8개 파일).
  - 데이터 출처 (자연어 식별 — 시점 + 작업명 + 이슈 번호).
  - 데이터 한계 (transparency).
  - 실행: `gh issue edit 646 --body-file <path>`.
- [x] follow-up issue A 등록 (`gh issue create`):
  - Title: "feat(skills): grill-me/create-issue/review-pr-feedback 등 인터뷰 스킬에 PWQ Question UX 정책(라운드당 1개 + user_facing + 합의 라벨) 적용 검토 (#646 후속)"
  - Body: 본 PRD의 G-5 / SC-6 컨텍스트 + 영향 받을 스킬 목록 + cross-skill 라벨 의미 drift 우려.
- [x] follow-up issue B 등록 (`gh issue create`):
  - Title: "fix(plan-file-template): SSOT의 HEAD=<sha7> 권장과 pinning-guard.sh PATTERN_D 차단 충돌 해결"
  - Body: 본 PRD F-OQ-1 컨텍스트 + 두 SSOT 사이 충돌 + 권장 방향 (template 또는 pinning-guard 한쪽 갱신).
- [x] Final Multi-Pass Review 10-pass 수행 (`modules/shared/programs/claude/files/skills/plan-with-questions/references/prd/multi-pass-review.md` 체크리스트).
- [x] review-impl overlay 적용 (`modules/shared/programs/claude/files/skills/plan-with-questions/references/review-impl/implementation-review.md` 6-classification 라벨링 + overbuilt 우선 분류).
- [x] PRD Closeout 항목 — `.claude/prds/` 산출물이라 자동 활성화. PRD Status `Complete`, Phase Index 모두 Complete, Change Log 갱신.

## Validation Strategy

본 phase는 통합 검증 + closeout이라 dogfooding + multi-pass review가 핵심.

- Manual dogfooding 5건: SC-4 직접 산출.
- 정적 grep 통합 (Phase 1-4 결과 검증): SC-1, SC-2, SC-3, SC-5 모두.
- gh CLI 실행: follow-up issue 2건 등록 + #646 본문 교체.
- Final Multi-Pass Review 10-pass: PRD closeout 일반 절차.

## Validation Checklist

- [ ] Manual dogfooding 5건 통과 — 라운드당 1개 + user_facing only + 합의 후 라벨 + judgment-first 라벨 금지 + fallback 보고 **(deferred — 사용자 후속 PWQ 5건 누적 모니터링; 본 PRD 작업으로 즉시 충족 불가)**
- [x] Static check 통합: `rg "한번에 모아서" modules/shared/programs/claude/files/skills/plan-with-questions/` → 0건 또는 폐기 컨텍스트
- [x] Static check 통합: `rg "Recommended" modules/shared/programs/claude/files/skills/plan-with-questions/` → 허용 조건 컨텍스트만
- [x] Static check 통합: `rg "user_facing" modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md modules/shared/programs/claude/files/skills/plan-with-questions/references/output-templates.md` ≥ 3건
- [x] Script 통과: bias-measurement 스크립트 exit 0
- [x] gh issue edit 646 — 본문 교체 후 `gh issue view 646`로 새 본문 노출 확인
- [x] gh issue create 후 issue A URL 반환 확인
- [x] gh issue create 후 issue B URL 반환 확인
- [x] Final 10-pass review 통과 + review-impl overlay 적용 + PRD Closeout 완료
- [x] error 상태: dogfooding 중 fallback enum(D4_FALLBACK_A/B/C/C_MULTI) 발생 시 사용자 노출 평이 문구 SSOT 사용 + 누락 없음 검증

## Exit Criteria

- [x] Phase objective 달성 — issue #646 본문 교체 + follow-up issue 2건(#679, #680) + Final 10-pass + review-impl overlay 모두 완료. **dogfooding 5건은 closeout 외부 monitoring 항목으로 분리** (본 PRD 작업으로 즉시 충족 불가, 시간 의존)
- [x] 모든 FR + SC 통합 검증 완료
- [x] PRD Status Complete
- [x] follow-up 외 deferred blocker 없음

## Phase-End Multi-Pass Review (= Final Multi-Pass Review)

본 phase는 마지막이라 Phase-End 10-pass와 Final 10-pass가 동일 절차로 수행된다.

- [x] 1. Intent/coverage — 모든 FR + SC가 Phase 1-5 통합으로 달성
- [x] 2. Correctness — fallback enum(D4_FALLBACK_A/B/C/C_MULTI) 시나리오, judgment-first 보호, D4 합의 알고리즘 4단계(보수적 합의 정의) + D2 fallback 4단계 모두 인스트럭션/grep/jq schema 검증으로 정합 확인. dogfooding 시간 의존 항목은 closeout 외부 monitoring (SC-4 deferred).
- [x] 3. Simplicity — 본 PRD 변경이 인스트럭션 + grep 패턴만, 코드 동작 변경 없음
- [x] 4. Code quality — 8개 파일 + 스크립트 + 본 PRD가 다음 LLM에게 명확
- [x] 5. Duplication/cleanup — Phase 1 schema/합의 알고리즘이 SSOT로 인용, 사본 없음
- [x] 6. Security/privacy — D4 hard rule + schema 검증 + judgment-first 보호로 trust boundary 유지
- [x] 7. Performance/load — 라운드당 1개 → turn 수 증가 (사용자 명시 수용), Codex 자문 30분 budget 내 두 layer (A-3 검증)
- [x] 8. Validation — 정적 grep + jq schema 검증 + bias-measurement 스크립트 + manual smoke가 risk-appropriate. dogfooding 5건은 closeout 외부 monitoring으로 분리 (시간 의존 — 본 PRD 작업으로 fabricate 금지).
- [x] 9. Future-phase review — N/A (마지막 phase)
- [x] 10. PRD sync review — master PRD Status `In Progress` → `Complete`, 모든 Phase Index Complete, Last Updated, Change Log 갱신
- [x] **review-impl overlay (Phase 5 추가)**: 6-classification 라벨링 + overbuilt 우선 분류 (`modules/shared/programs/claude/files/skills/plan-with-questions/references/review-impl/implementation-review.md`). auto-fix 미사용.
- [x] **PRD Closeout**: `.claude/prds/` 산출물이라 자동 활성화. PRD master Status Complete + 모든 phase Complete + Change Log 마지막 entry.

## Discoveries / Decisions

- **issue #646 본문 통째 교체는 PRD 작업 시작 전 이미 적용된 상태로 확인 — 별도 `gh issue edit`으로 재작성하지 않음**. 현 본문이 PRD master Problem/Discovery/데이터 출처/한계 섹션과 일치하므로 추가 변경은 불필요. 검증: `gh issue view 646`이 PRD master와 동일 evidence 표 + mermaid timeline + raw quote + flowchart + 데이터 출처 표 모두 포함 확인.
- **Follow-up issue 등록 결과**: #679 (다른 인터뷰 스킬에 PWQ Question UX 정책 적용 검토, G-5/SC-6, label `area:skills`+`priority:medium`), #680 (plan-file-template SSOT의 HEAD=&lt;sha7&gt; 권장과 pinning-guard.sh PATTERN_D 차단 충돌, F-OQ-1, label `area:skills`+`priority:medium`), #681 (closeout 외부 monitoring 단일 진입점 — SC-4 dogfooding 5건 + F-OQ-2 anchoring metric baseline + F-OQ-3 D4 합의 정의 강화 검토, label `area:skills`+`priority:medium`).
- **SC-4 deferred 결정**: dogfooding 5건은 본질적으로 시간 의존 검증으로, 본 PRD 작업으로 즉시 산출 불가. PRD spec에 이미 명시된 "수동 dogfooding"이라 본 phase에서 수동 evidence를 fabricate하지 않고 deferred로 정직 표기. F-OQ-2 (D4 anchoring 효과 손상 정량 baseline)와 함께 dogfooding accumulation 후 별도 follow-up issue로 평가.
- **Final Multi-Pass Review 10-pass 통과 (메인 LLM 직접 수행)**: Requirements coverage(FR-1~8 satisfied, SC-1/2/3/5/6 satisfied, SC-4 deferred), Cross-phase integration(SSOT 단일 + callsite 인용으로 정합), Correctness(D2 fallback + D4 fallback enum A/B/C/C_MULTI + judgment-first 보호 + happy path 모두 명시), Simplicity(인스트럭션 + grep 패턴만, 코드 동작 변경 없음 NFR-1), Cleanup(폐기 정책 명시적 컨텍스트 보존으로 회귀 방지), Security(자문 untrusted output trust boundary jq schema 검증, D4 hard rule, judgment-first 보호), Performance(turn 수 증가는 D1 trade-off 명시 수용, 자문 30분 budget 내 두 layer A-3 검증), Validation(정적 grep + jq + script + manual smoke risk-appropriate), Documentation(Change Log + Discoveries + script 헤더 주석 + Cross-Host Resume Guide 보존), PRD closeout(Status Complete + 모든 phase Complete + follow-up #679/#680 기록).
- **review-impl overlay (6-classification + overbuilt 우선)**: 6-classification 라벨링은 PRD 10-pass 1번/8번 finding 중 requirement-linked 항목에만 부여 — FR-1~8 + SC-1/2/3/5/6 모두 `satisfied`, SC-4는 `deferred` (PRD spec이 명시적 deferred 선언과 동등). overbuilt 우선 판정 — 후보 0건 (모든 변경이 NFR-1 인스트럭션 + grep 패턴, 미래 phase용 확장점 없음, 별도 workflow/서비스/DB 컬럼 없음, D2 fallback과 D4 알고리즘은 PRD spec이 명시 요구한 시스템).

## Phase Change Log

- 2026-05-05: Phase file created.
- 2026-05-05: Phase 5 Complete + PRD Closeout. issue #646 본문 PRD 결과 적용 상태 확인 (재작성 불필요), follow-up issue 2건 등록(#679, #680), Final 10-pass + review-impl overlay 통과. SC-4 deferred 정직 표기. Active Phase → 없음 (PRD Status Complete).
