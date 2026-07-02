# Plan 020: 소용량 고가치 데이터를 restic으로 Cloudflare R2에 매일 오프사이트 백업한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report. When done, update the status row in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 6a1ef4ef..HEAD -- modules/nixos/programs/docker/ modules/nixos/options/homeserver.nix libraries/constants.nix modules/nixos/programs/opnix/`
> 변경이 있으면 "Current state"와 대조하고, 불일치 시 STOP.
> (plan 019가 먼저 머지됐다면 immich-originals-mirror 관련 diff는 예상된 것 — STOP 아님.)

## Status

- **Priority**: P2
- **Effort**: M-L
- **Risk**: MED (신규 외부 의존 — R2 계정/자격증명. 데이터는 읽기 전용 전송)
- **Depends on**: **운영자 선행 절차 (아래 "운영자 사전 준비" — 미완이면 착수 불가)**
- **Category**: enhancement (백업 자세 — 016 추천 (B) 구현)
- **Planned at**: commit `6a1ef4ef`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/962

## Why this matters

현재 모든 백업이 같은 호스트의 물리 디스크에 있다 — 화재/도난/동시 다중 장애
시 원본과 백업이 함께 소실된다. `plans/016-findings-backup-posture.md` §Step2의
계층 설계에 따라, **소용량 고가치 데이터(합계 약 3G 미만: Immich DB 덤프,
Karakeep SQLite+아카이브, Uptime Kuma SQLite)를 매일 오프사이트로** 보내면
저비용으로 3-2-1에 근접한다. 운영자 결정(016 open questions 답): 대상 =
**Cloudflare R2**, 암호화 키 보관 = **1Password**. restic은 클라이언트측
암호화·중복제거·증분을 제공하므로 R2에는 암호문만 저장된다. 사진 원본(105G)은
plan 019(로컬 미러)가 담당하고, 오프사이트 승격은 이 plan의 운영이 안정된 후
별도 판단이다.

## Current state

- 백업 대상 (016 §Step1 인벤토리 기준, 경로는 전부 실측·인용 검증됨):

