# Immich 버전 체크 및 업데이트 가이드

## 개요

`homeserver.immichUpdate.enable = true`로 활성화되는 자동화 시스템:
- 매일 03:00 GitHub Releases API로 최신 버전 체크 → 새 버전 시 Pushover 알림
- `sudo immich-update` 명령으로 안전한 수동 업데이트

## 파일 구조

| 파일 | 역할 |
|------|------|
| `modules/nixos/programs/immich-update/default.nix` | NixOS 모듈 (systemd 서비스/타이머) |
| `modules/nixos/programs/immich-update/files/version-check.sh` | Immich 전용 버전 체크 (Immich API 사용) |
| `modules/nixos/programs/immich-update/files/update-script.sh` | 수동 업데이트 |
| `modules/nixos/lib/service-lib.sh` | 공통 함수 (send_notification, fetch_github_release 등) |
| `modules/nixos/lib/service-lib.nix` | service-lib.sh Nix wrapper |
| `modules/nixos/lib/mk-update-module.nix` | 업데이트 모듈 생성 헬퍼 (copyparty, uptime-kuma, karakeep용) |

> Immich는 API로 현재 버전을 확인하는 고유 로직이 있어 `mk-update-module.nix`를 사용하지 않고 독자 구현.
> Copyparty, Uptime Kuma, Karakeep는 `mk-update-module.nix` + `generic-version-check.sh` 사용.
> 통합 시스템 상세: [service-update-system.md](service-update-system.md)

## API 접근 URL

버전 체크 및 업데이트 스크립트는 `http://127.0.0.1:2283`으로 Immich API에 접근합니다.
Immich 서버가 `127.0.0.1`에만 바인딩되어 있으므로, Tailscale IP로는 직접 접근할 수 없습니다.
외부(macOS 등)에서 접근할 때는 Caddy 리버스 프록시(`https://immich.greenhead.dev`)를 사용합니다.

## 버전 체크 스크립트 동작

### API 호출

1. 현재 버전: Immich API `/api/server/version`의 `major`·`minor`·`patch`를 `major.minor.patch` 문자열로 합친다
2. 최신 버전: GitHub `repos/immich-app/immich/releases/latest`의 `tag_name`에서 앞의 `v`를 떼어 같은 형식으로 맞춘다

### 상태 관리

- `/var/lib/immich-update/last-notified-version`: 마지막 알림 버전 기록
- `/var/lib/immich-update/last-success`: 마지막 성공 시각 (Unix timestamp) — 워치독용
- 초기 실행 시: 현재 버전을 기록하고 종료 (불필요한 알림 방지)
- 이미 알린 버전은 재알림하지 않음
- 3일 이상 성공 없으면 Pushover 경고 알림 (장기 실패 워치독)

### 에러 처리

- GitHub API rate limit (429) / 타임아웃 → `exit 0` (다음 실행에 재시도)
- Immich API 연결 실패 → `exit 0`
- Pushover 전송 실패 → 무시 (알림은 best-effort)

## 업데이트 스크립트 플로우

```
[동시 실행 방지] flock으로 lockfile 확보
    ↓
[상태 확인] postgres 컨테이너 running 여부
    ↓
[DB 백업] pg_dump | gzip → /var/lib/immich-update/backups/
    ↓
[무결성 검증] gzip -t + 최소 크기(1KB) 확인
    ↓
[이미지 Pull] immich-server + immich-ml (설정된 pinned tag)
    ↓
[재시작] stop server → stop ml → start ml → start server
    ↓
[헬스체크] /api/server/version (60회, 10초 간격 = 최대 10분)
    ↓
[ML 상태 확인] immich-ml 컨테이너 running 여부 (경고 알림)
    ↓
[알림] 성공/실패 Pushover 전송
    ↓
[정리] 7일 이상 된 백업 삭제
```

### --dry-run 모드

`sudo immich-update --dry-run`으로 실제 변경 없이 상태 확인:
- 현재 버전 출력
- postgres 컨테이너 상태 확인
- 수행할 작업 목록 출력

## DB 백업/복원

Immich DB 백업은 두 계층으로 나뉜다. disko 재설치는 NVMe(`/dev/nvme0n1`)만 포맷하고 HDD(`/dev/sda`)는 보존하므로(`hosts/greenhead-minipc/disko.nix`), 재해복구 시점에 살아남는 것은 HDD에 쌓인 일일 백업뿐이다.

| 계층 | 포맷 | 위치 | 보관 | 재설치 시 | 복원 명령 |
|------|------|------|------|-----------|-----------|
| 일일 백업 | `pg_dump -Fc` 커스텀 포맷 `.dump` | `/mnt/data/backups/immich/` (HDD) | 기본 30일 (`homeserver.immichBackup.retentionDays`) | 생존 | `pg_restore --exit-on-error` |
| 업데이트 직전 백업 | `pg_dump \| gzip` 평문 SQL `.sql.gz` | `/var/lib/immich-update/backups/` (SSD) | 7일 | 소멸 | `psql -v ON_ERROR_STOP=1 --single-transaction` |

