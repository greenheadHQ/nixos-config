# Plan 012: claude 훅들의 stdin JSON 파싱을 hook-runtime.sh 공유 헬퍼로 수렴한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/shared/programs/claude/files/hooks/ modules/shared/programs/claude/files/lib/hook-runtime.sh tests/suites/hook-runtime.sh`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: M
- **Risk**: MED (훅은 PreToolUse 게이트 — fail-closed 동작을 깨면 안 됨)
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/949

## Why this matters

공유 훅 런타임(`hook-runtime.sh`)이 stdin JSON 파싱 헬퍼를 제공하는데, claude
훅 10개 중 2개(pinning-guard, pinning-alert)만 쓴다. 나머지 8개는 각자
`INPUT=$(cat)` + `jq -r '.tool_name // empty'` 류를 재구현하고 있어, 훅 입력
스키마가 바뀌거나 파싱 안전화(빈 입력/malformed JSON 처리)를 개선할 때 훅마다
개별 수정해야 한다. 이미 만들어 둔 SSOT가 방치된 상태 — 점진 마이그레이션으로
수렴시키고, 훅별 fixture 테스트로 fail-closed 동작을 박제한다.

## Current state

- 공유 헬퍼 — `modules/shared/programs/claude/files/lib/hook-runtime.sh`
  (grep 실측):

```
 44: hook_load_lib()
 79: hook_init_scan_dir()
116: hook_parse_tool_name()
127: hook_parse_session_id()
```

- 채택 현황 (grep `hook-runtime.sh` 실측): claude 훅 중 `pinning-guard.sh`,
  `pinning-alert.sh` 2개만 source. (codex 쪽 훅 5개는 이미 사용 중 — 대상 아님.)
- 미채택 claude 훅 8개 (`modules/shared/programs/claude/files/hooks/`):
  `fragile-hardcoding-guard.sh`, `log-skill.sh`, `nrs-session-cleanup.sh`,
  `plans-gc.sh`, `record-last-session.sh`, `session-init-icons.sh`,
  `system-bash-guard.sh`, `worktree-path-guard.sh`
- 자체 파싱 예시 — `fragile-hardcoding-guard.sh:25-30`:

```bash
INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
...
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
```

- 기존 테스트: `tests/suites/hook-runtime.sh` (hook-runtime 자체),
  `tests/suites/fragile-hardcoding-guard.sh` (훅에 JSON stdin을 흘려 stdout
  permissionDecision을 assert하는 패턴 — **훅 fixture 테스트의 exemplar**).
- 사용 패턴 exemplar: `pinning-guard.sh`가 hook-runtime을 어떻게 source하고
  헬퍼를 호출하는지 — 마이그레이션 전 반드시 읽고 동일 패턴 적용.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 채택 현황 | `grep -rln "hook-runtime.sh" modules/shared/programs/claude/files/hooks/` | 전환 진행에 따라 증가 |
| 셸 린트 | `shellcheck -S warning modules/shared/programs/claude/files/hooks/<훅>.sh` | exit 0 |
| Suite 실행 | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 전부 통과 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

**주의**: 훅 경로는 pre-commit `ai-skills-consistency`의 커밋 차단 대상
(`modules/shared/programs/claude/*`)이다 — 구조 일관성 검사를 통과시킬 것.

## Scope

**In scope**:
- 미채택 claude 훅 8개 중 **JSON 파싱을 실제로 하는 훅** (Step 1에서 실측
  선별 — 파싱이 없는 훅은 전환 대상이 아니다)
- `modules/shared/programs/claude/files/lib/hook-runtime.sh` (부족한 헬퍼 추가
  시에만 — 예: `tool_input.file_path` 파서)
- `tests/suites/` (전환 훅별 fixture 테스트 — 기존에 없던 훅만)

