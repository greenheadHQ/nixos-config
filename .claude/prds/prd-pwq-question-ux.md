# PRD: plan-with-questions Question UX — 1개씩 + 두 layer + 합의 추천

## Document Status

- Status: Complete
- File Mode: Split
- Current Phase: Phase 5 (Complete)
- Active Phase File: [Phase 5: Dogfooding and follow-up](./prd-pwq-question-ux/phase-05-dogfooding-and-followup.md) (Complete)
- Last Updated: 2026-05-05
- PRD File: `.claude/prds/prd-pwq-question-ux.md`
- Source: https://github.com/greenheadHQ/nixos-config/issues/646
- Supersedes: `.claude/plans/issue-646-pwq-question-ux.md` (mode 전환 — DL-3에 reference)
- Purpose: Living PRD / 실행 source of truth. 여기에서 작업을 체크 off 하고, 구현 중 새 사실이 드러나면 이 문서를 갱신하고, 계획이 바뀌면 진행 전에 후속 phase를 수정한다.

## Problem

`plan-with-questions` 스킬이 사용자에게 (1) 한꺼번에 묶어서, (2) 어려운 기술 용어로 질문을 던져 사용자가 이해 못 한 채 답변하거나 turn_abort 시키는 만성 패턴이 약 2.5개월간 지속되었다. 1.7GB 세션 로그 전수조사로 검증된 정량 evidence:

| 지표 | Mac CC | Mac Codex CLI | miniPC |
|---|---|---|---|
| 사용자 직접 PWQ invoke | 142 | 169 | 35 |
| 라운드당 4개 묶기 비율 | 17.9% | 0% (3개 max) | 20.3% |
| PWQ 세션 turn_aborted | — | **34.3% (58/169)** | — |
| 추천 라벨 노출 | — | **92.3% (180/195)** | — |

대표 사용자 발화: 2026-03-21 "WTF Moment", 2026-05-03 "지금 질문들 하나도 이해못하겠어 + 하나씩 다시 내게 질문하도록 해", 2026-05-05 issue/671 args 우회 지시, 2026-03-02 5회 반복 "초등학생에게 설명하듯".

Root cause 세 메커니즘 결합: SKILL.md Invariant 7 ("한번에 모아서") + consulting-step.md 출력 schema 미가공 노출 + AskUserQuestion 도구 description 추천 라벨 권장 ↔ anti-anchoring 1번 규칙 충돌.

## Goals

- G-1: 라운드당 질문 1개 강제로 사용자 인지 부하 제거.
- G-2: 자문 결과 schema에 user-facing layer 추가, 사용자에게는 비유+평이한 한국어만 노출.
- G-3: 추천 라벨 정책을 "허용 + 자문+합의 후 부착"으로 명시, 합의 미달 옵션에는 라벨 금지.
- G-4: judgment-first 라운드도 두 layer 분리 적용.
- G-5: 본 fix는 plan-with-questions에만 적용. 다른 인터뷰 스킬은 별도 follow-up issue로 즉시 등록.
- G-6: bias-measurement.md / scripts/ai/measure-anchoring-bias.sh의 anchoring 측정 metric을 새 라벨 정책에 맞춰 동시 갱신.

## Non-Goals

- NG-1: AskUserQuestion / `request_user_input` 도구 schema 자체 변경.
- NG-2: 다른 인터뷰 스킬 본문 수정 (G-5 follow-up issue로 분리).
- NG-3: 사용자 학습/persistence 기반 인지.
- NG-4: 자동 비유 생성 알고리즘 구현.
- NG-5: anti-anchoring 4 규칙 중 2/3/4번 변경. 1번만 폐기.
- NG-6: plan-file-template ↔ pinning-guard 충돌 자체 해결 — 별도 follow-up issue.

## Success Criteria