> `.dump`는 gzip도 평문 SQL도 아니라서 `psql`로 복원할 수 없다. 아래 절차는 파일 확장자로 형식을 골라 복원 명령을 정한다.

### 백업 위치

```
/var/lib/immich-update/backups/        # SSD - 업데이트 직전 (.sql.gz, 7일, 재설치 시 소멸)
├── backup-20260206-030000.sql.gz
├── backup-20260207-030000.sql.gz
└── ...

/mnt/data/backups/immich/              # HDD - 일일 (.dump, 재설치 후에도 생존)
├── immich-db-2026-02-06_030000.dump
├── immich-db-2026-02-07_030000.dump
└── ...
```

두 디렉터리 모두 root 전용(`0700`)이라 목록도 `sudo ls -l /mnt/data/backups/immich/ /var/lib/immich-update/backups/`로 본다.

### 복구 절차

기존 `immich` DB는 그대로 두고 새 DB `immich_restore`에 복원해 검증한 뒤, 이름을 맞바꿔 전환한다. 전환 전 DB는 `immich_before_restore_<시각>`으로 남으므로 복귀는 이름을 되돌리면 된다. 앱은 복원과 검증 동안 기존 DB로 계속 동작하고, 전환할 때만 잠시 멈춘다.

지키는 조건:

- 백업 권한을 넓히지 않는다. 두 백업 디렉터리는 root 전용이다. 백업 파일을 여는 명령 전체를 `sudo bash -c`로 root 셸에서 실행한다. 일반 사용자 셸의 입력 리다이렉션(`sudo … < 백업`)이나 파이프 앞단(`gunzip -c 백업 | sudo …`)은 파일을 일반 사용자 권한으로 열어 `Permission denied`로 실패한다.
- 파이프 실패를 전체 실패로 만든다. 파이프 앞단의 실패는 `pipefail`이 없으면 빈 입력을 받은 뒷단의 성공(종료 코드 0)에 가려지므로, root 셸도 `bash -o pipefail`로 띄운다.
- SQL 오류에서 멈춘다. `.dump`는 `pg_restore --exit-on-error`, `.sql.gz`는 `psql -v ON_ERROR_STOP=1 --single-transaction`으로 복원한다.
- 복원이나 검증이 실패하면 `immich_restore`를 지우고 멈춘다. 이때 `immich` DB와 앱은 복원 전 그대로다.
- 전환은 `immich_restore_db`가 복원과 검증을 모두 마쳐 검증 완료 표식(`COMMENT ON DATABASE immich_restore IS 'verified:<백업 파일 이름>'`)을 남긴 DB만 받는다. 표식은 전환 트랜잭션에서 지워지므로, 도중에 끊긴 복원(SSH 끊김·Ctrl-C)이나 복귀 뒤 남은 `immich_restore`는 앱을 건드리지 않고 거부된다.
- 앱은 검증과 이름 맞바꿈이 모두 성공한 뒤에만 다시 시작한다.
- 앱 버전을 백업 시점에 맞춘다. 업데이트 직전 백업은 새 이미지를 받기 전에 만든 것이다. 백업 시점 버전(2절의 `version_history` 조회)과 현재 이미지 태그(`modules/nixos/programs/docker/immich.nix`의 `immich-server`·`immich-ml`)가 다르면, 앱을 멈춘 채 전환한 뒤 태그를 되돌린다: `immich_restore_db` → 버전 확인 → `immich_switch_to_restore --no-start` → 태그를 백업 시점 버전으로 바꾸고 `nrs` → 확인. 새 앱이 옛 스키마에 마이그레이션을 다시 실행하지 않게 하려는 것이다.
  - 태그를 먼저 되돌려 `nrs`하지 않는다. `immich-server`는 `autoStart`라서 옛 서버가 아직 새 버전인 `immich` DB에 붙어 뜨고, 복원하는 내내 그 상태가 이어진다.
  - `nrs`가 멈춰 둔 유닛을 시작하는지는 확인하지 않았다. `nrs` 뒤 앱이 떠 있지 않으면 `sudo systemctl start podman-immich-ml.service podman-immich-server.service`로 시작한다.
  - 전환 함수는 백업 시점 버전이 1.133.0 미만이거나 읽을 수 없으면(`version_history` 없음 등) 앱을 건드리지 않고 거부한다. VectorChord 전환 뒤에는 1.133.0 미만으로 되돌릴 수 없다(`immich.nix`의 이미지 주석).
- 백업 시점 이후(복원하는 동안 포함)에 올린 사진은 전환 뒤 DB에 행이 없다.

#### 1. 준비

MiniPC의 셸(bash 또는 zsh)에 아래 블록을 붙여 넣는다. 먼저 `BACKUP`을 복원할 파일 경로로 바꾼다. 첫 줄은 zsh가 블록 안의 주석을 명령으로 읽지 않게 하는 설정이고, bash에서는 아무 일도 하지 않는다. 함수는 root가 필요한 명령에만 `sudo`를 붙인다. SQL은 heredoc(표준 입력)으로만 넘긴다. `podman exec -i`가 붙여 넣은 다음 줄을 입력으로 가져가지 않게 하려는 것이다. 새 셸을 열었으면 이 블록을 다시 붙여 넣는다.

