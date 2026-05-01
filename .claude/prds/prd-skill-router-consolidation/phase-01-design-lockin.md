# Phase 1: Design Lock-in

Parent PRD: [PRD: Skill Router Consolidation](../prd-skill-router-consolidation.md)
Status: Complete
Last Updated: 2026-05-01

## Objective

PR #612 머지 상태와 lefthook/eval/codex SoT 인프라 동작을 확인하고, Decision Log DL-1~17을 PRD master에 SSOT로 lock한다. 변경 대상 17 파일 + 디렉토리 6의 정확한 위치·라인을 확정하여 Phase 2~5의 변경 작업이 hallucination 없이 진행되도록 sealed baseline을 만든다.

## Context From Master PRD

- Goals covered: G-1~6 (lock-in이 모든 G의 전제)
- Success Criteria: SC-3, SC-4 (변경 대상 검증 baseline)
- Requirements covered: 모든 FR/NFR의 사실 baseline
- Key scenarios touched: Scenario 1, 2 (현재 standalone trigger 동작 baseline)

## Phase Discovery Gate

코드 편집 전에 재확인한다:
- [x] `gh pr view 612 --json state,mergedAt` — PR #612 **state=MERGED**, **mergedAt=2026-05-01T05:52:07Z** 확인.
- [x] `git rev-parse main` — **main HEAD = f7c818bab4602b991f2c0856af37dda240a72e06** (full SHA, prefix f7c818b) 확인.
- [x] `cat lefthook.yml` — pre-commit hook 6개 (`ai-skills-consistency`, `gitleaks`, `nixfmt`, `shellcheck`, `eval-tests`, `codex-hook-fixtures`) 정의 확인. commit-msg hook (pinning) + pre-push hook (shell-script-tests, codex-hook-fixtures, flake-check) 추가 확인.
- [x] `cat tests/run-eval-tests.sh` — `nix eval --impure --file tests/eval-tests.nix` 호출 확인.
- [x] `cat scripts/ai/warn-skill-consistency.sh` — `.claude/skills` ↔ `.agents/skills` 투영 비교 + `diff-filter=A` 신규 추가 확인 메커니즘 확인.
- [x] `cat scripts/ai/verify-ai-compat.sh` — `EXPECTED_EXPOSED` 배열 정확한 위치 **line 349 시작 ~ line 362 닫는 `)`**. `prd` = **line 356**, `review-implementation` = **line 357** 잔존 확인 (12 entries 중 7번째/8번째). PRD master FR-7 명시 "349-357"은 배열 시작 ~ review-implementation entry까지의 sub-range (정확).
- [x] `sed -n '38,51p' modules/shared/programs/codex/default.nix` — `exposedCodexSkills` list **line 38 시작 ~ line 51 닫는 `]`**. `"prd"` = **line 45**, `"review-implementation"` = **line 46** 정확한 라인 확인.
- [x] `sed -n '230,245p' modules/shared/programs/claude/default.nix` — claude declaration 정확 위치 **line 235~240** (주석 포함 6줄): line 235 `# prd 스킬 (user-scope)`, line 236 prd symlink, line 237 빈 줄, line 238 `# review-implementation 스킬 (user-scope)`, line 239-240 review-implementation symlink (2줄로 split). PRD master FR-5 명시 "236-240"은 declaration body 라인 인용; 주석 포함 시 235-240.
- [x] `rg -n -- '\.\./prd/|\.\./\.\./prd/|\.\./review-implementation\b' modules/shared/programs/claude/files/skills/plan-with-questions/` — plan-with-questions 본인 link 갱신 대상 **5 main + 4 보조 = 9 파일** 확인. 정확한 line 매핑은 Discoveries/Decisions 섹션에 기록.
- [x] `rg -n -- '\.\./prd/' modules/shared/programs/claude/files/skills/run-da/` — run-da/SKILL.md **line 75** 1 link 확인. arbiter-prompt.md **line 192/195/196** example 3 line 확인 (별도 sed 출력).
- [x] PRD master Decision Log DL-1~17이 본 PRD에 SSOT로 기록됨 확인 (handoff seed `/tmp/plan-c54b0af3-611-lSbrfj/plan.md`와 일관성). DL-17은 stop-time review에서 보강된 Commit 5 검증 전용 결정. **`grep -c '^### DL-' = 17` 통과**.
- [x] Assumption A-3 baseline 확인: `ls .agents/skills/prd .agents/skills/review-implementation` → **부재 (No such file or directory)** 확인. syncCodexConfig 두 경로 (line 192 fresh-create 차단 + line 220-230 orphan removal) 모두 적용 가능 확인.
- [x] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신. — 본 baseline 결과 PRD master FR-5/FR-7 라인 인용이 정확한 sub-range임을 Discoveries에 기록 (정정 필요는 minor; Phase 2-5 Implementation 시점에 정확한 라인 사용).

