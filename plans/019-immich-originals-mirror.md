# Plan 019: Immich 원본 사진을 HDD로 일일 미러링한다 — 무백업 SSD 단독 존재 해소

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 6a1ef4ef..HEAD -- modules/nixos/programs/docker/immich.nix modules/nixos/options/homeserver.nix libraries/constants.nix modules/nixos/configuration.nix`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P1 (016 보고서의 "단일 최우선 시정")
- **Effort**: M
- **Risk**: LOW (읽기 전용 rsync 미러 — 원본 무변경. 실 배포 검증은 운영자 `nrs`)
- **Depends on**: none (plan 004의 테스트 인프라가 있으면 좋으나 hard 아님)
- **Category**: bug (데이터 보존 결함 시정)
- **Planned at**: commit `6a1ef4ef`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/961

## Why this matters

Immich 원본 사진/영상 **약 105G(2026-07-02 실측)가 SSD의
`/var/lib/docker-data/immich/upload-cache`에만 존재하고 어떤 백업도 없다**
(`plans/016-findings-backup-posture.md` §Step1 행 #1 — 실측·재검증 완료).
disko 재설치는 SSD(NVMe)를 포맷하므로, 재해복구 시 DB 덤프(HDD)는 살아도
원본은 영구 소실된다 — 복원해도 자산 없는 껍데기 DB만 남는다. SSD 단일 장애도
동일하다. 이 plan은 016 보고서 §Step4 추천 (A)("단일 최우선 시정")의 구현이다:
운영자 결정(016 open questions 답)에 따라 **원본 위치는 유지**(SSD)하고, HDD로
**일일 rsync 미러**를 추가해 "원본이 포맷 대상 디스크에만 존재"하는 구조를
깬다. HDD 여유는 1.2T(실측)로 충분하다. 오프사이트 계층은 별도 plan(020)이
다룬다.

## Current state

관련 파일과 역할:

- `modules/nixos/programs/docker/immich-backup.nix` — **모듈 구조 exemplar**
  (읽기 전용): agenix 시크릿 + `writeShellApplication` + systemd oneshot
  (`ConditionPathExists`, `TimeoutSec`, `PrivateTmp`, `NoNewPrivileges`,
  environment 주입) + timer(`wantedBy = [ "timers.target" ]`) 조합.
- `modules/nixos/programs/docker/karakeep-notify.nix:19-28` — **스크립트 파일
  분리 exemplar**: `text = builtins.readFile ./karakeep-notify/files/webhook-bridge.sh;`
  — 신규 스크립트는 처음부터 이 패턴으로 작성한다 (plan 004의 방향과 정합).
- `modules/nixos/options/homeserver.nix:21-34` — 옵션 블록 exemplar:

```nix
immichBackup = {
  enable = lib.mkEnableOption "Immich PostgreSQL daily backup to HDD";
  backupTime = lib.mkOption {
    type = lib.types.str;
    default = "*-*-* 05:30:00";
    description = "OnCalendar time for daily backup";
  };
  retentionDays = lib.mkOption { ... };
};
```

- `libraries/constants.nix:43-46` — 경로 SSOT:
  `dockerData = "/var/lib/docker-data"`(SSD), `mediaData = "/mnt/data"`(HDD),
  `immichUploadCache = "/var/lib/docker-data/immich/upload-cache"`(원본 위치).
- `modules/nixos/configuration.nix` — homeserver 서비스 활성화 위치
  (`homeserver.immichBackup.enable = true;` 류가 모여 있음 — 실제 형태 확인).
- 알림 관례: `modules/nixos/lib/service-lib.nix` import + `SERVICE_LIB` env +
  스크립트에서 `source "$SERVICE_LIB"` 후 `send_notification` (실패 시만 알림,
  성공 시 무알림 — `immich-backup.nix`의 `cleanup_on_error` trap 참조).
- 소스 데이터 특성: `upload-cache` 최상위는 Immich user-id 디렉토리. 원본은
  불변 파일 위주. Immich 앱 레벨 휴지통(기본 30일)이 실수 삭제의 1차 방어.
  스토리지 템플릿은 **비활성 유지**가 운영자 결정 — 경로 구조는 현행 그대로.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Nix 평가 | `bash tests/run-eval-tests.sh` | 통과 |
| Flake | `nix flake check --no-build --all-systems` | exit 0 |
| 포맷/린트 | `nixfmt --check <신규 .nix>` / `shellcheck -S warning <신규 .sh>` | exit 0 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

`nrs` 실 배포와 첫 미러 실행(105G, 수십 분)은 **운영자 후속**.

## Scope

**In scope**:
- `modules/nixos/programs/docker/immich-originals-mirror.nix` (신규)
- `modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh` (신규)
- `modules/nixos/options/homeserver.nix` (`immichOriginalsMirror` 옵션 블록 추가)
- `modules/nixos/configuration.nix` (활성화 1줄 — 기존 immichBackup 활성화와 같은 위치)
- `libraries/constants.nix` (목적지 경로 상수 추가가 자연스러우면 — 기존 backups 경로들이 상수화되어 있지 않고 모듈 내 `"${mediaData}/backups/..."` 조합이면 그 관례를 따르고 상수 추가 생략)

**Out of scope** (do NOT touch):
- `immich.nix`의 볼륨/컨테이너 구성 — 원본 위치는 유지(운영자 결정). 이전
  (relocation)은 이 plan이 아니다.
- 기존 `immich-backup.nix`(DB 덤프) — 별개 서비스로 공존.
- 오프사이트 전송 — plan 020.
- Immich 스토리지 템플릿 설정 — 비활성 유지 (운영자 결정).

## Git workflow

- Branch: `advisor/019-immich-originals-mirror`
- Commit 예: `feat(immich): 원본 사진 HDD 일일 미러 — 무백업 SSD 단독 존재 해소`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 미러 스크립트 작성 (files/ 분리)

`immich-originals-mirror/files/immich-originals-mirror.sh`:

- env 주입(전부 systemd environment에서): `SRC_DIR`(= immichUploadCache),
  `DEST_DIR`(= `${mediaData}/backups/immich-originals`), `PUSHOVER_CRED_FILE`,
  `SERVICE_LIB`.
- 로직 (exemplar: `immich-backup.nix`의 방어 구조):
  1. `source "$PUSHOVER_CRED_FILE"` + `source "$SERVICE_LIB"`.
  2. 실패 시 Pushover 알림 trap (`cleanup_on_error` 패턴 — 제목
     "Immich Originals Mirror").
  3. SRC_DIR 존재·비어있지 않음 확인 (빈 소스로 `--delete` 미러 실행 시 목적지
     전체 삭제 방지 — **핵심 가드**: `[ -d "$SRC_DIR" ] && [ -n "$(ls -A "$SRC_DIR")" ]`
     실패 시 exit 1).
  4. 목적지 디스크 여유 검사 (`df` — immich-backup의 5GB 검사 패턴, 여기선
     증분 여유 기준으로 완화 가능).
  5. `rsync --archive --delete --human-readable --stats "$SRC_DIR/" "$DEST_DIR/"`
     — 미러 방식. 삭제 전파는 의도된 결정: 실수 삭제 방어는 Immich 앱 휴지통
     (30일)과 오프사이트 계층(plan 020)의 몫이라는 016 계층 설계를 따른다.
     이 결정을 스크립트 주석으로 남긴다.
  6. rsync exit code 처리: 0 정상, **24(vanished source files)는 경고 후 정상
     취급**(라이브 업로드 중 파일 이동은 자연 현상), 그 외 non-zero는 실패.
  7. 완료 로그에 `--stats` 요약 출력 (journald).
- `writeShellApplication`의 `runtimeInputs`: `rsync coreutils curl` (+ service-lib가
  요구하는 것 — exemplar 확인).

**Verify**: `shellcheck -S warning modules/nixos/programs/docker/immich-originals-mirror/files/immich-originals-mirror.sh` → exit 0

### Step 2: NixOS 모듈 작성

`immich-originals-mirror.nix` — `immich-backup.nix`를 골격 그대로 따라:

- `cfg = config.homeserver.immichOriginalsMirror`, `lib.mkIf (cfg.enable && immichCfg.enable)`.
- agenix `pushover-immich` 시크릿 재사용 (같은 선언 — 모듈 시스템이 merge;
  `karakeep-backup.nix`의 중복 선언 주석 참조).
- systemd oneshot: `ConditionPathExists = pushoverCredPath`,
  `TimeoutSec = "3h"` (초회 105G 전체 복사 대비 — HDD 쓰기 병목 기준 여유),
  `ReadWritePaths` 불가 사유가 없으므로 가능하면 지정, `PrivateTmp`,
  `NoNewPrivileges`. environment로 `SRC_DIR`/`DEST_DIR`/`PUSHOVER_CRED_FILE`/`SERVICE_LIB`.
- timer: 기본 `*-*-* 04:30:00` (DB 백업 05:30 이전 — 미러가 먼저 끝나 IO 경합
  회피; 옵션으로 조정 가능).
- `text = builtins.readFile ./immich-originals-mirror/files/immich-originals-mirror.sh;`

**Verify**: `nixfmt --check modules/nixos/programs/docker/immich-originals-mirror.nix` → exit 0

### Step 3: 옵션 선언 + 활성화 + import 배선

1. `homeserver.nix`에 `immichOriginalsMirror = { enable = lib.mkEnableOption ...;
   mirrorTime = lib.mkOption { default = "*-*-* 04:30:00"; ... }; }` 추가
   (기존 immichBackup 블록 스타일).
2. 모듈 import 배선: 기존 `immich-backup.nix`가 어디서 import되는지 확인
   (`grep -rn "immich-backup" modules/nixos/`)하고 같은 위치에 추가.
3. `configuration.nix`에 `homeserver.immichOriginalsMirror.enable = true;` 추가
   (기존 immichBackup 활성화 옆).

**Verify**: `bash tests/run-eval-tests.sh` → 통과,
`nix flake check --no-build --all-systems` → exit 0

### Step 4: 전체 게이트

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP

## Test plan

- plan 004(백업 스크립트 특성화)가 아직 TODO이므로 suite 인프라 재사용은 불가
  전제. 이 plan에서는 **빈 소스 가드**만 최소 테스트로 박제한다:
  `tests/suites/`에 소형 suite 1개 — sandbox에서 `SRC_DIR`을 빈 디렉토리로
  주고 스크립트 실행 → non-zero exit + rsync 미호출(스텁 rsync가 마커 파일
  미생성)을 assert. 구조 모델: `tests/suites/fragile-hardcoding-guard.sh` +
  `tests/lib/test-common.sh` 헬퍼. (전체 특성화는 plan 004 머지 후 그 패턴으로
  확장 — Maintenance notes.)

## Done criteria

- [ ] 신규 파일 2개 존재 + 옵션/활성화/import 배선 grep 확인
  (`grep -rn "immichOriginalsMirror" modules/nixos/ | wc -l` ≥ 3)
- [ ] `bash tests/run-all-tests.sh` → exit 0 (신규 빈-소스 가드 테스트 포함)
- [ ] `nix flake check --no-build --all-systems` → exit 0
- [ ] 빈 소스 가드가 스크립트에 존재 (`grep -n 'ls -A' <신규 .sh>` 1건)
- [ ] rsync exit 24 처리 존재 (`grep -n '24' <신규 .sh>` 1건 이상)
- [ ] 최종 보고에 운영자 후속 명시: "`nrs` 적용 → `sudo systemctl start
  immich-originals-mirror.service` 수동 1회(초회 105G, 수십 분) →
  `journalctl -u immich-originals-mirror -f`로 완료 확인 → 목적지 파일 수/용량
  대조(`du -sh`)"
- [ ] `git status --porcelain`에 in-scope 외 파일 없음
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- "Current state"의 exemplar 구조(immich-backup.nix의 서비스/타이머 골격)가
  실제와 다르다.
- `pushover-immich` agenix 시크릿의 중복 선언이 eval 에러를 낸다 (merge가
  기대와 다름 — karakeep 선례와 대조 후 보고).
- 목적지 경로 정책 충돌: `${mediaData}/backups/`에 이미 originals 관련 디렉토리가
  존재한다 (다른 수단이 이미 있음 — 중복 구현 금지, 보고).

## Maintenance notes

- **삭제 전파(–delete) 결정**: 미러는 원본의 삭제를 따라간다. 실수 삭제 방어는
  Immich 휴지통(앱, 30일) + 오프사이트 계층(plan 020)의 몫 — 이 계층 설계는
  016 보고서 §Step2가 근거. 이 결정을 바꾸려면(예: `--backup-dir` 지연 삭제)
  스토리지 성장 관리가 함께 필요하다.
- plan 004가 머지되면 이 스크립트도 그 특성화 패턴(스텁 rsync)으로 테스트를
  확장할 것.
- 유지보수 창 runbook(`plans/017-maintenance-window-runbook.md`)의 "사전
  게이트"가 이 plan의 적용을 전제한다 — **창 실행 전에 이 plan이 머지·적용되고
  초회 미러가 완료되는 것이 이상적**이다.
- Immich 스토리지 템플릿을 향후 활성화하면 원본 경로가 `library/`(HDD 쪽
  마운트)로 이동해 이 미러의 SRC가 비게 된다 — 그 시점에 이 모듈의 존폐를
  재판단할 것 (빈 소스 가드가 목적지 삭제는 막아준다).
