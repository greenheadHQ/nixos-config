# Findings 016: 홈서버 백업/복구 자세 — same-disk 탈피 최소안 + 복원 드릴

> **성격**: 설계(spike) 보고서. 코드 변경 없음. 구현은 이 보고서 승인 후 별도 plan.
> **조사 일자**: 2026-07-02 (실 호스트 `greenhead-minipc`에서 read-only 실측 포함)
> **기준 커밋**: `fb2a8aa6`
> **이슈**: https://github.com/greenheadHQ/nixos-config/issues/953
> **에픽 방향 근거**: #912 본문 "향후 고려 — 홈서버 데이터 백업/복구 자세"

## 품질 게이트 표기 규약

- 모든 경로 주장은 `.nix` 파일:라인 인용으로 뒷받침한다.
- 디스크 사용량은 `2026-07-02` 실측(`du -sh`/`df -h`, `greenhead-minipc`)이며, 변동값이다.
- 외부 도구 주장은 출처 URL을 병기하고, 확인하지 못한 것은 `[UNVERIFIED]`로 표기한다.
- **Drift 인지**: `git diff fb2a8aa6..HEAD`에 `karakeep-log-monitor/files/log-monitor.sh` 2줄 변경이 있으나 이는 plan 003(mktemp 원자성 수정) 머지분으로, 본 보고서의 전제(백업 모듈 목록·목적지·disko·constants)와 무관하다.

---

## 요약 (TL;DR)