```bash
if [ -n "${ZSH_VERSION:-}" ]; then setopt interactive_comments; fi

# 복원할 백업 — 둘 중 하나를 골라 실제 파일 이름으로 바꾼다
BACKUP=/mnt/data/backups/immich/immich-db-YYYY-MM-DD_HHMMSS.dump
# BACKUP=/var/lib/immich-update/backups/backup-YYYYMMDD-HHMMSS.sql.gz

# 복원 DB에 있어야 하는 확장 (운영 중인 Immich 태그의 스키마 선언 + VectorChord 이미지 기준)
IMMICH_REQUIRED_EXTENSIONS='cube earthdistance pg_trgm unaccent uuid-ossp vector vchord'

# postgres 컨테이너의 psql. SQL은 heredoc(표준 입력)으로만 넘긴다
immich_psql() {
  sudo podman exec -i immich-postgres psql -X -q -v ON_ERROR_STOP=1 -U immich "$@"
}

immich_drop_restore() {
  immich_psql -d postgres <<'SQL'
DROP DATABASE IF EXISTS immich_restore;
SQL
}

# immich 계열 DB(immich, immich_restore, immich_before_restore_*)에 클라이언트 연결이 없어야 통과
immich_assert_no_connections() {
  immich_psql -d postgres <<'SQL'
DO $$
DECLARE
  sessions text;
BEGIN
  SELECT string_agg(format('pid=%s db=%s app=%s client=%s',
                           pid, datname, application_name, client_addr), '; ')
    INTO sessions
    FROM pg_stat_activity
   WHERE backend_type = 'client backend'
     AND (datname = 'immich' OR datname LIKE 'immich\_%');
  IF sessions IS NOT NULL THEN
    RAISE EXCEPTION 'immich 계열 DB에 연결이 남아 있다: %', sessions;
  END IF;
END
$$;
SQL
}

# public 스키마의 기본 키·외래 키·UNIQUE·인덱스 수를 immich와 immich_restore 나란히 출력한다
immich_postdata_counts() {
  local db
  printf '%-16s %4s %4s %6s %6s\n' DB PK FK UNIQUE INDEX
  for db in immich immich_restore; do
    immich_psql -d "$db" -At <<'SQL' || printf '%-16s (읽지 못함)\n' "$db"
SELECT format('%-16s %4s %4s %6s %6s', current_database(),
              count(*) FILTER (WHERE contype = 'p'), count(*) FILTER (WHERE contype = 'f'),
              count(*) FILTER (WHERE contype = 'u'),
              (SELECT count(*) FROM pg_indexes WHERE schemaname = 'public'))
  FROM pg_constraint WHERE connamespace = 'public'::regnamespace;
SQL
  done
}

# 1) 빈 DB immich_restore에 복원하고 검증한다. 둘 다 성공해야 검증 완료 표식을 남긴다
immich_restore_db() {
  sudo test -f "$BACKUP" || { printf '백업 파일이 없다: %s\n' "$BACKUP" >&2; return 1; }
  # 같은 이름의 DB가 이미 있으면(이전 시도의 잔재) 지우지 않고 멈춘다
  immich_psql -d postgres <<'SQL' || return 1
CREATE DATABASE immich_restore OWNER immich TEMPLATE template0;
SQL
  # 백업 파일은 root 셸이 연다. pipefail로 압축 해제 실패도 전체 실패가 된다
  case "$BACKUP" in
    *.dump)
      sudo bash -o pipefail -c 'podman exec -i immich-postgres pg_restore --exit-on-error -U immich -d immich_restore < "$1"' restore "$BACKUP"
      ;;
    *.sql.gz)
      sudo bash -o pipefail -c 'gzip -dc -- "$1" | podman exec -i immich-postgres psql -X -q -o /dev/null -v ON_ERROR_STOP=1 --single-transaction -U immich -d immich_restore' restore "$BACKUP"
      ;;
    *)
      printf '지원하지 않는 백업 형식: %s\n' "$BACKUP" >&2
      false
      ;;
  esac || {
    printf '복원 실패 — immich_restore를 지운다\n' >&2
    immich_drop_restore
    return 1
  }
  if ! immich_verify_restore; then
    printf '검증 실패 — immich_restore를 지운다\n' >&2
    immich_drop_restore
    return 1
  fi
  # 복원과 검증이 모두 성공한 뒤에만 표식을 남긴다. 전환은 이 표식이 있는 immich_restore만 받고,
  # 표식은 전환 트랜잭션에서 지워진다
  immich_psql -d postgres -v marker="verified:${BACKUP##*/}" <<'SQL'
COMMENT ON DATABASE immich_restore IS :'marker';
SQL
}

# 2) 복원 DB 검증: 핵심 테이블·post-data(PK·FK·인덱스)·확장·행 수. 판정만 하고 지우지 않는다
#    (지우기는 호출부인 immich_restore_db와 표식이 확인된 전환이 한다)
immich_verify_restore() {
  if ! immich_psql -d immich_restore -v required="$IMMICH_REQUIRED_EXTENSIONS" <<'SQL'
SET restore.required_extensions = :'required';
DO $$
DECLARE
  missing text;
BEGIN
  SELECT string_agg(t, ', ') INTO missing
    FROM unnest(ARRAY['user', 'asset', 'album']) AS t
   WHERE to_regclass(format('public.%I', t)) IS NULL;
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION '핵심 테이블이 없다: %', missing;
  END IF;
  -- post-data는 복원 끝부분에 만들어지므로, 도중에 끊긴 복원에서 빠진다
  SELECT string_agg(t, ', ') INTO missing
    FROM unnest(ARRAY['user', 'asset', 'album']) AS t
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint
                      WHERE conrelid = format('public.%I', t)::regclass AND contype = 'p');
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION '기본 키가 없다: %', missing;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE connamespace = 'public'::regnamespace AND contype = 'f') THEN
    RAISE EXCEPTION 'public 스키마에 외래 키가 없다';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname = 'public') THEN
    RAISE EXCEPTION 'public 스키마에 인덱스가 없다';
  END IF;
  SELECT string_agg(e, ', ') INTO missing
    FROM regexp_split_to_table(current_setting('restore.required_extensions'), '\s+') AS e
   WHERE e <> '' AND NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = e);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION '확장이 없다: %', missing;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public."user") THEN
    RAISE EXCEPTION 'user 테이블이 비어 있다';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.asset) THEN
    RAISE EXCEPTION 'asset 테이블이 비어 있다';
  END IF;
END
$$;
SELECT extname, extversion FROM pg_extension ORDER BY extname;
SELECT (SELECT count(*) FROM public."user") AS users,
       (SELECT count(*) FROM public.asset) AS assets,
       (SELECT count(*) FROM public.album) AS albums;
SQL
  then
    printf '검증 실패\n' >&2
    return 1
  fi
  immich_postdata_counts
  printf '검증 통과 — 위 확장 목록, 행 수, 제약·인덱스 수를 확인한다\n'
}

# 3) 전환: 표식·버전 확인 → 재검증 → 앱 중지 → 연결 확인 → 이름 맞바꿈 → 앱 시작
#    --no-start: 이름을 바꾼 뒤 앱을 멈춘 채 둔다(이미지 태그를 백업 시점 버전으로 되돌려 nrs할 때)
immich_switch_to_restore() {
  local old start=1
  if [ "${1:-}" = --no-start ]; then
    start=0
    shift
  fi
  if [ "$#" -ne 0 ]; then
    printf '사용법: immich_switch_to_restore [--no-start]\n' >&2
    return 2
  fi
  old="immich_before_restore_$(date +%Y%m%d_%H%M%S)"
  if ! immich_psql -d postgres -At <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'immich_restore') THEN
    RAISE EXCEPTION 'immich_restore DB가 없다';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'immich_restore'
                    AND shobj_description(oid, 'pg_database') LIKE 'verified:%') THEN
    RAISE EXCEPTION 'immich_restore에 검증 완료 표식이 없다';
  END IF;
END
$$;
SELECT '복원한 백업: ' || regexp_replace(shobj_description(oid, 'pg_database'), '^verified:', '')
  FROM pg_database WHERE datname = 'immich_restore';
SQL
  then
    printf '전환 거부 — immich_restore_db로 다시 복원한다 (남은 immich_restore는 내용을 확인한 뒤 수동으로 DROP)\n' >&2
    return 1
  fi
  # 백업 시점 버전(version_history 최근 행)을 확인한다. VectorChord 전환 뒤에는 Immich를
  # 1.133.0 미만으로 되돌릴 수 없다(immich.nix 이미지 주석). 버전을 읽지 못해도 거부한다
  if ! immich_psql -d immich_restore -At <<'SQL'
DO $$
DECLARE
  latest text;
  parts text[];
BEGIN
  IF to_regclass('public.version_history') IS NULL THEN
    RAISE EXCEPTION 'version_history 테이블이 없다 — 백업 시점 버전을 알 수 없다';
  END IF;
  SELECT version INTO latest FROM public.version_history ORDER BY "createdAt" DESC LIMIT 1;
  parts := regexp_match(coalesce(latest, ''), '^v?(\d+)\.(\d+)\.(\d+)');
  IF parts IS NULL THEN
    RAISE EXCEPTION '백업 시점 버전을 읽지 못했다: %', coalesce(latest, '(행 없음)');
  END IF;
  IF parts::int[] < ARRAY[1, 133, 0] THEN
    RAISE EXCEPTION '백업 시점 버전 %: 1.133.0 미만 — VectorChord 전환 뒤에는 되돌릴 수 없다', latest;
  END IF;
END
$$;
SELECT '백업 시점 Immich 버전: ' || version FROM public.version_history ORDER BY "createdAt" DESC LIMIT 1;
SQL
  then
    printf '전환 거부 — 백업 시점 버전을 확인할 수 없거나 되돌릴 수 없는 버전이다\n' >&2
    return 1
  fi
  if ! immich_verify_restore; then
    printf '검증 실패 — immich_restore를 지운다\n' >&2
    immich_drop_restore
    return 1
  fi
  sudo systemctl stop podman-immich-server.service podman-immich-ml.service || return 1
  if ! immich_assert_no_connections || ! immich_psql -d postgres -v old="$old" <<'SQL'
BEGIN;
-- 앞의 확인 뒤 표식이 사라졌으면 이름을 바꾸지 않고 되돌린다
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'immich_restore'
                    AND shobj_description(oid, 'pg_database') LIKE 'verified:%') THEN
    RAISE EXCEPTION 'immich_restore에 검증 완료 표식이 없다';
  END IF;
END
$$;
COMMENT ON DATABASE immich_restore IS NULL;
ALTER DATABASE immich RENAME TO :"old";
ALTER DATABASE immich_restore RENAME TO immich;
COMMIT;
SQL
  then
    printf '전환 실패 — DB 이름은 그대로이고 앱은 멈춰 있다. 원인을 해결해 다시 실행하거나, 복원을 포기하려면: sudo systemctl start podman-immich-ml.service podman-immich-server.service\n' >&2
    return 1
  fi
  printf '이름 변경 완료 — 이전 DB: %s\n' "$old"
  if [ "$start" = 0 ]; then
    printf '앱은 멈춘 채 둔다. 다음: modules/nixos/programs/docker/immich.nix의 immich-server·immich-ml 태그를 위 백업 시점 버전으로 바꾸고 nrs한다. nrs 뒤 앱이 떠 있지 않으면: sudo systemctl start podman-immich-ml.service podman-immich-server.service\n'
    printf '되돌리려면: 태그를 바꿔 nrs했다면 immich_revert_restore --no-start %s, 태그를 아직 바꾸지 않았다면 --no-start 없이 immich_revert_restore %s\n' "$old" "$old"
    return 0
  fi
  if ! sudo systemctl start podman-immich-ml.service podman-immich-server.service; then
    printf '앱 시작 실패 — 로그(sudo podman logs --tail 50 immich-server)를 보거나 immich_revert_restore %s로 되돌린다\n' "$old" >&2
    return 1
  fi
  printf '전환 완료 — 이전 DB: %s\n' "$old"
}

# 4) 복귀: 인자는 전환 때 출력된 이전 DB 이름
#    --no-start: 이름을 되돌린 뒤 앱을 멈춘 채 둔다(--no-start로 전환해 태그도 되돌려야 할 때)
immich_revert_restore() {
  local start=1
  if [ "${1:-}" = --no-start ]; then
    start=0
    shift
  fi
  case "$#:${1:-}" in
    1:immich_before_restore_*) ;;
    *)
      printf '사용법: immich_revert_restore [--no-start] immich_before_restore_<시각>\n' >&2
      return 2
      ;;
  esac
  # 앱을 멈추기 전에 이전 DB가 있는지 본다
  immich_psql -d postgres -v old="$1" <<'SQL' || return 1
SET restore.old_db = :'old';
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = current_setting('restore.old_db')) THEN
    RAISE EXCEPTION '이전 DB % 가 없다', current_setting('restore.old_db');
  END IF;
END
$$;
SQL
  sudo systemctl stop podman-immich-server.service podman-immich-ml.service || return 1
  if ! immich_assert_no_connections || ! immich_psql -d postgres -v old="$1" <<'SQL'
BEGIN;
ALTER DATABASE immich RENAME TO immich_restore;
ALTER DATABASE :"old" RENAME TO immich;
COMMIT;
SQL
  then
    printf '복귀 실패 — DB 이름은 그대로이고 앱은 멈춰 있다. 원인을 해결해 다시 실행하거나, 지금 DB로 앱을 시작하려면: sudo systemctl start podman-immich-ml.service podman-immich-server.service\n' >&2
    return 1
  fi
  if [ "$start" = 0 ]; then
    printf 'DB 이름을 되돌렸다. 앱은 멈춘 채 둔다. 다음: immich.nix의 immich-server·immich-ml 태그를 전환 전 버전으로 되돌리고 nrs한다. nrs 뒤 앱이 떠 있지 않으면: sudo systemctl start podman-immich-ml.service podman-immich-server.service\n'
    return 0
  fi
  if ! sudo systemctl start podman-immich-ml.service podman-immich-server.service; then
    printf '앱 시작 실패 — 로그(sudo podman logs --tail 50 immich-server)를 본다\n' >&2
    return 1
  fi
  printf '복귀 완료 — 복원했던 DB는 immich_restore로 남았다\n'
}
```

