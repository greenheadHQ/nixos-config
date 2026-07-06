# Plan 010: verify-ai-compat의 lint 엔진을 분리하고 host-state 검증부에 회귀 테스트를 씌운다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat a6bbf637..HEAD -- scripts/ai/verify-ai-compat.sh scripts/ai/lib/ tests/`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (커밋 게이트 스크립트의 동작 불변 리팩토링)
- **Depends on**: none
- **Category**: tech-debt
- **Planned at**: commit `fb2a8aa6`, 2026-07-02 (reconcile 재검증: `a6bbf637`,
  2026-07-06 — 커밋 `09fffbee`의 EXPECTED_EXPOSED 1줄 삽입으로 라인 번호 +1
  shift, finding 자체는 불변. Current state를 현행화함)
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/947

## Why this matters

`scripts/ai/verify-ai-compat.sh`(1621줄)는 AI 도구 호환성의 안전 게이트다 —
pre-commit `ai-skills-consistency` 훅이 `scripts/ai/warn-skill-consistency.sh:109`
경유로 호출하고, 사용자도 수동 재검증에 쓴다. 문제는 두 가지다. ① 파일의 약
절반이 자체 완결적인 skill-neutral-lint 엔진(자체 fixture self-test 포함)인데
분리되어 있지 않아, 게이트 전체를 통독해야 lint 규칙을 이해/수정할 수 있다.
② host-state 검증부(심링크/실행권한/oracle-사용 검사)는 실제 리포 상태에
대해서만 실행될 뿐 로직 회귀를 잡는 fixture 테스트가 없다 — 검증 조건이 항상
pass가 되도록 망가져도 통합 테스트(`tests/run-all-tests.sh`)가 통과한다.
게이트가 조용히 약화되는 것을 감지할 수단을 만든다.

## Current state

- `scripts/ai/verify-ai-compat.sh` — 함수 배치 (grep 실측):

```
 230: _skill_neutral_lint()               ← lint 엔진 시작
 584: run_skill_neutral_fixture_tests()   ← lint 자체 self-test (--run-fixture-tests)
1047: verify_codex_helper()               ← host-state 검증부 시작
1065: verify_codex_helper "fleiss-kappa.py"
1068: verify_claude_helper()
1086: verify_claude_helper "fleiss-kappa.py"
1286: _check_hook_executable()
1314: _check_hook_executable ".codex/hooks/record-prompt-submit.sh"   (외 다수 호출)
1322: _check_executable_symlink_suffix()
1438: verify_used_by_oracle()
1582: verify_used_by_oracle "$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh" "pinning-patterns.sh"
```

- 호출처: `scripts/ai/warn-skill-consistency.sh:109`가
  `scripts/ai/verify-ai-compat.sh | ...` 형태로 실행 (pre-commit 훅 경로).
  `tests/run-all-tests.sh`·lefthook.yml·CI에는 직접 참조 없음 (grep 실측).
- `tests/`의 "verify-ai-compat" 참조는 주석(oracle/fixture 공유 명시:
  `tests/lib/codex-hook-expectations.sh:6`, `tests/fixtures/codex-hooks/README.md:120`,
  `tests/test-codex-hook-fixtures.sh:39`·`:61`·`:71`)과 기대-사유 문자열 리터럴
  (`tests/test-codex-hook-fixtures.sh:668`·`:690`)뿐 — 실행 호출은 없음.
- 기존 공유 lib 위치: `scripts/ai/lib/` (예: `tomlkit-bootstrap.sh`) — 분리
  파일의 자연스러운 배치처.
- README.md의 검증 절이 `verify-ai-compat.sh --run-fixture-tests`(lint fixture만
  검증)와 일반 실행을 문서화한다 — **CLI 인터페이스는 변경 금지**.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 일반 실행 (전후 비교 기준) | `bash scripts/ai/verify-ai-compat.sh` | exit 0 + 출력 저장 |
| lint self-test | `bash scripts/ai/verify-ai-compat.sh --run-fixture-tests` | exit 0 |
| 셸 린트 | `shellcheck -S warning scripts/ai/verify-ai-compat.sh scripts/ai/lib/<신규>.sh` | exit 0 |
| Suite 실행 | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 전부 통과 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope**:
- `scripts/ai/verify-ai-compat.sh` (lint 엔진 추출 후 source로 축소)
- `scripts/ai/lib/skill-neutral-lint.sh` (신규 — 추출된 lint 엔진 + self-test)
- `tests/suites/verify-ai-compat.sh` (신규 — host-state 검증부 fixture 테스트)

**Out of scope** (do NOT touch):
- `scripts/ai/warn-skill-consistency.sh` — 호출 인터페이스가 안 바뀌므로 수정
  불필요. 바뀌어야 한다면 STOP.
- lint 규칙·검증 로직의 **의미 변경 일절** — 순수 조직화다.
- `scripts/ai/check-skill-noise.sh` 등 다른 AI 스크립트.
- **주의**: `scripts/ai/verify-ai-compat.sh`와 `scripts/ai/lib/*`는 pre-commit
  `ai-skills-consistency`의 **커밋 차단 대상 경로**다 (README 검증 절). 구조
  일관성 검사를 우회하지 말고 통과시켜야 한다.

## Git workflow

- Branch: `advisor/010-verify-ai-compat-split`
- Commit 예: `refactor(ai): verify-ai-compat lint 엔진 분리` →
  `test(ai): host-state 검증부 fixture 테스트` (2커밋 권장)
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 전후 비교 기준 확보

`bash scripts/ai/verify-ai-compat.sh > /tmp/before.out 2>&1; echo "exit=$?"` 와
`--run-fixture-tests` 실행 결과를 저장한다 (동작 불변 검증의 oracle).

