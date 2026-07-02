# Plan 009: codex-remote-control-maint의 패키지 sync·알림 상태전이에 테스트를 추가한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh tests/suites/codex-remote-control.sh`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/007-maint-flock-timeout.md (같은 파일·같은 suite를 만지므로 먼저 머지 권장 — soft)
- **Category**: tests
- **Planned at**: commit `fb2a8aa6`, 2026-07-02

## Why this matters

`codex-remote-control-maint.sh`(870줄)의 위험도 높은 코어(프로세스 종료
kill-safety)는 기존 suite(`tests/suites/codex-remote-control.sh`)가 촘촘히
검증한다. 그러나 두 경로가 미커버로 남아 있다: ① `sync_standalone_package`
(실제 `nix profile` 설치를 수행하는 86줄) — 실패 처리 회귀가 조용히 패키지
드리프트를 만든다. ② `send_alerts`의 실패/복구 상태전이 — `last-health-state`
파일 기반 쿨다운·복구 알림 로직이 깨지면 장애를 알리지 못하거나 알림이
스팸이 된다. 둘 다 외부 명령 스텁으로 저렴하게 특성화할 수 있다.

## Current state

- 대상 함수 위치 (`codex-remote-control-maint.sh`, grep 실측):
  - `:176 sync_standalone_package()` — nix 명령 실행부
  - `:262 capture_login_status()`
  - `:754 load_alerting()` — `SERVICE_LIB`/`PUSHOVER_CRED_FILE`(또는
    `CREDENTIALS_DIRECTORY`) source
  - `:767 send_alerts()` — 발췌:

```bash
send_alerts() {
  local exit_code="$1"
  command -v send_notification >/dev/null 2>&1 || return 0
  [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ] || return 0

  local now
  now="$(date +%s)"
  local state_file="$STATE_DIR/last-health-state"
  local last_failure_file="$STATE_DIR/last-failure-alert"
  local previous="unknown"
  [ -f "$state_file" ] && previous="$(cat "$state_file" 2>/dev/null || echo unknown)"

  if [ "$exit_code" -eq 0 ]; then
    if [ "$previous" = "failed" ]; then
      send_notification "Codex Remote Control Recovered" \
        "greenhead-minipc remote-control is healthy (${APP_SERVER_VERSION:-unknown})." 0
    fi
```

  (이하 실패 분기·쿨다운 로직은 실행 시 파일에서 직접 읽어 특성화한다 —
  현재 동작을 기대값으로 박제하는 것이 목적이지, 동작 변경이 아니다.)

- 기존 suite: `tests/suites/codex-remote-control.sh` (452줄, 테스트 다수) —
  sandbox + stub PATH + 서브커맨드/함수 구동 패턴의 exemplar. 신규 테스트는
  이 파일에 이어서 추가한다.
- 공통 헬퍼: `tests/lib/test-common.sh` (`new_sandbox`/`fail`/`assert_contains`).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Suite 실행 | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 전부 통과 |
| 셸 린트 | `shellcheck -S warning tests/suites/codex-remote-control.sh` | exit 0 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

## Scope

**In scope**:
- `tests/suites/codex-remote-control.sh` (테스트 추가만)

**Out of scope** (do NOT touch):
- `codex-remote-control-maint.sh` **동작 변경 일절** — 특성화가 목적이다.
  테스트를 위해 스크립트 수정이 필요해 보이면 STOP.
- 기존 테스트들의 수정.

## Git workflow

- Branch: `advisor/009-maint-sync-alert-tests`
- Commit 예: `test(codex): remote-control maint sync/알림 상태전이 특성화`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 기존 suite의 함수 구동 방식 파악

`tests/suites/codex-remote-control.sh`의 기존 테스트가 maint 스크립트의 함수를
어떻게 구동하는지(전체 스크립트 서브커맨드 실행인지, source 후 함수 호출인지)
확인하고 같은 방식을 쓴다.

**Verify**: 기존 방식과 동일 패턴으로 빈 테스트 1개를 추가해 suite가 그것을
발견·실행함을 확인 (이후 실제 assert로 교체).

### Step 2: send_alerts 상태전이 특성화 테스트 추가

`STATE_DIR`을 sandbox로, `send_notification`을 마커 파일 기록 스텁으로 주입해
다음 전이를 assert한다 (기대값은 **현행 코드를 읽고** 박제):

1. previous=failed + exit_code=0 → "Recovered" 알림 1회 + state 파일 healthy 갱신.
2. previous=healthy(또는 파일 없음) + exit_code=0 → 알림 0회.
3. previous=healthy + exit_code≠0 → 실패 알림 1회 + state 파일 failed.
4. 실패 직후 재실패(쿨다운 창 내) → 알림 재발송 없음 (`last-failure-alert`
   파일 기반 — 정확한 쿨다운 동작은 코드에서 확인해 박제).
5. `PUSHOVER_TOKEN` 미설정 → 조기 return, 알림/상태 파일 무변화.

**Verify**: suite 실행에서 신규 테스트들 통과.

### Step 3: sync_standalone_package 실패 전파 테스트 추가

`nix`를 스텁(성공/실패 제어)으로 주입해: 스텁 실패 시 함수가 non-zero(또는
스크립트의 기존 실패 보고 방식 — 코드에서 확인)를 반환하고, 성공 시 기대
호출 인자가 기록됨을 assert한다. `capture_login_status`는 codex CLI 스텁으로
성공/실패 두 분기만.

**Verify**: suite 실행에서 신규 테스트 통과 + `bash tests/run-all-tests.sh` → exit 0

## Test plan

Steps 2-3이 test plan이다. 구조 모델: 같은 파일의 기존 테스트들.

## Done criteria

- [ ] `grep -c "^test_.*alert\|^test_.*sync" tests/suites/codex-remote-control.sh` → 신규 테스트 함수들 존재
- [ ] `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` → exit 0
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `git diff --stat` → 변경이 `tests/suites/codex-remote-control.sh` 1개 파일뿐
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- 함수 단위 구동이 불가능하고(스크립트가 source-safe하지 않음) 기존 suite에도
  그런 선례가 없다 — 스크립트를 고치지 말고 보고.
- 특성화 중 현행 동작이 명백한 버그로 보인다(예: 복구 알림이 영구히 안 나감)
  — 고치지 말고 기대값 박제를 중단하고 발견 내용을 보고.

## Maintenance notes

- 이 테스트들은 현행 동작의 박제다 — 알림 정책을 의도적으로 바꾸는 PR은 이
  테스트의 기대값을 함께 바꿔야 하며, 그것이 정상이다.
- plan 007(flock 타임아웃)과 같은 파일·suite를 만지므로 머지 순서를 지키면
  충돌이 없다.
