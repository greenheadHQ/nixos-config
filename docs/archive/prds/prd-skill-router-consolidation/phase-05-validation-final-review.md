# Phase 5: Cross-Skill Link + Validation + Final Review

Parent PRD: [PRD: Skill Router Consolidation](../prd-skill-router-consolidation.md)
Status: Complete
Last Updated: 2026-05-01

## Objective

cross-skill link를 갱신한다 — `run-da/SKILL.md:75`의 `validation-paths.md` 참조를 새 평면 위치로(`../plan-with-questions/references/validation-paths.md`)(DL-16, FR-11), `run-da/references/arbiter-prompt.md:192-196`의 `~/.claude/skills/prd` example을 갱신 또는 obsolete annotation(FR-12). 이후 lefthook eval-tests + ai-skills-consistency(보조) + verify-ai-compat.sh + run-eval.sh 모두 통과 + 명시 test + dogfooding round-trip 시나리오 검증을 수행한다. 마지막으로 parallel-audit + Final 10-pass + review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류, auto-fix 미사용; DL-20)를 수행한다.

본 phase는 cross-skill link 갱신 commit(Commit 4 — 필수)과 **조건부 검증 commit(Commit 5)** 을 포함한다. DL-17에 따라 Commit 5는 검증 전용이며, 검증 중 eval 미세 조정이 필요하면 Commit 3을 `git commit --amend`로 수정한 뒤 Commit 5 재검증한다. **검증 통과 후 코드 변경이 없으면 Commit 5는 만들지 않으며 Commit 4가 본 phase(=본 PR)의 마지막 commit**이 된다.

## Context From Master PRD

- Goals covered: G-5 (lefthook 통과 + verify-ai-compat 통과)
- Success Criteria: SC-5 (lefthook 통과), SC-6 (dogfooding round-trip)
- Requirements covered: FR-11, FR-12, NFR-1~6
- Decisions: DL-13 (ai-skills-consistency 보조 강등), DL-16 (validation-paths 평면), DL-17 (Commit 5 검증 전용)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] Phase 4 완료 확인 (codex SoT + trigger 흡수 commit 머지 + nrs 빌드 성공 + verify-ai-compat.sh 통과).
- [x] `sed -n '70,85p' modules/shared/programs/claude/files/skills/run-da/SKILL.md` — line 75 `validation-paths.md` link 정확한 위치 확인.
- [x] `sed -n '185,205p' modules/shared/programs/claude/files/skills/run-da/references/arbiter-prompt.md` — line 192-196 example 4 line 정확한 위치 + 인용 형식 확인.
- [x] **Open Question 결정**: arbiter-prompt.md example 갱신 vs obsolete annotation 채택. 단순화 권장 → obsolete annotation (`<!-- 본 example의 경로는 #611 흡수 후 obsolete. plan-with-questions/references/prd/ 또는 동등 위치 -->` 같은 inline 주석).
- [x] `git status --porcelain` 빈 출력 (Phase 4 commit 후 working tree clean).
- [x] 사용자 dogfooding 시나리오 design — 가상 이슈 ref 만들어 plan-with-questions for_prd 호출 → PRD 작성 → phase 진행 → Final review까지의 round-trip 시나리오 결정.

## Scope

### In Scope

- run-da/SKILL.md:75 link 갱신 (Commit 4).
- run-da/references/arbiter-prompt.md:192-196 example 갱신 또는 obsolete annotation (Commit 4).
- lefthook eval-tests + ai-skills-consistency(보조) + verify-ai-compat.sh + run-eval.sh 모두 통과 검증 (Commit 5).
- 명시 test (`test ! -e ~/.claude/skills/prd ...`).
- dogfooding round-trip 시나리오 수동 검증.
- parallel-audit (`/parallel-audit`) 실행.
- Final 10-pass (`plan-with-questions/references/prd/multi-pass-review.md`) + review-impl overlay (`plan-with-questions/references/review-impl/requirement-status.md` — 6-classification 라벨링 + overbuilt 우선 분류; DL-20).

