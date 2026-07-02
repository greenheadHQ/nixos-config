# Plan 016: 홈서버 백업/복구 자세를 설계한다 — same-disk 탈피 최소안 + 복원 드릴 (spike)

> **Executor instructions**: 이것은 **설계(spike) plan이다 — 소스 코드를 일절
> 수정하지 않는다**. 산출물은 설계 보고서 파일 하나다. Follow this plan step
> by step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/docker/ hosts/greenhead-minipc/ libraries/constants.nix`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.

## Status

- **Priority**: P2
- **Effort**: M (설계만 — 구현은 별도 plan)
- **Risk**: LOW (읽기 전용 spike)
- **Depends on**: none (plan 005 spike 보고서가 먼저 있으면 유지보수 창 절에서 참조)
- **Category**: direction
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/953

## Why this matters

이 홈서버의 존재 이유는 개인 사진(Immich)·북마크(Karakeep)·파일(Copyparty)
보존인데, 현재 백업 자세로는 **디스크 1개 장애가 원본과 백업을 동시에
지운다**: 백업 모듈은 Immich/Karakeep 둘뿐이고(Copyparty·Uptime Kuma 없음),
둘 다 목적지가 원본 데이터와 **같은 HDD**(`/mnt/data/backups/`)다. 오프사이트
/2차 매체 사본이 없고, 복원 드릴을 해본 적이 없어 "백업이 있다"가 "복구가
된다"를 보장하지 않는다. epic #912가 이를 "향후 고려 — 홈서버 데이터
백업/복구 자세"로 명시해 두었다 (gh issue #912 본문). 단일 메인테이너
저장소이므로 3-2-1 원칙의 교과서 구현이 아니라 **운영 부담 최소의 현실안**을
설계하는 것이 목적이다.

## Current state

전부 **읽기 전용** 근거:

- 백업 모듈 실태 (`ls modules/nixos/programs/docker/ | grep backup`):
  `immich-backup.nix`, `karakeep-backup.nix` — 2건뿐.
- 목적지가 원본과 같은 디스크:
  - `immich-backup.nix:18` — `backupDir = "${mediaData}/backups/immich"`
  - `karakeep-backup.nix:17-18` — `srcDir = "${mediaData}/karakeep"`,
    `backupDir = "${mediaData}/backups/karakeep"` (**원본과 백업이 같은 HDD**)
  - `mediaData = "/mnt/data"` (HDD), `dockerData = "/var/lib/docker-data"`
    (SSD) — `libraries/constants.nix:43-45`
- 디스크 구성: `hosts/greenhead-minipc/disko.nix` — NVMe(SSD)만 disko 관리,
  HDD(/dev/sda)는 미포함(재설치 시 보존).
- 미백업 데이터 인벤토리의 출발점: Copyparty 데이터(`mediaData` 아래 — 정확한
  경로는 `copyparty.nix`에서 확인), Uptime Kuma SQLite(`uptime-kuma.nix`에서
  볼륨 확인), Immich **원본 사진 자체**(`mediaData` 아래 — DB 백업만 있고
  사진 파일 백업은 없음), agenix 시크릿(리포에 암호화 커밋 — 별도 불필요 판단
  포함할 것).
- 관련 결정/계획: 이슈 #917(update-script 통합)이 유지보수 창 대기,
  plan 001이 `.dump` 복원 문서를 추가, plan 004가 백업 스크립트 테스트를 추가
  — 이 spike의 복원 드릴 정의는 이들과 정합해야 한다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 데이터 인벤토리 | `grep -rn "mediaData\|dockerData" modules/nixos/programs/docker/*.nix` | 서비스별 데이터 경로 표 |
| epic 원문 | `gh issue view 912 --json body` | "향후 고려" 절 확인 |
| 볼륨 확인 | 각 서비스 .nix의 `volumes =` 블록 읽기 | 백업 대상 확정 |

디스크 사용량 실측(`du`)은 대상 디렉토리가 크므로 필요 시 `du -sh` 수준만.

## Scope

**In scope** (생성 가능한 파일 — 이 하나뿐):
- `plans/016-findings-backup-posture.md` (신규 — 설계 보고서)

**Out of scope** (do NOT touch):
- 소스 코드/모듈 일체 — 구현은 이 보고서 승인 후 별도 plan.
- 특정 클라우드/원격 스토리지 계약 체결을 전제한 설계 — 후보와 트레이드오프만.

## Git workflow

- Branch: `advisor/016-backup-posture-spike`
- Commit 예: `docs(plans): 홈서버 백업/복구 자세 설계 보고서`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 백업 대상 인벤토리 작성

각 서비스의 데이터 경로·크기 규모·현재 백업 여부·소실 시 피해를 표로:
Immich(DB + **원본 사진**), Karakeep(SQLite + 아카이브 자산), Copyparty
(사용자 파일), Uptime Kuma(SQLite), agenix(리포 커밋 — 제외 근거 명시),
설정 자체(이 리포 — GitHub 원격 존재, 제외 근거 명시).

**Verify**: 표의 모든 경로가 .nix 파일 인용으로 뒷받침됨.

### Step 2: 2차 사본 경로 후보 설계 (최소 운영 부담 기준)

후보별 트레이드오프 (각 2~4문장): ① 외장 디스크 rsync(수동/타이머)
② 원격 rsync/restic(오프사이트 — 대상 후보와 암호화 요구)
③ 클라우드 객체 스토리지. **사진 원본(용량 큼)**과 **DB 덤프(작음)**의
계층 분리(작은 것부터 오프사이트) 옵션을 반드시 포함. 기존 인프라
(Tailscale, systemd 타이머 + Pushover 알림 관례)를 재사용하는 안을 우선.

**Verify**: 각 후보에 예상 운영 부담(설치 후 사람 손 가는 빈도)이 명시됨.

### Step 3: 복원 드릴 정의

분기(또는 반기) 드릴 절차 초안: 무엇을(DB 덤프 복원 — plan 001 문서 절차
재사용, 파일 샘플 복원), 어디서(운영 호스트 vs 임시 환경), 성공 기준,
소요 시간. **다음 유지보수 창에서 1회차를 실행하는 것을 재개 트리거로**
명시하고, 이슈 #917 실경로 검증·plan 005 마이그레이션과 같은 창에 묶는
운영 권고(순서: 드릴 먼저)를 포함.

**Verify**: 드릴 절차의 각 단계에 성공 기준이 있음.

### Step 4: 권고안 확정 + open questions

최소안 1개를 추천으로 명시하고(예: "DB/설정 덤프를 원격 1곳에 restic, 사진
원본은 외장 디스크 월 1회"— 실제 추천은 조사 결과 기준), 결정이 필요한
open questions(오프사이트 대상 계정, 암호화 키 보관, 예산)를 나열한다.

**Verify**: 보고서에 추천 1개 + open questions 절 존재.

## Test plan

코드 변경 없음. 품질 게이트: 모든 경로 주장에 `.nix` 인용, 모든 외부 도구
주장에 출처 URL 또는 `[UNVERIFIED]`.

## Done criteria

- [ ] `test -f plans/016-findings-backup-posture.md` → exit 0
- [ ] 보고서에 인벤토리 표 / 후보 트레이드오프 / 복원 드릴 / 추천+open questions 절 존재
- [ ] `git diff --stat` → 변경이 `plans/` 아래에만
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- 데이터 경로 인벤토리 중 .nix에서 확정할 수 없는 항목이 있다 (실 호스트
  확인 필요) — 그 항목만 `[UNVERIFIED]`로 표기하고 진행하되, 과반이
  미확정이면 STOP.
- epic #912 본문의 방향과 모순되는 결정 기록을 발견한다.

## Maintenance notes

- 이 보고서 승인 후의 구현 plan(들)은 이 저장소의 관례(systemd 타이머 +
  Pushover 알림 + `homeserver.*` 옵션 + constants 경로)를 따라야 한다.
- plan 004의 백업 테스트가 먼저 있으면 구현 단계 회귀 안전망이 된다.
