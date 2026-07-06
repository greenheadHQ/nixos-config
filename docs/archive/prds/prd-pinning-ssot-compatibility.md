# PRD: Pinning SSOT Compatibility

## Document Status
- Status: Complete
- File Mode: Split
- Current Phase: Complete
- Active Phase File: [Phase 4: Validation activation closeout](./prd-pinning-ssot-compatibility/phase-04-validation-activation-closeout.md)
- Last Updated: 2026-05-05
- PRD File: `.claude/prds/prd-pinning-ssot-compatibility.md`
- Source: https://github.com/greenheadHQ/nixos-config/issues/659
- Purpose: Living PRD / execution source of truth for issue #659. Work is checked off here and in phase files; new implementation facts must update this PRD before later phases continue.

## Problem

`plan-with-questions` SSOT currently teaches durable plan state formats that can be blocked by the pinning guard when a new plan or PRD is written. The issue is not the guard itself; the source-of-truth instructions still include short hash style baseline examples, external-review wording that matches guard patterns, and durable references to ephemeral result paths.

The implementation must update the SSOT so future generated durable artifacts use stable natural-language anchors, stable summaries, and guard-safe wording while preserving resume safety.

## Goals

- G-1: Replace hash-based Baseline guidance with branch + natural-language anchor + natural-language dirty status.
- G-2: Preserve fail-closed resume behavior when natural-language anchors or dirty state cannot be safely resolved.
- G-3: Keep external-review runtime correlation out of durable state while keeping durable entries guard-safe.
- G-4: Keep `pinning-patterns.sh` as the pattern SSOT; do not duplicate pattern semantics in prose.
- G-5: Preserve runtime examples in `consulting-step.md` while making generated durable-output guidance guard-safe.
- G-6: Validate source and deployed skill surfaces after `nrs`.

## Non-Goals

- NG-1: No guard sanitizer changes.
- NG-2: No PATTERN_B tracing or broader guard pattern redesign.
- NG-3: No retro-rewrite of existing plan files.
- NG-4: No measurement automation work.
- NG-5: No guard exception-path additions.

## Success Criteria

- SC-1: The five scoped markdown files no longer instruct agents to write short hash Baseline values or hash-derived dirty state into durable plan files.
- SC-2: Resume guidance fails closed when a natural-language anchor, same-branch drift, or dirty state cannot be safely compared.
- SC-3: Durable external-review state records natural-language status plus verdict summaries or stable artifact names, not one-off run identifiers or ephemeral scratch paths.
- SC-4: `consulting-step.md` keeps required runtime examples, and validation explicitly separates preserved runtime examples from generated durable-output guidance.
- SC-5: Negative and positive hook smoke checks prove old-style generated durable content is denied and new-style generated durable content passes.
- SC-6: `nrs` and `./scripts/ai/verify-ai-compat.sh` pass after source changes.

## Key Scenarios

### Scenario 1: New for_action plan baseline
- Actor: plan-with-questions for_action flow.
- Trigger: Step 4.5 creates a new plan.
- Expected outcome: Baseline uses a natural-language anchor and dirty status. It does not contain a short hash or a dirty hash.

### Scenario 2: Resume after repository drift
- Actor: a later session resumes an existing plan.
- Trigger: current branch, anchor meaning, or dirty state does not safely match the stored Baseline.
- Expected outcome: the flow reruns discovery or asks the user before jumping to `Resume From`.

### Scenario 3: External review state in a durable plan
- Actor: plan-with-questions records external review progress.
- Trigger: review starts, completes, or is resumed.
- Expected outcome: durable state records natural-language review status plus verdict summary or stable artifact name. It does not record one-off run identifiers or ephemeral scratch result paths.

## Discovery Summary

- Reviewed:
  - `modules/shared/programs/claude/files/skills/plan-with-questions/references/plan-file-template.md`
  - `modules/shared/programs/claude/files/skills/plan-with-questions/references/resume-state.md`
  - `modules/shared/programs/claude/files/skills/plan-with-questions/references/consulting-step.md`
  - `modules/shared/programs/claude/files/skills/plan-with-questions/references/da-integration.md`
  - `modules/shared/programs/claude/files/skills/plan-with-questions/modes/for_action.md`
  - `modules/shared/programs/claude/files/lib/pinning-patterns.sh`
  - `modules/shared/programs/claude/files/hooks/pinning-guard.sh`
  - `tests/test-codex-hook-fixtures.sh`
