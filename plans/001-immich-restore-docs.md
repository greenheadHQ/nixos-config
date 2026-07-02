# Plan 001: Immich DB 재해복구 문서를 실제 백업 이원 구조에 맞게 정정한다

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- .claude/skills/running-containers/references/immich-update.md README.md modules/nixos/programs/docker/immich-backup.nix modules/nixos/programs/immich-update/files/update-script.sh`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: docs
- **Planned at**: commit `fb2a8aa6`, 2026-07-02

## Why this matters

Immich(사진 서버)의 백업은 두 계층으로 갈라져 있는데, 문서화된 유일한 복원 절차는
**재해 시 소멸하는 쪽 백업만** 다룬다. disko 재설치는 SSD(`/dev/nvme0n1`)를
포맷하므로(HDD `/dev/sda`는 보존 — `hosts/greenhead-minipc/disko.nix:3-4`),
그 순간 살아남는 것은 HDD의 `pg_dump -Fc` 커스텀 포맷 `.dump` 파일뿐이다.
그런데 이 `.dump`는 (1) 복원 문서가 없고, (2) 기존 문서의 `gunzip | psql`
명령을 그대로 쓰면 실패한다(`-Fc` 포맷은 gzip도 평문 SQL도 아니고 `pg_restore`가
필요하다). 실제 재해복구 순간에 "가진 백업은 복원법을 모르고, 복원법 있는 백업은
이미 사라진" 상태가 된다. 추가로 README가 "각 서비스별 백업 서브시스템 포함"이라고
약속하지만 백업 모듈은 Immich/Karakeep 두 개뿐이라(Copyparty/Uptime Kuma 없음)
백업 커버리지에 대한 오신을 만든다. 이 plan은 문서만 고친다.

## Current state

관련 파일과 역할:

- `.claude/skills/running-containers/references/immich-update.md` — 수정 대상 1.
  "## DB 백업/복원" 섹션(82행 부근)에 SSD 사전백업만 문서화되어 있다.
- `README.md` — 수정 대상 2. 65행의 백업 약속 문구.
- `modules/nixos/programs/docker/immich-backup.nix` — **읽기 전용 근거**. HDD 일일 백업의 SSOT.
- `modules/nixos/programs/immich-update/files/update-script.sh` — **읽기 전용 근거**. SSD 사전백업의 SSOT.
- `libraries/constants.nix:43-45` — 경로 SSOT: `dockerData = "/var/lib/docker-data"`(SSD),
  `mediaData = "/mnt/data"`(HDD).

**백업 계층 1 — HDD 일일 백업 (재설치 생존)**, `immich-backup.nix`에서:

```nix
# immich-backup.nix:18
backupDir = "${mediaData}/backups/immich";   # mediaData = /mnt/data (HDD)
```

```bash
# immich-backup.nix backupScript 본문 중 (74-77행 부근)
# 3. pg_dump -Fc (커스텀 포맷, 내장 압축)
podman exec immich-postgres pg_dump -Fc -U immich immich > "$TMP_FILE"
# ...
# 4. 무결성 검증 (pg_restore --list: TOC 파싱만, 데이터 복원 없음)
podman exec -i immich-postgres pg_restore --list < "$TMP_FILE" > /dev/null
```

파일명 패턴은 `immich-db-$TIMESTAMP.dump`(`TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)`),
보관 기간은 `homeserver.immichBackup.retentionDays`(기본 30,
`modules/nixos/options/homeserver.nix:28-31`).

**백업 계층 2 — SSD 업데이트 직전 백업 (재설치 시 소멸)**, `update-script.sh:101-104`:

```bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_FILE="$BACKUP_DIR/backup-${TIMESTAMP}.sql.gz"

podman exec immich-postgres pg_dump -U immich immich | gzip > "$BACKUP_FILE"
```

목적지는 `/var/lib/immich-update/backups/`(SSD), 보관 7일.

**기존 문서의 복원 절차** — `.claude/skills/running-containers/references/immich-update.md`
"### 수동 복원"(93-105행), SSD `.sql.gz`만 다룬다:

```bash
# 1. Immich 서비스 중지
sudo systemctl stop podman-immich-server.service

# 2. 백업 복원
gunzip -c /var/lib/immich-update/backups/backup-YYYYMMDD-HHMMSS.sql.gz | \
  sudo podman exec -i immich-postgres psql -U immich -d immich