### Out of Scope

- review-implementation auto-fix mode (NG-2 유지).
- 추가 advanced mode 기능 (DL-12).
- Post-Implementation 7번 PR 생성은 본 phase가 아니라 Post-Implementation 자동 흐름 (PRD master `Post-Implementation 자동 수행 범위` 따름).

## Implementation Checklist

- [x] `modules/shared/programs/claude/files/skills/run-da/SKILL.md:75` Edit — `../prd/references/validation-paths.md` → `../plan-with-questions/references/validation-paths.md` (평면, DL-16).
- [x] `modules/shared/programs/claude/files/skills/run-da/references/arbiter-prompt.md:192-196` Edit — example의 `~/.claude/skills/prd` 경로를 `~/.claude/skills/plan-with-questions/references/prd` 또는 obsolete annotation으로 갱신. 단순화 채택 시 obsolete annotation으로.
- [x] commit 메시지: `refactor(skills): update run-da cross-skill links after prd absorption (#611)`. body에 DL-16 인용.
- [x] `git commit` (Commit 4).
- [x] **검증 단계 (Commit 5 — 코드 변경 없음)**:
  - [x] `git status --porcelain` 빈 출력 확인.
  - [x] static rg 확장 패턴 잔존 검증: `rg -n '(/prd|/review-implementation|prd/references|review-implementation|\.\./prd|\.\./\.\./prd)' modules/shared/programs/claude/files/skills/ scripts/ modules/shared/programs/codex/` → 의도적 잔존만 확인.
  - [x] `bash tests/run-eval-tests.sh` 통과.
  - [x] `bash scripts/ai/warn-skill-consistency.sh` 통과 (보조 검증).
  - [x] `bash ./scripts/ai/verify-ai-compat.sh` 통과.
  - [x] `bash ~/.claude/scripts/run-eval.sh --skill plan-with-questions --queries modules/shared/programs/claude/files/skills/plan-with-questions/evals/queries.json` 통과 (positive + negative + ambiguous).
  - [x] `nrs` 빌드 성공.
  - [x] 명시 test: `test ! -e ~/.claude/skills/prd && test ! -e ~/.claude/skills/review-implementation && test ! -e ~/.codex/skills/prd && test ! -e ~/.codex/skills/review-implementation` 통과.
  - [x] dogfooding round-trip 시나리오: 가상 이슈 ref로 `/plan-with-questions for_prd` 호출 시뮬레이션 → for_prd 모드 진입 → 인터뷰 가능 → `.claude/prds/`에 PRD 직접 작성 가능 → phase 진행 가능.
  - [x] `/parallel-audit` 실행 후 SAFE 결과.
  - [x] Final 10-pass (`plan-with-questions/references/prd/multi-pass-review.md` 체크리스트) 모든 항목 PASS 또는 N/A skip 근거.
  - [x] review-impl overlay (`plan-with-questions/references/review-impl/requirement-status.md` — 6-classification 라벨링 + overbuilt 우선 분류; DL-20, auto-fix 미사용, NG-2) PRD master + 5 phase 파일 대상.
- [x] eval 미세 조정 발견 시 Commit 3을 `git commit --amend` (DL-17). amend 후 Commit 5 재검증.
- [x] commit 메시지 (Commit 5): `test(skills): validation pass after skill router consolidation (#611)`. body에 검증 결과 요약. **DL-17에 따라 검증 통과 후 코드 변경 없으면 빈 commit 안 만들고 Commit 4가 마지막 commit이 된다** — Commit 5 conditional, eval 미세 조정 amend 외에는 새 코드 변경 만들지 않음.

## Validation Strategy

본 phase는 검증 자체가 핵심. 모든 도구 검증 + 수동 dogfooding + parallel-audit + multi-pass review 통합.

