# PRD: Codex User Legacy Hooks

## Document Status
- Status: Complete
- File Mode: Split
- Current Phase: Complete
- Active Phase File: [Phase 4](./prd-codex-user-legacy-hooks/phase-04-validation-handoff.md)
- Last Updated: 2026-05-02
- PRD File: `.claude/prds/prd-codex-user-legacy-hooks.md`
- Purpose: Living PRD / execution source of truth for issue #637. Work is checked off here and in phase files; new implementation facts must update this PRD before later phases continue.

## Problem
Codex can still load user-level hook configuration from `~/.codex/hooks.json`. A stale Claude-era legacy file there can invoke missing scripts such as session icon or old guard scripts, causing repeated hook failures at session/tool boundaries. The repo already removes repo-local retired `.codex/hooks*.json` artifacts, but it does not detect or clean stale user-level legacy entries.

DA for_plan corrected an important boundary: `~/.codex/hooks.json` is still an official Codex hook source, so file existence alone is not stale. This PRD therefore removes or fails only on known stale legacy entries/artifacts, not on valid user-owned hooks.

## Goals
- G-1: Prevent recurrence of known stale user-level Claude-era Codex hook entries.
- G-2: Preserve valid user-owned `~/.codex/hooks.json` hooks.
- G-3: Keep actual Codex-native `PreToolUse` implementation and ownership decisions in issue #587.
- G-4: Make verifier output actionable when stale user-level hook state reappears.
- G-5: Cover common, Darwin, and NixOS nrs wrapper paths with sandboxed tests.

## Non-Goals
- NG-1: Do not revive legacy JSON projection as a Codex hook source of truth.
- NG-2: Do not implement native `PreToolUse` guards in #637.
- NG-3: Do not change Codex hook templates, hook provisioning, or hook oracle for `PreToolUse` in #637.
- NG-4: Do not store full machine-local `~/.codex/hooks*.json` contents in repo.
- NG-5: Do not delete valid user-owned `~/.codex/hooks.json` merely because the file exists.

## Success Criteria
- SC-1: `nrs` cleanup removes repo-local retired `.codex/hooks*.json` exactly as before.
- SC-2: `nrs` cleanup removes user-level `~/.codex/hooks.compatibility.json` when present.
- SC-3: `nrs` cleanup prunes only known stale managed legacy entries from non-symlinked user-level `~/.codex/hooks.json`, preserving unrelated user hooks and symlinked user hook files.
- SC-4: `verify-ai-compat.sh` fails on stale user-level legacy state and tells the user how to repair it with `nrs` or, for symlinked user-owned hook files, manual stale-entry removal; it does not fail merely because `~/.codex/hooks.json` exists.
- SC-5: Shell tests prove stale user-level cleanup for NixOS force, Darwin force, and Darwin no-change paths.
- SC-6: Existing Codex hook fixture tests still pass without adding `PreToolUse` as a managed template event.

## Key Scenarios
### Scenario 1: Fully Stale User Legacy File
- Actor: developer running `nrs`
- Trigger: `~/.codex/hooks.json` contains only known stale legacy commands owned by old projection.
- Expected outcome: stale handlers are removed; if no handlers remain, the file may be removed or reduced to an empty safe state. Output explains what was cleaned.

### Scenario 2: Mixed User File
- Actor: developer with a valid custom Codex hook plus stale legacy entries.
- Trigger: `nrs`
- Expected outcome: stale legacy entries are pruned and valid custom hook entries remain.

### Scenario 3: Stale State Reappears
- Actor: developer or old tool recreates `~/.codex/hooks.compatibility.json` or stale known entries.
- Trigger: `./scripts/ai/verify-ai-compat.sh`
- Expected outcome: verifier fails with specific user-level stale-state guidance.

### Scenario 4: Native PreToolUse Work
- Actor: developer implementing #587.
- Trigger: native `PreToolUse` guard work is needed.
- Expected outcome: #637 does not implement it; PR/issue notes point to #587.

## Discovery Summary
- Reviewed: issue #637, issue #587, `modules/shared/scripts/lib/rebuild/common.sh`, `modules/darwin/scripts/nrs.sh`, `modules/nixos/scripts/nrs.sh`, `scripts/ai/verify-ai-compat.sh`, `tests/shell-script-tests.sh`, Codex config templates, `pinning-alert.sh`, sync-preservation fixtures, OpenAI Codex hooks docs.
- Current system: repo-local `.codex/hooks.json` and `.codex/hooks.compatibility.json` are removed before rebuild; user-level equivalents are not cleaned or verified.
- Current machine: `~/.codex/hooks.json` and `~/.codex/hooks.compatibility.json` are absent; active `~/.codex/config.toml` has `UserPromptSubmit`, `Stop`, `PostToolUse` only.
- Validation surface: shell wrapper tests, Codex hook fixture tests, verifier, `nrs` activation, and post-`nrs` verifier.
- Design implications: official Codex docs list `~/.codex/hooks.json` as a current hook source, so the implementation must parse and preserve valid user hooks.
- Confidence / gaps: exact stale-entry matcher is limited to known old managed hook script basenames; native `PreToolUse` ownership remains intentionally out of scope for #637.

## Requirements
### Functional Requirements
- FR-1: Keep existing repo-local retired artifact cleanup unchanged.
- FR-2: Add user-level cleanup for `~/.codex/hooks.compatibility.json`.
- FR-3: Add user-level `~/.codex/hooks.json` stale-entry pruning based on exact known managed legacy script commands, not file existence or substring mentions.
- FR-4: Preserve non-stale entries in user-level `hooks.json`.
- FR-5: If `hooks.json` is malformed, symlinked, or cannot be safely parsed, do not destructively rewrite it; verifier should inspect readable symlink targets and fail stale/malformed states with manual repair guidance where `nrs` intentionally preserves ownership.
- FR-6: Add verifier checks for user-level compatibility artifact and stale known legacy entries.
- FR-7: Add shell tests for cleanup and preservation behavior.
- FR-8: Document in PR/issue handoff that actual native `PreToolUse` implementation and ownership are delegated to #587.