**Out of scope** (do NOT touch):
- 각 훅의 **판정 로직** (deny 조건, 스캔 패턴) — 파싱 계층만 교체.
- codex 쪽 훅 (`modules/shared/programs/codex/files/hooks/`) — 이미 채택.
- `pinning-guard.sh`/`pinning-alert.sh` — 이미 채택.
- 훅 등록 배선 (settings/hooks 설정) — 파일 내용만 바뀐다.

## Git workflow

- Branch: `advisor/012-hook-runtime-adoption`
- Commit: 훅 1~2개 단위로 나눠 커밋 권장 —
  `refactor(hooks): <훅명> hook-runtime 파서 채택`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 대상 선별 및 전환 순서 확정

8개 훅 각각을 열어 ① stdin JSON을 파싱하는지 ② 어떤 필드를 읽는지
(`tool_name`/`session_id`/`tool_input.*`) 표로 정리한다. 파싱이 없는 훅은
제외. `hook_parse_tool_name`/`hook_parse_session_id`로 덮이지 않는 필드
(예: `tool_input.file_path`)가 2개 훅 이상에서 반복되면 hook-runtime에 헬퍼를
**추가**한다 (1개 훅만 쓰는 필드는 헬퍼화하지 않는다 — YAGNI).

**Verify**: 선별 표를 최종 보고에 포함할 형태로 작성 완료.

### Step 2: 훅을 하나씩 전환 (fail-closed 보존)

각 대상 훅에 대해:

1. `pinning-guard.sh`의 source 패턴 그대로 hook-runtime을 로드.
2. 자체 파싱 라인을 헬퍼 호출로 교체. **교체 전후 실패 모드 비교 필수**:
   기존 훅이 jq 부재/파싱 실패 시 어떻게 동작했는지(exit 0 no-op인지 deny인지)
   확인하고, 헬퍼 경유 후에도 **동일한 실패 모드**가 유지됨을 확인한다.
3. 해당 훅의 fixture 테스트가 없으면 `tests/suites/`에 추가:
   정상 입력 → 기존 판정 유지, 빈 stdin → 기존 실패 모드 유지, malformed
   JSON → 기존 실패 모드 유지. 패턴 모델:
   `tests/suites/fragile-hardcoding-guard.sh`.

각 훅 전환 후 **Verify**: 해당 훅 shellcheck + suite 실행 통과.

### Step 3: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP,
`grep -rln "hook-runtime.sh" modules/shared/programs/claude/files/hooks/` →
Step 1 선별 대상 전부 포함.

## Test plan

Step 2-3이 test plan. 핵심 커버리지: 훅별 (정상/빈 입력/malformed) × 실패
모드 보존.

## Done criteria

- [ ] Step 1 선별 표가 최종 보고에 있음
- [ ] 선별된 모든 훅이 hook-runtime을 source (`grep -rln` 확인)
- [ ] 각 전환 훅에 fixture 테스트 존재 (기존 포함)
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] 커밋이 `ai-skills-consistency` 포함 pre-commit 통과
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- 어떤 훅의 자체 파싱이 헬퍼와 **의미가 다르다** (예: `// empty` 대신 다른
  기본값, 대상 필드가 헬퍼와 미묘하게 다른 경로) — 통일하지 말고 차이를 보고.
- 전환 후 fixture 테스트에서 실패 모드가 달라진다 (no-op이던 것이 deny가
  되거나 그 반대) — 즉시 해당 훅 전환을 되돌리고 보고.
- hook-runtime에 추가해야 할 헬퍼가 3개를 넘는다 — 설계 재검토가 필요하다는
  신호이므로 추가 전에 보고.

## Maintenance notes

- 이후 새 claude/codex 훅은 hook-runtime 파서 사용이 관례다 — 리뷰어는 새
  훅의 `INPUT=$(cat)` + 인라인 jq를 반려 기준으로 삼을 것.
- 훅 JSON **출력** 조립(permissionDecision 등)의 헬퍼화는 이번 범위에 넣지
  않았다 — 출력 형식은 이벤트 종류별로 달라 파싱보다 수렴 이득이 작다.
  파싱 수렴이 안착한 뒤 별도 판단.
