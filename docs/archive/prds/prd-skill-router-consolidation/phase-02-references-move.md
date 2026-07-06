# Phase 2: References Move

Parent PRD: [PRD: Skill Router Consolidation](../prd-skill-router-consolidation.md)
Status: Complete
Last Updated: 2026-05-01

## Objective

`/prd/references/` 5 파일과 `/review-implementation/references/` 1 파일을 `plan-with-questions/references/` 하위로 git mv한다. `validation-paths.md`만 평면 위치(`plan-with-questions/references/validation-paths.md`)로, 나머지는 `prd/`·`review-impl/` 하위(DL-16). 이동 후 plan-with-questions 본인의 9 link를 갱신한다(DL-11).

본 phase는 단일 commit (Commit 1)으로 처리한다. 이동 후 standalone 디렉토리는 빈 상태 (Phase 3에서 제거).

## Context From Master PRD

- Goals covered: G-2 (references 물리 이동)
- Success Criteria: SC-3 (디렉토리 부재 검증의 전제)
- Requirements covered: FR-3, FR-4, FR-10
- Decisions: DL-4, DL-11, DL-16

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] `git log --oneline modules/shared/programs/claude/files/skills/prd/references/` — 이동 대상 5 파일의 git history 확인 (rename 추적).
- [x] `git log --oneline modules/shared/programs/claude/files/skills/review-implementation/references/` — 이동 대상 1 파일.
- [x] `ls modules/shared/programs/claude/files/skills/plan-with-questions/references/` — 기존 평면 references 10 파일 확인 (충돌 없음 검증).
- [x] `rg -n '../prd/|../review-implementation|prd/references|\.\./\.\./prd' modules/shared/programs/claude/files/skills/plan-with-questions/` — 갱신 대상 9 파일의 정확한 line 번호 식별.
- [x] `rg -n '../prd/references/validation-paths.md' modules/shared/programs/claude/files/skills/plan-with-questions/` — validation-paths 차용 위치 식별 (별도 처리, 평면).
- [x] `mkdir -p modules/shared/programs/claude/files/skills/plan-with-questions/references/{prd,review-impl}` — 대상 하위 디렉토리 사전 생성 (git mv 첫 번째 호출이 자동 생성하지만 명시).
- [x] Master PRD의 assumption(A-3: home.activation.syncCodexConfig orphan 자동 정리) 유효 확인.
- [x] 발견이 이 phase 또는 후속 phase를 바꾸면 PRD 파일을 먼저 갱신.

## Scope

### In Scope

- 6 파일 git mv (1 평면 + 4 prd/ + 1 review-impl/).
- plan-with-questions 본인 9 link 갱신 (SKILL.md, modes/{for_prd, for_action}.md, references/{post-implementation, task-size-routing, runtime-boundaries, resume-state, plan-file-template, consulting-step}.md).
- standalone 디렉토리는 이 phase에서 빈 상태로 남음 (Phase 3에서 제거).

### Out of Scope

- standalone SKILL.md, evals/queries.json 삭제 (Phase 3).
- 빈 디렉토리 rmdir (Phase 3).
- claude/default.nix declaration 제거 (Phase 3).
- run-da link 갱신 (Phase 5).
- evals/queries.json 흡수 trigger 추가 (Phase 4).

## Implementation Checklist