# 3. 서비스 재시작
sudo systemctl start podman-immich-server.service
```

**README의 과잉 약속** — `README.md:65`:

```
**서비스 카테고리**: Immich(사진), Karakeep(웹 아카이버/북마크), Copyparty(파일 서버), Uptime Kuma(모니터링), Caddy(HTTPS 리버스 프록시). 각 서비스별 백업/업데이트 체크/알림 서브시스템 포함.
```

실태: 백업 모듈은 `immich-backup.nix`, `karakeep-backup.nix` 둘뿐이다
(`ls modules/nixos/programs/docker/`로 확인 가능). 업데이트 체크/알림은 4개 서비스
모두 존재한다.

**저장소 문서 컨벤션** (반드시 준수):

- 문서는 한국어. 기존 `immich-update.md`의 헤딩 스타일(`##`/`###`)과 코드블록
  형식을 그대로 따른다.
- **헤딩·본문에 개수/줄 수 하드코딩 금지** — 이 저장소는 "N개 파일" 같은 fragile
  수치 표현을 안티패턴으로 본다. 보관 기간 같은 설정값은 "기본 30일
  (`homeserver.immichBackup.retentionDays`)"처럼 옵션 경로를 함께 적는다.
- `.claude/skills/` 수정은 pre-commit 훅(`local-skill-noise-check`,
  `ai-skills-consistency`) 대상이다. 내용 수정은 구조 검사와 무관해 통과해야
  정상이다.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 백업 모듈 실태 확인 | `ls modules/nixos/programs/docker/ \| grep backup` | `immich-backup.nix`, `karakeep-backup.nix` 두 줄만 |
| 경로 상수 확인 | `grep -n "mediaData\|dockerData" libraries/constants.nix` | `/mnt/data`, `/var/lib/docker-data` |
| 문서 검증 | 아래 Done criteria의 grep들 | 각 기대값 |
| 커밋 게이트 | `git commit` 시 lefthook pre-commit 자동 실행 | 훅 통과 |

## Scope

**In scope** (수정 가능한 파일):
- `.claude/skills/running-containers/references/immich-update.md`
- `README.md` (65행의 한 문장만)

**Out of scope** (관련해 보여도 건드리지 말 것):
- `modules/nixos/programs/docker/immich-backup.nix`, `update-script.sh` 등 코드 일절 —
  이 plan은 문서 정정이다. 백업 동작 변경은 별도 plan(004)이 다룬다.
- `.agents/skills/` — `.claude/skills/`로의 심링크라 자동 반영된다. 직접 수정 금지.
- Karakeep 백업 복원 문서 신설 — Karakeep 백업(`.db.gz`)은 gunzip으로 자명하게
  복원되므로 이번 범위가 아니다.
- Copyparty/Uptime Kuma 백업 **구현** — 문서는 부재를 정직하게 기술만 한다.
  (백업 자세 전반은 direction 항목으로 별도 관리.)

## Git workflow

- Branch: `advisor/001-immich-restore-docs`
- Commit 메시지: 저장소 컨벤션(conventional commits, 한국어 요약) —
  예: `docs(immich): 재해복구 복원 절차를 백업 이원 구조에 맞게 정정`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: immich-update.md의 "## DB 백업/복원" 섹션을 이원 구조로 재작성

`.claude/skills/running-containers/references/immich-update.md`의
"### 백업 위치"(84행 부근)를 다음 내용으로 확장한다 (형식은 기존 문서 스타일 유지):

1. 두 백업 계층을 구분하는 표 추가. 담을 사실:
   - **일일 백업**: `pg_dump -Fc` 커스텀 포맷 `.dump` /
     `/mnt/data/backups/immich/`(HDD) / 기본 30일
     (`homeserver.immichBackup.retentionDays`) / **disko 재설치 후에도 생존**
     (disko는 NVMe만 포맷 — `hosts/greenhead-minipc/disko.nix`) /
     복원은 `pg_restore` 필요
   - **업데이트 직전 백업**: `pg_dump | gzip` 평문 SQL `.sql.gz` /
     `/var/lib/immich-update/backups/`(SSD) / 7일 / **재설치 시 소멸** /
     복원은 `gunzip | psql`
2. 기존 "### 수동 복원"을 "### 수동 복원 — 업데이트 직전 백업 (`.sql.gz`)"로
   개칭하고 내용은 유지.
3. 새 하위 섹션 "### 재해복구 복원 — 일일 백업 (`.dump`)"을 추가. 담을 절차:

```bash
# 0. 복원 전 TOC 확인 (읽기 전용 — 파일이 유효한 pg_dump 커스텀 포맷인지)
sudo podman exec -i immich-postgres pg_restore --list \
  < /mnt/data/backups/immich/immich-db-YYYY-MM-DD_HHMMSS.dump | head

# 1. Immich 서비스 중지 (DB 쓰기 차단)
sudo systemctl stop podman-immich-server.service podman-immich-machine-learning.service

# 2. 복원 (--clean --if-exists: 기존 오브젝트 드롭 후 재생성)
sudo podman exec -i immich-postgres pg_restore -U immich -d immich --clean --if-exists \
  < /mnt/data/backups/immich/immich-db-YYYY-MM-DD_HHMMSS.dump

# 3. 서비스 재시작
sudo systemctl start podman-immich-server.service podman-immich-machine-learning.service
```

   절차 앞에 한 줄 경고를 넣는다: "`gunzip`/`psql`로는 `.dump`를 복원할 수 없다
   (pg_dump 커스텀 포맷)."

**Verify**:
`grep -c "pg_restore" .claude/skills/running-containers/references/immich-update.md`
→ `3` 이상 (TOC 확인 + 복원 명령 + 경고/표 언급)

### Step 2: README.md 65행의 백업 약속 문구를 실태에 맞게 정정

`README.md:65`의 마지막 문장
"각 서비스별 백업/업데이트 체크/알림 서브시스템 포함."을 다음 취지로 교체한다
(정확한 표현은 문장이 자연스럽게):

> 전 서비스에 업데이트 체크/알림 서브시스템, Immich·Karakeep에는 백업 서브시스템 포함.

**Verify**: `grep -n "각 서비스별 백업" README.md` → 출력 없음 (exit 1)

### Step 3: 최종 검증 및 커밋

**Verify**:
- `git diff --stat` → 변경 파일이 정확히 2개
  (`.claude/skills/running-containers/references/immich-update.md`, `README.md`)
- `git add -A && git commit -m "docs(immich): ..."` → lefthook pre-commit 통과, 커밋 성공

## Test plan

문서 변경이므로 신규 테스트는 없다. 검증은 Done criteria의 grep과 lefthook
pre-commit 훅(local-skill-noise-check 등) 통과로 갈음한다.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "pg_restore -U immich" .claude/skills/running-containers/references/immich-update.md` → 1건 이상
- [ ] `grep -n "/mnt/data/backups/immich" .claude/skills/running-containers/references/immich-update.md` → 1건 이상
- [ ] `grep -n "각 서비스별 백업" README.md` → 0건 (exit 1)
- [ ] `grep -n "gunzip" .claude/skills/running-containers/references/immich-update.md` → 여전히 존재 (기존 `.sql.gz` 절차 보존)
- [ ] `git status --porcelain`에 in-scope 외 파일 없음
- [ ] 커밋이 lefthook pre-commit을 통과 (우회 플래그 없이)
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

Stop and report back (do not improvise) if:

- "Current state"의 발췌와 실제 코드가 다르다 (특히 `immich-backup.nix`의
  `pg_dump -Fc`나 `backupDir`가 변경된 경우 — 문서가 아니라 전제가 바뀐 것).
- `immich-update.md`에 이미 `.dump`/`pg_restore` 복원 절차가 존재한다
  (다른 세션이 먼저 고쳤을 수 있음 — 중복 작성 금지).
- pre-commit 훅이 스킬 문서 수정을 차단한다 (`ai-skills-consistency` 구조 검사
  실패 등) — 우회(`--no-verify`, `SKIP_AI_SKILL_CHECK=1`) 금지, 원인을 보고.

## Maintenance notes

- 백업 스크립트의 포맷/경로가 바뀌면 이 문서도 함께 갱신해야 한다 — plan 004
  (백업 스크립트 추출+테스트)가 진행되면 파일 위치 인용이 바뀔 수 있으니 리뷰 시
  교차 확인.
- `pg_restore --clean --if-exists`는 문서 초안 수준의 표준 절차다. 실제 복원
  드릴(운영자 유지보수 창)에서 검증되면 그 결과로 문서를 다듬는 후속이 자연스럽다
  — direction 항목 "백업/복구 자세 spike"와 연결된다.
- 리뷰어는 문서의 경로/옵션명이 `constants.nix`·`homeserver.nix`의 현재 값과
  일치하는지 본다.