- SC-1 (정적, verifiable, source 기준): `rg "한번에 모아서" modules/shared/programs/claude/files/skills/plan-with-questions/`가 0건 또는 "폐기됨" 컨텍스트만 매칭. (deployed 재검증은 머지 + nrs 후 `~/.claude/skills/plan-with-questions/` — 본 PR 작업 시점에는 source path 정본)
- SC-2 (정적, verifiable, source 기준): `rg "Recommended" modules/shared/programs/claude/files/skills/plan-with-questions/`가 bias-measurement.md "Source label sanitization baseline" 화이트리스트 파일/섹션 안의 매칭만 (deployed 재검증도 머지 + nrs 후).
- SC-3 (schema): `references/consulting-step.md` 출력 JSON schema에 `user_facing` layer 필드 등장 + 1-shot 예시 포함.
- SC-4 (수동 dogfooding, **closeout 외부 monitoring — 추적 issue #681**): 다음 PWQ 호출 5건 수동 샘플 리뷰 — 라운드당 1개 + 합의 후 라벨만 + matrix 미노출. 본질적으로 시간 의존 검증이라 PRD 작업으로 즉시 충족하지 않으며, PRD Closeout 후 사용자 후속 PWQ 5건 누적 모니터링으로 평가한다 (F-OQ-2/F-OQ-3와 함께 dogfooding accumulation, 추적 단일 진입점은 #681).
- SC-5 (anchoring metric 일관성): bias-measurement.md/스크립트의 라벨 metric이 새 정책에 맞춰 갱신.
- SC-6 (follow-up issue): 다른 인터뷰 스킬 follow-up issue + plan-file-template/pinning-guard 충돌 follow-up issue 본 PRD 종료 즉시 등록.

## Key Scenarios

### Scenario 1: 트레이드오프 라운드 (정상 자문 통과 + 합의 PASS)
- Actor: PWQ 호출 사용자
- Trigger: 옵션 2+ 트레이드오프 발견 → Step 3.5 자문 호출
- Expected outcome: 자문 결과 user_facing layer만 사용자 노출, 메인 LLM이 D4 합의 알고리즘 4단계 실행 — 후보 정확히 1개로 좁혀진 경우 그 옵션에 (Recommended) 라벨 부착, 사용자가 한 라운드에 1개 질문만 받음.

### Scenario 2: 자문 timeout / parse fail
- Actor: 동일
- Trigger: Codex 자문 30분 budget 초과 또는 result.json invalid
- Expected outcome: D4_FALLBACK_A 내부 enum으로 격하 — 라벨 부착 금지, 모든 옵션을 라벨 없이 user_facing layer로만 표시. 사용자에게는 enum 라벨 대신 평이 한국어 문구만 노출 ("자문이 완료되지 못했어요. 추천 없이 옵션을 그대로 보여드릴게요").

### Scenario 3: judgment-first 라운드
- Actor: 동일
- Trigger: 트레이드오프 결정의 judgment-first 라운드 (기준 선택)
- Expected outcome: 기준 옵션 라벨/설명을 user_facing 평이 라벨로 표시, 추천 라벨 절대 부착 안 함 (anti-anchoring 효과 보호).

## Discovery Summary

- Reviewed (편집 대상은 Nix source path, 본 PR 작업 시점의 정적 검증은 모두 source path에서 수행 — deployed 검증은 머지 + nrs 후 closeout 외부 monitoring):
  - Source (편집 + Phase 1~5 정적 grep/jq 검증): `modules/shared/programs/claude/files/skills/plan-with-questions/SKILL.md`, `modes/for_action.md`, `modes/for_issue.md`, `modes/for_prd.md`
  - Source (편집 + 정적 검증): `modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md`, `output-templates.md`, `runtime-boundaries.md`, `bias-measurement.md`, `fanout-fanin.md`
  - Deployed (본 PR 작업 시점에는 PR 변경이 미반영 상태 — 머지 + nrs 후에만 source와 동기): `~/.claude/skills/plan-with-questions/...` (Mac과 miniPC 양쪽 호스트 동일). **본 PR 작업 시점의 모든 Validation Checklist는 source path를 정본으로 사용했고, deployed 재검증은 closeout 외부 monitoring 항목**.
  - `scripts/ai/measure-anchoring-bias.sh` (repo-relative, git tracked)
  - 1.7GB 세션 로그 (Mac Claude Code 968MB / Mac Codex CLI 785MB / miniPC 351MB)
- Current system: SKILL.md Invariant 7이 "한번에 모아서 왕복 횟수 최소화"로 묶기 권장. consulting-step.md 출력 schema 7키 evaluation_matrix가 사용자에 그대로 노출. AskUserQuestion 도구 description이 추천 라벨 권장 → anti-anchoring 1번 규칙 정면 위반 92.3%.
- Validation surface: 정적 grep + schema 검증 + 수동 5샘플. 자문 round-trip + fallback 시뮬레이션.
- Design implications:
  - D2 두 layer는 backward-compatible 유지 (fallback 알고리즘 plan에 명시).
  - D4 합의 알고리즘 4단계 + 4 fallback enum (A/B/C/C_MULTI)이 anti-anchoring 1번 폐기의 mitigation. schema 한계 내 보수적 합의 정의로 단순화 — 후보 정확히 1개일 때만 라벨 허용, 후보 2+는 사용자 양쪽 비교 + tentative 선호 표명. (D2 fallback 4단계는 별개 시스템 — user_facing 텍스트 복구 흐름.) Fallback enum 라벨은 내부 Decision Log 전용이며 사용자에게는 평이 한국어 문구만 노출.
  - judgment-first 라운드는 라벨 부착 절대 금지 (D3 anti-anchoring 보호).
- Confidence / gaps:
  - 메인 LLM의 "D4 합의 알고리즘 4단계" 안정 적용은 dogfooding 누적 후 평가 (F-OQ-2).
  - 도구 description의 추천 라벨 자동 권장이 LLM에 얼마나 강하게 작용하는지는 SC-2 grep으로만 검출 (실측 evidence 부재).

## Requirements

### Functional Requirements

- FR-1 (D1): PWQ 호출 시 라운드당 사용자 질문 도구 questions 배열 길이 1.
- FR-2 (D2): Step 3.5 자문 출력 schema에 `technical_matrix` (메인 LLM 내부) + `user_facing` (사용자 노출) 두 layer.
- FR-3 (D2 fallback): user_facing 누락 시 fallback 4단계 (legacy 필드명 호환 — `technical_matrix.요구충족` 우선, 없으면 `evaluation_matrix.요구충족` 사용 → generic 비유 → `D2_FALLBACK_USER_FACING` 내부 enum 으로 메인 LLM 자체 작성 + 사용자에게는 평이 한국어 문구로 출처 표기 → 자문 미수행 동등 처리).
- FR-4 (D3): judgment-first 라운드 옵션을 user_facing 평이 라벨로 표시 + 추천 라벨 부착 절대 금지.
- FR-5 (D4 합의 알고리즘): 라벨 부착 4단계 알고리즘 (자문 정상 → schema 검증 → 후보 필터 → 후보 1개일 때만 라벨 부착) + 4 fallback enum (A=자문 invalid, B=schema fail, C=후보 0, C_MULTI=후보 2+). schema 한계 내 보수적 합의 정의로 단순화 (자문 측 추천/반대 신호 필드 부재). enum 라벨은 내부 Decision Log 전용.
- FR-6 (D4 컨텍스트 강화): Step 3.5 자문 prompt에 신규 섹션 "현 상황 적합성 컨텍스트".
- FR-7 (D4 hard rule): SKILL.md/output-templates.md/consulting-step.md 세 곳에 "도구 default 무시 + 합의 미달 옵션 라벨 절대 금지" 명시.
- FR-8 (anchoring metric 일관성): bias-measurement.md + scripts 갱신, "허용 조건 컨텍스트 외 라벨 0건" baseline 적용.

### Non-Functional Requirements

- NFR-1: 본 변경은 인스트럭션 문서 수정 + grep 패턴 갱신만 (코드 동작 변경 없음). git revert 1 commit으로 복구 가능.
- NFR-2: D2 schema 변경은 backward-compatible (fallback 알고리즘 강제).
- NFR-3: D4 라벨 정책 변경은 backward-compatible (합의 미달 시 라벨 미부착으로 기존 라벨 금지와 동일 결과).
- NFR-4: 모든 phase는 사용자 명시 stop 또는 하위 스킬 BLOCKED 외에는 자체 생략 금지.

## Assumptions

- A-1: 메인 LLM이 D4 합의 알고리즘 4단계 + 4 fallback enum을 안정 실행한다 (dogfooding으로 검증).
- A-2: AskUserQuestion 도구 description의 추천 라벨 권장은 SKILL 본문 hard rule로 override 가능하다 (실측 evidence는 SC-2 grep으로 사후 검출).
- A-3: Codex 자문 30분 budget 내에 두 layer 출력이 가능하다.

## Dependencies / Constraints

- AskUserQuestion 도구 schema는 변경 불가 (NG-1).
- pinning-guard.sh PATTERN_D는 7자 hex 박제를 차단 (Baseline 형식 commit subject 자연어로 우회).
- Codex `request_user_input` 묶음 default 3개 (현재 패턴), 다른 인터뷰 스킬과의 cross-skill 라벨 의미 drift 가능 (G-5로 mitigation).

## Risks / Edge Cases

- 두 layer 충돌: technical_matrix가 옵션 약점 명시, user_facing이 강점 부각 시 합의 실패 처리 (D4 알고리즘 자동 연동).
- 합의 미달 후 fallback C 또는 C_MULTI 발생 시 사용자에게 "추천 없음" 평이 문구 보고 누락 위험 → output-templates.md 패턴 + consulting-step.md "Fallback enum" 표 SSOT에 명시.
- D4 합의 정의가 "자문 필터 통과 후 후보 1개"로 좁혀져 있어, 후보 2+ 케이스(C_MULTI)는 합의 PASS로 라벨링하지 않는다. future schema extension(자문 측 추천/반대 신호 필드 도입)으로 합의 의미 강화 가능 — 별도 follow-up.
- AskUserQuestion 도구가 자동 라벨 삽입하면 SC-2 grep으로 검출 후 수동 정정 필요.
- 다른 인터뷰 스킬과의 라벨 의미 drift는 G-5 follow-up issue로 mitigation, 본 PRD 범위 외.

## Execution Rules

- 본 PRD가 명시적으로 수정되지 않는 한 phase는 순서대로 완료한다.
- 어떤 phase든 시작 전에 master PRD + active phase file + 관련 context note를 읽는다.
- PRD 파일만 active plan으로 사용한다 (plan 파일은 supersede됨).
- 사소한 애매함은 가장 합리적인 옵션을 고르고 assumption으로 기록한 뒤 계속 진행한다.
- 다음 항목에 한해서만 진행을 멈추고 도움을 요청한다: 접근 권한 부재, 비가역적 파괴 변경, 주요 요구사항 충돌, 보안/법률 의미 risk.
- 검증 방법은 risk와 가용 도구에 맞춰 선택한다 (validation-paths.md 참조).
- 각 phase 종료 시 본 PRD를 갱신하고 학습 결과에 따라 후속 phase를 수정한다.

## Cross-Host Resume Guide

본 PRD는 Mac (darwin)과 miniPC (NixOS) 양쪽 호스트에서 resume 가능하다. 다음 두 가지를 인지하지 않으면 path 혼동으로 잘못 편집할 수 있다.

### 편집 대상 vs 읽기 대상의 분리

PWQ skill 본문은 **Nix source**가 정본이며, `~/.claude/skills/plan-with-questions/...`은 nrs로 deploy된 산출물이다. 비유: source는 **고치는 책상**, deployed는 **읽는 책장**. 책상에서 고치고 nrs로 책장에 옮긴다.

| 동작 | Path |
|---|---|
| **편집** (Phase 1~4 Implementation Checklist) | `modules/shared/programs/claude/files/skills/plan-with-questions/...` (repo, git tracked) |
| **읽기/검증** (Phase별 Validation Checklist `rg`) | `~/.claude/skills/plan-with-questions/...` (deployed, nrs 후 갱신됨) |
| **anchoring 스크립트** (Phase 4) | `scripts/ai/measure-anchoring-bias.sh` (repo-relative, git tracked) |

각 phase의 Implementation Checklist path는 **source(`modules/shared/...`)** 기준이고, **본 PR 작업 시점의 Validation Checklist `rg`도 source path에서 수행**한다 — 본 PR 머지 전이라 deployed(`~/.claude/skills/...`)는 PR 변경이 미반영 상태이기 때문이다. 머지 + nrs 후에만 deployed가 source와 동기화된다 (Cross-Host Resume Guide의 "Resume 절차" Step 6 nrs 실행이 그 시점).

### Resume 절차 (Mac → miniPC 또는 그 반대)

1. **Pull**: `git pull origin issue/646` — PRD master + 5 phase + (이미 완료된 phase의) PWQ source 변경 모두 sync.
2. **Baseline drift 검증**: `git log -1 --pretty=format:"%s"`의 commit subject가 PRD master의 `Baseline` 필드 commit subject와 동일한지 확인. 다르면 새 baseline으로 PRD `Baseline` 갱신.
3. **PRD Status 읽기**: PRD master의 `Current Phase`, `Active Phase File`, `Last Updated`, `Phase Index` Status 컬럼으로 현재 진행 단계 파악.
4. **Active Phase File 진입**: Phase Discovery Gate 읽고 모든 체크박스 통과 확인.
5. **Phase Implementation Checklist 진행**: Edit 대상은 Nix source(`modules/shared/...`). 단순 파일 편집.
6. **nrs 실행**: `nrs` (Mac은 darwin-rebuild, miniPC는 nixos-rebuild) — 편집한 source가 `~/.claude/skills/...`에 deploy.
7. **Validation Checklist 진행**: nrs 실행 후라면 `rg`는 deployed path(`~/.claude/skills/...`) 또는 source path 어느 쪽에서든 동일 결과 보장. **nrs 실행 전(예: PR 작업 중)이라면 source path만 정본** — deployed는 PR 변경 미반영 상태.
8. **Phase-End Multi-Pass Review + PRD master sync**: Phase Index Status `Not Started` → `Complete`, `Active Phase File`을 다음 phase로 갱신, `Last Updated` + `Change Log` 갱신.
9. **Phase commit + push**: 다른 호스트가 다음 phase resume 가능.

### 양 호스트 동시 작업 회피

같은 phase를 두 호스트에서 동시에 작업하지 않는다. PRD `Current Phase`를 lock으로 사용 — 한 호스트가 phase 시작 시 `In Progress`로 갱신·commit·push, 종료 시 `Complete`로 갱신·commit·push.

### 자문/DA raw output ephemeral 주의

Step 3.5 자문 결과(`/tmp/consult-*`)와 DA reviewer/Arbiter 산출물(`/tmp/da-*`, `/tmp/arb-*`)은 cleanup된다. PRD master Decisions + Decision Log에 모든 결정이 통합되어 있어 normally 재현 불필요. 단, Phase 진행 중 raw 자문이 다시 필요하면 새 Step 3.5 round를 호출한다 (consulting-step.md SSOT 따라).

## Phase Index

| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: Schema and Anchoring | Complete | references/consulting-step.md 출력 schema 두 layer + fallback + 합의 알고리즘 + Anti-anchoring 1번 재작성 + 4번 라운드 라벨 금지 | rg + schema + dummy decision round-trip | [phase-01-schema-and-anchoring.md](./prd-pwq-question-ux/phase-01-schema-and-anchoring.md) |
| Phase 2: SKILL and modes flow | Complete | SKILL.md Invariant 7 + modes/for_action.md Step 4 합의 알고리즘 호출 + modes/for_issue.md Step I-4 1개 통일 + modes/for_prd.md 차용 | rg + 본 PRD self-test | [phase-02-skill-and-modes-flow.md](./prd-pwq-question-ux/phase-02-skill-and-modes-flow.md) |
| Phase 3: Output templates and runtime | Complete | references/output-templates.md Step 4/I-4 패턴 + references/runtime-boundaries.md 라운드 정책 통일 | rg + 패턴 일관성 manual | [phase-03-output-templates-and-runtime.md](./prd-pwq-question-ux/phase-03-output-templates-and-runtime.md) |
| Phase 4: Bias measurement | Complete | references/bias-measurement.md + scripts/measure-anchoring-bias.sh 라벨 metric 갱신 | 스크립트 실행 + grep | [phase-04-bias-measurement.md](./prd-pwq-question-ux/phase-04-bias-measurement.md) |
| Phase 5: Dogfooding and follow-up | Complete | 수동 5샘플 + issue #646 본문 교체 + follow-up issue 2건 등록 + Final 10-pass | 수동 dogfooding + gh issue create | [phase-05-dogfooding-and-followup.md](./prd-pwq-question-ux/phase-05-dogfooding-and-followup.md) |

## Final Multi-Pass Review After All Phases

`~/.claude/skills/plan-with-questions/references/prd/multi-pass-review.md` 체크리스트를 참조하여 메인 에이전트가 직접 수행한다 (fan-out 금지). PRD Closeout 항목은 `.claude/prds/` 산출물이라 자동 활성화.

review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류)도 Final 단계에 적용한다 (`~/.claude/skills/plan-with-questions/references/review-impl/implementation-review.md`).

