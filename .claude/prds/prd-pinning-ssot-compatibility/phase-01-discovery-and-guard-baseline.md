# Phase 1: Discovery and Guard Baseline

Parent PRD: [PRD: Pinning SSOT Compatibility](../prd-pinning-ssot-compatibility.md)
Status: Complete
Last Updated: 2026-05-05

## Objective

Confirm the current repo state and guard behavior before editing the SSOT files.

## Context From Master PRD
- Goals covered: G-1, G-3, G-5
- Success Criteria: SC-1, SC-4, SC-5
- Requirements covered: FR-1, FR-2, FR-6, FR-10
- Key scenarios touched: Scenario 1, Scenario 3

## Phase Discovery Gate
Before code edits:
- [x] Read master PRD.
- [x] Read `modules/shared/programs/claude/files/lib/pinning-patterns.sh`.
- [x] Read `modules/shared/programs/claude/files/hooks/pinning-guard.sh`.
- [x] Read the five scoped target files.
- [x] Confirm no existing `.claude/prds/prd-pinning-ssot-compatibility.md` collision.
- [x] Confirm branch and working tree status before edits.

## Scope
### In Scope
- Confirm current short-hash Baseline references.
- Confirm current external-review durable wording references.
- Confirm preserved runtime examples in `consulting-step.md`.
- Run old-style generated durable-content deny smoke.

### Out of Scope
- Editing the five target docs in this phase.
- Creating follow-up issues.

## Implementation Checklist
- [x] Record current target sections for Baseline format in `plan-file-template.md`.
- [x] Record current target sections for Baseline algorithm in `resume-state.md`.
- [x] Record current target sections for external-review state in `da-integration.md`, `plan-file-template.md`, and `resume-state.md`.
- [x] Record current target heading in `for_action.md`.
- [x] Identify the preserved runtime example block in `consulting-step.md`.
- [x] Run a hook stdin smoke that proves old-style generated durable content is denied.

## Validation Strategy

Use static reads and one negative hook smoke. This phase verifies the starting condition, not the final fix.

## Validation Checklist
- [x] `rg -n "HEAD=|short|hash|result path|Run ID" modules/shared/programs/claude/files/skills/plan-with-questions/references modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_action.md`
- [x] Hook stdin smoke with old-style generated durable content returns deny JSON.
- [x] No tracked files changed during discovery-only work except PRD status updates.

## Exit Criteria
- [x] Current-state evidence is sufficient to guide Phase 2 and Phase 3 edits.
- [x] Old-style deny smoke confirms the guard behavior being fixed.
- [x] No blocker prevents editing the five scoped docs.

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
- Initial PRD planning confirmed the implementation should keep only stable facts and link issue #659 for raw history.
- Existing-state grep found the expected old Baseline/result-path/run-token guidance in target docs.
- Old-style generated durable-content hook smoke returned deny.

## Phase Change Log
- 2026-05-05: Phase file created.
- 2026-05-05: Phase complete after current-state grep, PRD collision check, branch status check, and old-style deny smoke.
