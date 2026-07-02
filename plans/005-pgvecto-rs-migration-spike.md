# Plan 005: Immich DB(pgvecto-rs) 업그레이드 절벽을 조사하고 마이그레이션 절차를 설계한다 (spike)

> **Executor instructions**: 이것은 **조사(spike) plan이다 — 소스 코드를 일절
> 수정하지 않는다**. 산출물은 보고서 파일 하나다. Follow this plan step by
> step. If anything in the "STOP conditions" section occurs, stop and report.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat fb2a8aa6..HEAD -- modules/nixos/programs/docker/immich.nix modules/nixos/programs/immich-update/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M (조사·설계만 — 실제 마이그레이션은 별도, 유지보수 창 필요)
- **Risk**: LOW (읽기 전용 spike)
- **Depends on**: none
- **Category**: migration
- **Planned at**: commit `fb2a8aa6`, 2026-07-02
- **Issue**: https://github.com/greenheadHQ/nixos-config/issues/942

## Why this matters

Immich의 PostgreSQL 컨테이너가 `tensorchord/pgvecto-rs:pg16-v0.2.0`에 고정되어
있다. pgvecto-rs는 상류(tensorchord)가 VectorChord로 대체하며 유지보수를 접는
방향을 공지했고, Immich 상류도 신규 배포에 VectorChord 계열 DB 이미지를
권고한다. 반면 이 저장소의 자동 버전 체크(`immich-update`)는 **Immich 서버
릴리즈만** 추적하고 DB 이미지는 어떤 update 모듈도 추적하지 않는다. 서버는 매주
버전 체크로 계속 올라가는데 DB는 제자리이므로, 어느 Immich 릴리즈에서
pgvecto-rs 지원이 끊기는 순간 **사진 데이터가 담긴 프로덕션 DB가 조용히 기동
실패하는 "보이지 않는 업그레이드 절벽"**이 된다. 그때 가서 급하게 하는 DB
마이그레이션이 가장 위험하다. 지금 절벽의 정확한 위치(버전/시점)와 마이그레이션
절차를 조사해 문서로 박제해 두면, 운영자가 유지보수 창 하나로 계획적으로 넘어갈
수 있다.

## Current state

관련 파일(전부 **읽기 전용**):

- `modules/nixos/programs/docker/immich.nix` — 컨테이너 정의:

```nix
# :91
image = "tensorchord/pgvecto-rs:pg16-v0.2.0";
# :130
image = "ghcr.io/immich-app/immich-machine-learning:v2.6.1";
# :150
image = "ghcr.io/immich-app/immich-server:v2.6.1";
# :115 (참고: 캐시 전용, 영속성 불필요 주석 있음)
image = "redis:7-alpine";
```

- `modules/nixos/programs/immich-update/default.nix` — 버전 체크가
  `immich-app/immich` GitHub 릴리즈만 추적. DB 이미지 추적 없음.
- `modules/nixos/programs/immich-update/files/update-script.sh` — 업데이트
  플로우: 사전 백업(`pg_dump | gzip`) → 2개 이미지(server/ML) pull → 재시작 →
  60-retry 헬스체크. **postgres 이미지는 업데이트 대상이 아니다.**
- `modules/nixos/programs/docker/immich-backup.nix` — HDD 일일 백업
  (`pg_dump -Fc` → `/mnt/data/backups/immich/`, 기본 30일 보관). 마이그레이션
  절차의 롤백 재료.
- DB 데이터 볼륨: `immich.nix`의
  `"${dockerData}/immich/postgres:/var/lib/postgresql/data"`
  (`dockerData = /var/lib/docker-data`, SSD).

**이미 결정된 맥락** (조사 시 존중할 것):

