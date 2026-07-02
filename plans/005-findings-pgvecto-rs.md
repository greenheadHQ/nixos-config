# Plan 005 Findings: Immich DB(pgvecto-rs → VectorChord) 업그레이드 절벽 조사 (spike)

> **조사 일자**: 2026-07-02 (WebSearch/WebFetch로 공식 소스 확인). 이 보고서는
> **시점 산물**이다 — 실제 마이그레이션 착수 시 Immich 문서를 재확인해야 한다.
> 모든 사실 주장에는 출처 URL을 병기했고, 확인되지 않은 항목은 `[UNVERIFIED]`로
> 표기했다. 코드는 일절 수정하지 않았다(읽기 전용 spike).
> **소스 코드 변경 0건** — 산출물은 이 보고서 파일 하나다.

## 요약 (TL;DR)

- **절벽의 위치 = Immich 서버 `v3.0`.** v3.0에서 pgvecto.rs 지원이 **완전
  제거**되어 `DB_VECTOR_EXTENSION=pgvecto.rs`가 에러를 던진다. v2.x에서
  pgvecto.rs를 쓰는 인스턴스는 **v3.0으로 올리기 전에 VectorChord로 마이그레이션**
  해야 한다.
- **현행 서버 `v2.6.1`은 아직 안전하다.** Immich는 pgvecto.rs `>=0.2, <0.4`를
  지원하고, 우리 DB 이미지는 `tensorchord/pgvecto-rs:pg16-v0.2.0`(= pgvecto.rs
  0.2.0)이라 지원 범위 안이다. 현재 정상 기동 중인 사실과 모순 없음 → STOP 조건
  아님.
- **위험 구조는 그대로다.** `immich-update`의 version-check는 `immich-app/immich`
  서버 릴리스만 추적(`version-check.sh:52`, `default.nix:58`)하고, DB 이미지는 어떤
  update 모듈도 추적하지 않는다. 서버는 매주 버전 체크로 계속 올라가는데
  update-script는 postgres 이미지를 갱신 대상에서 제외한다
  (`update-script.sh:122-127`는 server/ML 2개만 pull). 어느 주 서버가 v3.x로
  넘어가는 순간 프로덕션 DB가 조용히 기동 실패할 수 있다.
- **권고 마이그레이션 = 인플레이스 이미지 스왑**(같은 PG major 16). 볼륨을
  재사용하고, pgvecto.rs와 VectorChord를 **둘 다** 담은 전환용(transitional)
  이미지로 교체하면 Immich가 기동 시 자동 마이그레이션한다.
