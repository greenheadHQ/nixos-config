# Phase 2: Claude Guard

Parent PRD: [PRD: Pinning PreToolUse Guard](../prd-pinning-pretooluse-guard.md)
Status: Complete
Last Updated: 2026-05-03

## Objective
Add Claude Code PreToolUse hard-fail pinning coverage while coexisting cleanly with current PostToolUse warn-only alerts.

## Context From Master PRD
- Goals covered: G-2, G-4, G-5
- Success Criteria: SC-1, SC-2, SC-6
- Requirements covered: FR-3, FR-5, FR-8, NFR-1
- Key scenarios touched: Scenario 1, Scenario 3, Scenario 4

## Phase Discovery Gate
Before code edits:
- [x] Read `modules/shared/programs/claude/files/settings.json`.
- [x] Read `modules/shared/programs/claude/files/hooks/fragile-hardcoding-guard.sh`.
- [x] Read `modules/shared/programs/claude/files/hooks/worktree-path-guard.sh`.
- [x] Read `modules/shared/programs/claude/files/hooks/system-bash-guard.sh`.
- [x] Read `modules/shared/programs/claude/files/hooks/pinning-alert.sh`.
- [x] Read Claude hook deny JSON style in existing guard scripts.
- [x] Confirm shared library from Phase 1 is available.
- [x] Confirm master PRD assumptions still hold before editing.

## Scope
### In Scope
- Add `modules/shared/programs/claude/files/hooks/pinning-guard.sh`.
- Register PreToolUse matcher for `Edit|Write|NotebookEdit`.
- Register PreToolUse matcher for `Bash`.
- Parse Edit, Write, NotebookEdit, and Bash stdin shapes.
- Deny only newly introduced pinning where OLD/NEW comparison is available.
- Define Write/new-file conservative behavior and existing-content behavior in fixtures.
- Keep existing PostToolUse warn-only `pinning-alert.sh` unless this phase records a replacement decision.

### Out of Scope
- Codex hook registration.
- Removing PostToolUse warn-only alerts.
- Broad Bash obfuscation detection.

## Implementation Checklist
- [x] Implement Claude guard with `hookSpecificOutput.permissionDecision` set to deny and a multiline correction reason.
- [x] Include NotebookEdit via matcher and parser for `tool_input.notebook_path` and `tool_input.new_source`.
- [x] Implement Edit old/new count comparison for eligible paths.
- [x] Implement Write/new-file behavior and document why it is conservative or delta-based.
- [x] Implement Bash durable command matching for git and gh commit/PR/issue surfaces.
- [x] Implement revert/cherry-pick hash skip behavior for Bash command text. (Superseded by #725: PATTERN_D and the partial-hash exception were removed; revert/cherry-pick no longer requires a skip path because commit hash is not hard-fail anymore.)
- [x] Register `Edit|Write|NotebookEdit` and `Bash` entries in Claude settings.
- [x] Add Claude Home Manager provisioning for `pinning-guard.sh`.
- [x] Add coexistence notes: PreToolUse hard-fail blocks before write/command; PostToolUse alert remains warn-only secondary signal.

## Validation Strategy
Use direct stdin fixtures for Claude hook input because PreToolUse blocks before write. Validate stdout JSON, exit status, and no stderr-only block behavior.

## Validation Checklist
- [x] Direct stdin payload: Claude Edit adds pinning and receives deny JSON.
- [x] Direct stdin payload: Claude Edit preserves old pinning without count increase and passes.
- [x] Direct stdin payload: Claude Write/new file with pinning receives deny JSON.
- [x] Direct stdin payload: Claude NotebookEdit with pinning receives deny JSON.
- [x] Direct stdin payload: Claude clean Write passes; full permanent clean matrix remains Phase 4.
- [x] Direct stdin payload: Bash targeted durable command with pinning receives deny JSON.
- [x] Direct stdin payload: Bash out-of-scope command passes.
- [x] Direct stdin payload: legitimate revert/cherry-pick hash context passes. (Superseded by #725: fixture and skip path removed; commit hash skip no longer needed.)
- [x] Existing PostToolUse warn-only fixture behavior remains unchanged.

## Exit Criteria
- [x] Claude hard-fail covers every durable file-edit surface currently covered by Claude pinning-alert.
- [x] Coexistence contract is documented in code comments or PRD discovery notes.
- [x] No new bypass from NotebookEdit omission.
- [x] No blocker for Codex guard phase.

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
- Independent planning review confirmed NotebookEdit must be included because current warn-only surface already covers it.
- Existing PostToolUse warn-only alert remains in place unless later evidence proves it should be removed.
- The permanent fixture namespace is deferred to Phase 4; this phase used direct stdin payload smoke to prove the new hook behavior before activation.
- `nrs` relinked the new Claude guard and post-activation verifier fully passed.

## Phase Change Log
- 2026-05-03: Phase file created.
- 2026-05-03: Phase completed after shellcheck, settings JSON parse, direct stdin payload smoke, existing fixture suite, `nrs`, and post-activation verifier all passed.