## Open Questions

- F-OQ-1 [BLOCKER for downstream — defer to follow-up issue]: plan-file-template SSOT의 `HEAD=<sha7>` 권장과 `pinning-guard.sh` PATTERN_D 차단 충돌 — 별도 issue로 즉시 등록 (Phase 5).
- F-OQ-2 [tracked by #681]: D4 anchoring 효과 손상 정량 측정 방법 — 합의 알고리즘 적용 후 dogfooding 누적으로 baseline 산출. SC-4와 함께 #681에서 추적.
- F-OQ-3 [tracked by #681]: D4 합의 정의 강화 — 자문 출력 schema에 `advisor_fit_signal`/`blocking_reasons` 같은 자문 측 추천/반대 신호 필드 추가하여 (Recommended) 라벨 의미를 "자문 신호와 메인 LLM 후보 일치"로 강화. 본 PR 작업 시점의 자동 검토에서 D4 라벨이 schema에 신호 없이 메인 LLM 휴리스틱으로만 만들어진다는 우려가 두 번 잡혔으나, 사용자 D4 결정("라벨 허용 + 합의 조건")을 본 PR 자동 반영으로 뒤집지 않는다 — 본 PR 머지 후 dogfooding 누적 시 라벨 신뢰도 평가 + schema extension 또는 라벨 자체 약화 결정. F-OQ-2/SC-4와 함께 #681에서 추적.

기존 plan 5건 Open Questions 중 3건은 본 PRD 결정 통합:
- ~~자문 미수행 시 라벨 부착 폴백~~ → FR-5 fallback enum (A/B/C/C_MULTI)으로 통합.
- ~~for_issue 4개 → 1개 통일 vs 4개 유지~~ → FR-1에서 1개 통일 결정.
- ~~다른 인터뷰 스킬 별도 이슈~~ → SC-6 + Phase 5 즉시 등록.

## Change Log

- 2026-05-05: Initial PRD created. Plan `.claude/plans/issue-646-pwq-question-ux.md`에서 mode 전환 (split-file 5 phase, Phase ≥4 자동 트리거 + 다중 도메인). 사용자 5결정(D1~D5) + Step 3.5 Codex xhigh 자문 + Step 5 DA Arbiter 17 CONFIRMED 모두 본 PRD 본문에 통합. plan 파일은 superseded 표시.
- 2026-05-05: Cross-Host Resume Guide 단락 추가 (사용자 인터뷰 — Mac과 miniPC 양쪽 호스트 resume 시나리오 명시 필요). Discovery Summary와 5개 phase 파일의 Implementation Checklist path를 deployed(`~/.claude/skills/...`)에서 source(`modules/shared/programs/claude/files/skills/plan-with-questions/...`)로 정정. Validation은 source 또는 nrs 후 deployed 양쪽 가능 — Cross-Host Resume Guide에 명시.
- 2026-05-05: Phase 1 (Schema and Anchoring) Complete. consulting-step.md에 두 layer schema(`technical_matrix` + `user_facing`) + 1-shot dummy 예시 + D4 합의 알고리즘 5단계 + D2 fallback 4단계 + 4 fallback 라벨 + 신규 "현 상황 적합성 컨텍스트" 입력 섹션 + judgment-first 라운드 라벨 금지 + 셸 호출 3 schema-level 검증 + D4 hard rule 단락 모두 반영. Validation: rg(user_facing 19, fallback A 4, 현 상황 적합성 컨텍스트 2, technical_matrix 15, FALLBACK_* 10) + jq 1-shot dummy round-trip 통과. Active Phase → Phase 2.
- 2026-05-05: Phase 2 (SKILL and modes flow) Complete. SKILL.md에 새 Invariant 8(라운드당 1개 + D4 hard rule) 추가, line 115 "주의사항" 정정, modes/for_action.md Step 4 본문 재작성(D1/D2/D4 합의 알고리즘 호출 + judgment-first 라벨 금지 + fallback A/B/C/D 사용자 보고 표 + D4 hard rule), modes/for_issue.md Step I-4를 라운드당 1개로 통일하고 트레이드오프 정책은 for_action callsite 인용, modes/for_prd.md 차용 단락에 D1/D2/D4 동일 적용 명시. Validation: rg("한번에 모아서" 폐기 컨텍스트만 2건 / "라운드당 최대 4개" 폐기 컨텍스트만 1건 / "라운드당 1개"·"라운드당 질문 1개" 합산 5건 / for_action "합의 알고리즘" 3건) 통과. Active Phase → Phase 3.
- 2026-05-05: Phase 3 (Output templates and runtime) Complete. references/output-templates.md Step 4/I-4 패턴을 라운드당 1개 강제 + user_facing layer 사용 의무 + D4 합의 알고리즘 호출 + hard rule + judgment-first 라벨 금지 + 라운드별 룰 매트릭스 7행(일반/트레이드오프 정상/fallback A·B·C·D/judgment-first)으로 재작성. references/runtime-boundaries.md request_user_input 페이로드 가이드의 폐기 정책(for_issue 4→3 자동 축소, Recommended 절대 금지)을 D1 라운드당 1개 강제 + D4 합의 PASS 시 부착으로 정정하고 "for_action·for_issue 라운드 정책 통일" 단락 추가. Validation: rg("라운드당 1개" output-templates 1건 / user_facing 9건 / judgment-first 라벨 금지 단락 명시 / Recommended 매칭 모두 허용 조건·hard rule·D4 합의 알고리즘 컨텍스트만 — SC-2 통과 / runtime-boundaries 라운드 정책 통일 단락 등장). bias-measurement.md L36의 "Recommended" anchor 키워드는 Phase 4 측정 metric 갱신 컨텍스트로 phase 4에서 다룬다. Active Phase → Phase 4.
- 2026-05-05: Phase 4 (Bias measurement) Complete. references/bias-measurement.md에 "Source label sanitization baseline (D4 정책 일관성)" 단락 추가 — transcript 4축 metric과 별개로 PWQ source 본문에서 (Recommended) 라벨이 D4 합의 PASS / hard rule / 허용 조건 컨텍스트로만 등장하는지 inline rg 명령으로 검증하는 절차 + 허용 컨텍스트 키워드 catalog (3 카테고리). axis-2 framing catalog의 "Recommended" 키워드가 transcript 측정 catalog 용도임을 명시 (D1/D2/D4 도입 후에도 transcript metric 변경 불필요). scripts/ai/measure-anchoring-bias.sh 헤더 주석에 source sanitization SSOT 위치(bias-measurement.md "Source label sanitization baseline" 섹션) + 두 cadence 분리 이유 명시. Validation: source sanitization rg(Recommended 매칭 모두 허용 컨텍스트 catalog로 grep -v 후 EXIT=1 — baseline PASS), transcript 스크립트 실행(--skip-ssh exit 0, minipc 543 transcripts 정상 측정). Active Phase → Phase 5.
- 2026-05-05: Phase 5 (Dogfooding and follow-up) Complete + **PRD Closeout**. issue #646 본문은 PRD Problem/Discovery 결과로 이미 교체 상태 확인 (별도 edit 불필요). Follow-up issue 2건 등록 — #679 (다른 인터뷰 스킬에 PWQ Question UX 정책 적용 검토, G-5/SC-6), #680 (plan-file-template SSOT의 HEAD=&lt;sha7&gt; 권장과 pinning-guard.sh PATTERN_D 차단 충돌, F-OQ-1). Final Multi-Pass Review 10-pass + review-impl overlay (6-classification + overbuilt 우선) 메인 LLM이 직접 수행: FR-1~FR-8 모두 satisfied, SC-1/2/3/5/6 satisfied, **SC-4 (수동 dogfooding 5건) deferred** — 사용자 후속 PWQ 5건 누적 모니터링이 본질적으로 시간 의존이라 본 PRD 작업으로 즉시 충족 불가. overbuilt 후보 0건 (모든 변경이 인스트럭션 + grep 패턴, NFR-1으로 코드 동작 변경 없음, 미래 phase용 확장점 없음). PRD master Status In Progress → Complete, 모든 Phase Index Complete.