현재 백업 자세의 실제 약점은 plan 작성 시 추정(#912, plan 016 Current state)보다 **한 단계 더 심각**하다:

1. **Immich 원본 사진/영상(약 105G)은 HDD가 아니라 SSD에 있다.** `disko`가 재설치 시 SSD(NVMe)를 포맷하므로, 재해복구 시 **DB 덤프(HDD, 생존)는 남고 원본 사진(SSD)은 소멸**한다 — 복원해도 자산 없는 껍데기 DB만 남는 최악 조합. 원본 사진에 대한 **어떤 백업도 존재하지 않는다.**
2. Karakeep 백업만이 문자 그대로 "원본과 백업이 같은 HDD"(single-disk failure에 동시 취약)다. Immich DB 덤프는 SSD→HDD로 이미 디스크를 건넌다(부분 완화).
3. Copyparty 사용자 파일(= `/mnt/data` 전체), Karakeep 아카이브 자산, Uptime Kuma SQLite에는 백업 모듈이 없다.

→ 최우선 시정은 "same-disk 탈피"가 아니라 **"원본 사진이 disko-포맷 대상 SSD에만 존재하는 구조를 먼저 깨는 것"**이다. 그 위에 작은 데이터(<3G)의 오프사이트 계층을 얹는다.

---

## Step 1: 백업 대상 인벤토리

각 데이터의 위치·디스크·규모·현재 백업 여부·재설치(disko) 생존 여부·소실 피해.
디스크 배치 근거: `dockerData = /var/lib/docker-data`(SSD), `mediaData = /mnt/data`(HDD) — `libraries/constants.nix:43-44`. HDD 마운트는 `hosts/greenhead-minipc/default.nix:36-37`(`/dev/disk/by-uuid/3f1111d9-…` → `/mnt/data`). disko는 NVMe(`/dev/nvme0n1`)만 포맷하고 HDD(`/dev/sda`)는 보존 — `hosts/greenhead-minipc/disko.nix:16-17,48-49`.

df 실측(2026-07-02): HDD `/dev/sda1` 1.8T 중 619G 사용 / SSD `/dev/nvme0n1p3` 461G 중 154G 사용.

| # | 데이터 | 컨테이너 경로 → 호스트 경로 (근거) | 디스크 | 크기(2026-07-02) | 현재 백업 | 백업 목적지 | disko 재설치 시 | 소실 피해 |
|---|--------|-----------------------------------|--------|------------------|-----------|-------------|-----------------|-----------|
| 1 | **Immich 원본 사진/영상** | `/usr/src/app/upload/upload` → `${dockerData}/immich/upload-cache` (`immich.nix:155`; `constants.immichUploadCache`) | **SSD** | **105G** | **없음** | — | **소멸** | **전체 원본 영구 소실** (복구 불가) |
| 2 | Immich PostgreSQL DB | 컨테이너 `immich-postgres`, 데이터 vol `${dockerData}/immich/postgres` (`immich.nix:94`) | SSD | 413M | daily `pg_dump -Fc` `.dump` (`immich-backup.nix:76,18`) | `/mnt/data/backups/immich` (HDD) (`immich-backup.nix:18`) | 원본 vol은 소멸·백업(HDD)은 생존 | 앨범/얼굴/메타 (덤프로 복원 가능) |
| 3 | Immich 파생물 (thumbs/encoded-video/profile/자체backups) | `/usr/src/app/upload` → `${mediaData}/immich/photos` (`immich.nix:154`) | HDD | 11G (thumbs 2.7G · encoded-video 6.7G · Immich자체backups 985M) | 없음 | — | 생존 | 재생성 가능(원본 존재 시). 원본 없으면 유일 잔존 프리뷰 |
| 4 | Karakeep SQLite (db.db + queue.db) | `${mediaData}/karakeep` (`karakeep.nix:141`; `karakeep-singlefile-bridge.nix:65-66`) | HDD | (아래 1.1G에 포함) | daily `sqlite .backup`→`.gz` (`karakeep-backup.nix:63-65,18`) | `/mnt/data/backups/karakeep` (HDD) (`karakeep-backup.nix:18`) | 둘 다 HDD, 생존. **단 single-disk failure에 원본·백업 동시 취약** | 북마크 메타 소실 |
| 5 | Karakeep 아카이브 자산 + Meilisearch | `${mediaData}/karakeep`, `${mediaData}/karakeep/meilisearch` (`karakeep.nix:77,210`) | HDD | (1.1G 총계에 포함) | **없음** (`karakeep-backup.nix:3` 주석: "assets는 같은 HDD라 별도 백업 불필요") | — | 생존 | 저장된 웹 스냅샷/검색 인덱스 소실 |
| 6 | Karakeep archive-fallback | `${mediaData}/archive-fallback` (`karakeep.nix:78`; `karakeep-fallback-sync.nix:53,67`) | HDD | 282M | 없음 | — | 생존 | fallback 스냅샷 소실 |
| 7 | **Copyparty 사용자 파일** | `/data` → `${mediaData}` **전체** (`copyparty.nix:90`) | HDD | = `/mnt/data` 전체(619G) | **없음** | — | 생존 | 업로드 파일 소실 (HDD 장애 시) |
| 8 | Copyparty 세션/hists/config | `${dockerData}/copyparty/{sessions,hists,config}` (`copyparty.nix:88-89,17`) | SSD | 9.8M | 없음 | — | 소멸 | 세션·설정 소실(재생성 용이, config는 agenix에서 재주입) |
| 9 | **Uptime Kuma SQLite** | `/app/data` → `${dockerData}/uptime-kuma/data` (`uptime-kuma.nix:27,19`) | SSD | 19M | **없음** | — | **소멸** | 모니터 정의·상태 이력 소실 |
| 10 | agenix 시크릿 | 리포 `secrets/*.age` (예 `copyparty.nix:48`, `karakeep-backup.nix:101`) | git 원격 | — | GitHub(암호화 커밋) | — | 파일 자체 생존 | **제외** (아래 근거·단서) |
| 11 | 설정(이 리포) | Nix 소스 = git | git 원격 | — | GitHub | — | 생존 | **제외** (원격 존재) |

### 제외 항목 근거

- **#11 설정**: GitHub 원격에 push되어 있어 호스트 소실과 무관하게 복구 가능. 별도 데이터 백업 불필요.
- **#10 agenix 시크릿**: `.age`는 암호화된 채 리포에 커밋되어 원격에 존재. **단, 복호화 identity에 단서가 있다** — 부팅 의존 시크릿(SA token 등)의 agenix recipient는 host key `/etc/ssh/ssh_host_ed25519_key`(`constants.agenixHostIdentityKey`)이며, 이 host key는 리포에 없고 SSD(`/`)에 있어 **재설치 시 소멸**한다. 사용자 로그인 키도 recipient이므로(`secrets/secrets.nix`) 사용자 키를 보유한 머신에서 **재암호화로 복구 가능**하지만, "리포에 있으니 안심"은 부분적으로만 참이다. → 시크릿 데이터는 백업 대상에서 제외하되, **복원 드릴에 "새 host key로 재암호화 절차 확인"을 포함**하는 것으로 갈음한다.

### plan 016 Current state와의 차이(중요)

- plan은 "Immich 원본 사진 자체(`mediaData` 아래)"로 기술했으나, **실측 결과 원본은 `dockerData`(SSD)의 `upload-cache`에 있고 `mediaData`(HDD)에는 파생물만 있다.** `upload-cache` 디렉토리 최상위는 Immich user-id 단일 디렉토리(`294ae9b0-…`)로, `/usr/src/app/upload/upload/<userId>/`에 원본이 누적된다. 이는 Immich 기본 동작(스토리지 템플릿 미적용 시 원본이 `upload/`에 영속)과 일치한다 — Immich 문서 근거: https://docs.immich.app/administration/backup-and-restore/ , https://docs.immich.app/administration/storage-template/ . 상수·주석의 이름("upload-cache", "immich 업로드 캐시")은 실제 역할(원본 라이브러리 대부분)과 어긋나 오해 소지가 있다.
- 결과적으로 위험도가 상향된다: 원본이 **재설치 시 보존되는 HDD가 아니라 포맷되는 SSD**에만 있다.

---

## Step 2: 2차 사본 경로 후보 (최소 운영 부담 기준)

전제: 현재 백업 도구(restic/rclone/borg/kopia)는 리포 어디에도 없음(2026-07-02 grep 확인). 기존 인프라 재사용 우선순위 — Tailscale(`modules/nixos/programs/tailscale.nix`), systemd 타이머 + Pushover 알림 관례(`service-lib.sh`의 `send_notification`; 예 `immich-backup.nix:47`, `karakeep-backup.nix:42`), `homeserver.*` mkOption(`modules/nixos/options/homeserver.nix`), constants 경로.

### 후보 ① 외장 디스크 rsync (수동 or systemd 타이머)

외장 USB HDD를 MiniPC에 연결해 rsync로 주기 복사. 원본 사진 105G + 파생 11G ≈ 120G로, 저렴한 외장 1개면 충분하고 대역폭 병목이 없다.
- **운영 부담**: 상시 연결 + 타이머면 설치 후 거의 무인. 콜드 스토리지(월 1회 물리 연결)면 **월 1회 물리 작업**.
- **트레이드오프**: 오프사이트 아님(화재/도난에 원본과 동시 소실). single-disk failure·disko 재설치·실수 삭제로부터는 보호. 암호화 필요 시 LUKS.
- **적합 대상**: 대용량 사진 원본(#1)의 **즉시·저비용 1차 방어선**.

### 후보 ② 원격 restic (오프사이트, 암호화)

restic으로 암호화·중복제거·증분 백업을 원격 저장소(SFTP/S3/B2/rclone backend)에 전송. 공식: https://restic.net/ , 문서: https://restic.readthedocs.io/ (restic = 증분·중복제거·클라이언트측 암호화 백업). NixOS는 `services.restic.backups` 모듈을 제공한다(옵션 검색: https://search.nixos.org/options?query=services.restic — 정확한 옵션 스키마는 구현 시점에 재확인. `[UNVERIFIED: 이 저장소에서 빌드 검증한 바 없음]`).
- **Tailscale 재사용**: 오프사이트 대상이 Tailscale 노드(예: 다른 집의 소형 서버/NAS)라면 SFTP 백엔드로 기존 VPN을 그대로 사용 — 신규 포트 개방 불필요.
- **운영 부담**: 초기 설정 후 **거의 무인**(타이머 + Pushover 알림). retention은 restic `forget --keep-*`로 자동.
- **트레이드오프**: 원격 저장소 가용성·repo password 관리 필요. 105G 초기 시드는 업로드 대역폭 소요(증분은 작음).
- **적합 대상**: 작은 데이터(#2 DB덤프, #4/#5 Karakeep, #9 Uptime Kuma, 설정) — **매일 오프사이트**.

### 후보 ③ 클라우드 객체 스토리지

Backblaze B2 / Cloudflare R2 / AWS S3 등에 restic(위) 또는 rclone(https://rclone.org/ , crypt 백엔드로 클라이언트측 암호화)로 전송.
- **비용**: B2는 저장 용량 과금(대략 $6/TB/월 수준으로 알려져 있으나 `[UNVERIFIED: 가격은 시점·리전별 변동, 계약 전 공식 페이지 확인 필요]`). R2는 egress 무료가 강점 `[UNVERIFIED: 요금 조건 확인 필요]`.
- **운영 부담**: 무인. 계정·결제·API 키·수명주기 정책 관리.
- **트레이드오프**: 지속 비용, 복원 시 egress 시간/비용. 105G 사진 전체를 클라우드로 두면 월 비용·초기 업로드가 부담.

### 계층 분리 (필수 포함) — "작은 것부터 오프사이트"

| 계층 | 대상(크기) | 권장 매체 | 주기 |
|------|-----------|-----------|------|
| 작은/고가치 | DB 덤프 + Karakeep + Uptime Kuma + 설정 (< 약 3G) | 오프사이트(후보 ②/③) | 매일 |
| 대용량 | Immich 원본 사진(105G) | 로컬 2차 매체(후보 ①)로 시작 → 대역폭 확보 후 오프사이트 승격 | 월 1회 → (승격 시) 증분 |

근거: 작은 데이터는 오프사이트 비용·대역폭이 미미해 즉시 3-2-1에 근접시킬 수 있고, 사진 원본은 로컬 2차 매체로 **단일 사건(디스크 장애·재설치) 취약성부터** 제거한 뒤 오프사이트를 논한다.

---

## Step 3: 복원 드릴 정의

주기: **분기 1회 권장(최소 반기)**. 각 단계에 성공 기준을 둔다.

### 드릴 A — DB 덤프 복원 (plan 001 문서 절차 재사용)

`.claude/skills/running-containers/references/immich-update.md`의 "재해복구 복원 — 일일 백업 (`.dump`)" 절 절차를 **그대로 재사용**한다(`pg_restore --list`로 TOC 확인 → 서비스 중지 → `pg_restore --clean --if-exists` → 재시작).
- **어디서**: **임시 환경 우선**(운영 DB 파괴 회피). 별도 임시 postgres 인스턴스 또는 임시 데이터베이스명으로 복원. 운영 호스트에서 직접 복원은 실제 재해 상황에서만.
- **성공 기준(각 단계)**:
  1. `pg_restore --list < <최근 .dump>`가 유효 TOC를 출력(파일이 유효한 커스텀 포맷). — 실패 시 즉시 중단.
  2. 임시 DB로 복원이 exit 0.
  3. 복원 DB에 주요 테이블(예 `assets`, `users`) 존재 + row count > 0.
- **소요**: ~15분.

### 드릴 B — 파일 샘플 복원

2차 사본(외장/원격)에서 **무작위 원본 N개(예 5개)**를 복원해 원본과 대조.
- **성공 기준**: 복원 파일의 `sha256`이 소스와 일치.
- **소요**: ~10분.

### 드릴 C — 시크릿 재암호화 확인 (경량)

새 host key 상황을 모사해, 사용자 키 보유 머신에서 `.age` 재암호화 절차(managing-secrets 스킬)가 동작함을 1회 확인.
- **성공 기준**: 재암호화 후 대상 시크릿이 정상 복호화(`/run/agenix` 마운트 or 수동 `age -d`).
- **소요**: ~5분.

### 재개 트리거 & 유지보수 창 묶음 권고

- **다음 유지보수 창에서 드릴 1회차 실행을 본 spike의 재개 트리거로 삼는다.**
- 이슈 #917(update-script 통합 실경로 검증), plan 005(Immich DB `pgvecto-rs` 마이그레이션)와 **같은 창에 묶되 순서는 드릴 먼저**: 마이그레이션이 DB를 건드리기 전에, 현재 백업으로 실제 복원이 되는지 확인해야 안전망이 유효하다. plan 004(백업 스크립트 특성화 테스트)가 선행되어 있으면 구현 회귀 안전망이 된다.

---

## Step 4: 권고안 + Open questions

### 추천 (최소 운영 부담)

**2단계로 착수한다.**

- **(A) 즉시 최소안 — 가장 큰 구멍부터**: Immich 원본(SSD `upload-cache` 105G)을 **최소한 HDD로, 이상적으로는 외장 디스크(후보 ①)로 복제**해 "원본이 disko-포맷 SSD에만 존재"하는 구조를 깬다. 이것이 현 자세의 **단일 최우선 시정**이다. (부수적으로, 구현 plan에서 원본 저장 위치 자체를 HDD로 옮기거나 disko에 HDD를 포함할지도 함께 판단한다.)
- **(B) 오프사이트 계층**: 작은 데이터(#2 DB덤프 + #4/#5 Karakeep + #9 Uptime Kuma + 설정, <약 3G)를 **restic으로 원격 1곳(Tailscale SFTP 우선, 없으면 B2/R2)에 매일** 전송한다. 기존 systemd 타이머 + Pushover + `homeserver.*` 옵션 + constants 경로 관례를 따른다. 사진 원본은 (A)의 외장 디스크로 시작해 대역폭·예산이 서면 오프사이트로 승격한다.

한 줄 요약: **"작은 것은 매일 오프사이트(restic), 사진 원본은 먼저 외장 디스크로 단일-사건 취약성 제거."**

### Open questions (결정 필요)

1. **오프사이트 대상**: Tailscale로 접근 가능한 2차 노드(예: 다른 위치의 소형 서버/NAS)가 있는가? 없으면 클라우드(B2/R2 등) 계정을 만든다.
2. **암호화 키 보관**: restic repo password/rclone crypt 키를 어디에 두는가(1Password vault? agenix?). **이 키가 호스트와 함께 소실되면 백업 자체를 복호화할 수 없다** → 반드시 오프-호스트(1Password 등)에 별도 보관.
3. **예산**: 클라우드 스토리지 월 비용 허용 범위(사진 원본까지 클라우드로 둘지 결정에 직결).
4. **사진 원본 위치 재배치 여부**: `upload-cache`(SSD)를 HDD로 이전할지, disko에 HDD를 포함할지, 아니면 위치는 두고 백업만 추가할지 — 구현 plan의 핵심 결정.
5. **Immich 스토리지 템플릿**: 활성화해 원본을 `library/`로 정리하면 백업 대상 경로가 안정화되나, 대규모 재배치가 발생 — 마이그레이션 창(plan 005)과의 조율 필요.

---

## 이 보고서 이후 구현 plan에 대한 제약(유지보수 노트)

- 구현은 저장소 관례를 따른다: systemd 타이머 + Pushover 알림 + `homeserver.*` mkOption + constants 경로.
- plan 004(백업 스크립트 특성화 테스트)가 먼저 있으면 구현 단계 회귀 안전망이 된다.
- 복원 드릴 정의는 plan 001의 `.dump` 복원 문서와 정합해야 하며(재사용), plan 005 마이그레이션·#917 실경로 검증과 같은 유지보수 창에 드릴을 먼저 배치한다.
