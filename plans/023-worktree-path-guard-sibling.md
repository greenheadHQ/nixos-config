# Plan 023: worktree-path-guard의 sibling worktree 오탐 차단을 제거한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 79530cec..HEAD -- modules/shared/programs/claude/files/hooks/worktree-path-guard.sh tests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW-MED (가드 완화 방향 — main repo 보호가 약해지지 않는지가 리뷰 포인트)
- **Depends on**: none
- **Category**: bug (guard false positive)
- **Planned at**: commit `79530cec`, 2026-07-03
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/935

## Why this matters

`worktree-path-guard.sh`는 worktree 세션이 실수로 main repo 파일을
Edit/Write하는 것을 차단하는 PreToolUse 훅이다. 그런데 이 저장소의 worktree는
관례상 main repo **하위**(`<main>/.claude/worktrees/<name>`)에 생성되므로,
worktree A에서 sibling worktree B의 파일을 편집하려 하면 "main repo 하위 경로
+ 현재 worktree 밖" 판정에 걸려 **오탐 차단**된다. 멀티-worktree 세션(리뷰,
비교 작업)에서 정당한 편집이 막히고, 사용자가 훅을 우회하게 만들어 가드
신뢰를 갉아먹는다.

## Current state

- `modules/shared/programs/claude/files/hooks/worktree-path-guard.sh` (62행) —
  대상 훅. 전체 로직이 이 파일 하나에 있다.
- worktree 위치 관례: `wt`가 `<main>/.claude/worktrees/<dir>`에 생성 (repo
  루트 `CLAUDE.md`의 Worktree 절 참조).
- 이 훅의 전용 테스트 suite는 없다 (`grep -rln "worktree-path-guard" tests/`
  → `tests/suites/codex-user-hooks.sh`뿐이며, 이는 훅 등록/배선 검증이지 판정
  로직 테스트가 아니다).

핵심 판정 코드 (`modules/shared/programs/claude/files/hooks/worktree-path-guard.sh:22-23, 45-60`):

```bash
WORKTREE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
MAIN_REPO=$(cd "$COMMON_DIR/.." 2>/dev/null && pwd) || exit 0
# …
# main repo 경로이면서 현재 worktree 하위가 아닌 경우 차단
_is_main_repo_path() {
  local p="$1"
  [[ "$p" != "$MAIN_REPO"/* ]] && return 1
  [[ "$p" == "$WORKTREE_ROOT"/* ]] && return 1
  return 0
}

if _is_main_repo_path "$FILE_PATH" || _is_main_repo_path "$RESOLVED"; then
```

버그 시나리오: 세션 cwd가 `<main>/.claude/worktrees/A`일 때
`<main>/.claude/worktrees/B/foo.nix`는 `$MAIN_REPO/*` 하위이면서
`$WORKTREE_ROOT/*` 하위가 아니므로 차단된다 — 하지만 이 파일은 main repo
파일이 아니라 sibling worktree 파일이다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 훅 단독 실행 | `printf '%s' '<hook JSON>' \| bash modules/shared/programs/claude/files/hooks/worktree-path-guard.sh` | 케이스별 deny JSON 또는 무출력 exit 0 |
| shell 테스트 | `bash tests/run-shell-script-tests.sh` | exit 0 |
| shellcheck | `shellcheck modules/shared/programs/claude/files/hooks/worktree-path-guard.sh` | 경고 0 (기존 수준 유지) |
| 통합 게이트 | `bash tests/run-all-tests.sh` | FAILED 0 |

## Scope

**In scope**:

- `modules/shared/programs/claude/files/hooks/worktree-path-guard.sh`
- 판정 로직 테스트 신설: `tests/suites/` 아래 새 suite 파일 1개 (기존
  `tests/suites/fragile-hardcoding-guard.sh`를 구조 패턴으로 삼는다)

**Out of scope**:

- `_is_main_repo_plan_path` 예외(29–43행) — 별개 정책, 유지.
- `wt` 스크립트 및 worktree 생성 위치 관례 자체.
- Codex 쪽 훅 구성 — 이 훅은 Claude 전용이다.

## Git workflow

- Branch: `fix/935-worktree-guard-sibling`
- Conventional commits (예: `fix(hooks): worktree-path-guard sibling worktree 오탐 제거 (#935)`)
- push/PR 생성은 운영자 지시 없이는 하지 않는다.