#### 2. 복원과 검증

여유 공간을 먼저 본다. 복원하는 동안 `immich` DB 크기만큼 공간이 더 필요하다.

```bash
immich_psql -d postgres <<'SQL'
SELECT pg_size_pretty(pg_database_size('immich')) AS immich_size;
SQL
df -h /var/lib/docker-data
```

복원하고 검증한다. 앱은 기존 DB로 계속 동작한다.

```bash
immich_restore_db
```

- 새 DB `immich_restore`(소유자 `immich`, `template0` 기반)를 만든다. 같은 이름이 이미 있으면 지우지 않고 멈춘다. 이전 시도의 잔재인지 확인한 뒤 5절의 명령으로 지운다.
- 확장자로 형식을 고른다. `.dump`는 `pg_restore --exit-on-error`, `.sql.gz`는 `gzip -dc`를 거쳐 `psql -v ON_ERROR_STOP=1 --single-transaction`으로 복원한다. 둘 다 root 셸(`sudo bash -o pipefail -c`)이 파일을 연다.
- 복원이 실패하면 `immich_restore`를 지우고 종료 코드 1로 끝난다.
- 이어서 `immich_verify_restore`가 복원 DB를 검증한다. 다음이 모두 있어야 통과한다.
  - 핵심 테이블 `user`·`asset`·`album`과 각 테이블의 기본 키
  - public 스키마의 외래 키와 인덱스
  - `IMMICH_REQUIRED_EXTENSIONS`의 확장
  - `user`·`asset`의 행
