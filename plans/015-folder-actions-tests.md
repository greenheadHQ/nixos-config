# Plan 015: folder-actions 스크립트군(darwin)의 공유 라이브러리부터 특성화 테스트를 씌운다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/darwin/programs/folder-actions/ tests/`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P3
- **Effort**: L (전체) — 이 plan은 그중 **1단계(공유 lib + upload-immich 분기)만** 다룬다
- **Risk**: LOW (테스트 추가만)
- **Depends on**: plans/011-pushover-shared-helper.md (soft — 011이
  `_folder-actions-lib.sh`를 수정하므로 먼저 머지되면 충돌 없음. 반대 순서면
  011이 이 테스트의 기대값을 갱신해야 함)
- **Category**: tests
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/952

## Why this matters

macOS Folder Actions로 배선된 스크립트군(`upload-immich.sh` 732줄,
`compress-video.sh`, `compress-rar.sh`, `convert-video-to-gif.sh`,
`rename-asset.sh`, 공유 lib `_folder-actions-lib.sh`)은 사용자 파일을
**이동·변환·업로드 후 원본 삭제**까지 하는 파괴적 운영 스크립트인데 테스트가
0건이다 (grep 실측). 원본 유실로 직결되는 회귀(실패 파일 격리 로직, 파일
안정화 대기, 큐 드레인)를 잡을 수단이 없다. 전체 커버는 L 규모라, 이 plan은
가장 leverage 높은 조각 — 모든 스크립트가 공유하는 `_folder-actions-lib.sh`의
파일 처리 함수들과 `upload-immich.sh`의 조용한 종료 분기 — 만 특성화한다.
트랜스코드 스크립트들의 커버는 후속으로 명시적으로 남긴다.

## Current state

- `modules/darwin/programs/folder-actions/files/scripts/_folder-actions-lib.sh`
  — 함수 구조 (grep 실측):

```
 24: notify_failure()        55: ensure_failed_dir()
 85: move_to_failed()       121: wait_file_stable()
157: drain_queue()          204: quarantine_or_abort()
```

- `upload-immich.sh:660-675` 부근 — 자격증명 부재 시 **조용한 exit 0** 분기:

```bash
if [ ! -f "$IMMICH_CREDENTIALS" ]; then
    log "자격증명 없음: $IMMICH_CREDENTIALS"
    exit 0
fi
if [ ! -f "$PUSHOVER_CREDENTIALS" ]; then
    log "자격증명 없음: $PUSHOVER_CREDENTIALS"
    exit 0
fi
```

- 이 스크립트들은 macOS 전용 배선이지만 **bash 스크립트 자체는 Linux 테스트
  러너에서도 구동 가능**해야 한다 — 단, macOS 절대경로 명령(`/bin/rm`,
  `/usr/bin/stat` 등)을 쓰는 곳이 있어(CLAUDE.md의 BSD/GNU 라우팅 정책) 함수
  단위로 스텁 가능한 것만 대상으로 한다. 각 함수를 열어 의존 명령을 확인하고
  Linux에서 구동 불가능한 함수는 제외 목록에 기록한다.
- suite 컨벤션: `tests/suites/*.sh` + `tests/lib/test-common.sh`
  (`new_sandbox` 등). 모델: `tests/suites/fragile-hardcoding-guard.sh`.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Suite 실행 | `nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 bash tests/run-shell-script-tests.sh` | 전부 통과 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |
| 셸 린트 | `shellcheck -S warning tests/suites/folder-actions-lib.sh` | exit 0 |

## Scope

**In scope**:
- `tests/suites/folder-actions-lib.sh` (신규)

**Out of scope** (do NOT touch):
- folder-actions 스크립트들의 **동작 변경 일절** — 특성화다. source-safe
  문제가 있으면 STOP.