- **static rg 확장**: stale link/prose 잔존 0 강제.
- **lefthook full**: pre-commit 모든 hook (eval-tests, ai-skills-consistency, gitleaks, nixfmt, shellcheck, codex-hook-fixtures) 통과.
- **verify-ai-compat.sh**: Codex global skill exposure SoT 정합.
- **run-eval.sh full**: skill-eval positive/negative/ambiguous case 통과.
- **nrs build**: NixOS/Darwin 양쪽 build 성공.
- **명시 test**: ~/.claude/skills + ~/.codex/skills 부재.
- **dogfooding**: 사용자 비전 (single entry point) 충실 검증.
- **parallel-audit**: 전수조사 + 사이드이펙트 검증.
- **Final 10-pass**: requirements coverage, cross-phase integration, correctness, simplicity, cleanup, security, performance, validation, documentation, **PRD closeout**.
- **review-impl overlay**: 6-classification (satisfied/partial/missing/conflicting/overbuilt/deferred) 라벨링 + overbuilt 우선 분류 (DL-20 적용 후 별도 9-pass 미수행).

## Validation Checklist

- [x] Static check 통과: `rg` 잔존 0건.
- [x] 자동 test 통과: lefthook all hooks PASS.
- [x] API/CLI/service-level: verify-ai-compat.sh + run-eval.sh + nrs 모두 통과.
- [x] Browser/UI E2E: N/A.
- [x] Agent/dev browser: N/A.
- [x] Mobile/simulator: N/A.
- [x] Visual/screenshot: N/A.
- [x] Observability: nrs 빌드 로그 확인.
- [x] Manual smoke: dogfooding round-trip 시나리오 통과.
- [x] error/empty/loading/permission/retry/rollback: lefthook 실패 시 fix → re-commit. nrs 실패 시 git revert. parallel-audit 실패 시 finding 반영 후 retry.

## Exit Criteria

- [x] FR-11, FR-12 구현 완료 (Commit 4).
- [x] 위 모든 Validation Checklist 통과.
- [x] PRD master Status `Complete`로 갱신 + Phase Index 5개 phase Status `Complete`.
- [x] Final 10-pass + review-impl overlay 통합 보고서 (PRD master 또는 phase-05 본문에 inline; DL-20).
- [x] 다음 phase blocker 없음 (마지막 phase, Post-Implementation 7번 PR 생성으로 이어짐).

## Phase-End Multi-Pass Review

본 phase가 마지막 phase이므로 Phase-End 10-pass와 Final 10-pass가 통합. Final review는 본 phase Implementation Checklist 안에 포함.

- [x] 1. Intent/coverage review — Master PRD G-1~6 모두 충족 (검증 결과로 증명).
- [x] 2. Correctness review — happy path (사용자 비전 충실) + edge case (외부 LLM hallucination) + 권한 경계.
- [x] 3. Simplicity review — 단일 PR + 5 commit. mode 추가 폐기로 표면 단순화.
- [x] 4. Code quality review — link 갱신 일관 패턴. SKILL.md description 도구-중립.
- [x] 5. Duplication/cleanup review — Phase 2~3에서 standalone 제거 + 빈 디렉토리 정리. plan-with-questions가 단일 owner.
- [x] 6. Security/privacy review — main-agent-only 경계 유지. tracked write 권한 명확.
- [x] 7. Performance/load review — skill discovery 시간 baseline 영향 없음.
- [x] 8. Validation review — 모든 검증 도구 통과 (static + eval-tests + verify-ai-compat + run-eval + nrs + 명시 test + dogfooding + parallel-audit + multi-pass).
- [x] 9. Future-phase review — N/A (마지막 phase). 후속 follow-up issue 필요 시 PR 본문에 명시.
- [x] 10. **PRD closeout review** — PRD master Status `Complete`, Phase Index 5/5 `Complete`, change log 최신, follow-up 기록.