- [x] `mkdir -p modules/shared/programs/claude/files/skills/plan-with-questions/references/{prd,review-impl}` 사전 생성 (git이 빈 디렉토리 미추적이지만 git mv 첫 호출 안전성).
- [x] `git mv modules/shared/programs/claude/files/skills/prd/references/validation-paths.md modules/shared/programs/claude/files/skills/plan-with-questions/references/validation-paths.md` (평면, DL-16).
- [x] `git mv modules/shared/programs/claude/files/skills/prd/references/file-mode-selection.md modules/shared/programs/claude/files/skills/plan-with-questions/references/prd/file-mode-selection.md`.
- [x] `git mv modules/shared/programs/claude/files/skills/prd/references/multi-pass-review.md modules/shared/programs/claude/files/skills/plan-with-questions/references/prd/multi-pass-review.md`.
- [x] `git mv modules/shared/programs/claude/files/skills/prd/references/phase-template.md modules/shared/programs/claude/files/skills/plan-with-questions/references/prd/phase-template.md`.
- [x] `git mv modules/shared/programs/claude/files/skills/prd/references/prd-master-template.md modules/shared/programs/claude/files/skills/plan-with-questions/references/prd/prd-master-template.md`.
- [x] `git mv modules/shared/programs/claude/files/skills/review-implementation/references/requirement-status.md modules/shared/programs/claude/files/skills/plan-with-questions/references/review-impl/requirement-status.md`.
- [x] `plan-with-questions/SKILL.md` **link 갱신만 (description frontmatter 변경은 Phase 4 담당)**: 본문 link + Reference Index/차용 reference 표의 모든 link 갱신 — `../prd/references/validation-paths.md` → `./references/validation-paths.md`, `../prd/references/{multi-pass-review,prd-master-template,phase-template,file-mode-selection}.md` → `./references/prd/*.md`, `../review-implementation/SKILL.md` 참조 제거.
- [x] `plan-with-questions/modes/for_prd.md` link 갱신 (handoff 표현도 "/prd 스킬에 위임" → "내부 prd refs로 위임").
- [x] `plan-with-questions/modes/for_action.md:98` link 갱신.
- [x] `plan-with-questions/references/post-implementation.md:23` link 갱신.
- [x] `plan-with-questions/references/task-size-routing.md` link 갱신 (`/prd/references/file-mode-selection.md`, `../../prd/references/file-mode-selection.md` 등).
- [x] `plan-with-questions/references/runtime-boundaries.md:58` `/prd 스킬이 작성` 표현 갱신 (DL-11).
- [x] `plan-with-questions/references/resume-state.md:33-40` `/prd handoff` 표현 갱신 (DL-11).
- [x] `plan-with-questions/references/plan-file-template.md:8` link 갱신 (DL-11).
- [x] `plan-with-questions/references/consulting-step.md:43` link 갱신 (DL-11).
- [x] commit 메시지: `refactor(skills): move prd/review-implementation references into plan-with-questions (#611)`. body에 DL-4, DL-11, DL-16 인용.

## Validation Strategy

이동 후 link 무결성과 잔존 stale prose 검증. static rg + 수동 link clickthrough가 핵심.

- **Static (확장 패턴)**: `rg -n '(/prd|/review-implementation|prd/references|review-implementation|\.\./prd|\.\./\.\./prd)' modules/shared/programs/claude/files/skills/plan-with-questions/` — 잔존 0 확인. 의도적 잔존(`prd-` slug 사용처 등)은 allowlist 주석.
- **Link 무결성 (수동)**: 갱신된 9 파일의 모든 markdown link target이 새 위치에 실재 확인. 예: `plan-with-questions/SKILL.md`의 `./references/validation-paths.md` → `modules/shared/programs/claude/files/skills/plan-with-questions/references/validation-paths.md` 실재.
- **git rename 추적**: `git log --follow modules/shared/programs/claude/files/skills/plan-with-questions/references/validation-paths.md` — rename history 보존 확인.
- 본 phase는 nrs 빌드 안 함 (Phase 3 후 빌드).

## Validation Checklist

- [x] Static check: `rg -n '\.\./prd/references|\.\./\.\./prd/references|\.\./review-implementation' modules/shared/programs/claude/files/skills/plan-with-questions/` 결과 0건.
- [x] 자동 test: N/A (이동 후 다른 phase에서 통합 검증).
- [x] API/CLI/service-level: `git diff --stat HEAD~1` — 6 rename + 9 modify 확인.
- [x] Browser/UI E2E: N/A.
- [x] Agent/dev browser: N/A.
- [x] Mobile/simulator: N/A.
- [x] Visual/screenshot: N/A.
- [x] Observability: N/A.
- [x] Manual smoke: plan-with-questions/SKILL.md 빠른 참조 표 + 차용 reference 표 수동 클릭 검증.
- [x] error/empty/loading/permission/retry/rollback: N/A. rollback은 `git revert <commit-1>` 단순.

