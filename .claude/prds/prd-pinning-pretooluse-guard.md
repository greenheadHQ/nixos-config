# PRD: Pinning PreToolUse Guard

## Document Status
- Status: Complete
- File Mode: Split
- Current Phase: Phase 5
- Active Phase File: [Phase 5](./prd-pinning-pretooluse-guard/phase-05-validation-docs-closeout.md)
- Last Updated: 2026-05-03
- PRD File: `.claude/prds/prd-pinning-pretooluse-guard.md`
- Source: https://github.com/greenheadHQ/nixos-config/issues/587
- Purpose: Living PRD / execution source of truth for issue #587. Work is checked off here and in phase files; new implementation facts must update this PRD before later phases continue.

## Problem
LLM session and review metadata can still enter durable outputs outside the current repo-local commit-message warning layer. The repo already has warn-only commit-message and PostToolUse pinning alerts, but issue #587 requires deterministic PreToolUse hard-fail coverage across Claude Code and Codex so durable markdown, shell, commit, PR, and issue surfaces are blocked before write or command execution.

## Goals
- G-1: Add a shared pinning-pattern library that is the single source for pattern definitions, hash bounds, scan helper, eligibility helper, and finding labels.
- G-2: Add Claude Code PreToolUse hard-fail coverage for Edit, Write, NotebookEdit, and Bash durable-output commands.
- G-3: Add Codex-managed PreToolUse hard-fail coverage for apply_patch/Edit/Write aliases and Bash durable-output commands.
- G-4: Preserve existing warn-only layers while defining an explicit coexistence contract.
- G-5: Extend fixtures, verifier, and oracles so missing hook/lib provisioning or config drift is caught before runtime.
- G-6: Document the managed Codex PreToolUse ownership change and the new hard-fail policy.

## Non-Goals
- NG-1: Do not solve broad shell command obfuscation such as split variables or generated command strings.
- NG-2: Do not remove existing PostToolUse warn-only alerts unless a phase explicitly proves a replacement is complete and documents the decision.
- NG-3: Do not delete or rewrite valid user-owned Codex hook files beyond the documented template-owned event behavior.
- NG-4: Do not change unrelated hook lifecycle work from issues #603 or #637 except where verifier/config text must stay consistent.

## Success Criteria
- SC-1: Claude and Codex PreToolUse pinning guards deny newly introduced pinning on eligible durable surfaces and pass clean inputs.
- SC-2: Existing commit-message and PostToolUse warn-only behavior remains unchanged unless this PRD records a deliberate replacement.
- SC-3: Shared library provisioning exists under both `.claude/lib/` and `.codex/lib/`, and deterministic hook fixtures reproduce those lib paths.
- SC-4: Codex config templates manage PreToolUse registration and verifier/oracle checks confirm the expected command.
- SC-5: Sync-preservation fixtures document that Codex PreToolUse is now template-owned, while non-template events remain user-owned.
- SC-6: `tests/test-codex-hook-fixtures.sh --no-live`, `./scripts/ai/verify-ai-compat.sh`, and relevant shellcheck checks pass before implementation closeout.
- SC-7: After `nrs`, `./scripts/ai/verify-ai-compat.sh` passes and live smoke checks are recorded or explicitly marked unavailable with reason.

## Key Scenarios
### Scenario 1: Claude File Edit
- Actor: Claude Code session.
- Trigger: Edit, Write, or NotebookEdit attempts to add pinning text to an eligible markdown, shell, notebook, or body temp file.
- Expected outcome: PreToolUse returns deny JSON with a clear correction reason before the write occurs.

### Scenario 2: Codex apply_patch
- Actor: Codex session.
- Trigger: apply_patch adds pinning text to an eligible markdown, shell, notebook, or body temp file.
- Expected outcome: Managed PreToolUse hook sees canonical `tool_name` as `apply_patch`, parses `tool_input.command`, and denies before the patch is applied.