- Current system:
  - `plan-file-template.md` still documents short hash Baseline and dirty hash examples.
  - `resume-state.md` still computes a short head value and dirty hash for resume comparison.
  - `da-integration.md` still documents a per-run identifier in durable state.
  - `for_action.md` still has external-review wording that matches guard patterns.
  - `consulting-step.md` intentionally keeps runtime examples; those examples need explicit validation handling rather than blanket removal.
- Validation surface:
  - Static checks using `modules/shared/programs/claude/files/lib/pinning-patterns.sh`.
  - Hook stdin smoke tests against `modules/shared/programs/claude/files/hooks/pinning-guard.sh`.
  - Relevant PreToolUse fixture coverage in `tests/test-codex-hook-fixtures.sh`.
  - `nrs` plus post-activation `./scripts/ai/verify-ai-compat.sh`.
- Design implications:
  - Baseline and resume logic must be changed together.
  - Durable external-review wording touches more than `da-integration.md`; state/resume wording in `plan-file-template.md` and `resume-state.md` must be updated too.
  - The PRD must not copy issue handoff history or review provenance. Issue #659 remains the raw context link.

## Requirements

### Functional Requirements

- FR-1: `plan-file-template.md` Baseline fields and prose use branch + natural-language anchor + natural-language dirty status.
- FR-2: `resume-state.md` removes short hash generation and dirty hash equality comparison from the Baseline algorithm.
- FR-3: Resume logic requires a fail-closed decision when an anchor cannot be confidently resolved.
- FR-4: Resume logic requires a fail-closed decision when baseline or current state is dirty and content identity cannot be safely compared.
- FR-5: `consulting-step.md` adds a consistency note tying durable Baseline formatting to the existing durable temp-path boundary.
- FR-6: `da-integration.md` keeps per-run correlation runtime-only and records durable review state in natural language.
- FR-7: Durable state wording in `da-integration.md`, `plan-file-template.md`, and `resume-state.md` records verdict summaries or stable artifact names, not ephemeral scratch result paths.
- FR-8: `for_action.md` external-review section wording avoids the guard keyword shape while preserving meaning.
- FR-9: `da-integration.md` links `pinning-patterns.sh` as the pattern SSOT and avoids an exhaustive forbidden-to-replacement mapping table.
- FR-10: Validation includes old-style deny smoke and new-style pass smoke.

### Non-Functional Requirements

- NFR-1: SSOT source edits are limited to the five scoped markdown docs; PRD files are living tracking artifacts.
- NFR-2: Runtime command examples in `consulting-step.md` remain intact unless a phase records a specific safer equivalent.
- NFR-3: The implementation remains reversible as markdown-only source changes.
- NFR-4: PRD and PR text avoid volatile review/session metadata and short hash examples.

## Assumptions

- A-1: Natural-language anchors are acceptable if resume behavior fails closed when ambiguity remains.
- A-2: Runtime-only review correlation may use implementation-local identifiers, but durable markdown must not depend on or record them.
- A-3: `nrs` updates user-scope skill symlinks before `verify-ai-compat.sh` validates runtime surface.

## Dependencies / Constraints

- `nrs` alias must be used; direct rebuild commands are out of scope.
- Tracked writes, branch mutation, commit/push, GitHub writes, and `nrs` are main-agent-only.
- `modules/shared/programs/claude/files/lib/pinning-patterns.sh` remains the guard pattern SSOT.
- Approval for this PRD means Post-Implementation steps 1-7 run by default. This supersedes the older issue handoff skip note unless the user explicitly narrows scope.

## Risks / Edge Cases

