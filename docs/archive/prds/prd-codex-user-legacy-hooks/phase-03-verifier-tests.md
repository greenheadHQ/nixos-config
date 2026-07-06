# Phase 3: Verifier And Tests

Parent PRD: [PRD: Codex User Legacy Hooks](../prd-codex-user-legacy-hooks.md)
Status: Complete
Last Updated: 2026-05-02

## Objective
Add verifier coverage and regression tests that catch stale user-level legacy hook state while preserving valid user hooks.

## Context From Master PRD
- Goals covered: G-1, G-2, G-4, G-5
- Success Criteria: SC-4, SC-5, SC-6
- Requirements covered: FR-5, FR-6, FR-7
- Key scenarios touched: Scenario 1, Scenario 2, Scenario 3

## Phase Discovery Gate
코드 편집 전에 재확인한다:
- [x] 관련 코드/파일: `scripts/ai/verify-ai-compat.sh`, `tests/shell-script-tests.sh`
- [x] 관련 테스트/fixture: existing nrs wrapper tests around repo-local retired artifacts
- [x] 관련 docs/spec/외부 참조: master PRD stale-entry contract
- [x] 관련 command 또는 도구: `./tests/shell-script-tests.sh`, `./tests/test-codex-hook-fixtures.sh --no-live`
- [x] Master PRD의 assumption이 여전히 유효함
- [x] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신

## Scope
### In Scope
- Verifier fail for user-level `hooks.compatibility.json`.
- Verifier fail for stale known legacy entries inside user-level `hooks.json`.
- Verifier non-fail for valid user-owned `hooks.json` with no stale entries.
- Shell tests for cleanup and preservation.

### Out of Scope
- Live Codex hook execution.
- Native `PreToolUse` fixture additions.

## Implementation Checklist
- [x] Update `verify-ai-compat.sh` hook artifact section to distinguish repo-local retired artifacts from user-level stale legacy state.
- [x] Do not fail verifier on `~/.codex/hooks.json` existence alone.
- [x] Fail verifier on `~/.codex/hooks.compatibility.json` existence with `nrs` guidance.
- [x] Fail verifier on known stale legacy entries in `~/.codex/hooks.json` with `nrs` guidance.
- [x] Add shell tests for NixOS force user-level cleanup.
- [x] Add shell tests for Darwin force user-level cleanup.
- [x] Add shell tests for Darwin no-change user-level cleanup.
- [x] Add mixed `hooks.json` fixture test that preserves non-stale user entries.
- [x] Add malformed `hooks.json` behavior test if implementation handles it explicitly.
- [x] Keep `tests/test-codex-hook-fixtures.sh --no-live` unchanged unless verifier/hook oracle change requires it.

## Validation Strategy
Use deterministic shell fixtures with sandboxed HOME. The verifier must be tested without touching real `~/.codex`.

## Validation Checklist
- [x] Static check 통과: `bash -n` relevant shell scripts if practical.
- [x] 자동 test 추가/갱신 및 통과: `./tests/shell-script-tests.sh`
- [x] Existing hook fixture test remains green: `./tests/test-codex-hook-fixtures.sh --no-live`
- [x] Manual smoke check: verifier message wording distinguishes repo-local vs user-level state.
- [x] 해당 시 error, empty, malformed, permission, rollback 상태 검증

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
- D-1: Verifier now treats repo-local `.codex/hooks*.json` as retired artifacts, user-level `hooks.compatibility.json` as retired, and user-level `hooks.json` as valid unless known stale commands are present.
- D-2: Shell tests cover mixed user-level hook preservation in NixOS force, Darwin force, and Darwin no-change paths, including old deployed repo-local-only cleanup helper coverage for NixOS force and Darwin no-change.
- D-3: A malformed user-level `hooks.json` is not rewritten by cleanup and is left for verifier/manual repair.
- D-4: `tests/test-codex-hook-fixtures.sh --no-live` remains unchanged because #637 does not add managed native `PreToolUse` fixtures.
- D-5: Shell tests cover symlinked user-level `hooks.json` preservation so cleanup cannot clobber dotfile-managed hook state.
- D-6: Verifier uses the shared jq stale-count filter on symlink targets too: clean symlinked hooks can pass, while symlinked stale entries fail with manual-removal guidance.
- D-7: Stale matching is exact for direct managed hook commands and ignores path mentions such as `.backup` suffixes or shell snippets that merely reference a stale filename.

## Phase Change Log
- 2026-05-02: Phase file created.
- 2026-05-02: Phase completed with verifier stale guards and sandboxed cleanup regression tests.
- 2026-05-02: DA for_pr Round 1 added mixed-version old-helper regression coverage.
- 2026-05-02: DA for_pr Round 2 added symlink preservation regression coverage.
- 2026-05-02: DA for_pr Round 3 added clean/stale symlink target stale-count coverage.
- 2026-05-02: parallel-audit added exact matcher coverage for stale path mentions and exact `$HOME` paths.