## Steps

### Step 1: 판정에 worktree 컨테이너 예외 추가

`_is_main_repo_path`에 조건 하나를 추가한다: 경로가
`"$MAIN_REPO/.claude/worktrees/"*` 하위이면 main repo 경로로 취급하지 않는다
(return 1). 이 경로 아래는 정의상 worktree들의 영역이므로 main repo 보호
대상이 아니다.

`.claude/worktrees` 리터럴을 함수 안에 중복 기입하지 말고 파일 상단에
`WORKTREES_CONTAINER="$MAIN_REPO/.claude/worktrees"` 변수로 둔다.

의도적으로 **git 호출 추가 없이 프리픽스 검사만으로** 해결한다. 대상 파일
디렉토리에서 `git rev-parse`를 다시 실행하는 설계는 신규 파일(아직 없는
경로)·성능·심링크 케이스가 더 복잡해 채택하지 않는다. `.claude/worktrees`
밖에 수동 생성한 worktree는 이 예외의 보호를 받지 못하지만, 그 경로는 repo
관례(`wt`) 밖이므로 허용 오차로 명시한다 (파일 주석 1줄).

**Verify**: 아래 3개 케이스를 `printf '%s' '<JSON>' | bash …/worktree-path-guard.sh`로 실행 (worktree 안 cwd에서):
1. sibling worktree 파일 → 무출력, exit 0
2. main repo 파일 (예: `<main>/flake.nix`) → deny JSON
3. 현재 worktree 파일 → 무출력, exit 0

### Step 2: 판정 로직 테스트 suite 신설

`tests/suites/worktree-path-guard.sh`를 만든다. 임시 디렉토리에 bare-minimum
git repo + `git worktree add`로 worktree 2개를 만들고, 훅에 JSON을 stdin으로
넣어 다음을 검증한다:

1. main repo 세션(cwd=main)에서는 모든 편집 통과 (git-dir == common-dir 조기 종료)
2. worktree A에서 main repo 파일 → deny
3. worktree A에서 worktree A 파일 → allow
4. worktree A에서 sibling worktree B 파일 → allow (이번 수정의 회귀 테스트)
5. worktree A에서 `<main>/.claude/plans/x.md` → allow (기존 예외 회귀)

suite 등록 방식은 `tests/run-shell-script-tests.sh`가 `tests/suites/`를
어떻게 로드하는지 기존 suite 하나를 열어 확인 후 동일하게 따른다.

**Verify**: `bash tests/run-shell-script-tests.sh` → exit 0, 신규 suite 5케이스 pass

### Step 3: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → FAILED 0

## Test plan

- Step 2의 5케이스가 전부다. 케이스 4가 이 plan의 존재 이유이며, 케이스 2가
  "가드가 약해지지 않았다"의 증거다.
- 테스트는 실제 `$HOME`이나 이 저장소의 worktree를 건드리지 않고 mktemp
  샌드박스에서만 돈다.

## Done criteria

- [ ] Step 1 verify 3케이스 통과
- [ ] `tests/suites/worktree-path-guard.sh` 신설, 5케이스 pass
- [ ] `bash tests/run-all-tests.sh` FAILED 0
- [ ] in-scope 밖 파일 수정 없음 (`git status`)
- [ ] `plans/README.md` status row 갱신

## STOP conditions

- "Current state" 발췌와 실제 코드 불일치 (drift).
- `tests/run-shell-script-tests.sh`의 suite 로딩 방식이 신규 suite를 받지
  않는 구조인 경우 (등록 지점을 찾을 수 없음).
- 케이스 2(main repo 파일 deny)가 수정 후 실패하는 경우 — 가드 약화이므로
  즉시 STOP.

## Maintenance notes

- worktree 생성 위치 관례(`.claude/worktrees`)가 바뀌면
  `WORKTREES_CONTAINER`도 함께 바뀌어야 한다 — `wt` 관련 변경 리뷰 시 확인.
- 이 훅과 같은 판정을 쓰는 다른 가드가 생기면 프리픽스 판정 로직의 공용화
  (hook-runtime.sh)를 검토할 것 — 지금은 단일 사용처라 inline 유지.