- Natural-language anchors can be ambiguous; fail-closed resume behavior is required.
- Dirty working tree summaries can hide content drift; dirty state must not authorize same-HEAD resume by itself.
- Runtime temp-dir examples in `consulting-step.md` can be mistaken for generated durable-output violations; validation must separate those surfaces.
- Regex-safe per-run labels can still violate the user-scope durable metadata policy; keep review correlation out of markdown.
- A detailed prose mapping table can drift from `pinning-patterns.sh`; examples must stay illustrative.

## Execution Rules

- This PRD is the only active plan artifact for issue #659.
- Phases run in order unless this PRD is updated first.
- Before each phase, read master PRD and active phase file.
- If new facts change later phases, update this PRD before continuing.
- Keep the minimum reversible change that satisfies the current phase.
- Complete phase checkboxes immediately as work is verified.
- Post-Implementation 1-7 automatic flow is approved unless the user explicitly narrows scope: implementation, implementation commit, code review loop, parallel audit, final multi-pass review, review fixes/commit if needed, and PR creation.

## Phase Index

| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: Discovery and guard baseline | Complete | Confirm current target lines, helper behavior, and guard reproduction before edits. | Existing-state grep + old-style deny smoke. | [phase-01-discovery-and-guard-baseline.md](./prd-pinning-ssot-compatibility/phase-01-discovery-and-guard-baseline.md) |
| Phase 2: Baseline and resume contract | Complete | Update Baseline/resume semantics as one invariant. | Natural anchor format + fail-closed drift cases. | [phase-02-baseline-and-resume-contract.md](./prd-pinning-ssot-compatibility/phase-02-baseline-and-resume-contract.md) |
| Phase 3: Durable external-review wording | Complete | Update durable external-review state and wording across all affected docs. | Runtime-only correlation + no ephemeral result paths. | [phase-03-durable-external-review-wording.md](./prd-pinning-ssot-compatibility/phase-03-durable-external-review-wording.md) |
| Phase 4: Validation activation closeout | Complete | Run scoped static, hook, fixture, activation, review, audit, and PR closeout. | Negative/positive smoke + `nrs` + verifier. | [phase-04-validation-activation-closeout.md](./prd-pinning-ssot-compatibility/phase-04-validation-activation-closeout.md) |

## Final Multi-Pass Review After All Phases

Run the plan-with-questions PRD final review checklist plus review-implementation overlay. PRD Closeout is active because this PRD writes under `.claude/prds/`.

## Open Questions

- None. Scope, file mode, phase structure, and post-implementation workflow are resolved.

## Change Log

- 2026-05-05: Initial PRD created for issue #659 after user approval. External consultation and plan review findings were incorporated into the phase structure: baseline/resume invariant, durable external-review wording invariant, scoped validation split, and current post-implementation workflow.
- 2026-05-05: Phase 1 complete. Existing-state grep confirmed old Baseline/result-path/run-token guidance remains in target docs, and hook stdin smoke confirmed old-style generated durable content is denied. Active Phase -> Phase 2.
- 2026-05-05: Phase 2 complete. Baseline metadata now uses natural-language anchor and dirty status; resume-state removes short-head and dirty digest comparison, adds fail-closed anchor/dirty ambiguity handling, and consulting-step links Baseline formatting to durable-output boundaries. Active Phase -> Phase 3.
- 2026-05-05: Phase 3 complete. External-review durable state now keeps run correlation runtime-only, uses durable verdict summaries or stable artifact names, keeps helper-as-SSOT wording, and updates the for_action heading. Active Phase -> Phase 4.
- 2026-05-05: Phase 4 in progress. Static helper checks, consulting runtime example check, old-style deny smoke, new-style pass smoke, fixture tests, `nrs`, `verify-ai-compat`, and implementation commit completed. Review findings about stale result-output wording, PRD status drift, NFR scope wording, guard-internal prose, and Baseline delimiters were incorporated.
- 2026-05-05: Phase 4 closeout in progress. Code review, parallel audit, and final multi-pass review completed; accepted fixes were incorporated and validation was rerun. Remaining: PR creation and PRD completion update.
- 2026-05-05: Phase 4 complete. PR #683 created for issue #659 and PRD closeout recorded.
