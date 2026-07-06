# Phase 1: Pattern SSOT

Parent PRD: [PRD: Pinning PreToolUse Guard](../prd-pinning-pretooluse-guard.md)
Status: Complete
Last Updated: 2026-05-03

## Objective
Create the shared pinning-pattern library and refactor existing warn-only layers without changing their external behavior.

## Context From Master PRD
- Goals covered: G-1, G-4, G-5
- Success Criteria: SC-2, SC-3, SC-6
- Requirements covered: FR-1, FR-2, FR-9, NFR-2, NFR-3
- Key scenarios touched: Scenario 4

## Phase Discovery Gate
Before code edits:
- [x] Read `scripts/ai/commit-msg-pinning.sh`.
- [x] Read `modules/shared/programs/claude/files/hooks/pinning-alert.sh`.
- [x] Read `modules/shared/programs/codex/files/hooks/pinning-alert.sh`.
- [x] Read `modules/shared/programs/claude/default.nix`.
- [x] Read `modules/shared/programs/codex/default.nix`.
- [x] Read `tests/test-codex-hook-fixtures.sh` sandbox setup.
- [x] Read `scripts/ai/verify-ai-compat.sh` hook provisioning checks.
- [x] Confirm master PRD assumptions still hold before editing.

## Scope
### In Scope
- Add `modules/shared/programs/claude/files/lib/pinning-patterns.sh`.
- Move pattern definitions, hash bounds, scan helper, eligibility helper, and finding message labels into the library.
- Keep hook-specific stdin parsing and apply_patch section parsing inside runtime hook scripts.
- Source the library from commit-message and PostToolUse alert scripts.
- Add `.claude/lib/pinning-patterns.sh` and `.codex/lib/pinning-patterns.sh` provisioning.
- Update deterministic fixture sandbox to reproduce lib paths when hooks are copied into sandbox.

### Out of Scope
- Adding PreToolUse hard-fail hooks.
- Changing warn-only exit behavior.
- Solving command obfuscation.

## Implementation Checklist
- [x] Create shared shell library with strict, shellcheck-clean helpers.
- [x] Refactor `commit-msg-pinning.sh` to source the library and preserve warning output and exit success.
- [x] Refactor Claude `pinning-alert.sh` to source the library and preserve PostToolUse warn-only behavior.
- [x] Refactor Codex `pinning-alert.sh` to source the library while keeping Codex apply_patch parsing local.
- [x] Register `.claude/lib/pinning-patterns.sh` in Claude Home Manager files.
- [x] Register `.codex/lib/pinning-patterns.sh` in Codex Home Manager files.
- [x] Update fixture sandbox setup to copy or link `.codex/lib` and `.claude/lib` as needed.
- [x] Add verifier checks for shared lib existence, readability, and expected symlink target suffix.
- [x] Replace pattern lockstep checks with shared-library checks, or keep lockstep only where inline copies remain by explicit decision.

## Validation Strategy
Use focused shell/static checks first, then existing deterministic hook fixture coverage to prove warn-only behavior did not drift.

## Validation Checklist
- [x] `shellcheck -S warning` on changed shell scripts.
- [x] Existing pinning-alert fixtures still match expected stderr.
- [x] `tests/test-codex-hook-fixtures.sh --no-live` passes.
- [x] `./scripts/ai/verify-ai-compat.sh` passes or has only expected pre-activation gap documented before `nrs`.
- [x] Missing-lib negative fixture or verifier path fails clearly where feasible.
- [x] Existing commit-message warning smoke still exits success for pinned and clean examples.

## Exit Criteria
- [x] Shared library is the only source for common pattern and scan/report helper behavior.
- [x] Existing warn-only layers behave the same from the caller perspective.
- [x] Fixture sandbox and verifier both cover lib provisioning.
- [x] No blocker for Claude hard-fail phase.

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
- Independent planning review confirmed that "where safe" is too vague. Runtime stdin parsing stays local; common scanning and labeling moves to the shared library.
- `verify-ai-compat.sh` failed before activation because active symlinks still targeted the main checkout and the new lib links were not provisioned. After `nrs`, worktree relink and lib provisioning were correct and verifier fully passed.
- Existing warn-only fixture outputs stayed stable after the refactor.

## Phase Change Log
- 2026-05-03: Phase file created.
- 2026-05-03: Phase completed after shellcheck, fixture tests, commit-message smoke, `nrs`, and post-activation verifier all passed.
