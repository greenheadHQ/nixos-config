# Phase 5: Validation Docs Closeout

Parent PRD: [PRD: Pinning PreToolUse Guard](../prd-pinning-pretooluse-guard.md)
Status: Complete
Last Updated: 2026-05-03

## Objective
Document the final policy, run activation-level validation, and complete the approved post-implementation review/PR flow.

## Context From Master PRD
- Goals covered: G-4, G-5, G-6
- Success Criteria: SC-6, SC-7
- Requirements covered: FR-10, NFR-4
- Key scenarios touched: all scenarios

## Phase Discovery Gate
Before code edits:
- [x] Read `README.md` hook section.
- [x] Read `modules/shared/programs/claude/files/CLAUDE.md`.
- [x] Read issue #584/#603/#637 references if PR text needs cross-links.
- [x] Read final changed files from Phases 1-4.
- [x] Confirm durable docs avoid volatile review identifiers and short hashes.
- [x] Confirm master PRD assumptions still hold before editing.

## Scope
### In Scope
- Update README hook documentation.
- Update Claude user-scope docs with hard-fail plus warn-only policy.
- Run static and deterministic validation.
- Run `nrs` and post-activation verifier per repo rule.
- Perform live smoke checks where local runtime supports them.
- Run post-implementation code review loop, parallel audit, final review, and PR creation as approved.

### Out of Scope
- Broad rewrite of hook docs unrelated to pinning guard.
- Cross-machine live smoke if current machine lacks the required runtime; record the gap instead.

## Implementation Checklist
- [x] Update README hook section with PreToolUse hard-fail and existing warn-only layers.
- [x] Update Claude user-scope docs with durable-output pinning policy.
- [x] Ensure docs avoid literal volatile review tokens and short hash examples.
- [x] Run shellcheck on changed shell scripts.
- [x] Run deterministic hook fixture tests.
- [x] Run verifier before activation if useful for preflight.
- [x] Run `nrs`.
- [x] Run `./scripts/ai/verify-ai-compat.sh` immediately after `nrs`.
- [x] Run live Claude hard-fail smoke or record why unavailable.
- [x] Run live Codex hard-fail smoke or record why unavailable.
- [x] Cross-link #584, #603, #637 in PR description or issue comment as appropriate.

## Validation Strategy
Combine deterministic checks, activation checks, and live smoke. Do not let live smoke replace deterministic coverage.

## Validation Checklist
- [x] `shellcheck -S warning` for changed shell scripts.
- [x] `tests/test-codex-hook-fixtures.sh --no-live`.
- [x] `./scripts/ai/verify-ai-compat.sh`.
- [x] `nrs`.
- [x] Post-`nrs` `./scripts/ai/verify-ai-compat.sh`.
- [x] Live Claude smoke: hard-fail and clean pass, or documented unavailable reason.
- [x] Live Codex smoke: hard-fail and clean pass, or documented unavailable reason.
- [x] Final docs grep for volatile review tokens and short hashes.
- [x] Post-implementation review loop completed.
- [x] Parallel audit completed.
- [x] Final multi-pass review completed.

## Exit Criteria
- [x] All required deterministic validation passes.
- [x] Activation validation passes after `nrs`.
- [x] Live smoke is passed or explicitly documented as unavailable.
- [x] PRD master and phase files are updated to Complete.
- [x] PR is created or a blocker is documented: https://github.com/greenheadHQ/nixos-config/pull/650

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
- User approval means Post-Implementation 1-7 proceeds automatically unless a blocker or explicit user stop occurs.
- A plain `nrs` no-op build can skip activation while new out-of-store hook/lib links are still absent. Use `nrs --force` for this class of hook projection validation before running the post-activation verifier.
- Code review confirmed and fixed required issues around durable Bash command variants, missing shared library behavior, Codex alias no-increase edits, repo-relative self-exclusions, and verifier source-statement checks.
- Parallel audit baseline comparison was unchanged; no auditor workspace mutation was detected.
- Optional refactors remain out of this issue scope: deduplicating Codex apply_patch parsing, consolidating pattern counting/reporting internals, and sharing guard JSON/bash predicate helpers.

## Phase Change Log
- 2026-05-03: Phase file created.
- 2026-05-03: Phase complete after docs, review loop, parallel audit, forced activation, verifier, deterministic fixtures, active hook smoke, docs grep, commit, push, and PR creation all passed. PR: https://github.com/greenheadHQ/nixos-config/pull/650
