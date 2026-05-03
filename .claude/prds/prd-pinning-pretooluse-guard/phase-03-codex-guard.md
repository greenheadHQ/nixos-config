# Phase 3: Codex Guard

Parent PRD: [PRD: Pinning PreToolUse Guard](../prd-pinning-pretooluse-guard.md)
Status: Complete
Last Updated: 2026-05-03

## Objective
Add managed Codex PreToolUse hard-fail coverage and update the Codex config ownership contract.

## Context From Master PRD
- Goals covered: G-3, G-5, G-6
- Success Criteria: SC-1, SC-4, SC-5, SC-6
- Requirements covered: FR-4, FR-6, FR-7, FR-8, FR-9
- Key scenarios touched: Scenario 2, Scenario 3, Scenario 5

## Phase Discovery Gate
Before code edits:
- [x] Read `modules/shared/programs/codex/files/config.toml`.
- [x] Read `modules/shared/programs/codex/files/config.darwin.toml`.
- [x] Read `modules/shared/programs/codex/files/hooks/pinning-alert.sh`.
- [x] Read `modules/shared/programs/codex/files/sync-codex-config.py`.
- [x] Read `tests/fixtures/codex-hooks/sync-preservation/`.
- [x] Read `tests/lib/codex-hook-expectations.sh`.
- [x] Read current OpenAI Codex hooks docs for PreToolUse apply_patch schema.
- [x] Confirm shared library from Phase 1 is available.
- [x] Confirm master PRD assumptions still hold before editing.

## Scope
### In Scope
- Add `modules/shared/programs/codex/files/hooks/pinning-guard.sh`.
- Parse canonical Codex `tool_name=apply_patch` with `tool_input.command`.
- Match apply_patch using managed matcher values that current docs support.
- Parse Bash `tool_input.command`.
- Register PreToolUse in both Codex config templates.
- Add Codex Home Manager provisioning for guard and shared lib.
- Update config comments and verifier guidance because PreToolUse becomes template-owned.
- Add sync-preservation scenarios for user PreToolUse entry overwrite and remaining user-owned event preservation.
- Add oracle constant for the expected PreToolUse guard command.

### Out of Scope
- User-level manual PreToolUse registration as the primary path.
- Removing valid user-owned hooks from other events.
- Changing PostToolUse warn-only alert registration.

## Implementation Checklist
- [x] Implement Codex guard with deny JSON accepted by Codex PreToolUse.
- [x] Reuse shared library for scanning/reporting.
- [x] Keep apply_patch envelope section parsing local to Codex hook.
- [x] Preserve multi-file, move-to, remove-only, and eligible-path attribution behavior from current alert parser.
- [x] Add `[[hooks.PreToolUse]]` entries to both Codex config templates.
- [x] Use a single expected-command oracle constant for `$HOME/.codex/hooks/pinning-guard.sh`.
- [x] Update sync comments to remove PreToolUse from the user-owned event examples.
- [x] Add sync-preservation fixture for PreToolUse template-owned overwrite.
- [x] Add alternative fixture showing an actually undeclared event remains user-owned.
- [x] Update verifier to require the managed PreToolUse command and guard executable/symlink.

## Validation Strategy
Use static TOML/oracle checks and deterministic hook fixtures before any live Codex smoke. Verify that activation semantics are documented, not accidental.

## Validation Checklist
- [x] Direct smoke: Codex apply_patch adds pinning and receives deny JSON.
- [x] Direct smoke: Codex apply_patch multi-file attributes the matched file correctly.
- [x] Direct smoke: Codex apply_patch remove-only case passes.
- [x] Direct smoke: Codex apply_patch move-to case uses effective new path.
- [x] Direct smoke: Codex Bash durable command with pinning receives deny JSON.
- [x] Direct smoke: Codex Bash out-of-scope command passes.
- [x] Sync-preservation fixture proves PreToolUse is template-owned.
- [x] Sync-preservation fixture proves another undeclared event remains user-owned.
- [x] Verifier confirms expected PreToolUse command in active config after activation.

## Exit Criteria
- [x] Codex managed PreToolUse guard is registered in both templates.
- [x] Ownership contract change is explicit in comments, tests, verifier, and docs.
- [x] apply_patch parser remains behavior-compatible with existing alert parser for relevant cases.
- [x] No blocker for full fixture/verifier phase.

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
- User selected managed Codex template registration.
- Independent planning review confirmed this is a contract change: PreToolUse moves from user-owned example to template-owned event.
- Existing scenario C already proves a template-undeclared event remains user-owned; scenario F adds the PreToolUse overwrite case.
- Phase 4 will turn the direct hard-fail smoke cases into named deterministic fixtures.

## Phase Change Log
- 2026-05-03: Phase file created.
- 2026-05-03: Phase complete. Codex PreToolUse guard, config registration, provisioning, oracle, verifier, and sync-preservation coverage implemented and activation-verified.