- 이슈 #917(update-script 골격 통합)이 "실제 서비스 업데이트 = 유지보수 창
  필요"로 BLOCKED 상태다. **이 spike의 산출물인 마이그레이션도 같은 종류의
  유지보수 창을 요구하므로, 보고서에 "한 창에서 함께 처리할 후보"로 명시**한다
  (창 하나로: DB 마이그레이션 + 백업 복원 드릴 + #917 실경로 검증).
- 이 저장소의 상수 관리 규칙: 하드코딩 IP/경로/버전성 상수 변경은
  `libraries/constants.nix` 경유 (보고서의 권고안 작성 시 참고).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| 현행 이미지 확인 | `grep -n "image = " modules/nixos/programs/docker/immich.nix` | 위 발췌와 일치 |
| 버전체크 범위 확인 | `grep -rn "GITHUB_REPO\|immich-app" modules/nixos/programs/immich-update/` | 서버 릴리즈만 추적임을 확인 |

웹 조사가 필수다 — WebSearch/WebFetch(또는 동등 도구)가 가용해야 한다.

## Scope

**In scope** (생성 가능한 파일 — 이 하나뿐):
- `plans/005-findings-pgvecto-rs.md` (신규 — 조사 보고서)

**Out of scope** (do NOT touch):
- 소스 코드 일체 — `immich.nix` 이미지 교체 금지, update 모듈 수정 금지.
  실제 마이그레이션은 이 보고서를 근거로 운영자가 결정한 뒤 별도 plan으로.
- `plans/README.md`의 상태 행 갱신 외 다른 plan 파일.

## Git workflow

- Branch: `advisor/005-pgvecto-rs-spike`
- Commit 예: `docs(plans): Immich DB 마이그레이션 spike 보고서`
- Push/PR은 운영자 지시가 있을 때만.

## Steps

### Step 1: 절벽의 위치를 공식 소스로 확정

공식 소스(Immich 공식 문서 https://immich.app/docs, Immich GitHub 릴리즈 노트,
pgvecto-rs/VectorChord GitHub)에서 다음을 확인해 기록한다:

1. 현행 서버 `v2.6.1`의 공식 DB 요구사항 (지원 확장: pgvecto-rs 지원 여부,
   VectorChord 요구 버전).
2. pgvecto-rs 지원이 **제거되는(또는 제거된) Immich 버전**과 공지 링크.
3. Immich 공식 권장 DB 이미지(예: `ghcr.io/immich-app/postgres` 계열)와 그것이
   내장하는 확장.
4. pgvecto-rs `v0.2.0`/pg16에서 출발하는 공식 마이그레이션 경로 (Immich 문서의
   DB 마이그레이션 가이드가 있으면 그 절차 전문 링크 + 요약).

각 항목에 **출처 URL을 병기**한다. 출처가 확인되지 않는 주장은
`[UNVERIFIED]`로 표기한다.

**Verify**: 보고서 초안에 4개 항목 각각 출처 URL이 달려 있다.

### Step 2: 이 배포에 맞춘 마이그레이션 절차 초안 작성

Step 1의 공식 경로를 이 저장소의 실제 배치(위 Current state의 볼륨/백업/서비스
이름)에 대입해 절차 초안을 쓴다. 반드시 포함:

1. 사전 조건: HDD 일일 백업 최신본 확인 + 수동 `pg_dump -Fc` 1회 추가 확보.
2. 서비스 중지 순서(server/ML → postgres), 이미지 교체(`immich.nix` diff 초안
   — 코드 블록으로 보고서에만), 데이터 볼륨 재사용 vs 신규 초기화+복원 중
   공식 권장이 무엇인지.
3. 검증 절차: 기동 후 확인할 것(스마트 검색 동작, 로그의 확장 로드 메시지 등).
4. 롤백 절차: 실패 시 구 이미지 복귀 + `pg_restore` 복원 경로
   (plan 001이 문서화한 `.dump` 복원 절차 참조 — `plans/001-*.md`가 DONE이면
   그 문서 링크, 아니면 절차 인라인).
5. 소요 시간/다운타임 추정과 **유지보수 창 요구사항** — #917·백업 복원 드릴과
   같은 창에 묶는 권고를 명시.

**Verify**: 보고서에 위 5개 절이 모두 존재한다 (`grep -c '^## \|^### ' plans/005-findings-pgvecto-rs.md` ≥ 5).

### Step 3: 재발 방지 권고안 (판단만, 구현 금지)

보고서 마지막 절에 다음을 **권고안으로만** 기록한다:

1. DB 이미지도 추적 대상에 넣을지: `immich-update`의 version-check를 확장할지,
   별도 알림으로 할지, 아니면 "Immich 릴리즈 노트의 breaking change를 사람이
   확인"으로 충분한지 — 단일 메인테이너 저장소라는 맥락에서 과설계를 피하는
   판정을 내린다 ("추적 안 함 + 이 보고서의 절벽 버전에 도달하기 전 수동
   마이그레이션"도 유효한 답이다).
2. `redis:7-alpine`, `gcr.io/zenika-hub/alpine-chrome:124` 등 가변 태그 이미지의
   digest 고정 여부 — 같은 논리로 권고만.

**Verify**: 보고서에 권고안 절이 있고 각 항목에 찬반 트레이드오프가 1줄 이상씩 있다.

## Test plan

코드 변경이 없으므로 테스트는 없다. 품질 게이트는 "모든 사실 주장에 출처 URL
또는 `[UNVERIFIED]` 표기"다.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `test -f plans/005-findings-pgvecto-rs.md` → exit 0
- [ ] 보고서에 절벽 버전(또는 "아직 미공지"라는 확인 결과)과 출처 URL 존재
- [ ] 보고서에 마이그레이션 절차 초안(사전 백업/교체/검증/롤백/창 요구) 존재
- [ ] `git diff --stat` → 변경이 `plans/` 아래에만 있음 (소스 코드 0건)
- [ ] `plans/README.md` 상태 행 갱신

## STOP conditions

Stop and report back (do not improvise) if:

- 웹 조사 도구가 가용하지 않다 (이 spike는 공식 문서 확인 없이는 가치가 없다 —
  코드만 보고 추측한 보고서를 쓰지 말 것).
- 조사 결과 Immich가 이미 pgvecto-rs 지원을 끊은 버전대에 현행 서버(v2.6.1)가
  포함된다는 모순이 발견된다 (현재 동작 중이라는 전제와 충돌 — 전제 재검토 필요).
- 공식 마이그레이션 가이드가 이 배포의 pg 메이저(16)에서 불가능한 경로만
  제시한다.

## Maintenance notes

- 이 보고서는 시점 산물이다 — 실제 마이그레이션 착수 시점에 Immich 문서를
  재확인해야 한다(보고서에 조사 일자를 명기할 것).
- 실제 마이그레이션 plan(코드 수정 + 운영 절차)은 이 보고서 승인 후 별도로
  작성한다. 그 plan은 유지보수 창을 요구하므로 이슈 #917/백업 복원 드릴과
  일정을 묶는 것이 운영 비용상 유리하다.