## Scope

### In Scope

- Discovery Gate 항목 모두 확인.
- 변경 대상 파일 목록의 정확한 라인 번호 확정.
- DL-1~17의 SSOT 검증.
- 본 phase는 코드 변경 없음 (Discovery + lock-in only).

### Out of Scope

- 실제 파일 이동/삭제/수정 (Phase 2~5 담당).
- 흡수 trigger 정확한 query 목록 결정 (Phase 4).
- run-da/arbiter-prompt.md example 갱신 vs obsolete annotation 결정 (Phase 5).

## Implementation Checklist

- [x] Phase Discovery Gate 항목 모두 통과.
- [x] PR #612 머지 검증 결과를 PRD master `Document Status` 섹션의 Baseline 필드에 기록 확인 (`branch=main, HEAD=f7c818b, dirty=clean` 명시됨).
- [x] lefthook.yml hook 정의 baseline 기록 (Phase 5 Validation에서 비교용) — Discoveries에 hook 6개 명시.
- [x] codex/default.nix:38-51 exposedCodexSkills의 정확한 entry 순서 + 라인 번호 baseline — Discoveries에 prd=line 45, review-implementation=line 46 기록.
- [x] scripts/ai/verify-ai-compat.sh의 EXPECTED_EXPOSED 배열 정확한 라인 + 형식 baseline — Discoveries에 line 349-362 (prd=356, review-impl=357) 기록.
- [x] claude/default.nix:235-240 declaration 2개의 정확한 6줄 baseline (delete 단위 식별) — Discoveries에 주석 포함 6줄 명시.
- [x] plan-with-questions의 9 link 갱신 파일 목록 + 각 파일의 정확한 line 번호 매핑 확정 — Discoveries에 5 main (SKILL.md 86-91, modes/for_prd.md 17-23, modes/for_action.md 98, references/post-implementation.md 23, references/task-size-routing.md 86) + 4 보조 (runtime-boundaries.md 58, resume-state.md 33/38/40, plan-file-template.md 3/8/48/97/141, consulting-step.md 9/43) 기록.
- [x] run-da/SKILL.md:75 + run-da/references/arbiter-prompt.md:192,195,196 정확한 위치 baseline — sed 출력으로 확인.
- [x] DL-1~17이 PRD master Decision Log에 모두 등장하는지 검증 (17개 entry 확인) — `grep -c '^### DL-' = 17` 통과.

## Validation Strategy

본 phase는 검증 baseline 자체를 만드는 phase이므로 외부 도구 검증보다 self-consistency 검증 위주. 다음 도구로 PRD/plan 일관성 확인:

- `git status --porcelain` (clean 검증)
- `gh pr view 612 --json state,mergedAt` (PR 상태 검증)
- `rg -n` 명시 패턴 매칭 (변경 대상 위치 baseline)
- 본 PRD master 직접 read로 DL-1~17 SSOT 확인

## Validation Checklist

- [x] Static check 통과 (가용 시): `git status --porcelain` — branch는 issue/611-skill-router-consolidation, 작업 분기 위에서 4 commit; baseline (main HEAD) 비교 시 PRD 6 file 추가만 반영. Phase 1 자체는 코드 변경 없음.
- [x] 자동 test 추가/갱신 및 통과 (해당 시): N/A — 본 phase는 baseline lock-in만 (lefthook hook은 PRD 추가 commit 시 자동 통과 검증).
- [x] API/CLI/service-level workflow 검증 (충분한 경우): `gh pr view 612` MERGED 확인 + `git rev-parse main` 정확한 SHA 확인.
- [x] Browser/UI E2E — DOM/client 상호작용이 risk 경로일 때만 수행: N/A
- [x] Agent/dev browser check: N/A
- [x] Mobile/app simulator: N/A
- [x] Visual/screenshot check: N/A
- [x] Observability/logging/audit 동작 확인 (관련 시): N/A
- [x] Manual smoke check: 본 PRD master read + Decision Log 17 entry counter check — `grep -c '^### DL-' = 17` 통과.
- [x] 해당 시 error, empty, loading, permission, retry, rollback 상태 검증: N/A