**Verify**: 두 실행 모두 exit 0. **워크트리 실행 예외** (2026-07-06 실측):
git worktree에서 실행하면 host-state 검사가 `$HOME` 심링크의 대상(main repo
경로)과 REPO_ROOT(워크트리 경로)를 비교해 "`[FAIL] 노출 대상 불일치`" 및
"`대상 불일치`" 계열 오류 11건이 나온다 — 이는 워크트리 환경의 알려진
특성이므로 STOP이 아니다. 이 경우 그 출력을 그대로 before.out 기준으로 삼고,
이후 단계의 oracle은 "before/after 출력 diff 동일성"이다. **불일치 계열 외의
오류가 하나라도 섞여 있으면 STOP.** `--run-fixture-tests`는 환경 무관하게
exit 0이어야 한다 (아니면 STOP).

### Step 2: lint 엔진을 scripts/ai/lib/skill-neutral-lint.sh로 추출

lint 엔진 구간(대략 `_skill_neutral_lint`부터 `run_skill_neutral_fixture_tests`
및 그들이 참조하는 헬퍼/상수까지 — 실제 경계는 함수 간 참조를 따라 확정)을
새 파일로 옮기고, `verify-ai-compat.sh`는 그 파일을 `source`한다 (기존
`scripts/ai/lib/tomlkit-bootstrap.sh` source 패턴을 따름). 옮긴 함수의 이름·
시그니처·출력 형식은 그대로.

**Verify**: `bash scripts/ai/verify-ai-compat.sh > /tmp/after.out 2>&1; echo "exit=$?"`
→ exit 0, `diff /tmp/before.out /tmp/after.out` → 차이 없음 (또는 무해한
경로 표기 차이만 — 있으면 그 내용을 보고에 기록). `--run-fixture-tests`도 동일.

### Step 3: host-state 검증부 fixture 테스트 작성

`tests/suites/verify-ai-compat.sh`(신규, 기존 suite 구조 준수)에서
`_check_hook_executable`/`_check_executable_symlink_suffix`/`verify_used_by_oracle`
를 조작된 임시 디렉토리로 구동해 pass/fail 양방향을 assert한다:

1. 정상 구조(실행권한 있는 훅, 올바른 심링크) → pass.
2. 실행권한 제거된 훅 → fail 감지.
3. 잘못된/깨진 심링크 → fail 감지.
4. oracle 미사용 상태(참조 제거된 사본) → fail 감지.

함수들을 source로 불러올 수 있는지 먼저 확인한다. **supervisor 승인
(2026-07-06)**: `verify-ai-compat.sh`는 source-unsafe로 실측 확인됐다
(source 시 즉시 검증 실행). 다음 조건의 최소 source-safe화를 승인한다 —
검증 구동부(함수 정의가 아닌 실행 문장들)를
`if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then … fi` 가드로 감싼다. 가드 안
내용은 한 글자도 바꾸지 않는다(들여쓰기 조정만 허용). 이 저장소 선례:
`modules/shared/scripts/wt.sh`, `modules/shared/scripts/rebuild-common.sh`.
가드 추가 후 일반 실행 출력이 Step 1의 before.out과 동일함을 diff로 증명해야
한다. 단, 실행 문장이 파일 전반에 흩어져 있어 소수(1~3개)의 연속 블록
가드로 처리되지 않는 구조라면 — 재배열하지 말고 STOP 후 구조를 보고하라.

**Verify**: suite 실행에서 신규 테스트 통과.

### Step 4: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP. 커밋이
`ai-skills-consistency` 포함 pre-commit 통과.

## Test plan

Step 3이 test plan이다. 케이스 목록은 위 4개 + 발견되는 경계(예: 심링크
suffix 규칙의 정탐 보존).

## Done criteria

- [ ] `test -f scripts/ai/lib/skill-neutral-lint.sh` → exit 0
- [ ] `grep -n "source.*skill-neutral-lint" scripts/ai/verify-ai-compat.sh` → 1건
- [ ] `bash scripts/ai/verify-ai-compat.sh` → 출력이 Step 1의 before.out과
  동일 (main repo에서는 exit 0과 동치; 워크트리에서는 동일한 "대상 불일치"
  집합까지 허용 — supervisor가 머지 후 main에서 exit 0을 최종 확인)
- [ ] `bash scripts/ai/verify-ai-compat.sh --run-fixture-tests` → exit 0
- [ ] `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` → exit 0 (신규 suite 포함)
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- Step 1의 기준 실행이 exit 0이 아니고, 그 실패가 Step 1에 명시된 워크트리
  "대상 불일치" 계열만으로 설명되지 않는다.
- lint 엔진과 host-state 검증부의 경계가 얽혀 있어(상호 함수 호출) 분리가
  의미 변경 없이는 불가능하다 — 얽힌 지점을 보고.
- Step 3의 source-safe화가 승인된 최소 형태(연속 블록 1~3개의 BASH_SOURCE
  가드, 내용 무변경)로 불가능하다 — 재배열하지 말고 구조를 보고.
- pre-commit `ai-skills-consistency`가 차단한다 — 우회 금지, 원인 보고.

## Maintenance notes

- 분리 후 lint 규칙 수정은 `scripts/ai/lib/skill-neutral-lint.sh`에서,
  게이트 배선은 `verify-ai-compat.sh`에서 — 리뷰어는 PR이 이 경계를 지키는지
  확인.
- host-state 테스트는 fixture 디렉토리 기준이므로, 실제 리포의 훅 배치가
  바뀌어도(훅 추가/이동) 테스트는 깨지지 않는다 — 깨진다면 fixture가 리포
  상태에 의존하고 있다는 신호다.