- 검증에 실패하면 `immich_restore`를 지우고 멈춘다.
- 통과하면 확장 목록과 사용자·자산·앨범 수를 출력하고, 현재 `immich`와 `immich_restore`의 기본 키·외래 키·UNIQUE·인덱스 수를 나란히 출력한다. 수가 기대(예: 사고 전 웹 UI의 사진 수)와 맞는지 확인한 뒤 전환한다. 제약·인덱스 수가 다르다는 이유만으로 멈추지는 않으니, 차이가 있으면 원인을 판단한다.
- 마지막으로 `immich_restore`에 검증 완료 표식을 남긴다. `immich_verify_restore`를 단독으로 부르면 판정만 하고 DB를 지우지 않는다.

백업 시점의 Immich 버전을 보고 현재 이미지 태그와 비교한다. 다르면 "지키는 조건"의 앱 버전 순서를 따른다.

```bash
immich_psql -d immich_restore <<'SQL'
SELECT version, "createdAt" FROM version_history ORDER BY "createdAt" DESC LIMIT 1;
SQL
```

#### 3. 전환

백업 시점 버전과 현재 이미지 태그가 같으면 아래를 실행한다.

```bash
immich_switch_to_restore
```

다르면 앱을 멈춘 채 전환하고, 출력된 안내대로 태그를 백업 시점 버전으로 바꿔 `nrs`한다.

