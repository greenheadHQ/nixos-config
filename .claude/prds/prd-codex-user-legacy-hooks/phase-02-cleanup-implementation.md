# Phase 2: Cleanup Implementation

Parent PRD: [PRD: Codex User Legacy Hooks](../prd-codex-user-legacy-hooks.md)
Status: Complete
Last Updated: 2026-05-02

## Objective
Implement safe cleanup for retired user-level Codex legacy artifacts without deleting valid user-owned hooks.

## Context From Master PRD
- Goals covered: G-1, G-2, G-3
- Success Criteria: SC-1, SC-2, SC-3
- Requirements covered: FR-1, FR-2, FR-3, FR-4, FR-5
- Key scenarios touched: Scenario 1, Scenario 2, Scenario 4

## Phase Discovery Gate
코드 편집 전에 재확인한다:
- [x] 관련 코드/파일: `modules/shared/scripts/lib/rebuild/common.sh`, `modules/darwin/scripts/nrs.sh`, `modules/nixos/scripts/nrs.sh`
- [x] 관련 테스트/fixture: `tests/shell-script-tests.sh`
- [x] 관련 docs/spec/외부 참조: OpenAI Codex hooks docs, issue #637 Notes, issue #587
- [x] 관련 command 또는 도구: `rg -n "hooks\\.json|hooks\\.compatibility|_clear_retired_codex_hook_artifacts" modules scripts tests`
- [x] Master PRD의 assumption이 여전히 유효함
- [x] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신

## Scope
### In Scope
- Preserve existing repo-local cleanup.
- Add user-level cleanup for `~/.codex/hooks.compatibility.json`.
- Add safe pruning for known stale managed legacy entries in `~/.codex/hooks.json`.
- Keep Darwin/NixOS compatibility shims aligned.

### Out of Scope
- Native `PreToolUse` hook implementation.
- Template ownership changes for `PreToolUse`.
- Full deletion of valid `~/.codex/hooks.json`.

## Implementation Checklist
- [x] Define named stale artifact/path variables or helper names instead of scattering raw path strings.
- [x] In common cleanup, keep repo-local retired artifact deletion unchanged.
- [x] In common cleanup, remove `$HOME/.codex/hooks.compatibility.json` when present.
- [x] In common cleanup, parse `$HOME/.codex/hooks.json` only when it exists and is valid JSON.
- [x] Identify stale managed legacy entries by known command paths/basenames from issue #637, not by file existence.
- [x] Preserve unrelated user hook entries in `hooks.json`.
- [x] If all hook handlers are stale and removed, delete the empty `hooks.json` or leave a valid empty safe state; document the chosen behavior in output/tests.
- [x] If `hooks.json` is malformed or cannot be safely rewritten, do not destructively modify it; surface a clear warning/error for verifier/manual repair.
- [x] Mirror the same behavior in Darwin and NixOS compatibility shim fallback functions.
- [x] Ensure deletion/rewrite failures fail closed consistently with existing `set -e` nrs behavior.

## Validation Strategy
Phase 2 validation is local shell-level behavior using sandboxed HOME fixtures, plus static review of duplicated shim logic. Full test execution is Phase 3.

## Validation Checklist
- [x] Static check: cleanup paths appear only through named variables/helpers where practical.
- [x] Manual/sandbox smoke: repo-local artifact cleanup still deletes repo files.
- [x] Manual/sandbox smoke: user-level `hooks.compatibility.json` is removed.
- [x] Manual/sandbox smoke: mixed `hooks.json` preserves non-stale hook entries.
- [x] Manual/sandbox smoke: malformed `hooks.json` is not destructively rewritten.
- [x] 해당 시 error, empty, permission, rollback 상태 검증

## Exit Criteria
- [x] Phase objective 달성
- [x] 위에 열거한 요구사항이 구현되었거나 명시적으로 deferred
- [x] Validation checklist 완료 또는 gap이 근거와 함께 기록됨
- [x] 다음 phase를 시작하지 못하게 막는 blocker 없음

## Phase-End Multi-Pass Review
- [x] 1. Intent/coverage review — 본 phase가 objective와 매핑된 요구사항을 달성했다.
- [x] 2. Correctness review — happy path, edge case, error, empty state, state transition, 권한이 처리되었다.
- [x] 3. Simplicity review — 솔루션이 필요 이상으로 복잡하지 않다.
- [x] 4. Code quality review — 이름/경계/추상화/로컬 일관성이 깔끔하다.
- [x] 5. Duplication/cleanup review — 중복 로직, dead code, temporary code, 잡음 log, 주석 처리 잔재, 사용되지 않는 파일/의존성이 제거되었다.
- [x] 6. Security/privacy review — 권한, secret, 민감 데이터, injection risk, 클라이언트 노출, 감사 필요성이 안전하다.
- [x] 7. Performance/load review — bottleneck, 비싼 query, N+1, 불필요한 재렌더, 불필요한 네트워크 호출이 다루어졌다.
- [x] 8. Validation review — 선택한 check가 phase risk에 적절하다. 누락 check는 근거와 함께 기록.
- [x] 9. Future-phase review — 뒤 phase 파일/체크리스트가 여전히 옳다. 구현이 계획을 바꿨다면 수정.
- [x] 10. PRD sync review — master PRD status, active phase, assumption, risk, validation surface, change log가 갱신되었다.

## Discoveries / Decisions
- D-1: `~/.codex/hooks.json` remains a valid user-owned Codex hook source; cleanup prunes only known stale commands under `/.codex/hooks/`.
- D-2: When all handlers under an event are pruned, the implementation leaves a valid rewritten JSON object with empty event groups removed rather than deleting the whole file.
- D-3: Malformed user-level `hooks.json` is left unchanged and reported for manual repair; verifier fails that state later.
- D-4: Cleanup logic is centralized in `modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh`; Darwin/NixOS entrypoint shims source that helper and override old repo-local-only cleanup functions so mixed-version deployments still self-heal.
- D-5: Symlinked user-level `hooks.json` is treated as ambiguous user-owned state and left unchanged to avoid replacing dotfile-managed links with regular files.

## Phase Change Log
- 2026-05-02: Phase file created.
- 2026-05-02: Phase completed with safe user-level legacy cleanup in common helper and Darwin/NixOS shims.
- 2026-05-02: DA for_pr Round 1 replaced duplicated shim jq with shared helper-backed cleanup.
- 2026-05-02: DA for_pr Round 2 added symlink preservation behavior.