### Non-Functional Requirements
- NFR-1: Cleanup must be deterministic and fail closed on unsafe write/delete failures.
- NFR-2: User-owned hooks must not be silently dropped.
- NFR-3: Repeated path strings must be grouped through named variables/helpers where practical.
- NFR-4: Tests must use sandboxed HOME and avoid touching the real user `~/.codex`.

## Assumptions
- A-1: `~/.codex/hooks.compatibility.json` is not an official current Codex hook source in the checked docs and can be treated as retired.
- A-2: Known stale legacy commands can be identified by command path/basename from issue #637 evidence.
- A-3: `jq` is available in the target user environments where existing rebuild scripts already rely on it.
- A-4: #587 remains the owner for native `PreToolUse` guard implementation.

## Dependencies / Constraints
- Official Codex hooks docs: https://developers.openai.com/codex/hooks
- Related issue: #587 for native `PreToolUse`.
- Existing PostToolUse pinning alert and apply_patch parser remain unchanged.
- Main-agent-only commands: `nrs`, commits, GitHub writes.

## Risks / Edge Cases
- Valid user hook entry accidentally matches stale pattern.
- Stale entry command is wrapped in shell syntax not covered by initial matcher.
- Malformed `hooks.json` cannot be safely edited.
- `verify-ai-compat.sh` may fail for unrelated active symlink mismatch when run from a worktree before `nrs`.

## Execution Rules
- 본 PRD가 명시적으로 수정되지 않는 한 phase는 순서대로 완료한다.
- 어떤 phase든 시작 전에 master PRD + active phase file을 읽는다.
- PRD 파일만 active plan으로 사용한다. 경쟁하는 별도 체크리스트를 만들지 않는다.
- 목표를 만족하는 최소 가역적 변경을 선호한다.
- 기존 repo patterns를 보존한다.
- 검증은 risk에 맞는 최소 충분 조합으로 선택한다.
- 각 phase 종료 시 master PRD와 phase 파일을 갱신한다.
- Post-Implementation 1~7 자동 수행 (default): 구현, 구현 커밋, `/run-da for_pr`, `/parallel-audit`, Final Multi-Pass Review, 반영 커밋, `/create-pr`.

## Phase Index

| Phase | Status | Objective | Validation Focus | File |
|---|---|---|---|---|
| Phase 1: Scope Lock | Complete | Resolve issue evidence, PRD routing, DA findings, and scope boundary | PRD/DA consistency | [phase-01-scope-lock.md](./prd-codex-user-legacy-hooks/phase-01-scope-lock.md) |
| Phase 2: Cleanup Implementation | Complete | Implement safe user-level stale cleanup without deleting valid hooks | Shell behavior, parser safety | [phase-02-cleanup-implementation.md](./prd-codex-user-legacy-hooks/phase-02-cleanup-implementation.md) |
| Phase 3: Verifier And Tests | Complete | Add verifier stale guard and regression tests | Sandbox HOME tests, verifier messages | [phase-03-verifier-tests.md](./prd-codex-user-legacy-hooks/phase-03-verifier-tests.md) |
| Phase 4: Validation And Handoff | Complete | Run validation, update PRD closeout, and prepare PR handoff | nrs/verify/DA/audit evidence | [phase-04-validation-handoff.md](./prd-codex-user-legacy-hooks/phase-04-validation-handoff.md) |

## Final Multi-Pass Review After All Phases
Use `plan-with-questions/references/prd/multi-pass-review.md` as the canonical checklist, with review-impl overlay where applicable.

## Open Questions
- None. Confirmed DA findings have been reflected into the PRD scope.

## Change Log
- 2026-05-02: Initial PRD created from issue #637. User selected PRD mode and delegated all native `PreToolUse` implementation to #587.
- 2026-05-02: DA for_plan HIGH findings reflected: `~/.codex/hooks.json` file existence is not stale; cleanup/verifier must target known stale entries only.
- 2026-05-02: Phase 2 cleanup implemented for repo-local retired artifacts, user-level `hooks.compatibility.json`, and known stale user hook entries while preserving user hooks.
- 2026-05-02: Phase 3 verifier/tests completed, including mixed user-hook preservation and malformed user `hooks.json` preservation.
- 2026-05-02: Phase 4 validation started; `nrs` and post-`nrs` `verify-ai-compat.sh` passed on this machine.
- 2026-05-02: DA for_pr Round 1 confirmed mixed-version shim and duplicated jq matcher issues; fixed with shared `codex-legacy-hooks.sh`, old-helper fixture coverage, `nrs`, and post-`nrs` verifier pass.
- 2026-05-02: DA for_pr Round 2 confirmed symlinked user `hooks.json` clobber risk; fixed by leaving symlinks unchanged, making verifier fail for manual inspection, and adding symlink preservation coverage.
- 2026-05-02: DA for_pr Round 3 confirmed verifier over-failed valid symlinked `hooks.json`; fixed verifier to inspect symlink targets and fail only malformed/stale cases.
- 2026-05-02: parallel-audit found stale matcher substring false positives and master PRD symlink repair wording drift; fixed matcher to exact direct hook commands and documented symlink manual-repair carveout.
- 2026-05-02: Phase 4 completed after final `nrs`, post-activation verifier, and multi-pass review; PR handoff is ready.