```bash
immich_switch_to_restore --no-start
```

1. `immich_restore`에 검증 완료 표식이 있는지 보고, 표식의 백업 파일 이름을 출력한다. 표식이 없으면 앱을 건드리지 않고 거부한다. `immich_restore_db`로 다시 복원하되, 남은 `immich_restore`는 내용을 확인한 뒤 5절 방법으로 지운다.
2. 백업 시점 버전(`version_history` 최근 행)을 출력한다. 1.133.0 미만이거나 읽을 수 없으면 앱을 건드리지 않고 거부한다.
3. 검증을 다시 실행한다. 실패하면 `immich_restore`를 지우고, 앱을 건드리지 않고 멈춘다.
4. `podman-immich-server`와 `podman-immich-ml`을 멈춘다.
5. `immich`·`immich_restore`·`immich_before_restore_*` DB에 남은 클라이언트 연결이 없는지 확인한다. 남아 있으면 각 연결의 pid·DB·앱 이름·주소를 출력한다.
6. `postgres` DB에서 한 트랜잭션으로 표식을 다시 확인하고, 표식을 지우고, 이름을 바꾼다: `immich` → `immich_before_restore_<시각>`, `immich_restore` → `immich`. 1 이후 표식이 사라졌거나 하나라도 실패하면 모두 되돌려진다.
7. 이전 DB 이름을 먼저 출력하고 앱을 시작한다. 복귀와 정리에 이 이름을 쓴다. 앱 시작이 실패하면 복귀 명령을 안내한다. `--no-start`면 앱을 멈춘 채 두고 다음 단계(태그 변경과 `nrs`)를 출력한다.

5·6에서 실패하면 DB 이름은 그대로이고 앱은 멈춘 채 남는다. 원인(예: 남은 연결)을 해결하고 `immich_switch_to_restore`를 다시 실행한다. 복원을 포기하려면 기존 DB 그대로 앱을 시작한다: `sudo systemctl start podman-immich-ml.service podman-immich-server.service`.

전환 뒤 앱을 확인한다. Immich는 시작할 때 확장 버전과 마이그레이션을 점검하므로, 로그에 오류가 없고 웹에서 사진·앨범이 보이는지 본다.

```bash
curl -fsS http://127.0.0.1:2283/api/server/ping
sudo podman logs --tail 50 immich-server
```

#### 4. 복귀

전환 뒤 문제가 있으면 전환 때 출력된 이전 DB 이름으로 되돌린다.

```bash
immich_revert_restore immich_before_restore_YYYYMMDD_HHMMSS
```

