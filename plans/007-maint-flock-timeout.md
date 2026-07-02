# Plan 007: codex-remote-control-maint의 blocking flock에 타임아웃을 부여한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh tests/suites/codex-remote-control.sh`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `fb2a8aa6`, 2026-07-02

## Why this matters

`codex-remote-control-maint.sh`의 `with_lock`이 옵션 없는 `flock 9`(무한
blocking)를 쓴다. 이 스크립트는 systemd 타이머로 반복 실행되고 내부에서 codex
CLI를 여러 번 호출하므로(`ensure-running` 경로), 선행 실행이 CLI hang으로
락을 쥔 채 멈추면 후속 타이머 인보케이션들이 `flock 9`에서 무기한 블록되어
stuck 유닛이 누적된다. 서비스가 `Type = "oneshot"`이라 systemd 기본
타임아웃(`TimeoutStartSec`)도 적용되지 않는다
(`modules/nixos/programs/codex-remote-control.nix:81`, `RuntimeMaxSec` 미설정
— grep 실측). 같은 저장소의 다른 락 인프라 두 곳은 이미 타임아웃을 건다 —
이 파일만 컨벤션에서 벗어나 있다.

## Current state

- `modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh:85-99` — 수정 대상:

```bash
with_lock() {
  mkdir_state || {
    LAST_REPAIR_REASON="state-dir-unavailable"
    return 1
  }
  exec 9>"$LOCK_FILE" || {
    LAST_REPAIR_REASON="lock-open-failed"
    return 1
  }
  flock 9 || {
    LAST_REPAIR_REASON="lock-acquire-failed"
    return 1
  }
  "$@"
}
```

- 저장소의 타임아웃 컨벤션 (읽기 전용 exemplar):
  - `scripts/ai/install-lefthook-hooks.sh:140` — `flock --timeout "$LOCK_TIMEOUT_SECONDS"`
  - `modules/shared/scripts/lib/rebuild/locks.sh:205` 부근 — `flock --timeout`
- 기존 테스트: `tests/suites/codex-remote-control.sh` — CLI 서브커맨드를
  fixture로 구동하는 테스트가 다수 존재 (구조 exemplar).
- `LAST_REPAIR_REASON`은 이 스크립트가 실패 사유를 기록하는 기존 변수다 —
  같은 패턴으로 사유를 남긴다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 셸 린트 | `shellcheck -S warning modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh` | exit 0 |
| 해당 suite | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 전부 통과 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope**:
- `modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh`
  (`with_lock` 함수와 필요 시 타임아웃 상수 정의 1곳)
- `tests/suites/codex-remote-control.sh` (테스트 1개 추가)

**Out of scope** (do NOT touch):
- 이 파일의 다른 함수 — 특히 프로세스 종료(kill-safety) 로직은 기존 테스트가
  촘촘히 덮는 민감 영역이다.
- `codex-remote-control.nix` — systemd 쪽 `RuntimeMaxSec` 추가는 별도 판단
  사안 (Maintenance notes에 기록만).
- `sync_standalone_package`/`send_alerts` 테스트 — plan 009가 다룬다.

## Git workflow

- Branch: `advisor/007-maint-flock-timeout`
- Commit 예: `fix(codex): remote-control maint 락 획득에 타임아웃 부여`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: with_lock에 타임아웃 적용

파일 상단 상수 영역(기존 `LOCK_FILE` 정의 근처)에
`MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"`를 추가하고
(env 오버라이드 가능 형태 — 테스트에서 짧게 줄이기 위함), `flock 9`를:

```bash
  flock --timeout "$MAINT_LOCK_TIMEOUT_SECONDS" 9 || {
    LAST_REPAIR_REASON="lock-acquire-timeout"
    return 1
  }
```

로 교체한다. 기본 120초 근거: 정상 실행은 수 초 내이고, 타이머 주기 대비
충분히 짧아 stuck 누적을 방지한다.

**Verify**: `shellcheck -S warning modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh` → exit 0

### Step 2: 타임아웃 회귀 테스트 추가

`tests/suites/codex-remote-control.sh`에 기존 테스트들의 sandbox 패턴을 따라
1개 추가: 백그라운드 프로세스가 `flock`으로 LOCK_FILE을 선점한 상태에서
`MAINT_LOCK_TIMEOUT_SECONDS=1`로 스크립트의 락 경로를 구동 → 1초 후 실패
반환(무한 대기 아님)과 `lock-acquire-timeout` 사유를 assert. 테스트가 스크립트
전체 실행이 어려우면 `with_lock` 함수를 source 가능한지 확인하고(파일이 source
시 즉시 실행되는 구조인지 실측), 불가하면 기존 suite가 스크립트를 어떻게
구동하는지(fixture 서브커맨드 방식) 그대로 따른다.

**Verify**:
`nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh`
→ 신규 테스트 포함 전부 통과

## Test plan

Step 2가 test plan이다. 패턴 모델: `tests/suites/codex-remote-control.sh`의
기존 테스트 (sandbox + stub PATH + 서브커맨드 구동).

## Done criteria

- [ ] `grep -n 'flock --timeout' modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh` → 1건
- [ ] `grep -n 'lock-acquire-timeout' modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh` → 1건
- [ ] 옵션 없는 `flock 9` 잔존 0건
- [ ] `bash tests/run-all-tests.sh` → exit 0 (신규 테스트 포함)
- [ ] `git status --porcelain`에 in-scope 외 파일 없음
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- "Current state"의 `with_lock` 발췌가 실제 코드와 다르다.
- 기존 suite의 테스트가 blocking flock 동작에 의존한다 (타임아웃 도입으로
  기존 테스트가 깨지면 — 의존 지점을 보고).
- `flock --timeout`이 이 환경의 flock 구현에서 지원되지 않는다 (다른 두 락
  인프라가 이미 쓰므로 가능성 낮음 — 그래도 발생하면 보고).

## Maintenance notes

- systemd 쪽 이중 방어(`RuntimeMaxSec`)는 이번에 추가하지 않았다 — codex CLI
  정상 호출이 얼마나 걸릴 수 있는지(패키지 sync 포함) 운영 데이터 없이 값을
  정하면 오히려 정상 실행을 죽일 수 있다. 필요해지면 별도 판단.
- 타임아웃 발생은 `LAST_REPAIR_REASON=lock-acquire-timeout`으로 기존 사유
  보고 경로에 실린다 — 알림/로그에서 이 문자열로 검색 가능.