| 대상 | 호스트 경로 | 근거 |
|------|------------|------|
| Immich DB 일일 덤프 | `/mnt/data/backups/immich/` | `immich-backup.nix:18` |
| Karakeep 백업(.gz) | `/mnt/data/backups/karakeep/` | `karakeep-backup.nix:18` |
| Karakeep 라이브 데이터(아카이브 자산 포함) | `/mnt/data/karakeep/` | `karakeep.nix:141` 등 |
| Uptime Kuma SQLite | `/var/lib/docker-data/uptime-kuma/data/` | `uptime-kuma.nix:19,27` |

  주의: Karakeep 라이브 SQLite는 쓰기 중 스냅샷이 불안전하므로 **백업 산출물
  (`backups/karakeep`의 `.gz`)을 우선 대상**으로 하고, 라이브 디렉토리에서는
  아카이브 자산(정적 파일)만 포함할지 executor가 디렉토리 구조를 보고 판단해
  보고서에 기록한다. Uptime Kuma는 백업 산출물이 아직 없으므로(016 행 #9)
  라이브 SQLite를 직접 포함하되 sqlite 쓰기 경합 리스크를 주석으로 남긴다
  (완화: 새벽 시간 실행; 근본 해결은 #917의 uptime-kuma stop→backup→start
  경로가 백업 산출물을 만들기 시작한 후 그 산출물로 전환).

- **restic은 이 저장소에 첫 도입**이다 (grep 실측 0건). NixOS의
  `services.restic.backups` 모듈 사용 — `[UNVERIFIED]` 정확한 옵션 스키마
  (`repository`, `environmentFile`, `passwordFile`, `paths`, `timerConfig`,
  `pruneOpts` 등)는 착수 시 `nixos option` 검색 또는
  <https://search.nixos.org/options?query=services.restic>으로 확정한다.
- **1Password → 호스트 시크릿 주입 관례**: 이 호스트는 opnix가
  `OP_SERVICE_ACCOUNT_TOKEN`으로 `op://` reference를 materialize한다.
  exemplar: `modules/nixos/programs/opnix/default.nix`를 읽고 기존 항목
  (예: github-pat)이 어떻게 선언·소비되는지 그대로 따른다.
- R2는 S3 호환 API — restic의 `s3:` repository 형식 + `AWS_ACCESS_KEY_ID`/
  `AWS_SECRET_ACCESS_KEY` env로 접속한다. `[UNVERIFIED]` R2 엔드포인트 URL
  형식(`https://<account-id>.r2.cloudflarestorage.com/<bucket>`)은 운영자
  사전 준비 산출물로 확정.
- 알림 관례: 실패 시 Pushover — restic 모듈이 자체 알림이 없으면 systemd
  `OnFailure=` 유닛 또는 wrapper로 기존 `send_notification` 관례에 연결
  (exemplar: 기존 backup 모듈들).

## 운영자 사전 준비 (executor 착수 전 — 미완이면 STOP)

1. Cloudflare R2에 버킷 생성 (예: `greenhead-backup`) + S3 API 토큰
   (Access Key ID / Secret) 발급.
2. 1Password에 항목 생성: R2 access key/secret/endpoint + restic repository
   password (신규 생성 — **이 password를 잃으면 백업 전체를 복호화할 수 없다**).
3. opnix가 접근하는 vault에 위 항목 배치 (기존 opnix vault 정책 —
   `managing-secrets` 스킬의 라우팅 규칙 참조).
4. 완료 후 executor에게 1Password 항목의 `op://` reference 경로들을 전달.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Nix 평가 | `bash tests/run-eval-tests.sh` | 통과 |
| Flake | `nix flake check --no-build --all-systems` | exit 0 |
| restic 옵션 확정 | search.nixos.org 또는 `nix eval` 로컬 조회 | 옵션 스키마 확보 |
| 통합 | `bash tests/run-all-tests.sh` | 전부 통과/SKIP |

`nrs` + `restic init` + 첫 백업 + 복원 테스트는 운영자 후속.

## Scope

**In scope**:
- `modules/nixos/programs/offsite-backup.nix` (신규 — services.restic.backups 선언 + OnFailure 알림)
- `modules/nixos/options/homeserver.nix` (`offsiteBackup` 옵션 블록)
- `modules/nixos/configuration.nix` (활성화)
- opnix 선언 파일 (R2 자격증명/repo password materialize — 기존 opnix 패턴 위치에)
- `libraries/constants.nix` (필요 시 — R2 계정성 상수는 시크릿이므로 constants가
  아니라 1Password/opnix 경유. constants에는 비밀 아닌 것만)

**Out of scope** (do NOT touch):
- Immich 원본 105G의 오프사이트 전송 — 이 plan의 운영 안정 후 별도 판단
  (016 계층 설계).
- 기존 로컬 백업 모듈들의 동작 변경.
- R2 계정/버킷/토큰 생성 — 운영자 사전 준비.
- **시크릿 값을 리포에 커밋하는 모든 형태** — op:// reference와 materialized
  파일 경로만 코드에 나타난다.

## Git workflow

- Branch: `advisor/020-offsite-restic-r2`
- Commit 예: `feat(backup): 소용량 데이터 restic→R2 일일 오프사이트 백업`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 사전 준비 확인 + restic 옵션 스키마 확정

운영자 사전 준비 완료(op:// reference 경로 전달받음)를 확인한다. 미완이면
STOP. `services.restic.backups`의 옵션 스키마를 공식 소스로 확정하고 사용할
옵션 목록을 작업 노트에 기록한다.

**Verify**: 옵션 목록에 repository/passwordFile/environmentFile/paths/
timerConfig/pruneOpts 상당이 확정됨.

### Step 2: opnix로 자격증명 materialize 배선

기존 opnix 선언(exemplar: `modules/nixos/programs/opnix/default.nix`의 기존
항목)을 따라 R2 access key/secret/endpoint와 restic repo password를 호스트
파일로 materialize한다. 파일 퍼미션은 기존 항목과 동일 수준(root 전용).

**Verify**: `bash tests/run-eval-tests.sh` → 통과 (선언 평가 수준)

### Step 3: restic backup 선언 작성

`offsite-backup.nix`:

- `services.restic.backups.offsite = { repository = "s3:<R2 endpoint>/<bucket>";
  passwordFile = <opnix materialized>; environmentFile = <AWS_* env 파일>;
  paths = [ 위 대상 4경로 ]; timerConfig = { OnCalendar = cfg.backupTime;
  기본 "*-*-* 06:30:00" (로컬 백업들이 끝난 후); };
  pruneOpts = [ "--keep-daily 14" "--keep-weekly 8" "--keep-monthly 6" ]; }`
  — 정확한 속성명은 Step 1에서 확정한 스키마를 따른다.
- 첫 실행 전 `restic init`이 필요하면 모듈의 `initialize` 옵션(존재 시) 사용,
  없으면 운영자 후속 절차에 명령을 기재.
- 실패 알림: systemd `OnFailure=` → Pushover 알림 유닛 (기존
  `send_notification` 관례 재사용 — exemplar 확인).
- Karakeep 라이브/산출물 선택과 Uptime Kuma 라이브 포함 결정을 코드 주석으로
  남긴다 (Current state의 주의 참조).

**Verify**: `nixfmt --check` + `bash tests/run-eval-tests.sh` +
`nix flake check --no-build --all-systems` → 전부 통과

### Step 4: 옵션/활성화 배선 + 전체 게이트

`homeserver.nix`에 `offsiteBackup` 블록(enable/backupTime), import 배선,
`configuration.nix` 활성화.

**Verify**: `bash tests/run-all-tests.sh` → 전부 통과/SKIP

## Test plan

- eval 수준 게이트가 주 검증 (신규 모듈이 평가·배선되는지).
- 실경로(restic init → 첫 백업 → `restic snapshots` 확인 → **샘플 복원 1건**)는
  운영자 후속 절차로 최종 보고에 명시 — 특히 샘플 복원은 016 드릴 B의 "2차
  사본" 갭을 메우는 첫 실증이다.

## Done criteria

- [ ] `grep -rn "services.restic" modules/nixos/` → 1건 이상 (선언 존재)
- [ ] `grep -rn "offsiteBackup" modules/nixos/ | wc -l` ≥ 3 (옵션/모듈/활성화)
- [ ] 시크릿 값이 diff에 없음 (op:// reference와 파일 경로만 —
  `git diff | grep -iE 'secret|key' `를 사람이 검토)
- [ ] `bash tests/run-all-tests.sh` → exit 0
- [ ] `nix flake check --no-build --all-systems` → exit 0
- [ ] 최종 보고에 운영자 후속 명시: `nrs` → (필요 시) `restic init` → 타이머
  수동 1회 실행 → `restic snapshots` 확인 → 샘플 파일 1건 복원·대조 →
  Pushover 실패 경로 1회 유발 테스트(잘못된 자격증명 등으로 — 선택)
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

- 운영자 사전 준비(R2 버킷/토큰/1Password 항목/op:// 경로)가 미완이다.
- `services.restic.backups` 옵션 스키마를 공식 소스로 확정할 수 없다 —
  추측으로 선언을 쓰지 말 것.
- opnix 기존 패턴이 이 유형의 시크릿(env 파일 형태)을 지원하지 않는 구조다 —
  대안 설계를 발명하지 말고 구조를 보고.
- 백업 대상 경로 중 실측과 다른 것이 있다 (016 인벤토리와 대조).

## Maintenance notes

- **restic repo password는 1Password가 유일한 SSOT** — 호스트 소실 시에도
  1Password에서 복구 가능해야 백업이 의미 있다. 절대 리포/호스트에만 존재하게
  두지 말 것 (016 open question 2의 결정 사항).
- SA token 90일 rotation(기존 opnix 운용 정책)이 이 백업의 가용성에도 영향 —
  rotation 실패 시 백업도 멈춘다. 기존 opnix-rotate 알림이 이를 커버하는지
  리뷰어가 확인.
- 사진 원본(plan 019의 HDD 미러)의 오프사이트 승격은 이 plan의 운영 실적
  (전송량/비용/안정성) 확인 후 별도 plan으로 — R2 비용은 용량 과금이므로
  105G 승격 전 요금 확인 (`[UNVERIFIED]` 시점 요금).
- #917 실경로 검증(runbook 작업 C)이 uptime-kuma 백업 산출물을 만들기 시작하면
  라이브 SQLite 직접 백업을 그 산출물로 전환할 것 (Current state 주의 참조).