- `compress-video.sh`/`compress-rar.sh`/`convert-video-to-gif.sh`/
  `rename-asset.sh`의 트랜스코드 로직 테스트 — 명시적 후속 (ffmpeg 등 무거운
  의존성 스텁 설계가 별도 규모).
- launchd/Folder Actions 배선 (`default.nix`).

## Git workflow

- Branch: `advisor/015-folder-actions-tests`
- Commit 예: `test(darwin): folder-actions 공유 lib 파일 처리 특성화`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 라이브러리 source-safety와 함수별 의존 확인

`_folder-actions-lib.sh`를 열어 ① source 시 즉시 실행되는 부작용이 있는지
② 각 함수가 쓰는 외부 명령(절대경로 포함)을 표로 정리한다. Linux 러너에서
구동 불가(macOS 절대경로 필수)인 함수는 제외 목록에 넣고 suite 주석에 남긴다
(silent cap 금지).

**Verify**: 표 완성. source-unsafe면 STOP.

### Step 2: 파일 처리 함수 특성화

sandbox에서 (필요 시 macOS 절대경로 명령을 sandbox PATH 스텁 + 함수 내
경로가 env로 오버라이드 가능한지 확인 후):

1. `wait_file_stable` — 크기가 변하는 파일(백그라운드에서 append) vs 안정
   파일에 대한 현행 판정 박제 (타임아웃 짧게 조정 가능한지 확인).
2. `move_to_failed`/`ensure_failed_dir` — 실패 파일이 failed 디렉토리로
   이동되고 원본 위치에서 사라짐; 이름 충돌 시 현행 동작 박제.
3. `drain_queue` — 큐에 쌓인 파일들이 순서대로 처리되고 큐가 비워짐 (처리
   콜백은 스텁).
4. `quarantine_or_abort` — 격리 분기와 abort 분기의 현행 조건 박제.
5. `notify_failure` — Pushover curl을 스텁해 호출 인자만 확인
   (plan 011이 먼저 머지됐다면 `pushover_send` 스텁으로).

**Verify**: suite 실행에서 신규 테스트 통과.

### Step 3: upload-immich의 조용한 종료 분기 특성화

`upload-immich.sh`를 자격증명 파일 없는 sandbox HOME으로 구동해 exit 0 +
로그 메시지("자격증명 없음")를 assert한다. 스크립트가 그 이전 단계에서
macOS 전용 명령을 요구해 Linux에서 그 분기까지 도달하지 못하면, 이 케이스를
제외 목록에 기록하고 스킵한다.

**Verify**: suite 통과 + `bash tests/run-all-tests.sh` → exit 0

## Test plan

Steps 2-3이 test plan이다. 제외 목록(Linux 구동 불가 함수)이 suite 주석에
남는 것까지가 완결이다.

## Done criteria

- [ ] `grep -rl "folder-actions" tests/suites/` → 1건 (참조 0건 해소)
- [ ] 신규 테스트 전부 통과, 제외 함수 목록이 suite 주석에 존재
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] 대상 스크립트들 diff 없음 (`git diff --stat`에 tests/만)
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- `_folder-actions-lib.sh`가 source-unsafe하다 (로드 시 부작용) — 대상을
  고치지 말고 보고.
- 대부분의 함수가 macOS 절대경로에 하드 의존해 Linux 러너에서 의미 있는
  커버가 불가능하다 (제외 목록이 대상의 과반) — 접근 자체를 재검토해야
  하므로 보고 (예: Mac에서만 도는 별도 테스트 경로가 필요한지는 운영자 판단).

## Maintenance notes

- 후속(명시적 잔여): 트랜스코드 4종 스크립트의 입력 검증/실패 종료코드
  스모크. ffmpeg/unar 스텁 설계가 필요해 별도 plan 규모다.
- plan 011이 `_folder-actions-lib.sh`의 notify_failure를 수정하면 이 suite의
  해당 테스트 기대값을 함께 갱신해야 한다 (의존성 노트 참조).