### Scenario 3: Durable Bash Command
- Actor: Claude Code or Codex session.
- Trigger: Bash command attempts durable git or gh commit/PR/issue text containing pinning.
- Expected outcome: PreToolUse denies before command execution. (Note: legitimate revert/cherry-pick hash skip behavior was superseded by #725 — PATTERN_D and the partial-hash exception were removed; commit hash policy is now a CLAUDE.md prose guide, not hard-fail.)

### Scenario 4: Existing Pinned Content
- Actor: Agent editing a file that already contains old pinned text.
- Trigger: Edit touches nearby content without increasing pinning counts.
- Expected outcome: Existing content is not newly blocked by Edit delta logic. Write/new-file flows remain conservative and are fixture-covered.

### Scenario 5: Codex Config Ownership
- Actor: developer running `nrs`.
- Trigger: Codex config sync sees user entries under `hooks.PreToolUse`.
- Expected outcome: PreToolUse is treated like other template-owned hook events; docs and fixtures make that behavior explicit.

## Discovery Summary
- Reviewed: issue #587, related issue comments for #603/#637, Claude settings, Codex config templates, hook scripts, fixture runner, verifier, existing PRDs, OpenAI Codex hooks docs, and openai/codex PR #18391.
- Current system: `commit-msg-pinning.sh` and Claude/Codex PostToolUse `pinning-alert.sh` warn and exit success. No PreToolUse pinning hard-fail guard or shared pattern library exists.
- Current Claude baseline: PreToolUse has ask/plan/worktree/skill/fragile/system guards. PostToolUse has pinning-alert on `Edit|Write|NotebookEdit`.
- Current Codex baseline: templates manage `UserPromptSubmit`, `Stop`, and `PostToolUse`; comments and verifier currently describe `PreToolUse` as a template-undeclared user-owned event.
- Validation surface: shell static checks, deterministic hook fixtures, Codex config sync-preservation fixtures, verifier/oracle checks, `nrs` activation, and optional live hook smoke.
- External docs: Codex PreToolUse can intercept Bash and apply_patch. apply_patch matching can use `apply_patch`, `Edit`, or `Write`; stdin still reports canonical `tool_name` as `apply_patch` and uses `tool_input.command`.
- Independent planning review: confirmed the PRD must include NotebookEdit, Codex template-owned migration, lib provisioning in fixtures/verifier, explicit warn-only coexistence, shared helper boundaries, and Codex oracle command constants.

## Requirements
### Functional Requirements
- FR-1: Add `modules/shared/programs/claude/files/lib/pinning-patterns.sh` with shared pattern definitions, hash bounds, scan helper, eligibility helper, and human-readable finding labels.
- FR-2: Refactor `scripts/ai/commit-msg-pinning.sh` and both existing `pinning-alert.sh` scripts to source the shared library while preserving their current warn-only contracts.
- FR-3: Add Claude `pinning-guard.sh` with PreToolUse deny JSON for Edit, Write, NotebookEdit, and Bash.
- FR-4: Add Codex `pinning-guard.sh` with PreToolUse deny JSON for apply_patch/Edit/Write alias matching and Bash.
- FR-5: Register Claude guard in `settings.json` and Home Manager hook provisioning.
- FR-6: Register Codex guard in both Codex config templates and Home Manager hook provisioning.
- FR-7: Update sync-preservation fixtures and docs to reflect that Codex PreToolUse is now template-owned.
- FR-8: Add deterministic fixtures for Claude and Codex PreToolUse deny/pass behavior, including NotebookEdit and apply_patch multi-file cases.
- FR-9: Update `tests/lib/codex-hook-expectations.sh` and `verify-ai-compat.sh` for expected PreToolUse guard command and shared lib provisioning.
- FR-10: Update README and Claude user-scope docs with the two-layer policy: PreToolUse hard-fail plus existing warn-only/commit-message checks.

### Non-Functional Requirements
- NFR-1: Guard scripts must fail open only on missing local tooling that existing hooks already treat as non-fatal; intentional pinning matches must fail closed.
- NFR-2: Hook-specific stdin parsing may remain local, but shared scan and reporting logic must not drift.
- NFR-3: Tests must isolate host state and reproduce lib paths in sandbox.
- NFR-4: Docs and PR text must avoid embedding volatile review identifiers or short hashes as durable text.

## Assumptions
- A-1: Current Codex runtime includes apply_patch PreToolUse behavior from openai/codex PR #18391; fixtures still cover the canonical stdin contract.
- A-2: User accepts Codex PreToolUse becoming a managed template-owned hook event.
- A-3: Existing PostToolUse warn-only layer remains valuable as a second signal and should be kept unless a phase records a contrary decision.
- A-4: Runtime live smoke may be environment-dependent; deterministic fixture and verifier coverage are the required baseline.

## Dependencies / Constraints
- `nrs` must be used instead of direct rebuild commands.
- Nix-related commands run in the repo environment.
- Tracked writes, branch mutation, commit/push, GitHub writes, and `nrs` are main-agent-only.
- `request_user_input` decisions already selected split Living PRD, Claude+Codex hard-fail, and managed Codex template registration.
- Official Codex docs and current repo comments must be rechecked if hook schema or sync ownership changes during implementation.

## Risks / Edge Cases
- Codex PreToolUse template ownership can overwrite existing user entries under the same event.
- Shared lib sourcing can break hooks if `.claude/lib` or `.codex/lib` symlinks are not provisioned or sandboxed.
- Claude NotebookEdit can remain a bypass if omitted from matcher, parser, or fixtures.
- PreToolUse hard-fail can block existing pinned content if Edit delta and Write/new-file semantics are not precise.
- apply_patch parser changes can miss multi-file, rename, remove-only, or eligible-path attribution cases.
- Durable docs can accidentally contain the same volatile tokens the guard is meant to prevent.

## Execution Rules
- This PRD is the only active plan artifact for issue #587.
- Phases run in order unless this PRD is updated first.
- Before each phase, read master PRD and active phase file.
- If new facts change future phases, update this PRD before continuing.
- Keep the minimum reversible change that satisfies the current phase.
- Preserve existing hook contracts unless this PRD explicitly records a replacement.
- Complete phase checkboxes immediately as work is verified.
- Post-Implementation 1-7 automatic flow is approved by the user: implementation, implementation commit, code review loop, parallel audit, final multi-pass review, review fixes/commit, and PR creation.

## Phase Index

| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: Pattern SSOT | Complete | Create shared pattern library and preserve warn-only baseline behavior. | Shellcheck, fixture no-live, verifier lib checks. | [phase-01-pattern-ssot.md](./prd-pinning-pretooluse-guard/phase-01-pattern-ssot.md) |
| Phase 2: Claude Guard | Complete | Add Claude PreToolUse hard-fail for Edit, Write, NotebookEdit, and Bash. | Claude stdin fixtures, deny JSON, coexistence cases. | [phase-02-claude-guard.md](./prd-pinning-pretooluse-guard/phase-02-claude-guard.md) |
| Phase 3: Codex Guard | Complete | Add managed Codex PreToolUse hard-fail and ownership migration. | apply_patch fixtures, TOML sync preservation, oracle checks. | [phase-03-codex-guard.md](./prd-pinning-pretooluse-guard/phase-03-codex-guard.md) |
| Phase 4: Verifier Fixtures | Complete | Extend deterministic fixtures, oracles, and verifier coverage. | Full no-live fixture runner, verifier, sync scenarios. | [phase-04-verifier-fixtures.md](./prd-pinning-pretooluse-guard/phase-04-verifier-fixtures.md) |
| Phase 5: Validation Docs Closeout | Complete | Document policy, run activation validation, and complete review/PR flow. | docs grep, shellcheck, `nrs`, verifier, live smoke. | [phase-05-validation-docs-closeout.md](./prd-pinning-pretooluse-guard/phase-05-validation-docs-closeout.md) |

## Final Multi-Pass Review After All Phases
Run the plan-with-questions PRD final review checklist plus review-implementation overlay. At minimum verify intent coverage, correctness, simplicity, code quality, cleanup, security/privacy, performance/load, validation appropriateness, PRD closeout, and rollout/rollback notes.

## Open Questions
- None. User decisions for tracking mode, hard-fail scope, and Codex registration ownership are resolved.

## Change Log
- 2026-05-03: Initial split PRD created for issue #587 after user approval. Incorporated independent planning review findings for NotebookEdit, Codex PreToolUse ownership migration, lib provisioning, coexistence semantics, shared helper boundaries, and Codex oracle constants.
- 2026-05-03: Phase 1 complete. Shared pinning pattern library created, warn-only layers refactored, lib provisioning activated with `nrs`, and verifier fully passed after relink.
- 2026-05-03: Phase 2 complete. Claude PreToolUse guard added for Edit, Write, NotebookEdit, and Bash; direct stdin smoke, `nrs`, and verifier passed.
- 2026-05-03: Phase 3 complete. Codex managed PreToolUse guard added, config templates and provisioning updated, sync-preservation scenario added, direct apply_patch/Bash smoke passed, `nrs` completed, and verifier fully passed after relink.
- 2026-05-03: Phase 4 complete. Added separate PreToolUse hard-fail fixtures, notebook path eligibility, fixture README updates, Claude guard host verifier check, and shared-lib source verification for all pinning consumers.
- 2026-05-03: Phase 5 implementation complete. README/user-scope policy docs updated; code review and parallel audit findings were triaged; required fixes were added for durable Bash command variants, missing shared library behavior, Codex alias no-increase edits, repo-relative exclusions, verifier source checks, and stale comments. `nrs --force`, verifier, deterministic fixtures, docs grep, and active hook smoke all passed.
- 2026-05-03: PR created for final review: https://github.com/greenheadHQ/nixos-config/pull/650
