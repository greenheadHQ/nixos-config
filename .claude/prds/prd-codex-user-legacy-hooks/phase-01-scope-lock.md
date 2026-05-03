# Phase 1: Scope Lock

Parent PRD: [PRD: Codex User Legacy Hooks](../prd-codex-user-legacy-hooks.md)
Status: Complete
Last Updated: 2026-05-02

## Objective
Resolve issue #637 into a bounded PRD scope before code edits. This phase locks the boundary between stale legacy user-level cleanup and native `PreToolUse` implementation owned by #587.

## Context From Master PRD
- Goals covered: G-1, G-2, G-3
- Success Criteria: SC-1 through SC-6 shaped
- Requirements covered: FR-1 through FR-8
- Key scenarios touched: all scenarios

## Phase Discovery Gate
- [x] 관련 코드/파일: `modules/shared/scripts/lib/rebuild/common.sh`, `modules/darwin/scripts/nrs.sh`, `modules/nixos/scripts/nrs.sh`, `scripts/ai/verify-ai-compat.sh`
- [x] 관련 테스트/fixture: `tests/shell-script-tests.sh`, `tests/test-codex-hook-fixtures.sh`, `tests/fixtures/codex-hooks/sync-preservation/scenario-C-user-different-event.toml`
- [x] 관련 docs/spec/외부 참조: issue #637, issue #587, OpenAI Codex hooks docs
- [x] 관련 command 또는 도구: `gh issue view 637`, `gh issue view 587`, `./scripts/ai/verify-ai-compat.sh`, `./tests/shell-script-tests.sh`
- [x] Master PRD의 assumption이 여전히 유효함
- [x] 발견 사항이 이 phase 또는 후속 phase를 바꾸면, 구현 전에 PRD 파일을 먼저 갱신

## Scope
### In Scope
- PRD mode routing and split-file selection.
- User decision capture: all native `PreToolUse` implementation moves to #587.
- DA for_plan execution and confirmed finding reflection.

### Out of Scope
- Code implementation.
- Native `PreToolUse` scripts/templates/oracle.

## Implementation Checklist
- [x] Resolve issue #637 and related #587.
- [x] Verify current repo cleanup/verifier scope.
- [x] Verify current machine user-level hook state without reading/storing private hook contents.
- [x] Check official Codex hook docs for current `hooks.json` semantics.
- [x] Run Step 3.5 external consultation for scope/ownership tradeoffs.
- [x] Ask user scope decisions through question tool.
- [x] Run DA for_plan and Arbiter.
- [x] Reflect confirmed DA findings into PRD scope.

## Validation Strategy
This phase is planning-only. Validation is evidence review plus mandatory DA for_plan.

## Validation Checklist
- [x] Static check: relevant files read with `sed`/`rg`.
- [x] External docs checked: OpenAI Codex hooks docs.
- [x] Local command: `./tests/shell-script-tests.sh` passed existing shell wrapper tests.
- [x] Local command: `./scripts/ai/verify-ai-compat.sh` executed; failures recorded as existing worktree/global symlink mismatch, hook section passed.
- [x] DA for_plan completed and findings applied.

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
- D-1: `~/.codex/hooks.json` is an official current hook source and must not be treated as stale by existence.
- D-2: Native `PreToolUse` implementation and ownership are delegated to #587.

## Phase Change Log
- 2026-05-02: Phase completed during PRD initialization.