## Exit Criteria

- [x] Phase objective 달성 (DL-1~17 SSOT lock + 변경 대상 baseline 확정)
- [x] 위에 열거한 요구사항이 구현되었거나 명시적으로 deferred
- [x] Validation checklist 완료 또는 gap이 근거와 함께 기록됨
- [x] 다음 phase를 시작하지 못하게 막는 blocker 없음 (PR #612 main 머지 + working tree clean (PRD 갱신 staged 외) + DL 일관성 모두 통과)

## Phase-End Multi-Pass Review

다음 phase로 이동하기 전 순서대로 완료한다 (이동된 reference: `plan-with-questions/references/prd/phase-template.md` 10-pass 정본 — Phase 2 이후 적용. 본 phase에서는 handoff seed 시점의 phase-template 패턴 그대로):
- [x] 1. Intent/coverage review — 본 phase가 objective(DL-1~17 SSOT lock + baseline 확정)와 매핑된 요구사항을 달성했다.
- [x] 2. Correctness review — PR #612 MERGED 확인됨 (edge case "PR #612 미머지 시 대응"은 미발생). baseline 인용 라인 (FR-5 declaration "236-240"이 실제 declaration body line; 주석 포함 시 235-240)의 sub-range 정확성 Discoveries에 기록 — 후속 phase에서 정확한 라인 사용.
- [x] 3. Simplicity review — Phase 1은 baseline lock-in만 (코드 변경 없음). 복잡 logic 없음.
- [x] 4. Code quality review — 본 phase는 코드 변경 없음, baseline 기록만 (Discoveries 섹션 inline).
- [x] 5. Duplication/cleanup review — N/A (코드 변경 없음).
- [x] 6. Security/privacy review — Discovery Gate 항목이 secret/auth 노출하지 않음 확인.
- [x] 7. Performance/load review — N/A (Discovery only).
- [x] 8. Validation review — 선택한 check가 phase risk에 적절. baseline lock-in이라 도구 검증보다 self-consistency 위주 — Manual smoke (DL count) + git/gh 명령으로 충분.
- [x] 9. Future-phase review — Phase 2~5 파일이 Phase 1 baseline과 일치 확인 (Phase 2 git mv 6 파일 + plan-with-questions 9 link 갱신; Phase 3 standalone 4 file rm + claude/default.nix 235-240; Phase 4 codex/default.nix 38-51 + verify-ai-compat.sh 349-362; Phase 5 run-da link). 라인 인용 sub-range는 implementation 시점에 정확화.
- [x] 10. PRD sync review — master PRD `Phase Index` Phase 1 Status `Not Started` → `Complete`, `Document Status`의 Active Phase File phase-02로 갱신, Change Log Phase 1 완료 entry 추가 (본 commit).

추가로 `review-implementation/requirement-status.md` 6-classification 보조 layer 적용 (Phase-end 통합, NG-2로 auto-fix 미사용).

## Discoveries / Decisions

### Baseline (sealed)

| 항목 | 정확 위치/값 | 비고 |
|------|--------------|------|
| PR #612 | state=MERGED, mergedAt=2026-05-01T05:52:07Z | base=main, head=feat/plan-with-questions-overhaul |
| main HEAD | f7c818bab4602b991f2c0856af37dda240a72e06 | prefix f7c818b |
| 작업 branch | issue/611-skill-router-consolidation | PRD/문서 4 commit (0d7d298 → 76573cc → 8396217 → 47f56c6) |
| lefthook hook (pre-commit) | gitleaks, ai-skills-consistency, eval-tests, codex-hook-fixtures, nixfmt(glob), shellcheck(glob) | commit-msg: pinning. pre-push: shell-script-tests, codex-hook-fixtures(--no-live), flake-check |
| `claude/default.nix` declaration | **line 235-240** (주석 포함 6줄): 235 prd 주석, 236 prd symlink, 237 빈 줄, 238 review-impl 주석, 239-240 review-impl symlink (2줄 split) | PRD FR-5 인용 "236-240"은 declaration body sub-range; Phase 3 Edit 시 235-240 6줄 단위 제거 |
| `codex/default.nix` exposedCodexSkills | line 38-51, prd=**line 45**, review-implementation=**line 46** | Phase 4 Edit 시 두 entry만 제거 |
| `verify-ai-compat.sh` EXPECTED_EXPOSED | line 349-362 (12 entries + 닫는 `)`), prd=**line 356**, review-implementation=**line 357** | PRD FR-7 인용 "349-357"은 배열 시작 ~ review-implementation entry까지 sub-range (정확); Phase 4 Edit 시 **line 356-357 두 entry 제거** |
| `~/.claude/skills/{prd,review-implementation}` | 존재 (nix store /bmwny2nh.../home-manager-files/.claude/skills/...) | Phase 3 nrs 후 부재 검증 baseline |
| `~/.codex/skills/{prd,review-implementation}` | 존재 (동일 nix store path 하위) | Phase 4 nrs 후 부재 검증 baseline |
| `.agents/skills/{prd,review-implementation}` | **부재** (No such file or directory) | A-3 (i) 부재 유지 경로 검증 — syncCodexConfig가 SKILL.md 부재로 미생성 |
| `run-da/SKILL.md` link | **line 75** | Phase 5 Edit 시 갱신 |
| `run-da/references/arbiter-prompt.md` example | **line 192, 195, 196** | Phase 5 Edit 시 갱신 또는 obsolete annotation |

### plan-with-questions 본인 link 갱신 대상 9 파일 (Phase 2 작업 단위)

| 파일 | 정확 line(s) | 패턴 |
|------|-------------|------|
| `SKILL.md` | 86-91 (6 link) | `../prd/references/{validation-paths,multi-pass-review,prd-master-template,phase-template,file-mode-selection}.md` + `../review-implementation/SKILL.md` |
| `modes/for_prd.md` | 17-23 (7 link) | `../../prd/SKILL.md` + 5 references + `../../review-implementation/` |
| `modes/for_action.md` | 98 (1 link) | `../../prd/references/validation-paths.md` |
| `references/post-implementation.md` | 23 (1 link) | `../../prd/references/multi-pass-review.md` |
| `references/task-size-routing.md` | 86 (1 link) | `../../prd/references/file-mode-selection.md` |
| `references/runtime-boundaries.md` | 58 | `/prd 스킬이 작성` 표현 (DL-11) |
| `references/resume-state.md` | 33, 38, 40 (3 표현) | `/prd 스킬로 handoff`, `for_prd.user_confirmed`, `/prd Document Status` |
| `references/plan-file-template.md` | 3, 8, 48, 97, 141 (5 표현) | `/prd master template`, `prd/references/prd-master-template.md`, `/prd 스킬`, `prd/references/validation-paths.md`, `/prd로 handoff` |
| `references/consulting-step.md` | 9, 43 (2 표현) | `/prd로 handoff`, `prd/references/validation-paths.md` |

### A-3 검증 결과

`syncCodexConfig` 동작 확인: `.agents/skills/{prd,review-implementation}` 부재 baseline. (i) 부재 유지 경로 적용 — Phase 3 SKILL.md 삭제 후에도 추가 작업 불필요. (ii) orphan removal 경로는 발생하지 않음 (이미 부재).

### PRD master FR 인용 라인 sub-range note

PRD master FR-5("claude/default.nix:236-240")와 FR-7("verify-ai-compat.sh:349-357")의 라인 인용은 declaration body / EXPECTED_EXPOSED entry 라인 sub-range를 가리킨다. 실제 Edit 단위 (주석/배열 닫기 포함)는:
- FR-5 → **line 235-240** (주석 + body 6줄)
- FR-7 → **line 349-362** (배열 시작 + 12 entries + 닫는 `)`); 두 entry 제거 대상은 **line 356-357** (prd=356, review-implementation=357)

후속 Phase 3-4 Implementation Checklist는 이 정확한 라인을 사용한다. PRD master FR 라인 인용 자체는 sub-range로 그대로 유지 (정확성 유지하기 위해 sub-range 명시).

## Phase Change Log

- 2026-05-01: Phase 1 file created via /prd handoff from plan-with-questions for_prd.
- 2026-05-01: Phase 1 baseline lock-in 완료 — Discovery Gate 13 항목 모두 통과, Implementation Checklist 9 항목 모두 통과, Validation Checklist 적용 가능 항목 (3개 PASS + 7개 N/A) 통과, Exit Criteria 4/4 통과, Phase-End 10-pass review 모두 PASS. **Status: Not Started → Complete**. blocker 없음, Phase 2로 진행 가능.
