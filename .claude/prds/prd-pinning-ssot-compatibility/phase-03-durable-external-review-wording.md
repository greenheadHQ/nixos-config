# Phase 3: Durable External-Review Wording

Parent PRD: [PRD: Pinning SSOT Compatibility](../prd-pinning-ssot-compatibility.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

Update durable external-review wording so plan state remains stable and guard-safe without duplicating guard pattern semantics.

## Context From Master PRD
- Goals covered: G-3, G-4
- Success Criteria: SC-3
- Requirements covered: FR-6, FR-7, FR-8, FR-9
- Key scenarios touched: Scenario 3

## Phase Discovery Gate
Before code edits:
- [x] Read `da-integration.md` external-review state guidance.
- [x] Read `for_action.md` external-review section heading.
- [x] Read DA State/result wording in `plan-file-template.md`.
- [x] Read DA resume wording in `resume-state.md`.
- [x] Read `modules/shared/programs/claude/files/lib/pinning-patterns.sh`.
- [x] Confirm Phase 2 is complete.

## Scope
### In Scope
- `modules/shared/programs/claude/files/skills/plan-with-questions/references/da-integration.md`
- `modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_action.md`
- Durable external-review state wording in `plan-file-template.md`
- Durable external-review resume wording in `resume-state.md`

### Out of Scope
- Pattern definition changes.
- Exhaustive prose table that mirrors guard patterns.

## Implementation Checklist
- [x] Replace durable run identifier guidance with runtime-only correlation and natural-language durable state.
- [x] Remove durable guidance examples that use UUID fragments, temp-name fragments, or short hash components.
- [x] Update `for_action.md` heading/wording to avoid the guard keyword shape while preserving the Step 5-6 meaning.
- [x] Update durable state guidance to record verdict summaries or stable artifact names only.
- [x] Remove or replace durable wording that says to record ephemeral scratch result paths.
- [x] Link `modules/shared/programs/claude/files/lib/pinning-patterns.sh` as the pattern SSOT.
- [x] Include only a few guard-safe durable examples and state that examples must be validated with the helper.

## Validation Strategy

Use helper-based static checks on changed durable-output guidance and manual review for SSOT duplication.

## Validation Checklist
- [x] Shared helper reports no new guard findings in changed durable-output guidance.
- [x] `rg -n "result file|result path|shortsha|UUID fragment|mktemp basename" modules/shared/programs/claude/files/skills/plan-with-questions/references/da-integration.md modules/shared/programs/claude/files/skills/plan-with-questions/references/plan-file-template.md modules/shared/programs/claude/files/skills/plan-with-questions/references/resume-state.md` returns no active durable guidance matches.
- [x] `for_action.md` Step 5-6 heading no longer matches the guard keyword shape.
- [x] `da-integration.md` does not contain an exhaustive pattern mapping table.

## Exit Criteria
- [x] Durable external-review state is guard-safe and excludes per-run correlation identifiers.
- [x] Pattern semantics remain centralized in `pinning-patterns.sh`.
- [x] Phase 4 can validate both old-style deny and new-style pass behavior.

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
- Durable state may keep stable summaries, but it must not keep per-run correlation identifiers or ephemeral scratch paths.
- Helper validation across the four Phase 3 target files reported zero guard findings.
- Old phrase grep returned no active durable wording matches after rephrasing disallowed random suffix sources.

## Phase Change Log
- 2026-05-05: Phase file created.
- 2026-05-05: Phase complete after durable wording edits, helper count checks, old phrase grep, and diff whitespace check.