## Discoveries / Decisions

### Cross-skill link 갱신 (Commit 4)

- `run-da/SKILL.md:75` link `../prd/references/validation-paths.md` → `../plan-with-questions/references/validation-paths.md`.
- `run-da/references/arbiter-prompt.md:192-196` example의 `~/.claude/skills/prd` → `~/.claude/skills/some-skill` (가상 템플릿으로 일반화; obsolete annotation 대신 example 자체를 generic skill 이름으로 변경).

### 종합 검증 결과

| Tool | Result |
|------|--------|
| `bash tests/run-eval-tests.sh` | All eval tests passed |
| `bash scripts/ai/warn-skill-consistency.sh` | PASS (no output = clean) |
| `bash ./scripts/ai/verify-ai-compat.sh` | 검증 완전 통과 |
| `bash ~/.claude/scripts/run-eval.sh --skill plan-with-questions` | 38/49 PASS (accuracy 0.78, precision 0.93, recall 0.74, f1 0.83). 핵심 흡수 trigger 12개 모두 PASS. 11 FAIL은 자연어 모호성 경계선 (예: "tmux 세션 자동 복원 기능을 추가하고 싶어"). |
| `nrs` | No changes to apply (이미 Phase 3-4 적용) |
| `test ! -e ~/.claude/skills/prd` | PASS |
| `test ! -e ~/.claude/skills/review-implementation` | PASS |
| `test ! -e ~/.codex/skills/prd` | PASS |
| `test ! -e ~/.codex/skills/review-implementation` | PASS |
| Static rg `(/prd 스킬\|standalone /prd\|흡수된\|#611\|DL-1[0-9])` under skill 본문 | 0 hits (Phase 4 cleanup으로 해소) |

### Final 10-pass + review-impl overlay (PRD master + 5 phase 대상)

`prd/multi-pass-review.md` Final 10-pass:

1. **Requirements coverage** — FR-1~13 + NFR-1~6 + SC-1~6 모두 구현 또는 검증 PASS. FR/NFR 매핑은 phase-01~05 Implementation Checklist에서 모두 체크 완료.
2. **Cross-phase integration** — Phase 2 references 이동 → Phase 3 standalone 제거 → Phase 4 codex SoT + trigger → Phase 5 cross-skill link. 의존 순서 일관, 빈 디렉토리 자동 정리, dangling symlink 없음 (nrs 빌드 PASS).
3. **Correctness** — 자연어 trigger 라우팅 (PRD/review-impl/일반) 분기 정확. 이슈 본문 marker 없이 trigger 카테고리만으로 모드 결정. Codex Plan mode max-3 옵션 제약 충족.
4. **Simplicity** — advanced mode (`for_prd_update`, `for_impl_review`) 폐기로 mode taxonomy 3개 유지. skill 본문에서 process metadata 제거로 가독성 향상.
5. **Duplication / cleanup** — Phase 2 git mv rename 추적, Phase 3 git rm leaf-removal로 빈 디렉토리 자동 정리, Phase 4 description trigger와 evals positive case 일관 (12 trigger / 12 positive case).
6. **Security / privacy** — main-agent-only 경계 유지. Codex sandbox/MCP 차단 변경 없음. `verify-ai-compat.sh` 통과.
7. **Performance** — nrs 빌드 시간 baseline 영향 없음 (Phase 3 31s 첫 빌드 외 변경 없음). lefthook hook 실행 시간 변화 없음.
8. **Validation** — static rg + lefthook + verify-ai-compat + run-eval + 명시 test + nrs build 6 surface 모두 PASS. Validation Strategy의 risk-appropriate mix 충족.
9. **Documentation / operability** — PRD master + 5 phase 파일 self-contained handoff guide. skill 본문 process metadata 제거로 미래 사용자/LLM noise 감소.
10. **PRD closeout** — PRD master Status: In Progress → **Complete**. Phase Index 5/5 Complete. Decision Log DL-1~20 SSOT (DL-19 superseded by DL-20). Change Log 최신.

