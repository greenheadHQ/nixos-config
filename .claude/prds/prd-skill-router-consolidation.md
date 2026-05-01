# PRD: Skill Router Consolidation (Issue #611)

## Document Status
- Status: Complete
- File Mode: Split
- Current Phase: Complete (Phase 1-5 all done)
- Active Phase File: N/A (all phases closed)
- Last Updated: 2026-05-01
- PRD File: `.claude/prds/prd-skill-router-consolidation.md`
- Source: [Issue #611](https://github.com/greenheadHQ/nixos-config/issues/611) (greenheadHQ/nixos-config)
- Baseline: branch=main, HEAD=f7c818b, dirty=clean (PR #612 merged 2026-05-01T05:52:07Z)
- Purpose: Living PRD / 실행 source of truth. 사용자 facing single entry point 비전을 위해 `/prd`, `/review-implementation` standalone 스킬을 plan-with-questions로 흡수한다. plan-with-questions가 작성한 임시 plan(`/tmp/plan-c54b0af3-611-lSbrfj/plan.md`)은 handoff seed이며, 본 PRD가 SSOT다 (DL-14).

## Problem

PR #612(머지 완료, f7c818b)는 plan-with-questions 자체 개편(progressive disclosure + Step 3.5 외부 자문 + for_prd handoff wrapper + Living checkbox 강제)을 phase 1로 완료했다. 그러나 `/prd`와 `/review-implementation`은 standalone 스킬로 살아 있어 사용자가 직접 호출 가능하다.

사용자 비전(PR #612 종료 시점 코멘트): "plan-with-questions를 중앙 집중식 라우터로, /prd · /review-implementation 직접 호출 안 하고 모든 것이 plan-with-questions에 all-in-one." 본 작업은 그 phase 2(완전 흡수)다.

## Goals

- G-1: 사용자 facing 진입점을 plan-with-questions 하나로 통일.
- G-2: `/prd`, `/review-implementation`의 references를 plan-with-questions 하위로 물리 이동 (단 `validation-paths.md`만 평면 위치).
- G-3: standalone `/prd`, `/review-implementation` SKILL.md + evals/queries.json + 디렉토리 완전 제거.
- G-4: 흡수 trigger를 plan-with-questions evals/description에 추가 (positive + negative + ambiguous case 포함). advanced mode flag는 폐기.
- G-5: lefthook eval-tests + ai-skills-consistency hook(보조) + verify-ai-compat.sh 통과 보장.
- G-6: Codex/Claude 양쪽 skill exposure SoT 동기화.

## Non-Goals

- NG-1: standalone 호출 fallback 안내 추가 — system unknown 그대로 (DL-7).
- NG-2: review-implementation의 fix mode 활성화 — PR #612 NG-2 유지.
- NG-3: `/prd` Living PRD 작성 흐름 자체 변경 — 작성·갱신 로직은 그대로.
- NG-4: skill 시스템 외부 `_shared/` 영역 도입 (round 2 거부). `validation-paths.md`만 plan-with-questions/references/ 평면 위치는 round 3 채택 (DL-16).
- NG-5: PR #612 plan의 "/prd 스킬 자체 폐기 안 함" 유지 — 본 작업으로 변경됨 (DL-8).
- NG-6: advanced mode (`for_prd_update`, `for_impl_review`) 추가 — round 3 폐기 (DL-12).

## Success Criteria

- SC-1: 사용자가 'PRD 작성해줘', '구현 감사', '스펙 대비 감사', 'overbuilt 검사' 등 입력 시 plan-with-questions만 매치 (eval-tests positive case 통과).
- SC-2: 일반 코드 리뷰, 단일 plan, PR 코멘트 같은 입력은 plan-with-questions로 흡수되지 않음 (eval-tests negative case 통과).
- SC-3: `/prd/`, `/review-implementation/` 디렉토리 부재 + `~/.claude/skills/{prd,review-implementation}` symlink 부재 + `~/.codex/skills/{prd,review-implementation}` symlink 부재.
- SC-4: `claude/default.nix`에서 declaration 2개 제거. `codex/default.nix`의 `exposedCodexSkills`에서 두 entry 제거. `verify-ai-compat.sh`의 `EXPECTED_EXPOSED`에서 두 entry 제거. `nrs` 빌드 성공 + `./scripts/ai/verify-ai-compat.sh` 통과.
- SC-5: lefthook `eval-tests` 통과. `ai-skills-consistency` hook은 보조 검증 (shared user-scope symlink 회귀는 verify-ai-compat.sh + 명시 test가 강제).
- SC-6: plan-with-questions for_prd round-trip dogfooding 성공 (가상 시나리오: 이슈 ref → PRD 작성 + phase 진행 + Final review).

## Key Scenarios

### Scenario 1: 사용자가 'PRD 작성해줘' 입력
- Actor: 사용자 (greenhead)
- Trigger: chat 입력 'PRD 작성해줘' 또는 동등 자연어
- Expected outcome: plan-with-questions가 자동 매치 → for_prd 모드 자동 트리거 또는 사용자가 명시 `/plan-with-questions for_prd <ref>` 호출 → for_prd 모드 인터뷰 → `.claude/prds/`에 PRD 직접 작성. `/prd` 직접 호출은 unknown command.

### Scenario 2: 사용자가 '구현 감사' 입력
- Actor: 사용자
- Trigger: chat 입력 '구현 감사', '스펙 대비 감사', 'overbuilt 검사'
- Expected outcome: plan-with-questions for_action 모드 진입 + Post-Implementation 5번 Final review에서 PRD 10-pass + review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류) 수행 (auto-fix 미사용, NG-2; DL-20). `/review-implementation` 직접 호출은 unknown command.

## Discovery Summary

- **Reviewed**:
  - `modules/shared/programs/claude/files/skills/{plan-with-questions,prd,review-implementation,run-da}/` 전체.
  - `modules/shared/programs/claude/default.nix:236-240`, `codex/default.nix:34-228`, `scripts/ai/verify-ai-compat.sh:349-357`, `lefthook.yml`, `tests/run-eval-tests.sh`, `scripts/ai/warn-skill-consistency.sh`.
  - PR #612 머지 (f7c818b, 2026-05-01T05:52:07Z, main).
- **Current system**: plan-with-questions가 이미 prd 5 references + review-implementation을 link 차용 중. PR #612로 progressive disclosure + Step 3.5 외부 자문 + for_prd handoff wrapper + Living checkbox 도입 완료. standalone /prd, /review-implementation은 살아 있어 사용자 직접 호출 가능.
- **Validation surface**: static rg, lefthook eval-tests + ai-skills-consistency, verify-ai-compat.sh, run-eval.sh (skill-eval), nrs build, dogfooding round-trip.
- **Design implications**:
  - SKILL.md 부재 디렉토리는 skill discovery에 등록 안 됨 (line 192 of warn-skill-consistency 패턴).
  - `home.activation.syncCodexConfig`(codex/default.nix:166-228)이 SKILL.md 없는 디렉토리는 .agents/skills/ 투영 대상에서 제외 + orphan 자동 정리.
  - default.nix `mkOutOfStoreSymlink`로 디렉토리 통째 symlink — declaration 제거 시 nrs 빌드 후 자동 사라짐.
  - codex 측 SoT(exposedCodexSkills + verify-ai-compat.sh) 동기화 필수 (DA F1/F11/F13).
- **Confidence / gaps**:
  - 외부 LLM이 학습 데이터에서 `/prd`, `/review-implementation`을 standalone으로 알고 있을 가능성 — description note + dogfooding으로 보정.
  - run-da → plan-with-questions/references/ cross-skill 의존 방향 어색함 — DL-16에서 일부 평면 위치(`validation-paths.md`)로 완화하되 NGMI 우려 인정.

## Requirements

### Functional Requirements

- FR-1: standalone `/prd` SKILL.md, evals/queries.json, evals/, references/, prd/ 디렉토리 모두 git에서 삭제.
- FR-2: standalone `/review-implementation` SKILL.md, evals/queries.json, evals/, references/, review-implementation/ 디렉토리 모두 git에서 삭제.
- FR-3: `prd/references/validation-paths.md`을 `plan-with-questions/references/validation-paths.md` (평면)로 git mv. 나머지 4개 references는 `plan-with-questions/references/prd/` 하위로 git mv.
- FR-4: `review-implementation/references/requirement-status.md`을 `plan-with-questions/references/review-impl/requirement-status.md`로 git mv.
- FR-5: `claude/default.nix:236-240`의 prd, review-implementation symlink declaration 2개 제거.
- FR-6: `codex/default.nix:38-51`의 `exposedCodexSkills`에서 `"prd"`, `"review-implementation"` 두 entry 제거.
- FR-7: `scripts/ai/verify-ai-compat.sh:349-357`의 `EXPECTED_EXPOSED`에서 `prd`, `review-implementation` 두 entry 제거.
- FR-8: `plan-with-questions/SKILL.md` description에 흡수 trigger 추가 (`PRD 작성`, `구현 감사`, `스펙 대비 감사`, `overbuilt 검사`, `Living PRD`, `phase 계획`, `PRD 업데이트`, `문서 대비 구현 리뷰` 등 8-12개). references 차용 link 갱신.
- FR-9: `plan-with-questions/evals/queries.json`에 흡수 trigger positive case 8-12개 + negative case 4-6개 + ambiguous case 2-3개 추가. 기존 "Living PRD 작성" entry false→true.
- FR-10: `plan-with-questions/modes/{for_prd.md,for_action.md}` 및 `plan-with-questions/references/{post-implementation.md,task-size-routing.md,runtime-boundaries.md,resume-state.md,plan-file-template.md,consulting-step.md}` 9 파일의 `/prd`·`/review-implementation` 참조 link 갱신.
- FR-11: `run-da/SKILL.md:75`의 `../prd/references/validation-paths.md` link를 `../plan-with-questions/references/validation-paths.md`로 갱신.
- FR-12: `run-da/references/arbiter-prompt.md:192-196`의 `~/.claude/skills/prd` 경로 example 갱신 또는 obsolete annotation.
- FR-13: `plan-with-questions/modes/for_prd.md` 본문에 PRD 갱신·review-only 자연어 입력 처리 가이드 추가 (advanced mode 부재 보완, DL-12).

### Non-Functional Requirements

- NFR-1: 모든 변경은 단일 PR + 5 commit으로 분할. revert 단위 단일.
- NFR-2: lefthook pre-commit hook 모두 통과 (`eval-tests`, `ai-skills-consistency`(보조), `gitleaks`, `nixfmt`, `shellcheck`, `codex-hook-fixtures`).
- NFR-3: `./scripts/ai/verify-ai-compat.sh` 통과.
- NFR-4: `nrs` 빌드 성공.
- NFR-5: `~/.claude/skills/{prd,review-implementation}` 및 `~/.codex/skills/{prd,review-implementation}` symlink 부재 검증 (`test ! -e`).
- NFR-6: 도구-중립 용어 유지 (#599 cleanup 패턴 준수).

## Assumptions

- A-1: PR #612가 main에 머지된 상태에서 작업 시작. 추가 stack 불필요.
- A-2: 사용자가 익숙한 `/prd` 직접 호출이 unknown command가 되어도 silently breaking으로 간주하지 않음 (DL-7). announcement-only fallback이며 PR 본문에서 안내.
- A-3: `home.activation.syncCodexConfig`(codex/default.nix:166-228)는 (a) SKILL.md 있는 디렉토리만 `.agents/skills/`에 symlink로 추가하고(line 192 `[ -f "$source_skill_dir/SKILL.md" ] || continue`), (b) 이미 만들어졌던 symlink가 SOURCE 디렉토리 부재 시 orphan으로 자동 정리한다(line 220-230). 따라서 standalone SKILL.md 삭제 후 `.agents/skills/{prd,review-implementation}` symlink는 (i) 처음부터 부재였으면 그대로 부재 유지, (ii) 존재했었으면 orphan removal로 정리. 두 경로 모두 사용자 추가 작업 불필요. (현재 ls 결과에서 부재 확인 — Phase 1 Discovery Gate에서 baseline 재확인.)
- A-4: 외부 의존자 없음 (rg 검증으로 repo 외부 `/prd`, `/review-implementation` 직접 차용 발견되지 않음 — 단 추가 검증 Phase 5에서).

## Dependencies / Constraints

- PR #612 (plan-with-questions 자체 개편 phase 1) 머지됨. base = main, f7c818b.
- nixos-config selfhost. 사용자 1인 (greenhead). Living dogfooding.
- main-agent-only / single-writer 경계 (PR #612 Invariant 5) 유지.
- Codex/Claude Code 양쪽 호환 (도구-중립 용어).
- `lefthook.yml` pre-commit hook 정합성 보장.

## Risks / Edge Cases

- 외부 LLM이 학습 데이터에서 `/prd`, `/review-implementation`을 standalone으로 학습한 가능성 → description trigger 추가 + dogfooding으로 보정.
- run-da → plan-with-questions/references cross-skill 의존 방향 어색 → DL-16 일부 평면 위치로 완화. NGMI 우려는 인정.
- review-implementation/SKILL.md의 `../prd/references/validation-paths.md` link → SKILL.md 자체 삭제로 자동 소멸.
- `.agents/skills/{prd,review-implementation}` symlink 상태 → A-3 두 경로 모두 자동 처리 (부재 유지 또는 orphan removal). Phase 1 Discovery Gate에서 baseline 재확인.

## Execution Rules

- 본 PRD가 명시적으로 수정되지 않는 한 phase는 순서대로 완료한다.
- 어떤 phase든 시작 전에 master PRD + active phase file + 관련 context note를 읽는다.
- PRD 파일만 active plan으로 사용한다. 경쟁하는 별도 체크리스트를 만들지 않는다 (임시 plan은 handoff seed로만 보존).
- 사소한 애매함은 가장 합리적인 옵션을 고르고 assumption으로 기록한 뒤 계속 진행한다.
- 다음 항목에 한해서만 진행을 멈추고 도움을 요청한다: 접근 권한 부재, 비가역적 파괴 변경, 주요 요구사항 충돌, 보안/법률 관련 의미 있는 risk.
- 목표를 만족하는 최소·가역적 변경을 선호한다.
- 명백한 사유가 없는 한 기존 코드 패턴을 보존한다.
- 검증 방법은 risk와 가용 도구에 맞춰 선택한다 (`plan-with-questions/references/validation-paths.md` 참조).
- 각 phase 종료 시 본 PRD를 갱신하고 학습 결과에 따라 후속 phase를 수정한다.
- **Living checkbox 갱신 의무** (PR #612 Invariant 7): 각 단계(Phase Discovery Gate, Implementation Checklist, Validation Checklist, Exit Criteria, Phase-end review) 완료 즉시 본문 `- [ ]`를 `- [x]`로 갱신. lazy/end-of-session bulk update 금지.

## Phase Index

| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: Design Lock-in | **Complete** | DL-1~17 SSOT lock + 변경 대상 파일 목록 확정 + Discovery Gate | static rg, plan-with-questions Invariants 검토 | [phase-01-design-lockin.md](./prd-skill-router-consolidation/phase-01-design-lockin.md) |
| Phase 2: References Move | **Complete** | references 6 파일 git mv + plan-with-questions 본인 link 갱신 (9 파일) | static rg 확장 패턴, link 무결성 | [phase-02-references-move.md](./prd-skill-router-consolidation/phase-02-references-move.md) |
| Phase 3: Standalone Removal + Claude SoT | **Complete** | standalone SKILL.md/evals/디렉토리 제거 + claude/default.nix declaration 제거 | nrs build, ~/.claude/skills/{prd,review-implementation} 부재 | [phase-03-standalone-removal.md](./prd-skill-router-consolidation/phase-03-standalone-removal.md) |
| Phase 4: Codex SoT + Trigger Absorption | **Complete** | codex/default.nix + verify-ai-compat.sh 갱신 + plan-with-questions trigger 흡수 + skill 본문 cleanup | run-eval.sh, verify-ai-compat.sh, ~/.codex/skills 부재 | [phase-04-codex-sot-trigger.md](./prd-skill-router-consolidation/phase-04-codex-sot-trigger.md) |
| Phase 5: Cross-Skill Link + Validation + Final Review | **Complete** | run-da link 갱신 + lefthook 통과 + dogfooding + parallel-audit + Final 10-pass + review-impl overlay | lefthook full, parallel-audit, multi-pass review | [phase-05-validation-final-review.md](./prd-skill-router-consolidation/phase-05-validation-final-review.md) |

## Final Multi-Pass Review After All Phases

`plan-with-questions/references/prd/multi-pass-review.md` (이동 후 위치) 체크리스트를 따른다 (10-pass: Requirements coverage, Cross-phase integration, Correctness, Simplicity, Cleanup, Security/privacy, Performance, Validation, Documentation, **PRD closeout**). 추가로 `plan-with-questions/references/review-impl/requirement-status.md` overlay (6-classification 라벨링 + overbuilt 우선 분류)를 통합 수행 (auto-fix 미사용, NG-2; DL-20).

본 PRD는 `.claude/prds/` 하위에 위치하므로 PRD Closeout 항목 자동 활성화.

## Open Questions

- [x] 흡수 trigger positive/negative/ambiguous case의 정확한 query 목록 — Phase 4에서 확정 (evals/queries.json에 18 entry 추가, 12 흡수 trigger 모두 PASS).
- [x] `run-da/references/arbiter-prompt.md:192-196` example 갱신 vs obsolete annotation — Phase 5에서 갱신 채택 (set-icons 실재 placeholder + 가상 시나리오 명시).

## Decision Log

### DL-1: for_prd 자동 트리거 채택
- **Status**: accepted
- **Context**: Issue #611은 4-6 phase + 3 skill 동시 변경 + epic 보조 신호로 Phase ≥4 단독 트리거 hit.
- **Decision**: plan-with-questions가 for_action 진입 후 task-size-routing 알고리즘으로 PRD 후보 감지 → 사용자 1회 알림 + opt-out → 사용자 동의로 for_prd 모드 진입.
- **Consequences**: Living PRD 모드. .claude/prds/ 정본에 작성. phase 추적, decision 추적, baseline drift 검증 가능.

### DL-2: 평가 1순위 = 사용자 비전 충실
- **Status**: accepted
- **Context**: round 1에서 사용자가 평가 기준 1순위로 "사용자 비전 충실"(single entry point 강도) 선택.
- **Decision**: 모든 후속 트레이드오프에서 사용자 비전 우선. 구현비용/회귀위험은 부차적.
- **Consequences**: standalone 직접 호출 표면 제거 강도 우선. 작은 회귀 우려보다 단순화 우선.

### DL-3: standalone SKILL.md + evals 완전 제거 (DEC-B = B)
- **Status**: accepted
- **Context**: round 1 응답. stub 또는 metadata note만 추가하는 옵션 거부.
- **Decision**: `prd/SKILL.md`, `prd/evals/queries.json`, `review-implementation/SKILL.md`, `review-implementation/evals/queries.json` + 디렉토리 모두 git에서 삭제.
- **Consequences**: 사용자 `/prd` 직접 입력 → unknown command (DL-7과 결합). skill discovery에 등록 안 됨. 사용자 비전 충실.

### DL-4: references plan-with-questions 하위 물리 이동 (DEC-A_v2 = A2)
- **Status**: accepted (DL-16으로 일부 갱신)
- **Context**: round 2 응답. inline/_shared/references-only 거부.
- **Decision**: references를 `plan-with-questions/references/{prd,review-impl}/` 하위로 git mv. standalone 디렉토리 제거 + claude/default.nix declaration 제거.
- **Consequences**: plan-with-questions가 단일 owner. cross-skill 차용 시 의존 방향 plan-with-questions → 다른 skill (run-da 등)이 차용.

### DL-5: 흡수 trigger 추가 (DEC-D_v2 = D3 → D1 변형)
- **Status**: accepted (DL-12로 advanced mode 부분만 폐기)
- **Context**: round 2에서 D3 (흡수 + advanced mode) 채택. round 3에서 advanced mode 부분 폐기.
- **Decision**: plan-with-questions evals/description에 흡수 trigger positive + negative + ambiguous case 추가. advanced mode 폐기.
- **Consequences**: 사용자 'PRD 작성해줘' 입력 시 plan-with-questions만 매치. advanced mode (`for_prd_update`, `for_impl_review`) 안 만듦.

### DL-6: 단일 PR (DEC-C = B)
- **Status**: accepted
- **Context**: round 2 응답. PR별 분리 거부.
- **Decision**: 18+ file 변경을 단일 PR + 5 commit으로 처리.
- **Consequences**: 일관성 보장. revert 단위 단일. round 3에서 advanced mode 폐기로 PR 분리 우려 자동 해결.

### DL-7: standalone 호출 fallback = system unknown
- **Status**: accepted
- **Context**: round 2 응답. announcement-only / 자동 redirect 거부.
- **Decision**: `/prd`, `/review-implementation` 직접 입력 시 시스템 default unknown command 그대로 수용.
- **Consequences**: 사용자 1인 selfhost 맥락에서 silently breaking 수용. PR 본문에 announcement-only.

### DL-8: NG-1 변경 (PR #612 plan)
- **Status**: accepted
- **Context**: PR #612 plan은 "/prd 스킬 자체 폐기 안 함"을 NG-1로 명시. 본 작업이 그 NG를 변경.
- **Decision**: NG-1을 "user-facing standalone 폐기, references는 plan-with-questions 하위로 흡수"로 변경. PR #612 plan은 obsolete (단 supersede 명시는 PR #612 plan 본문에 별도 추가 안 함 — 본 PRD가 후속 SSOT).
- **Consequences**: PR #612 plan의 NG-1이 historical record로 남음. 본 PRD의 DL-8이 변경 근거.

### DL-9: review-implementation auto-fix mode 자연 소멸
- **Status**: accepted
- **Context**: review-implementation/SKILL.md "fix mode" 섹션이 SKILL.md 자체 삭제로 자동 소멸. NG-2(auto-fix 미사용)는 PR #612부터 유지.
- **Decision**: 별도 처리 없이 SKILL.md 삭제로 fix mode 사라짐. plan-with-questions for_prd는 NG-2로 미사용 → 영향 없음.
- **Consequences**: 사용자가 fix 원하면 `/plan-with-questions for_action`으로 작업 계획 후 수동 구현.

### DL-10: Codex global skill exposure SoT 함께 갱신 (DA F1/F11/F13)
- **Status**: accepted
- **Context**: DA Round 1에서 codex/default.nix:38-51 exposedCodexSkills + verify-ai-compat.sh:349-357 EXPECTED_EXPOSED 누락 발견.
- **Decision**: Phase 4에서 두 SoT 동시 갱신. SC-4에 verify-ai-compat.sh 통과 추가.
- **Consequences**: Codex/Claude 양쪽 skill exposure 동기화. ~/.codex/skills/{prd,review-implementation} symlink도 자동 사라짐.

### DL-11: stale link 검증 패턴 확장 (DA F2/F15)
- **Status**: accepted
- **Context**: DA Round 1에서 갱신 대상 누락 4 파일 (runtime-boundaries.md:58, resume-state.md:33-40, plan-file-template.md:8, consulting-step.md:43) + static 검증 패턴 좁음.
- **Decision**: 갱신 대상에 4 파일 추가. static 패턴을 `(/prd|/review-implementation|prd/references|review-implementation|\.\./prd|\.\./\.\./prd)`로 확장.
- **Consequences**: stale prose/link 잔존 0 보장.

### DL-12: Advanced mode 폐기 (DA F5/F6/F14 + round 3)
- **Status**: accepted (round 3 응답으로 round 2 D3 결정 일부 번복)
- **Context**: DA Round 1에서 advanced mode YAGNI/READABILITY 우려 + 본문 미정. round 3 사용자 응답 = 폐기.
- **Decision**: `for_prd_update.md`, `for_impl_review.md` 추가 안 함. plan-with-questions의 기존 3 mode (for_action, for_issue, for_prd)만 유지. PRD 갱신·review-only 직접 적용 use case는 for_prd 본문에서 자연어 입력으로 처리하도록 description 보완.
- **Consequences**: skill 표면 단순. mode taxonomy 확장 비용 회피. 사용자가 'PRD 갱신' 같은 입력은 for_prd 자연어 인식 의존.

### DL-13: ai-skills-consistency hook 보조 검증 강등 (DA F12)
- **Status**: accepted
- **Context**: ai-skills-consistency hook은 .claude/skills ↔ .agents/skills 투영 비교 + diff-filter=A 신규 추가만 검증. shared user-scope symlink 회귀를 강제하지 못함.
- **Decision**: ai-skills-consistency를 보조 검증으로 강등. shared symlink 회귀 강제 검증은 verify-ai-compat.sh + 명시 test (`test ! -e ~/.claude/skills/prd ...`).
- **Consequences**: SC-5에 명시 test 포함. Phase 5 Validation에서 verify-ai-compat.sh 강제.

### DL-14: PRD master를 Decision Log SSOT로 (DA F10/F16)
- **Status**: accepted
- **Context**: DA Round 1에서 임시 plan(`/tmp/plan-c54b0af3-611-lSbrfj/plan.md`)과 PRD master 사이 DL drift 우려.
- **Decision**: 본 PRD master의 Decision Log 섹션이 SSOT. 임시 plan은 "handoff seed, PRD 작성 후 superseded" 명시. phase 파일에는 DL 번호 참조만.
- **Consequences**: drift 방지. 임시 plan은 history 추적용으로만 보존.

### DL-15: evals positive + negative + ambiguous case (DA F8)
- **Status**: accepted
- **Context**: DA Round 1에서 positive-only 검증 NGMI 우려.
- **Decision**: `plan-with-questions/evals/queries.json`에 positive (8-12) + negative (4-6) + ambiguous (2-3) case 모두 추가. 일반 코드 리뷰, 단일 plan, PR 코멘트가 흡수되지 않는지 검증.
- **Consequences**: SC-2 추가. routing 정합 강화.

### DL-16: validation-paths.md 평면 위치 (round 3 응답, DA F7 일부 완화)
- **Status**: accepted
- **Context**: DA Round 1에서 shared reference NGMI 우려 (validation-paths.md가 plan-with-questions 하위로 굳으면 run-da 의존 방향 어색). round 3 응답 = 일부만 _shared.
- **Decision**: `validation-paths.md`만 `plan-with-questions/references/validation-paths.md` (prd/ 하위 아닌 평면). 나머지 5 references는 `prd/` 하위, requirement-status는 `review-impl/` 하위. `prd/` 라벨 부재로 cross-skill "공용성" 표현.
- **Consequences**: run-da/SKILL.md:75 link도 `../plan-with-questions/references/validation-paths.md`로 갱신. NGMI 우려는 인정하되 _shared 영역 도입의 기술 비용 회피.

### DL-17: Commit 5 검증 전용 분리 (DA F17 반영, stop-time review 보강)
- **Status**: accepted
- **Context**: DA Round 1 F17은 `Commit 5: 검증 통과 (코드 변경 없음, eval-tests 포함 커밋)` 본문이 "필요 시 evals 미세 조정"을 함께 명시해 commit 의도가 모순됨을 지적. handoff seed plan에서 DL-17로 가집계됐으나 본 PRD master에는 누락(stop-time review 적발).
- **Decision**: Commit 5는 **검증 전용**(코드 변경 없음). 검증 중 evals 미세 조정이 필요하면 Commit 3을 `git commit --amend`로 수정 + Commit 5 재실행. **검증 통과 후 코드 변경이 없으면 빈 commit을 만들지 않고 Commit 4가 마지막 commit**이 된다. eval 미세 조정 amend 외에는 Commit 5 위치에서 새 코드 변경을 만들지 않는다.
- **Consequences**: bisect granularity 보존. Phase 5 Implementation Checklist는 Commit 5 conditional 명시. Commit 4 단독 종료 경로도 유효.

### DL-18: 자연어 PRD/review-impl trigger의 이슈 우회 직접 진입 미도입 (Post-Impl 3 라우팅 finding)
- **Status**: accepted
- **Context**: Post-Implementation 3 (`/run-da for_pr`) Round 1에서 Design+Regression bundle이 review-impl/PRD 자연어 trigger의 이슈 우회 직접 진입 부재를 회귀로 지적 (D-1 review-impl HIGH, D-2 PRD HIGH, R-2 review-impl HIGH). Arbiter 9건 모두 CONFIRMED_ISSUE 판정. 그러나 이 finding 자체는 DL-12(advanced mode 폐기) + FR-13(for_prd 본문 자연어 처리 가이드) + `modes/for_prd.md` Step 1.2 ("텍스트 설명만으로는 진입할 수 없다") 결정과 직접 충돌.
- **Decision**: 사용자가 라우팅 finding 3건에 대해 "이슈 먼저 유지 (PRD 결정대로)"를 명시 선택. 자연어 PRD/review-impl trigger는 `for_issue` → 이슈 생성 → Step I-6 transition 경로로 일관 처리. 이슈 우회 직접 진입(`for_prd`/`for_action`이 ref 없는 텍스트 입력 직접 수신)은 도입하지 않는다. 라우팅 finding 3건은 PRD 결정과 일치하는 의도된 동작으로 정리 (Arbiter 판정은 정보 가치로만 보존).
- **Consequences**: PRD/review-impl 작업 시작 시 GitHub 이슈가 항상 작업 SSOT가 되어 추적성 일관 유지. 사용자 자연어 진입 시 한 단계 마찰(이슈 등록)은 trade-off. DA Round 1 자동 수정 6건 (C-1/C-2/R-1/M-1 깨진 상대 링크, M-2 이동된 reference의 standalone skill명 잔존, M-3 trigger 카테고리 SSOT 통합)은 별도 commit으로 반영.

### DL-19: 9-pass review-only 절차를 implementation-review.md 신규 reference로 이관 (Post-Impl 3 R2) [SUPERSEDED by DL-20]
- **Status**: superseded by DL-20
- **Context**: Post-Implementation 3 Round 2 (xhigh)에서 4 reviewer bundle이 9-pass review-only 본문 부재를 일관 지적 (C-1/D-1/R-1 모두 HIGH). 삭제된 `review-implementation/SKILL.md:56-68`의 Implementation 9-pass 정의가 어디로도 이관되지 않은 상태였고, `requirement-status.md`는 6-classification taxonomy만 정의. 결과 Phase 5 closure의 "9-pass review-only 적용 PASS" 주장이 부재한 절차에 대한 것이 됨 (실재 회귀). 외부 LLM 자문 (xhigh, anti-anchoring)은 3 옵션을 평가: α 새 reference 신설 / β 9-pass 자체 폐기 / γ requirement-status.md에 통합.
- **Decision**: 사용자가 옵션 α 채택. `plan-with-questions/references/review-impl/implementation-review.md` 신규 파일에 deleted SKILL.md:56-68의 9-pass 본문 이관. `requirement-status.md`는 6-classification taxonomy 전용 유지. 6곳의 9-pass owner link를 새 파일로 갱신.
- **Consequences (superseded)**: 본 결정의 9-pass 별도 checklist 유지 부분은 R3 D-3(YAGNI)에서 PRD 10-pass와 거의 1:1 중복임이 드러나 DL-20에서 overlay 모델로 축소. 새 reference 파일 신설 자체는 유지(파일 부재 회귀 방지) — 다만 본문이 별도 9-pass에서 PRD 10-pass에 얹는 delta(6-classification 라벨링 + overbuilt 우선)로 재서술됨.

### DL-20: Implementation review를 별도 9-pass에서 PRD 10-pass overlay로 축소 (Post-Impl 3 R3 D-3 YAGNI)
- **Status**: accepted
- **Context**: Post-Implementation 3 Round 3 (xhigh)에서 Design D-3가 새 finding 보고 — DL-19로 신설한 9-pass의 9개 항목(requirements/correctness/integration/simplicity/cleanup/security/performance/validation/docs)이 PRD Final 10-pass와 거의 1:1 동일. 차이는 10-pass의 cross-phase integration + PRD closeout 추가, 9-pass는 일반 integration. 사실상 Final review에서 두 절차를 병행하면 같은 finding이 두 번 산출되는 중복. 외부 LLM 자문 (xhigh, anti-anchoring)에서 3 옵션 평가 (Q delta 축소 / P 소거 통합 / R 현 유지). 자문 추천 + 사용자 가치 매칭(정보구조 명료성 + 중복 제거) 모두 Q.
- **Decision**: 사용자가 옵션 Q 채택. Final Multi-Pass Review의 canonical checklist는 PRD 10-pass 단일로 정함 (`references/prd/multi-pass-review.md`). `references/review-impl/implementation-review.md`는 별도 9-pass checklist에서 PRD 10-pass에 얹는 짧은 review-impl delta로 재서술 — (1) 각 finding에 6-classification 라벨 부여, (2) overbuilt 우선 분류 적용. SKILL.md/modes/references 6+ 곳의 "9-pass" 표현을 "PRD 10-pass + review-impl overlay"로 정리. R3 자동 수정 4건(R-3/C-1 SSOT 표 정정 + Final review mandatory 명시, R-4 review-only 정책 정렬, M-2 trigger 키워드 SSOT 위반 정리, M-1 measure-anchoring-bias.sh review-impl alias) 함께 반영.
- **Consequences**: review-impl 고유 가치(6-classification + overbuilt 우선)는 보존, 중복 checklist 제거, canonical "한 checklist + overlay" 구조. R3 D-1/R-1/R-2/D-2 (3회 반복 PRD 결정 충돌 finding)는 DL-18로 정리됨 (별도 DL 기록 불필요). PRD Phase 5 closure의 "9-pass review-only 적용" 표현은 본 DL 적용 후 "PRD 10-pass + review-impl overlay 적용"으로 의미 정합화 (Change Log entry로 추적).

## Change Log

- 2026-05-01: Initial PRD created via `/plan-with-questions for_action #611` → for_prd auto-trigger → user-confirmed → /prd handoff. plan-with-questions Step 1-6 (인터뷰·자문·DA) 완료, Step 7 사용자 승인, Step 8 본 PRD 작성. handoff seed: `/tmp/plan-c54b0af3-611-lSbrfj/plan.md`. 초기 Decision Log entries: DL-1 ~ DL-16.
- 2026-05-01: Stop-time review 보강 round 1 — DL-17 (Commit 5 검증 전용) 추가, A-3 정확화 (syncCodexConfig 두 경로 명시), Phase 2/4 SKILL.md 분담 명확화. **현재 Decision Log: 17 entries (DL-1 ~ DL-17, 본 PRD의 SSOT)**.
- 2026-05-01: Stop-time review 보강 round 2 — stale lower-bound DL reference (DL-17 추가 전 형식)와 phase-05 Objective의 "두 commit 포함" 단정 표현 정리 (DL-17 conditional Commit 5와 일관화).
- 2026-05-01: Stop-time review 보강 round 3 — phase-01 Validation Strategy entry counter check를 현재 SSOT(17 entries)에 정합화 (이전 round의 stale lower-bound 잔존 정리).
- 2026-05-01: **Phase 1 Complete** — Design Lock-in 종료. Discovery Gate 13/13, Implementation Checklist 9/9, Validation Checklist 적용 항목 PASS, Exit Criteria 4/4, Phase-End 10-pass 모두 PASS. baseline sealed (PR #612 MERGED, main HEAD f7c818b, claude/default.nix line 235-240, codex/default.nix line 38-51, verify-ai-compat.sh EXPECTED_EXPOSED line 349-362 (prd=line 356, review-impl=line 357), plan-with-questions 9 link 정확 매핑, .agents/skills/{prd,review-implementation} 부재 — A-3 (i) 경로 검증). Active Phase File phase-02로 전환.
- 2026-05-01: **Phase 2 Complete** — References Move 종료. 6 git mv (validation-paths.md 평면 + 4 prd 하위 + 1 review-impl 하위) + plan-with-questions 본인 9 파일 link 갱신 (SKILL.md, modes/for_action.md + modes/for_prd.md, references 6개). stale `../prd/` / `../review-implementation` / `/prd 스킬` 잔존 0건 (rg 검증). 잔존 stale은 review-implementation/SKILL.md (Phase 3에서 자동 소멸) + run-da/SKILL.md:75 + run-da/arbiter-prompt.md (Phase 5에서 갱신). Active Phase File phase-03으로 전환.
- 2026-05-01: **Phase 3 Complete** — Standalone Removal + Claude SoT 종료. 4 git rm (prd/SKILL.md, prd/evals/queries.json, review-implementation/SKILL.md, review-implementation/evals/queries.json) + 6 빈 디렉토리 자동 정리 (git rm leaf removal) + claude/default.nix:235-240 declaration block 제거. nrs 빌드 31s 성공 (home-manager generation 213). ~/.claude/skills/{prd,review-implementation} 부재 검증 PASS. **stop hook 지적 "exposed skills now point at moved reference files" 해소** (standalone SKILL.md 자체 부재로 깨진 link 사라짐). ~/.codex/skills은 Phase 4에서 정리. Active Phase File phase-04로 전환.
- 2026-05-01: **Phase 4 Complete** — Codex SoT + Trigger Absorption + Skill 본문 cleanup 종료. codex/default.nix:38-51 + verify-ai-compat.sh:349-362에서 prd, review-implementation 두 entry 제거. plan-with-questions/SKILL.md description에 흡수 trigger 12개 + evals positive/negative/ambiguous 18 entry 추가. modes/for_prd.md 본문을 "직접 작성" 흐름으로 재서술. **사용자 피드백 반영 — skill 본문에서 process metadata (이슈 번호, "흡수", "standalone /prd 폐기" 등 historical narrative) 모두 제거**, 현재 동작만 서술. PRD master + phase 파일은 history 추적 목적이라 그대로. nrs/verify-ai-compat.sh 통과, ~/.codex/skills 부재 검증 PASS. Active Phase File phase-05로 전환.
- 2026-05-01: **Phase 5 Complete** — Cross-Skill Link + Validation + Final Review 종료. run-da/SKILL.md:75 + run-da/references/arbiter-prompt.md:192-196 갱신 (Commit 4). 종합 검증: lefthook + verify-ai-compat (검증 완전 통과) + run-eval (38/49 PASS, 핵심 12 흡수 trigger 모두 PASS) + nrs + 명시 test 4종 + static rg 모두 PASS. Final 10-pass: requirements coverage / cross-phase integration / correctness / simplicity / cleanup / security / performance / validation / documentation / PRD closeout 모두 PASS. review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류; DL-20 적용 후 표현): FR-1~13 + NFR-1~6 + SC-1~6 모두 satisfied, overbuilt/conflicting/deferred 0건. DL-17에 따라 추가 코드 변경 없이 Commit 4가 본 PR의 마지막 commit (Commit 5 skip).
- 2026-05-01: **PRD Status: In Progress → Complete**. 모든 phase 종료. follow-up issue 없음. Post-Implementation 7번 PR 생성 단계로 진행 가능.
- 2026-05-01: **Post-Implementation 3 Round 1 (`/run-da for_pr`)** — Review Intensity = FULL. 4 reviewer bundle (Correctness/Design/Regression/Maintainability) 병렬 실행, Arbiter 9건 모두 CONFIRMED_ISSUE 판정. 자동 수정 6건 (C-1/C-2/R-1/M-1 깨진 상대 링크, M-2 standalone skill명 잔존, M-3 trigger 카테고리 SSOT 통합) 적용. 라우팅 finding 3건 (D-1/D-2/R-2 HIGH)은 PRD DL-12+FR-13+for_prd.md 결정과 충돌하여 사용자 결정으로 PRD 의도 유지(DL-18 추가). **현재 Decision Log: 18 entries (DL-1 ~ DL-18)**.
- 2026-05-01: **Post-Implementation 3 Round 2 (xhigh)** — 4 reviewer bundle이 9-pass review-only 본문 부재(HIGH × 3)를 일관 지적. 외부 LLM 자문(xhigh, anti-anchoring)으로 3 옵션 평가 후 사용자가 옵션 α 채택. `references/review-impl/implementation-review.md` 신규 reference로 deleted SKILL.md:56-68의 9-pass 본문 이관 + 6곳 owner link 갱신 (DL-19 추가). 추가 자동 수정 5건 (PRD 템플릿 stale prd 경로 / fix mode action 잔존 / review-implementation 명 잔존 / validation path 수 하드코딩) 적용. D-2 (issue body marker)는 PRD f7ef153 + DL-18과 충돌 → NOT_AN_ISSUE 정리. **현재 Decision Log: 19 entries (DL-1 ~ DL-19)**.
- 2026-05-01: **Post-Implementation 3 Round 3 (xhigh)** — D-3가 9-pass(R2 신설)와 PRD 10-pass의 1:1 중복 지적. 외부 LLM 자문(xhigh, anti-anchoring)으로 3 옵션(Q delta 축소 / P 소거 통합 / R 현 유지) 평가 후 자문 추천과 사용자 가치 매칭(정보구조 명료성 + 중복 제거) 모두 Q로 일치. 사용자가 옵션 Q 채택 (DL-19 supersede, DL-20 추가). implementation-review.md를 PRD 10-pass overlay (6-classification 라벨링 + overbuilt 우선 분류)로 재서술 + 6곳의 "9-pass" 표현을 "PRD 10-pass + review-impl overlay"로 정리. R3 자동 수정 4건 (R-3/C-1 SSOT 표 정정 + Final review mandatory 명시, R-4 review-only 정책 정렬, M-2 trigger 키워드 SSOT, M-1 measure-anchoring-bias.sh alias) 함께 적용. R3 D-1/R-1/R-2/D-2 (3회 반복 PRD 충돌)는 DL-18로 정리됨. **현재 Decision Log: 20 entries (DL-1 ~ DL-20)** — DL-19는 superseded.