## Exit Criteria

- [x] 6 git mv 완료 + 9 file link 갱신 완료.
- [x] static rg 잔존 0 확인.
- [x] git status clean.
- [x] commit 1개 생성 (Commit 1).
- [x] 다음 phase blocker 없음 (Phase 3 standalone 디렉토리는 빈 상태로 남아 있음 — 정상).

## Phase-End Multi-Pass Review

- [x] 1. Intent/coverage review — 6 파일 이동 + 9 file link 갱신 = FR-3/4/10 매핑.
- [x] 2. Correctness review — `validation-paths.md` 평면 위치 (prd/ 하위 아님) 확인. 다른 5 references는 prd/ 또는 review-impl/ 하위 확인.
- [x] 3. Simplicity review — `mkdir -p` + `git mv` 표준 명령. 복잡한 logic 없음.
- [x] 4. Code quality review — link 갱신이 일관 패턴 (`./references/` 또는 `./references/prd/`).
- [x] 5. Duplication/cleanup review — 이동 후 standalone 디렉토리 references/ 빈 상태. Phase 3에서 제거 예정.
- [x] 6. Security/privacy review — secret/auth 노출 없음.
- [x] 7. Performance/load review — N/A.
- [x] 8. Validation review — static rg 확장 패턴이 stale prose/link 잔존 검증에 충분.
- [x] 9. Future-phase review — Phase 3 (standalone 제거)이 본 phase 결과(빈 디렉토리)에 의존. 일관성 확인.
- [x] 10. PRD sync review — master PRD `Current Phase` Phase 1 → Phase 2로 갱신, Phase 1 Status `Complete`로, Phase 2 Status `In Progress`로.

추가로 `review-implementation/requirement-status.md` 6-classification 보조 layer 적용 (auto-fix 미사용, NG-2).

## Discoveries / Decisions

### 실제 변경 결과

- **6 git mv 모두 rename으로 추적됨** (validation-paths.md 평면 + 4 prd refs + 1 review-impl ref).
- **9 link 갱신 완료** (SKILL.md, modes/for_action.md, modes/for_prd.md, references/{post-implementation, task-size-routing, runtime-boundaries, resume-state, plan-file-template, consulting-step}.md).
- **stale `../prd/` / `../review-implementation` link 잔존 0건** in plan-with-questions (rg 검증).
- **prose `/prd 스킬` / `/prd로 handoff` 잔존 0건** in plan-with-questions.

### 잔존 stale (의도적, 후속 phase 처리)

- `review-implementation/SKILL.md` 본문의 `../prd/references/validation-paths.md` link 3개 (line 28, 67, 82) — Phase 3에서 SKILL.md git rm으로 자동 소멸. 본 phase에서 갱신 안 함.
- `run-da/SKILL.md:75` link `../prd/references/validation-paths.md` — Phase 5에서 갱신 (`../plan-with-questions/references/validation-paths.md`로). 본 phase 범위 밖.
- `run-da/references/arbiter-prompt.md:192/195/196` example의 `~/.claude/skills/prd` 경로 — Phase 5에서 갱신 또는 obsolete annotation.

### Phase 4 추가 작업 후보 (review-implementation/SKILL.md 본문 흡수)

review-implementation/SKILL.md는 Step 1-5 workflow + 9-pass review 절차를 정의한다. SKILL.md가 Phase 3에서 git rm되면 9-pass 정의도 사라짐. plan-with-questions for_prd가 9-pass review-only를 따르려면 review-impl/requirement-status.md (이미 흡수됨)에 9-pass + workflow 절차 통합이 필요할 수 있음 — Phase 4 Discovery Gate에서 결정. 본 phase 범위 밖.

## Phase Change Log

- 2026-05-01: Phase 2 file created via /prd handoff.
- 2026-05-01: Phase 2 references move 완료 — 6 git mv (validation-paths.md 평면 + 5 하위) + 9 link 갱신 (plan-with-questions 본인). stale 잔존 0건. **Status: Not Started → Complete**. blocker 없음, Phase 3로 진행 가능.