- **이 마이그레이션은 유지보수 창을 요구**하므로, 이슈 #917(update-script 실경로
  검증)·백업 복원 드릴과 **한 창에 묶는 것**을 권고한다(#917은 이미 "유지보수 창
  필요"로 BLOCKED).

## 1. 절벽의 위치 — 공식 소스 확정 (Step 1)

### 1.1 현행 서버 v2.6.1의 공식 DB 요구사항

- Immich가 받아들이는 확장/버전 범위(공식 문서):
  - **pgvecto.rs**: `>=0.2, <0.4` — 우리 이미지 `pg16-v0.2.0`은 이 범위 안이다.
    (Immich 이슈 제목이 이 범위를 명시: "The pgvecto.rs extension version is
    0.4.0, but Immich only supports >=0.2 <0.4."
    <https://github.com/immich-app/immich/issues/14654>)
  - **VectorChord (vchord)**: Immich 수용 범위 `>=0.3, <2.0`.
  - **pgvector**: `>=0.7, <0.9`.
  - **PostgreSQL major**: `>=14, <19`. 우리는 pg16 → 범위 안.
  - 확장 선호 순서(다중 설치 시): **VectorChord > pgvecto.rs > pgvector**.
    (출처: <https://docs.immich.app/administration/postgres-standalone/>)
- **결론**: v2.6.1 + pgvecto.rs 0.2.0 조합은 공식 지원 범위 안이다. "현재
  동작 중"이라는 전제와 모순 없음 → **STOP 조건(전제 충돌) 미발생**.

### 1.2 pgvecto.rs 지원이 제거되는 Immich 버전 = 절벽

- 마이그레이션 경로가 열린 시점: **v1.133.0** (2025). "Immich only supports
  upgrading directly from 1.107.2 or later"이고 "After switching to VectorChord,
  you should not downgrade Immich below 1.133.0."
  (출처: v1.133.0 릴리스 토론
  <https://github.com/immich-app/immich/discussions/18429>)
- 완전 제거 시점: **v3.0**. "Support for pgvecto.rs has been removed in v3.
  Using `DB_VECTOR_EXTENSION=pgvecto.rs` now throws an error." — v2.x에서
  pgvecto.rs를 쓰는 사용자는 v3.0.0 이상으로 올리기 전에 VectorChord로
  마이그레이션해야 한다.
  (출처: "Migrating to v3 | Immich Blog" <https://immich.app/blog/v3-migration>
  — 조사 시점 크롤은 PR 프리뷰 미러 `https://pr-558.dev.immich.app/blog/v3-migration`
  로 반환됨. 아래 [UNVERIFIED] 참조. 상위 확인: WebSearch 결과의 discussion
  #16335 / #25824 맥락과 upgrading 문서.)
- 문서상의 상시 경고: "Support for pgvecto.rs will be dropped in a later release,
  hence we recommend all users currently using pgvecto.rs to migrate to
  VectorChord at their convenience."
  (출처: <https://docs.immich.app/administration/postgres-standalone/>)
- `[UNVERIFIED]` v3.0.0의 **정확한 GA 릴리스 일자/현재 최신 버전**: 조사 시점
  검색은 최신 릴리스를 v2.7.0로, v3 마이그레이션 안내를 블로그 프리뷰 URL로
  반환했다. v3.0이 이미 GA인지 임박인지는 마이그레이션 착수 직전
  <https://github.com/immich-app/immich/releases> 에서 재확인할 것. **어느
  쪽이든 우리의 자동 version-check가 v3.x를 최신으로 잡는 순간 서버만 올라가는
  구조는 동일한 위험**이다.

### 1.3 Immich 공식 권장 DB 이미지와 내장 확장

- 권장 이미지 계열: **`ghcr.io/immich-app/postgres`** (VectorChord 내장).
  (출처: <https://docs.immich.app/install/upgrading/>)
- **전환용(transitional) 이미지** — pgvecto.rs와 VectorChord를 **둘 다** 내장해서
  기존 pgvecto.rs 데이터를 읽어 자동 마이그레이션할 수 있는 이미지. pg16 예시:
  `ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0`.
  (출처: 토론 #18429 — "If you are still using the default
  `docker.io/tensorchord/pgvecto-rs:pg16-v0.3.0` image, the new image should be
  `ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0`.")
- **주의 — 최신 태그는 pgvecto.rs를 더 이상 내장하지 않는다.** 조사 시점 레지스트리
  최신 pg16 태그는 `16-vectorchord0.5.3` / `16-vectorchord0.5.3-pgvector0.8.1`
  로, `-pgvector`(순수 pgvector)만 담고 `-pgvectors`(= pgvecto.rs)는 없다.
  (출처: <https://github.com/immich-app/base-images/pkgs/container/postgres>)
  → **인플레이스 자동 마이그레이션에는 반드시 pgvecto.rs를 담은 전환용
  `-pgvectors` 태그를 명시적으로 핀**해야 한다. 최신 태그로 바로 교체하면
  기존 pgvecto.rs 벡터를 읽지 못해 실패한다.
- 마이그레이션 완료 후(옵션): pgvecto.rs 없는 **경량 이미지**로 재교체 가능
  (예: `ghcr.io/immich-app/postgres:16-vectorchord*`).
  (출처: <https://docs.immich.app/install/upgrading/>)

### 1.4 pgvecto.rs v0.2.0/pg16에서 출발하는 공식 마이그레이션 경로

두 가지 공식 경로가 있다.

**(A) 자동(권장) — docker-compose 스타일 인플레이스 스왑**
(출처: <https://docs.immich.app/install/upgrading/>, 토론 #18429)

1. DB 백업.
2. DB 서비스 이미지를 `tensorchord/pgvecto-rs:pgNN-vX` → 같은 PG major의
   전환용 `ghcr.io/immich-app/postgres:NN-vectorchord…-pgvectors…`로 교체.
3. 구 healthcheck/command 파라미터 제거, `shm_size: 128mb` 추가, 필요 시
   `DB_STORAGE_TYPE: 'HDD'`.
4. **데이터 볼륨은 그대로 재사용**(in-place). Immich가 기동 시 DB를 자동 변경한다
   ("Immich will make some changes to the DB during startup").
5. `DB_VECTOR_EXTENSION=pgvector`가 설정돼 있으면 제거(설정 시 pgvector에 머문다).
   우리는 이 변수를 설정하지 않으므로 Immich가 VectorChord를 기본 선택한다.

**(B) 수동 — 사전 존재 Postgres용 SQL 절차**
(출처: <https://docs.immich.app/administration/postgres-standalone/> #migrating-to-vectorchord)

```sql
-- 1) 임베딩 차원 확인 (출력 숫자를 4)에서 사용)
SELECT atttypmod AS dimsize FROM pg_attribute f
  JOIN pg_class c ON c.oid = f.attrelid
  WHERE c.relkind = 'r'::char AND f.attnum > 0
    AND c.relname = 'smart_search'::text
    AND f.attname = 'embedding'::text;

-- 2) pgvecto.rs 참조 제거
DROP INDEX IF EXISTS clip_index;
DROP INDEX IF EXISTS face_index;
ALTER TABLE smart_search ALTER COLUMN embedding SET DATA TYPE real[];
ALTER TABLE face_search  ALTER COLUMN embedding SET DATA TYPE real[];

-- 3) VectorChord 설치(공식 문서 절차) 후
-- 4) 벡터 타입 복원 (<number>는 1)의 출력)
CREATE EXTENSION IF NOT EXISTS vchord CASCADE;
ALTER TABLE smart_search ALTER COLUMN embedding SET DATA TYPE vector(<number>);
ALTER TABLE face_search  ALTER COLUMN embedding SET DATA TYPE vector(512);
-- 5) Immich 기동 → 신규 인덱스 생성
```

- **pg major 16에서 실행 가능한 경로가 존재**한다(전환용 pg16 이미지 존재, 볼륨
  재사용 가능) → **STOP 조건(pg16 불가) 미발생**.

## 2. 이 배포에 맞춘 마이그레이션 절차 초안 (Step 2)

대상 배치(전부 기존 파일에서 확인):
- 컨테이너 정의: `modules/nixos/programs/docker/immich.nix`
  (postgres 이미지 `:91`, server `:150`, ml `:130`, redis `:115`)
- DB 데이터 볼륨: `/var/lib/docker-data/immich/postgres:/var/lib/postgresql/data`
  (`constants.paths.dockerData` = SSD)
- 일일 백업: `modules/nixos/programs/docker/immich-backup.nix` →
  `pg_dump -Fc` 커스텀 포맷 `.dump`를 `/mnt/data/backups/immich/`(HDD)에, 기본
  30일 보관(`immich-backup.nix:96`, `retentionDays`).
- systemd 서비스명: `podman-immich-postgres.service`,
  `podman-immich-server.service`, `podman-immich-ml.service`.

### 2.1 사전 조건 (백업 확보)

1. HDD 일일 백업 최신본 존재/무결성 확인:
   `ls -lt /mnt/data/backups/immich/*.dump | head` 후 최신 파일에 대해
   `sudo podman exec -i immich-postgres pg_restore --list < <최신.dump> | head`
   (읽기 전용 TOC 검증 — `immich-backup.nix:79-82`와 동일 방식).
2. **수동 `pg_dump -Fc` 1회 추가 확보**(창 직전 스냅샷):
   `sudo podman exec immich-postgres pg_dump -Fc -U immich immich > \
   /mnt/data/backups/immich/premigration-$(date +%Y%m%d-%H%M%S).dump`
   (기존 백업 스크립트와 동일한 `-Fc` 포맷이라 동일 복원 절차가 적용됨).
3. 디스크 여유 확인(백업 스크립트는 5GB 미만 시 중단 — 창 전 여유 확보).

### 2.2 서비스 중지 / 이미지 교체 / 볼륨 처리

**중지 순서**(update-script.sh:132-135와 동일 방향: server/ML 먼저, DB 나중):
1. `systemctl stop podman-immich-server.service`
2. `systemctl stop podman-immich-ml.service`
3. `systemctl stop podman-immich-postgres.service`

**이미지 교체(보고서 전용 diff 초안 — 적용 금지, 운영자가 별도 plan에서)**:

```nix
# modules/nixos/programs/docker/immich.nix:91 — DRAFT ONLY, DO NOT APPLY HERE
-      image = "tensorchord/pgvecto-rs:pg16-v0.2.0";
+      image = "ghcr.io/immich-app/postgres:16-vectorchord0.3.0-pgvectors0.3.0";
```

- **볼륨 처리 = 공식 권장은 인플레이스 재사용**(볼륨 마운트 그대로, PG major 16
  유지). 새 초기화+복원은 불필요하다.
- 추가 고려:
  - `shm_size 128mb` 대응: oci-containers `extraOptions`에 `--shm-size=128m`
    추가 검토(공식 compose가 요구).
  - 현행 `--health-cmd=pg_isready …`(immich.nix:104)는 이미지 무관한 generic
    체크라 그대로 두어도 무방(공식 안내의 "healthcheck 제거"는 compose의
    pgvecto.rs 전용 헬스체크를 가리킴). 단 새 이미지 기준으로 재검증할 것.
  - `DB_VECTOR_EXTENSION`은 **설정하지 않은 현행 유지**(설정 시 VectorChord 자동
    선택을 방해).

**교체 후**: `podman pull` → postgres 먼저 기동 → 헬스 대기 → ml → server 순
기동. Immich 기동 중 DB 자동 변경이 일어난다.

- `[UNVERIFIED]` **버전 정합 리스크(이 배포 고유)**: 우리 데이터는 pgvecto.rs
  **0.2.0**이 쓴 것인데, 위 pg16 전환용 이미지는 pgvecto.rs **0.3.0**을 내장한다
  (Immich 지원 범위 `>=0.2 <0.4` 안이긴 하다). 0.3.0 바이너리가 0.2.0이 쓴
  on-disk 포맷을 그대로 읽어 자동 마이그레이션하는지는 조사에서 태그 조합상
  0.2.0 내장 pg16 전환용 이미지를 찾지 못해 확정하지 못했다. 마이그레이션 직전
  스테이징(백업 복원본)으로 이 경로를 먼저 리허설할 것.
  - **폴백(정합 리스크 회피)**: 신규 볼륨에 전환용 이미지를 기동한 뒤
    `pg_restore`로 우리 `.dump`를 복원 → Immich 자동 마이그레이션. 새 DB
    이미지들은 "pgvector와 pgvecto.rs를 함께 담아 기존 백업에서 복원 가능"하다고
    안내한다(단 최신 순수 `-pgvector` 태그가 아닌 `-pgvectors` 전환용 태그
    필요). 이 폴백은 §2.4 롤백 재료와 같은 도구를 쓴다.

### 2.3 검증 절차 (기동 후)

1. 서버 헬스: `curl -sf -H "x-api-key: <KEY>" http://127.0.0.1:<port>/api/server/version`
   (update-script.sh:151-158과 동일 엔드포인트; `cfg.port`는 127.0.0.1 바인딩).
2. **VectorChord 확장 로드 확인**:
   `sudo podman exec -i immich-postgres psql -U immich -d immich -c "\dx"`
   에서 `vchord`가 보이고, pgvecto.rs(`vectors`)가 제거/미사용인지 확인.
3. **스마트 검색 동작 확인**: 웹 UI에서 자연어/유사 이미지 검색과 얼굴 인식이
   결과를 내는지(임베딩 컬럼이 `vector(dim)`으로 정상 재구성됐는지의 실질 검증).
4. postgres 로그에서 확장 로드/마이그레이션 메시지, ERROR 부재 확인:
   `journalctl -u podman-immich-postgres -n 200`.
5. 일일 백업 서비스 재검증: `systemctl start immich-db-backup.service` 수동 실행 후
   새 `.dump` 무결성(`pg_restore --list`) 통과 확인.

### 2.4 롤백 절차 (실패 시)

1. 서비스 중지(§2.2 역방향 아님 — 안전하게 server/ML/postgres 모두 stop).
2. 이미지를 **구 태그로 원복**: `immich.nix:91`을 `tensorchord/pgvecto-rs:pg16-v0.2.0`
   로 되돌린다.
3. 데이터가 손상됐거나 자동 마이그레이션이 볼륨을 되돌릴 수 없게 변경한 경우,
   **§2.1에서 확보한 `.dump`를 `pg_restore`로 복원**한다.
   - 복원 절차 전문은 **plan 001(DONE)이 문서화**한
     `.claude/skills/running-containers/references/immich-update.md`의
     "재해복구 복원 — 일일 백업 (`.dump`)" 절을 따른다(`pg_restore --clean
     --if-exists`, `.dump`는 `gunzip|psql` 불가). 여기 인라인하지 않는다.
   - 원복 대상 볼륨은 구 pgvecto.rs 이미지가 초기화한 신규/기존 볼륨이어야 한다
     (구 이미지는 pgvecto.rs 0.2.0을 담으므로 우리 `.dump`를 문제없이 복원).
4. 헬스체크 통과 확인 후 정상 서비스 복귀.

### 2.5 소요 시간 / 다운타임 추정과 유지보수 창

- **다운타임**: 이미지 pull + DB 자동 마이그레이션 + 인덱스 재생성. 사진 수/임베딩
  규모에 비례하므로 정확한 값은 `[UNVERIFIED]` — 창 계획 시 스테이징 리허설로
  실측할 것. VectorChord 인덱스 재구성은 데이터셋이 크면 수십 분대가 될 수 있다.
- **유지보수 창 요구사항**: 이 마이그레이션은 실서비스 중단·DB 스키마 변경·롤백
  리허설을 수반하므로 유지보수 창이 필수다. 이슈 #917(update-script 골격 통합)이
  이미 "실 서비스 업데이트 = 유지보수 창 필요"로 BLOCKED다. **한 창에서 함께
  처리할 후보**로 명시한다:
  1. DB 마이그레이션(본 보고서),
  2. 백업 복원 드릴(plan 001의 `.dump` 복원 실경로 실측),
  3. #917 update-script 실경로 검증.
  세 작업 모두 같은 종류의 창(서비스 중단 + DB 조작)을 요구하므로 묶는 편이
  운영 비용상 유리하다.

## 3. 재발 방지 권고안 (판단만 — 구현 금지) (Step 3)

### 3.1 DB 이미지를 추적 대상에 넣을지

**권고: 추적 자동화를 신설하지 않는다(과설계 회피). 대신 "이 보고서의 절벽
버전(v3.0)에 서버가 도달하기 전 수동 마이그레이션"으로 충분하다.** 근거는 아래
트레이드오프.

- **version-check 확장(DB 이미지 릴리스도 추적)**
  - 찬: 최신 DB 이미지/태그 변경을 자동 인지.
  - 반: `ghcr.io/immich-app/postgres` 태그는 vectorchord/pgvector 버전이 뒤섞인
    복합 태그라 "따라잡아야 할 최신"을 기계적으로 판정하기 어렵고, DB는 서버처럼
    매주 굴릴 대상이 아니다. 단일 메인테이너 저장소에서 유지비 대비 이득 낮음.
- **별도 알림만(브레이킹 체인지 감지)**
  - 찬: 구현 부담이 작고 "행동이 필요한 순간"만 알림.
  - 반: "언제가 브레이킹인지"를 결국 사람이 릴리스 노트로 판단해야 함 →
    알림 자체의 신호 대비 잡음이 애매.
- **추적 안 함 + 릴리스 노트를 사람이 확인(권고안)**
  - 찬: 절벽이 이미 **v3.0으로 특정**됐고, 서버 version-check가 v3.x를 최신으로
    올리기 전까지는 안전. 유지비 0.
  - 반: 사람이 v3.0 도달 전에 손을 대야 한다는 규율에 의존. → **완화책**:
    이 보고서를 이슈 #942/#917에 연결해 "v3.x 등장 시 마이그레이션 먼저"를
    체크포인트로 남긴다.
- (선택) 최소 안전장치: update-script가 서버 목표 태그의 major가 3 이상으로
  바뀌는 것을 감지하면 자동 진행을 막고 경고하도록 하는 가드는 별도 plan에서
  검토 가능(구현은 본 spike 범위 밖).

### 3.2 가변 태그 이미지의 digest 고정 여부

- `redis:7-alpine`(immich.nix:115)
  - 찬(고정): `7-alpine`은 롤링 태그라 재pull 시 조용히 바뀔 수 있음 —
    digest 핀은 재현성↑.
  - 반(현행 유지): 코드 주석대로 **캐시/잡 큐 전용, 영속성 불필요**
    (immich.nix:112). 재시작 시 재구축되므로 부작용이 작고, 보안 패치를 자동으로
    받는 이점이 오히려 큼. → **고정 우선순위 낮음.**
- `gcr.io/zenika-hub/alpine-chrome:124` 등 가변 태그(웹훅/렌더링 쪽에서 사용
  시)
  - 찬(고정): major 태그(`124`)도 하위 패치가 움직일 수 있어, 렌더 결과
    재현성/공급망 관점에서 digest 핀이 안전.
  - 반(현행 유지): 자동 보안 패치 수령, 핀 관리 비용.
  - **권고**: 상태를 갖는(persistent) DB류가 아닌 상기 두 이미지는 digest 고정의
    이득이 작다. 굳이 한다면 **DB/영속 데이터 이미지부터**가 우선이나, DB는
    §3.1대로 수동 마이그레이션이 이미 관문이라 별도 digest 핀 없이도 통제된다.
- 공통 규칙: 이미지 태그/버전 상수를 손댈 경우, 저장소 정책상 하드코딩 버전성
  상수는 `libraries/constants.nix` 경유가 원칙(현재 이미지들은 immich.nix에 인라인
  하드코딩 상태). digest 핀을 도입한다면 constants로 끌어올리는 것을 함께 검토.

## 출처 (조사 일자: 2026-07-02)

- Immich Upgrading(마이그레이션 공식 안내):
  <https://docs.immich.app/install/upgrading/>
- Immich Pre-existing Postgres(확장/버전 범위, 수동 SQL 절차):
  <https://docs.immich.app/administration/postgres-standalone/>
- v1.133.0 릴리스 토론(전환용 이미지 태그, 다운그레이드 제약):
  <https://github.com/immich-app/immich/discussions/18429>
- pgvecto.rs 지원 범위 `>=0.2 <0.4` (에러 메시지 인용):
  <https://github.com/immich-app/immich/issues/14654>
- DB 이미지 태그 목록(전환용 `-pgvectors` 소멸, 최신 `-pgvector`만):
  <https://github.com/immich-app/base-images/pkgs/container/postgres>
- Migrating to v3(pgvecto.rs 제거 = v3.0):
  <https://immich.app/blog/v3-migration>
  (`[UNVERIFIED]` 조사 시점 크롤은 프리뷰 미러
  `https://pr-558.dev.immich.app/blog/v3-migration`로 반환 — GA 여부/정확한 버전은
  <https://github.com/immich-app/immich/releases>에서 착수 직전 재확인)
- pgvecto.rs deprecated / VectorChord 이행 토론:
  <https://github.com/immich-app/immich/discussions/16335>

---

_읽기 전용 spike 산출물. 실제 마이그레이션(코드 수정 + 운영 절차)은 이 보고서
승인 후 별도 plan으로 작성하며, 유지보수 창(§2.5)을 요구한다._
