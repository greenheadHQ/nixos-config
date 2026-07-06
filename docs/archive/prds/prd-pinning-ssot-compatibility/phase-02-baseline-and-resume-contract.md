# Phase 2: Baseline and Resume Contract

Parent PRD: [PRD: Pinning SSOT Compatibility](../prd-pinning-ssot-compatibility.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

Update Baseline formatting and resume drift handling as one invariant so generated durable plan state avoids short hash pinning while resume safety remains fail-closed.

## Context From Master PRD
- Goals covered: G-1, G-2, G-5
- Success Criteria: SC-1, SC-2, SC-4
- Requirements covered: FR-1, FR-2, FR-3, FR-4, FR-5
- Key scenarios touched: Scenario 1, Scenario 2

## Phase Discovery Gate
Before code edits:
- [x] Read `plan-file-template.md` Baseline sections.
- [x] Read `resume-state.md` Baseline drift algorithm.
- [x] Read `consulting-step.md` durable-output boundary section.
- [x] Confirm Phase 1 evidence still matches current files.
- [x] Confirm master PRD assumptions still hold.

## Scope
### In Scope
- `modules/shared/programs/claude/files/skills/plan-with-questions/references/plan-file-template.md`
- `modules/shared/programs/claude/files/skills/plan-with-questions/references/resume-state.md`
- Baseline consistency note in `modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md`

### Out of Scope
- External-review runtime-correlation wording; handled in Phase 3.
- Runtime command examples in `consulting-step.md`.

## Implementation Checklist
- [x] Change `plan-file-template.md` Baseline metadata examples to branch + natural-language anchor + natural-language dirty status.
- [x] Remove short-hash Baseline examples from `plan-file-template.md`.
- [x] Rewrite `resume-state.md` Baseline field format away from short head and dirty hash values.
- [x] Remove old token equality guidance from the Baseline algorithm.
- [x] Define a mandatory drift decision procedure: unresolved anchor means rerun discovery or ask the user before resuming.
- [x] Define dirty-state fail-closed behavior: if baseline or current state is dirty and content identity cannot be safely compared, rerun discovery or ask the user.
- [x] Add same-branch new commit drift handling.
- [x] Add a `consulting-step.md` note tying durable Baseline formatting to the existing durable temp-path boundary.

## Validation Strategy

Use static checks for removed short-hash guidance plus manual scenario checks for same-branch drift and dirty-state ambiguity.

## Validation Checklist
- [x] `rg -n "HEAD=<sha|short_sha|sha1_of_diff|dirty=<clean\\|hash" modules/shared/programs/claude/files/skills/plan-with-questions/references/plan-file-template.md modules/shared/programs/claude/files/skills/plan-with-questions/references/resume-state.md` returns no active generated durable Baseline guidance matches.
- [x] Manual scenario: same branch with a newer commit cannot silently resume from old `Resume From`.
- [x] Manual scenario: same branch and same anchor with dirty ambiguity requires discovery rerun or user confirmation.
- [x] `consulting-step.md` new note does not alter runtime command examples.

## Exit Criteria
- [x] Baseline format no longer teaches short hash or dirty hash durable state.
- [x] Resume safety remains fail-closed for ambiguous anchor, same-branch drift, and dirty state.
- [x] Phase 3 can proceed without Baseline/resume inconsistencies.

## Phase-End Multi-Pass Review
- [x] 1. Intent/coverage review.
- [x] 2. Correctness review.
- [x] 3. Simplicity review.
- [x] 4. Code quality review.
- [x] 5. Duplication/cleanup review.
- [x] 6. Security/privacy review.
- [x] 7. Performance/load review.
- [x] 8. Validation review.
- [x] 9. Future-phase review.
- [x] 10. PRD sync review.

## Discoveries / Decisions
- Baseline formatting and resume drift handling are one invariant; they must not be implemented as independent phases.
- Validation pattern was tightened to avoid treating `git status --short` as a short commit identifier.
- Fail-closed dirty ambiguity is documented as a resume blocker unless the user confirms or discovery is rerun.

## Phase Change Log
- 2026-05-05: Phase file created.
- 2026-05-05: Phase complete after Baseline/resume edits, consulting-step note, targeted old-guidance grep, fail-closed scenario review, and diff whitespace check.