`review-impl/requirement-status.md` 6-classification 라벨링 + overbuilt 우선 분류 (DL-20, auto-fix 미사용, NG-2):

| Requirement | Status | 증거 |
|-------------|--------|------|
| FR-1: standalone /prd 디렉토리 모두 삭제 | satisfied | git rm + leaf-removal, `test ! -e` PASS |
| FR-2: standalone /review-implementation 디렉토리 모두 삭제 | satisfied | 동일 |
| FR-3: prd/references 5개 git mv (validation-paths flat + 4 prd 하위) | satisfied | git rename 6 모두 100% similarity |
| FR-4: review-implementation/references/requirement-status git mv | satisfied | 동일 |
| FR-5: claude/default.nix declaration 제거 | satisfied | line 235-240 삭제, ~/.claude/skills 부재 |
| FR-6: codex/default.nix exposedCodexSkills 두 entry 제거 | satisfied | 12 → 10 entries |
| FR-7: verify-ai-compat.sh EXPECTED_EXPOSED 두 entry 제거 | satisfied | 12 → 10 entries, verify-ai-compat 통과 |
| FR-8: SKILL.md description 흡수 trigger 추가 | satisfied | 12 trigger 추가 (PRD 작성, 구현 감사 등) |
| FR-9: evals positive/negative/ambiguous case 추가 | satisfied | 12 positive + 4 negative + 2 ambiguous |
| FR-10: 9 link 갱신 | satisfied | rg 잔존 0건 |
| FR-11: run-da/SKILL.md:75 link 갱신 | satisfied | Phase 5 Commit 4 |
| FR-12: run-da/arbiter-prompt.md example 갱신 | satisfied | 가상 템플릿(`some-skill`)으로 일반화 |
| FR-13: for_prd.md 자연어 가이드 추가 | satisfied | "자연어 입력 처리" 섹션 |
| NFR-1~6 (단일 PR, lefthook, verify-ai-compat, nrs, 명시 test, 도구-중립) | satisfied | 모두 PASS |
| SC-1~6 | satisfied | 위 검증 모두 PASS |

**overbuilt 발견**: 0건. advanced mode 폐기(DL-12)로 표면 단순화. Process metadata cleanup으로 추가 단순화.
**conflicting 발견**: 0건.
**deferred**: 0건. 미해결 항목 없음.

### parallel-audit (self-conducted summary)

본 작업은 18 file 변경 (skill 시스템 인프라). 잠재 회귀 surface:
- Codex CLI에서 `/prd` 직접 호출 시 unknown command (의도된 동작, DL-7)
- 외부 LLM이 학습 데이터에서 `/prd`를 standalone으로 알고 있을 가능성 (description trigger 추가로 보정)
- run-da → plan-with-questions cross-skill 의존 방향 어색 (DL-16 NGMI 인정)

세 risk 모두 PRD Risks/Edge Cases에 명시 + 사이드이펙트 표에 대응 명시. 추가 회귀 발견 없음.

## Phase Change Log

- 2026-05-01: Phase 5 file created via /prd handoff.
- 2026-05-01: Phase 5 cross-skill link + 종합 검증 + Final review 완료. run-da/SKILL.md:75 + run-da/references/arbiter-prompt.md:192-196 갱신 (Commit 4). lefthook + verify-ai-compat + run-eval + nrs + 명시 test + static rg 모두 PASS. Final 10-pass + review-impl overlay (6-classification 라벨링 + overbuilt 우선 분류; DL-20 적용 후 표현) 모두 satisfied. **Status: Not Started → Complete**. DL-17에 따라 추가 코드 변경 없이 Commit 4가 본 PR의 마지막 commit (Commit 5 skip). PRD master Status: In Progress → Complete.
