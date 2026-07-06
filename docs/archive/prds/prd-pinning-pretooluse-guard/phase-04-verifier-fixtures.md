# Phase 4: Verifier Fixtures

Parent PRD: [PRD: Pinning PreToolUse Guard](../prd-pinning-pretooluse-guard.md)
Status: Complete
Last Updated: 2026-05-03

## Objective
Make PreToolUse hard-fail behavior and provisioning contract deterministic through fixtures, oracles, and verifier checks.

## Context From Master PRD
- Goals covered: G-5
- Success Criteria: SC-3, SC-4, SC-5, SC-6
- Requirements covered: FR-8, FR-9, NFR-3
- Key scenarios touched: all scenarios

## Phase Discovery Gate
Before code edits:
- [x] Read `tests/test-codex-hook-fixtures.sh`.
- [x] Read `tests/fixtures/codex-hooks/README.md`.
- [x] Read `tests/fixtures/codex-hooks/stdin/`.
- [x] Read `tests/lib/codex-hook-expectations.sh`.
- [x] Read `scripts/ai/verify-ai-compat.sh`.
- [x] Confirm Phase 1-3 implementation facts are reflected in this phase.
- [x] Confirm master PRD assumptions still hold before editing.

## Scope
### In Scope
- Add separate PreToolUse fixture namespace, not mixed into existing warn-only pinning-alert names.
- Add fixture runner helper for stdout JSON deny assertions.
- Add expected stdout/stderr/exit-code handling for hard-fail cases.
- Add lib provisioning setup to fixture sandbox.
- Add oracle constants and verifier checks for PreToolUse command and shared lib.
- Update fixture README with separate sections for PostToolUse warn-only and PreToolUse deny.

### Out of Scope
- Live Codex execution as a required deterministic test.
- Rewriting the entire fixture runner.

## Implementation Checklist
- [x] Add `test_pretooluse_pinning_guard_behavioral` or equivalent clearly named runner function.
- [x] Use fixture names such as `pretooluse-pinning-guard-*` to avoid confusing them with PostToolUse warn-only fixtures.
- [x] Add stdout JSON normalization/assertion helper for deny output.
- [x] Capture stderr separately and assert expected warning/noise behavior.
- [x] Add Claude Edit/Write/NotebookEdit/Bash fixtures.
- [x] Add Codex apply_patch/Bash fixtures.
- [x] Add clean pass fixtures and existing-content delta fixtures.
- [x] Add lib provisioning to `new_hook_sandbox` or equivalent helper.
- [x] Add README section for PreToolUse hard-fail fixture category.
- [x] Update verifier checks for `.claude/lib`, `.codex/lib`, Claude guard, Codex guard, and Codex PreToolUse template command.

## Validation Strategy
Treat deterministic fixtures as the primary enforcement. Live smoke is supplemental because local Codex/Claude versions and auth can vary.

## Validation Checklist
- [x] `tests/test-codex-hook-fixtures.sh --no-live` passes.
- [x] PreToolUse fixture failures show useful diff output.
- [x] Verifier and sandbox fixtures cover shared lib provisioning without mutating active user links.
- [x] Verifier reports the expected PreToolUse guard command.
- [x] Existing PostToolUse fixture category still passes unchanged.
- [x] Fixture README accurately lists new cases and expected behavior.

## Exit Criteria
- [x] Hard-fail behavior is covered by deterministic fixtures across Claude and Codex.
- [x] Existing warn-only fixtures remain isolated and readable.
- [x] Oracles and verifier prevent command string drift.
- [x] No blocker for final validation/docs phase.

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
- Independent planning review did not confirm fixture naming as a defect in the original plan, but the preventive namespace rule is adopted to keep warn-only and hard-fail fixtures readable.
- Fixture sandbox already provisions `.claude/lib` and `.codex/lib`; verifier now checks host `.claude/hooks/pinning-guard.sh`, `.codex/hooks/pinning-guard.sh`, both shared lib symlinks, and shared-lib source usage in all pinning consumers.
- Destructive missing-lib simulation was not run against active user links; equivalent coverage is provided by sandbox fixture provisioning plus host verifier checks.

## Phase Change Log
- 2026-05-03: Phase file created.
- 2026-05-03: Phase complete. Added PreToolUse hard-fail fixture namespace, JSON deny assertion helper, README coverage, notebook eligibility, and verifier hardening.