`--no-start`로 전환해 태그도 바꿨다면, 앱을 멈춘 채 이름을 되돌린 뒤 태그를 전환 전 버전으로 되돌려 `nrs`한다. `nrs` 뒤 앱이 떠 있지 않으면 `sudo systemctl start podman-immich-ml.service podman-immich-server.service`로 시작한다. `--no-start`로 전환했어도 태그를 아직 바꾸지 않았다면 위의 기본 복귀로 이름을 되돌리고 앱을 시작한다.

```bash
immich_revert_restore --no-start immich_before_restore_YYYYMMDD_HHMMSS
```

먼저 이전 DB가 있는지 보고, 없으면 앱을 멈추지 않고 끝난다. 이어서 앱을 멈추고 연결을 확인한 뒤, 한 트랜잭션으로 `immich` → `immich_restore`, `immich_before_restore_<시각>` → `immich`로 바꾸고 앱을 시작한다. 복원했던 DB는 표식 없이 `immich_restore`로 남으므로 다시 전환되지 않는다.

복귀가 실패하면 DB 이름은 그대로이고 앱은 멈춘 채 남는다. 원인(예: 남은 연결)을 해결해 다시 실행하거나, 지금 DB로 앱을 시작한다: `sudo systemctl start podman-immich-ml.service podman-immich-server.service`.

#### 5. 정리

이전 DB는 자동으로 지우지 않는다. 다음을 모두 확인한 뒤 수동으로 지운다.

- 웹·앱에서 사진·앨범·사용자가 기대대로 보인다.
- 전환 뒤 일일 백업(`immich-db-backup`)이 한 번 이상 성공했다. `systemctl status immich-db-backup`과 `sudo ls -l /mnt/data/backups/immich/`로 본다. 복원된 DB의 백업이 생기기 전에는 이전 DB가 유일한 되돌릴 곳이다.
- 복귀하지 않기로 했다.

```bash
immich_psql -d postgres <<'SQL'
DROP DATABASE immich_before_restore_YYYYMMDD_HHMMSS;
SQL
```

복귀 뒤 남은 `immich_restore`에는 전환 기간에 앱이 쓴 행(새 업로드·편집)이 들어 있다. 필요한 내용을 옮기거나 버려도 되는지 확인한 뒤에 지운다. 이전 시도의 잔재도 같은 방법(`DROP DATABASE immich_restore;`)으로 지운다.

#### 검증 범위와 미확인 조건

`tests/suites/immich-db-restore.sh`가 "1. 준비" 블록을 그대로 source해 합성 PostgreSQL 16(prePushRuntime의 `postgresql_16`)에서 실행한다. `sudo`·`podman`·`systemctl`만 대역으로 바꾼다. 확인하는 것:

- 두 형식 모두 원본을 바꾼 뒤 복원·전환하면 행·스키마·제약·인덱스·소유자가 백업 시점과 같다. 전환 전 DB는 그대로 남고 복귀로 되찾는다.
- 일반 사용자가 열 수 없는 백업을 root 셸로 읽고, 백업 파일의 권한·소유자·내용은 바뀌지 않는다. 옛 형태(파이프 앞단 `gunzip`, 입력 리다이렉션)는 `Permission denied`로 실패하고, 파이프 형태는 `pipefail`이 없으면 종료 코드 0으로 실패를 가린다.
- 손상된 gzip, 중간 SQL 오류, `pg_restore` 실패, 검증 실패(행·확장·테이블)는 모두 종료 코드 1로 끝나고, 전환과 앱 재시작 없이 기존 DB를 그대로 둔다.
- post-data가 빠진 `immich_restore`는 표식이 없으면 표식 확인에서, 표식이 있으면 검증에서 전환을 거부한다. FK만 빠진 백업도 검증에서 멈춘다. 복귀 뒤 남은 `immich_restore`도 다시 전환하지 않는다.
- 복원 도중 운영자 셸이 죽어 검증을 통과할 만한 부분 복원(마지막 FK만 빠짐)이 남아도, 표식이 없어 전환하지 않는다. 표식 확인 뒤 표식이 사라지면 이름 변경 트랜잭션이 거부한다.
- 백업 시점 버전이 1.133.0 미만이거나 `version_history`가 없거나 버전을 읽을 수 없으면, 두 전환 방식 모두 앱을 건드리지 않고 거부한다. 버전은 성분별 정수로 비교한다(1.133.0은 받고 1.99.0은 거부한다). `--no-start` 전환과 복귀는 이름만 바꾸고 앱을 시작하지 않는다.
- 전환·복귀 함수의 인자 형태가 틀리면(뒤에 붙은 `--no-start`, 남는 인자, 빠진 이전 DB 이름) 앱·DB를 건드리지 않고 종료 코드 2로 끝난다.
- 연결이 남아 있으면 이름을 바꾸지 않는다. 확인 뒤 생긴 연결로 두 번째 이름 변경이 실패해도 첫 번째 변경과 표식 삭제까지 되돌려진다.
- 복원 DB는 `template0`에서 만들어 `template1`의 객체가 섞이지 않는다.

합성 환경에서 확인하지 못한 조건:

- 운영 postgres 이미지(`modules/nixos/programs/docker/immich.nix`의 `immich-postgres`)의 VectorChord·pgvector 확장. 테스트는 `IMMICH_REQUIRED_EXTENSIONS`에서 `vector`·`vchord`를 빼고 실행하므로, 실제 복원에서는 검증 단계가 두 확장의 존재를 확인한다.
- 확장 목록과 핵심 테이블 이름은 운영 중인 Immich 태그의 소스(`server/src/schema`) 기준이다. 태그를 바꾸면 다시 확인한다: `gh api "repos/immich-app/immich/contents/server/src/schema/index.ts?ref=<태그>" -H "Accept: application/vnd.github.raw" | grep @Extensions`(기본 내장인 `plpgsql`을 빼고 이미지가 주는 `vector`·`vchord`를 더한 것이 목록)와 `server/src/schema/tables/{user,asset,album}.table.ts`의 `@Table` 이름. pgvecto.rs를 쓰던 시기(이 저장소의 VectorChord 전환 이전)의 백업은 `vchord`가 없어 검증에서 멈춘다.
- [Immich 공식 복원 문서](https://docs.immich.app/administration/backup-and-restore)는 평문 SQL을 넣기 전에 `search_path` 설정 줄을 `sed`로 바꾼다. 합성 스키마(스키마를 명시한 SQL 함수와 식 인덱스)는 바꾸지 않고도 복원됐지만 실제 덤프로는 확인하지 않았다. `search_path` 관련 오류(`function … does not exist` 등)로 복원이 실패해도 절차는 기존 DB를 그대로 두고 멈춘다.
- 복원은 운영 중인 같은 postgres 컨테이너(메모리 제한 1g, `libraries/constants.nix`)에서 인덱스를 다시 만든다. 메모리가 모자라 OOM이 나면 PostgreSQL 전체가 복구 과정에 들어가 운영 연결도 끊길 수 있다. 합성 DB는 작아서 이 부하를 재현하지 않았다.
- DB 수준 설정(`ALTER DATABASE … SET`)은 `pg_dump`가 담지 않고, 이름 맞바꾸기로도 옮겨지지 않는다. Immich는 VectorChord 확장을 처음 만들 때만 `vchordrq.probes`를 DB 수준으로 설정하고, 검색 쿼리마다 `SET LOCAL`로 다시 지정한다(`server/src/repositories/database.repository.ts`의 `createExtension`과 `search.repository.ts` 기준). 전환 뒤 두 DB의 설정 차이는 아래로 본다.

```bash
immich_psql -d postgres <<'SQL'
SELECT d.datname, s.setconfig
  FROM pg_db_role_setting s JOIN pg_database d ON d.oid = s.setdatabase
 WHERE s.setrole = 0 AND (d.datname = 'immich' OR d.datname LIKE 'immich\_%');
SQL
```

## 트러블슈팅

### GitHub API rate limit

증상: 버전 체크가 조용히 실패 (로그에 "GitHub API request failed")

원인: 비인증 요청 60회/시간 제한

해결: 1일 1회 체크이므로 일반적으로 문제 없음. 다른 서비스가 같은 IP에서 GitHub API를 대량 호출하는지 확인

### 헬스체크 실패

증상: "Immich did not respond after 10 minutes"

원인:
- DB 마이그레이션이 10분 이상 소요 (대규모 업데이트)
- 컨테이너 시작 실패

해결:
```bash
# 로그 확인
sudo podman logs immich-server
sudo podman logs immich-ml
journalctl -u podman-immich-server -f

# 수동 재시작
sudo systemctl restart podman-immich-server.service
```

### Pushover 알림 미전송

증상: 새 버전이 있지만 알림이 오지 않음

확인:
```bash
# 수동 실행하여 로그 확인
sudo systemctl start immich-version-check
journalctl -u immich-version-check --no-pager

# 시크릿 파일 존재 확인
ls -la /run/agenix/immich-api-key /run/agenix/pushover-immich
```

### 초기 실행 후 알림 없음

원인: 정상 동작. 첫 실행 시 현재 버전을 기록만 하고 알림을 보내지 않음.

확인:
```bash
cat /var/lib/immich-update/last-notified-version
```

### 워치독 경고 수신

증상: "버전 체크가 N일간 성공하지 못했습니다" Pushover 알림

원인:
- Immich 서비스가 장기간 다운
- GitHub API가 지속적으로 실패
- 네트워크 문제

확인:
```bash
# 마지막 성공 시각 확인
sudo cat /var/lib/immich-update/last-success
# → Unix timestamp (예: 1770373041)

# 수동 실행하여 원인 확인
sudo systemctl start immich-version-check
journalctl -u immich-version-check --no-pager
```

### 동시 실행 차단

증상: "Another immich-update is already running"

원인: `sudo immich-update`가 이미 다른 터미널에서 실행 중

해결: 기존 프로세스 완료 대기 또는 `ps aux | grep immich-update`로 확인

### 타이머 미동작

```bash
# 타이머 상태 확인
systemctl list-timers | grep immich-version-check

# 타이머 활성화 확인
systemctl status immich-version-check.timer

# 수동 트리거
sudo systemctl start immich-version-check
```
