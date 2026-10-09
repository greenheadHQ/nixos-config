# tests/suites/immich-db-restore.sh — Immich DB 복구 문서 절차의 합성 PostgreSQL 16 검증 (#1397)
# shellcheck shell=bash
# SC2016: fake 도구·실행 스크립트는 작은따옴표 literal. SC2154: 공통 변수는 aggregator가 정의.
# shellcheck disable=SC2016,SC2154
#
# immich-update.md "복구 절차"의 "1. 준비" bash 블록을 그대로 source해 문서 함수로 복원·전환·복귀를
# 실행한다. 실제 DB·백업·컨테이너 대신 prePushRuntime의 postgresql_16 임시 클러스터를 쓰고,
# 아래 PATH 대역만 끼운다.
#   - podman: `podman exec [-i] immich-postgres <cmd>`를 로컬 <cmd>로 실행한다. `-i`가 없으면 표준
#     입력을 붙이지 않는다(실제 podman과 같다). root가 아니면 거부한다(rootful 컨테이너).
#     FAKE_RACE_DB를 주면 이름 변경 직전에 그 DB로 연결을 연다(확인과 변경 사이의 경합).
#     FAKE_RACE_CLEAR_MARKER를 주면 이름 변경 직전에 immich_restore의 검증 완료 표식을 지운다.
#     FAKE_INTERRUPT_RESTORE를 주면 plain SQL 복원 입력을 마지막 제약 직전에서 끊어(psql -1은
#     입력이 끝나면 COMMIT한다) 부분 복원을 남기고, 운영자 셸(FAKE_OPERATOR_PID)을 죽인다.
#   - systemctl: podman-immich-server/ml 유닛만 받는다. server 시작은 immich DB에 연결을 여는
#     앱 대역을 띄우고, 중지는 그 연결이 끊길 때까지 기다린다. root가 아니면 거부한다.
#     FAKE_START_FAIL을 주면 start가 실패한다.
#   - sudo: root 권한을 흉내 낸다. 실제 root 전용(0700) 디렉터리는 만들 수 없으므로, 일반 사용자가
#     보는 백업 경로는 권한 000 디렉터리 아래에 두고(열면 Permission denied) sudo 대역만 그 경로를
#     root 시점 트리(0700 디렉터리, 0600 파일)로 옮겨 적는다. 그래서 일반 사용자 셸이 여는 형태
#     (리다이렉션·파이프 앞단)는 실패하고, 파일을 여는 명령 전체가 sudo 아래에 있을 때만 읽힌다.
# 문서의 확장 목록 중 vector·vchord는 이 PostgreSQL에 없어 제외한다(미확인 범위).

_immich_restore_doc() {
  printf '%s/.claude/skills/running-containers/references/immich-update.md' "$REPO_ROOT"
}

_immich_restore_mode() {
  local mode
  if mode="$(stat -c '%a' "$1" 2>/dev/null)"; then
    printf '%s\n' "$mode"
    return
  fi
  /usr/bin/stat -f '%Lp' "$1"
}

_immich_restore_uid() {
  local uid
  if uid="$(stat -c '%u' "$1" 2>/dev/null)"; then
    printf '%s\n' "$uid"
    return
  fi
  /usr/bin/stat -f '%u' "$1"
}

_immich_restore_require_tools() {
  local tool version
  for tool in initdb pg_ctl psql pg_dump pg_restore gzip gunzip zsh; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "SKIP: immich DB restore fixture requires $tool (prePushRuntime provides postgresql_16 and zsh)"
      return 1
    fi
  done
  version="$(initdb --version)"
  case "$version" in
    *" 16."*) ;;
    *)
      echo "SKIP: immich DB restore fixture requires PostgreSQL 16 on PATH (found: $version)"
      return 1
      ;;
  esac
  if [ "$(id -u)" = 0 ]; then
    echo "SKIP: immich DB restore fixture cannot run as root (initdb refuses root)"
    return 1
  fi
}

# 문서 "#### 1. 준비" 절의 bash 블록을 순서대로 이어 붙인다.
_immich_restore_extract_procedure() {
  awk '
    $0 == "#### 1. 준비" { in_sec = 1; next }
    in_fence && /^```[[:space:]]*$/ { in_fence = 0; next }
    in_fence { print; next }
    in_sec && /^#+ / { exit }
    in_sec && /^```bash[[:space:]]*$/ { in_fence = 1; next }
  ' "$(_immich_restore_doc)"
}

_immich_restore_write_fakes() {
  local bin="$1"
  mkdir -p "$bin"

  cat > "$bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'sudo %s\n' "$*" >> "$FAKE_TRACE"
args=()
for arg in "$@"; do
  args+=("${arg//"$FAKE_USER_VIEW"/"$FAKE_ROOT_VIEW"}")
done
FAKE_SUDO_ROOT=1 exec "${args[@]}"
EOF

  cat > "$bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAKE_SUDO_ROOT:-}" = 1 ] || { echo "podman: rootful container requires root (fake)" >&2; exit 125; }
[ "${1:-}" = exec ] || { echo "fake podman: only exec is supported" >&2; exit 125; }
shift
interactive=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -i) interactive=1; shift ;;
    -*) echo "fake podman: unsupported exec option $1" >&2; exit 125 ;;
    *) break ;;
  esac
done
[ "${1:-}" = immich-postgres ] || { echo "fake podman: no such container: ${1:-}" >&2; exit 125; }
shift
printf 'podman exec %s\n' "$*" >> "$FAKE_TRACE"
# FAKE_RACE_DB: 이름 변경 호출(-v old=...) 직전에 그 DB로 연결을 한 번 열어, 연결 확인과 이름 변경
# 사이에 생긴 연결을 흉내 낸다.
if [ -n "${FAKE_RACE_DB:-}" ] && [[ " $* " == *" old="* ]] && [ ! -e "$FAKE_TRACE.race" ]; then
  : > "$FAKE_TRACE.race"
  PGAPPNAME=race-client nohup psql -X -q -U immich -d "$FAKE_RACE_DB" -c 'SELECT pg_sleep(86400)' \
    </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$FAKE_APP_PIDS"
  for _ in $(seq 1 100); do
    [ "$(psql -X -At -U immich -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'race-client'")" = 1 ] && break
    sleep 0.1
  done
fi
if [ -n "${FAKE_RACE_CLEAR_MARKER:-}" ] && [[ " $* " == *" old="* ]] && [ ! -e "$FAKE_TRACE.clear" ]; then
  : > "$FAKE_TRACE.clear"
  psql -X -q -U immich -d postgres -c 'COMMENT ON DATABASE immich_restore IS NULL'
fi
if [ -n "${FAKE_INTERRUPT_RESTORE:-}" ] && [[ " $* " == *" --single-transaction "* ]]; then
  partial="$(mktemp "${TMPDIR:-/tmp}/interrupted-restore.XXXXXX")"
  cat > "$partial"
  cut="$(awk '/^    ADD CONSTRAINT /{ last = NR - 2 } END { print last }' "$partial")"
  head -n "$cut" "$partial" | "$@" || true
  rm -f "$partial"
  kill -KILL "$FAKE_OPERATOR_PID"
  exit 1
fi
if [ "$interactive" = 1 ]; then
  exec "$@"
fi
exec "$@" </dev/null
EOF

  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAKE_SUDO_ROOT:-}" = 1 ] || { echo "systemctl: access denied (fake: root required)" >&2; exit 4; }
action="${1:-}"
shift || true
server=0
for unit in "$@"; do
  case "$unit" in
    podman-immich-server.service) server=1 ;;
    podman-immich-ml.service) ;;
    *) echo "Unit $unit not found." >&2; exit 5 ;;
  esac
done
printf 'systemctl %s %s\n' "$action" "$*" >> "$FAKE_TRACE"
if [ "$action" = start ] && [ -n "${FAKE_START_FAIL:-}" ]; then
  echo "Job for podman-immich-server.service failed (fake)." >&2
  exit 1
fi
[ "$server" = 1 ] || exit 0
app_connections() {
  psql -X -At -U immich -d postgres \
    -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'fake-immich-server'"
}
case "$action" in
  start)
    if [ "$(app_connections)" != 0 ]; then
      exit 0
    fi
    PGAPPNAME=fake-immich-server nohup psql -X -q -U immich -d immich -c 'SELECT pg_sleep(86400)' \
      </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" >> "$FAKE_APP_PIDS"
    for _ in $(seq 1 100); do
      [ "$(app_connections)" = 1 ] && exit 0
      sleep 0.1
    done
    echo "fake immich-server could not connect to immich" >&2
    exit 1
    ;;
  stop)
    # 컨테이너가 멈추면 앱의 DB 연결도 끊긴다.
    psql -X -q -At -U immich -d postgres -o /dev/null \
      -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = 'fake-immich-server'"
    for _ in $(seq 1 100); do
      [ "$(app_connections)" = 0 ] && exit 0
      sleep 0.1
    done
    echo "fake immich-server connection did not close" >&2
    exit 1
    ;;
  *)
    echo "fake systemctl: unsupported action $action" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$bin/sudo" "$bin/podman" "$bin/systemctl"
}

# Immich 스키마를 줄인 합성 스키마: contrib 확장, 스키마 한정 SQL 함수와 식 인덱스,
# 예약어 테이블("user"), FK·CHECK·UNIQUE 제약, gin/gist 인덱스, version_history(최근 3.0.0 —
# Immich는 serverVersion.toString()을 v 접두 없이 기록한다).
_immich_restore_fixture_sql() {
  cat <<'SQL'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE FUNCTION f_unaccent(text) RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  RETURN unaccent('unaccent', $1);
CREATE FUNCTION ll_to_earth_public(latitude double precision, longitude double precision)
  RETURNS public.earth LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
  AS $$SELECT public.cube(public.cube(public.cube(public.earth()*cos(radians(latitude))*cos(radians(longitude))),public.earth()*cos(radians(latitude))*sin(radians(longitude))),public.earth()*sin(radians(latitude)))::public.earth$$;
CREATE TABLE "user" (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  email varchar NOT NULL CONSTRAINT user_email_uq UNIQUE,
  name varchar NOT NULL
);
CREATE TABLE asset (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  "ownerId" uuid NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  "originalFileName" varchar NOT NULL CONSTRAINT asset_name_nonempty CHECK ("originalFileName" <> ''),
  checksum bytea NOT NULL,
  CONSTRAINT asset_owner_checksum_uq UNIQUE ("ownerId", checksum)
);
CREATE INDEX asset_name_trgm_idx ON asset USING gin (f_unaccent("originalFileName") gin_trgm_ops);
CREATE TABLE asset_exif (
  "assetId" uuid PRIMARY KEY REFERENCES asset(id) ON DELETE CASCADE,
  latitude double precision,
  longitude double precision
);
CREATE INDEX exif_gist_earthcoord ON asset_exif USING gist (ll_to_earth_public(latitude, longitude));
CREATE TABLE album (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  "ownerId" uuid NOT NULL REFERENCES "user"(id),
  "albumName" varchar NOT NULL
);
CREATE TABLE version_history (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  "createdAt" timestamptz NOT NULL DEFAULT now(),
  version varchar NOT NULL
);
INSERT INTO version_history ("createdAt", version)
  VALUES ('2025-06-01T00:00:00Z', '1.132.3'), ('2026-07-03T00:00:00Z', '3.0.0');
INSERT INTO "user" (email, name) VALUES ('admin@example.invalid', 'Admin'), ('b@example.invalid', 'Béla');
INSERT INTO asset ("ownerId", "originalFileName", checksum)
  SELECT u.id, 'IMG_' || g || '.jpg', decode(md5(u.email || g), 'hex') FROM "user" u, generate_series(1, 3) g;
INSERT INTO asset_exif ("assetId", latitude, longitude) SELECT id, 37.5, 127.0 FROM asset;
INSERT INTO album ("ownerId", "albumName") SELECT id, 'Trip' FROM "user" WHERE name = 'Admin';
SQL
}

_immich_restore_psql() {
  psql -X -q -v ON_ERROR_STOP=1 -U immich "$@"
}

_immich_restore_make_db() {
  local db="$1"
  _immich_restore_psql -d postgres -c "CREATE DATABASE \"$db\" OWNER immich TEMPLATE template0"
  _immich_restore_fixture_sql | _immich_restore_psql -d "$db" >/dev/null
}

_immich_restore_db_exists() {
  [ "$(psql -X -At -U immich -d postgres -c "SELECT count(*) FROM pg_database WHERE datname = '$1'")" = 1 ]
}

_immich_restore_before_dbs() {
  psql -X -At -U immich -d postgres \
    -c "SELECT coalesce(string_agg(datname, ' ' ORDER BY datname), '') FROM pg_database WHERE datname LIKE 'immich\\_before\\_restore\\_%'"
}

_immich_restore_app_connections() {
  psql -X -At -U immich -d postgres \
    -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'fake-immich-server' AND datname = 'immich'"
}

# DB 상태 요약: 스키마(제약·인덱스·함수·확장·객체 소유자 포함), 테이블별 행 수와 정렬 checksum, DB 소유자.
_immich_restore_snapshot() {
  local db="$1" table
  pg_dump -s -U immich "$db" | grep -Ev '^\\(un)?restrict '
  psql -X -At -U immich -d "$db" -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY 1" \
    | while IFS= read -r table; do
      printf '%s ' "$table"
      psql -X -At -U immich -d "$db" \
        -c "SELECT count(*) || ' ' || md5(coalesce(string_agg(t::text, E'\\n' ORDER BY t::text), '')) FROM public.\"$table\" t"
    done
  psql -X -At -U immich -d postgres -c "SELECT 'db owner ' || pg_get_userbyid(datdba) FROM pg_database WHERE datname = '$db'"
}

_immich_restore_file_state() {
  printf '%s %s %s %s %s\n' \
    "$(_immich_restore_mode "$IMMICH_RESTORE_SANDBOX/fs/mnt/data/backups/immich")" \
    "$(_immich_restore_mode "$IMMICH_RESTORE_SANDBOX/fs/var/lib/immich-update/backups")" \
    "$(_immich_restore_mode "$IMMICH_RESTORE_SANDBOX/rootfs/mnt/data/backups/immich")" \
    "$(_immich_restore_mode "$IMMICH_RESTORE_SANDBOX/rootfs/var/lib/immich-update/backups")" \
    "$(_immich_restore_uid "$IMMICH_RESTORE_SANDBOX/rootfs/mnt/data/backups/immich")"
  local file
  for file in "$IMMICH_RESTORE_SANDBOX"/rootfs/mnt/data/backups/immich/* \
    "$IMMICH_RESTORE_SANDBOX"/rootfs/var/lib/immich-update/backups/*; do
    printf '%s %s %s %s\n' "${file##*/}" "$(_immich_restore_mode "$file")" "$(_immich_restore_uid "$file")" \
      "$(cksum < "$file")"
  done
}

# 백업 파일을 root 시점 트리(0700/0600)에 두고, 일반 사용자 시점 경로를 출력한다.
_immich_restore_place_backup() {
  local src="$1" rel="$2" root_path
  root_path="$IMMICH_RESTORE_SANDBOX/rootfs/$rel"
  chmod 700 "$(dirname "$root_path")"
  cp "$src" "$root_path"
  chmod 600 "$root_path"
  printf '%s/fs/%s\n' "$IMMICH_RESTORE_SANDBOX" "$rel"
}

_immich_restore_lock_user_view() {
  chmod 000 "$IMMICH_RESTORE_SANDBOX/fs/mnt/data/backups/immich" \
    "$IMMICH_RESTORE_SANDBOX/fs/var/lib/immich-update/backups"
}

_immich_restore_teardown() {
  local pid
  chmod 700 "$IMMICH_RESTORE_SANDBOX/fs/mnt/data/backups/immich" \
    "$IMMICH_RESTORE_SANDBOX/fs/var/lib/immich-update/backups" 2>/dev/null || true
  if [ -f "$IMMICH_RESTORE_SANDBOX/pgdata/postmaster.pid" ]; then
    pg_ctl -D "$IMMICH_RESTORE_SANDBOX/pgdata" -m immediate -w stop >/dev/null 2>&1 || true
  fi
  if [ -f "$FAKE_APP_PIDS" ]; then
    while IFS= read -r pid; do
      kill "$pid" 2>/dev/null || true
    done < "$FAKE_APP_PIDS"
  fi
}

# 클러스터·원본 immich DB·앱 대역·잠긴 백업 디렉터리를 준비한다. 호출자는 subshell 안에서
# `trap _immich_restore_teardown EXIT`를 먼저 건다.
_immich_restore_setup() {
  local sandbox="$1" sock procedure_file pg_bin
  IMMICH_RESTORE_SANDBOX="$sandbox"
  # nixpkgs PostgreSQL은 실행 경로(symlink 포함) 기준으로 share·lib을 찾는다(relative-to-symlinks
  # 패치). prePushRuntime은 /bin만 링크하므로 실제 store bin을 PATH 앞에 둔다.
  pg_bin="$(dirname "$(readlink -f "$(command -v initdb)")")"
  export PATH="$pg_bin:$PATH"
  mkdir -p "$sandbox/rootfs/mnt/data/backups/immich" "$sandbox/rootfs/var/lib/immich-update/backups" \
    "$sandbox/fs/mnt/data/backups/immich" "$sandbox/fs/var/lib/immich-update/backups"
  _immich_restore_write_fakes "$sandbox/bin"

  sock="$sandbox/s"
  # unix socket 경로 상한(macOS 104바이트)을 넘으면 짧은 경로로 옮긴다.
  if [ "${#sock}" -gt 80 ]; then
    sock="$(mktemp -d /tmp/immich-restore.XXXXXX)"
    printf '%s\n' "$sock" >> "$TEST_TMP_FILE"
  fi
  mkdir -p "$sock"
  unset PGPORT PGUSER PGDATABASE PGPASSWORD PGSERVICE PGOPTIONS PGAPPNAME PGHOSTADDR BASH_ENV
  export PGHOST="$sock"
  export FAKE_TRACE="$sandbox/trace" FAKE_APP_PIDS="$sandbox/app.pids"
  export FAKE_USER_VIEW="$sandbox/fs/" FAKE_ROOT_VIEW="$sandbox/rootfs/" IMMICH_RESTORE_FAKE_BIN="$sandbox/bin"
  : > "$FAKE_TRACE"

  initdb -D "$sandbox/pgdata" -U immich --auth=trust -E UTF8 --locale=C >/dev/null
  pg_ctl -D "$sandbox/pgdata" -l "$sandbox/pg.log" \
    -o "-k '$sock' -c listen_addresses='' -c fsync=off" -w start >/dev/null
  _immich_restore_psql -d postgres -c 'CREATE ROLE immich_mutator'
  _immich_restore_make_db immich
  # template1에 객체를 둔다. 복원 DB를 template1로 만들면 이 테이블이 섞여 스냅샷이 달라진다.
  _immich_restore_psql -d template1 -c 'CREATE TABLE public.template1_leak (id int)'

  procedure_file="$sandbox/procedure.sh"
  _immich_restore_extract_procedure > "$procedure_file"
  [ -s "$procedure_file" ] || fail "immich-update.md '#### 1. 준비' bash 블록을 찾지 못했다"
  export IMMICH_RESTORE_PROCEDURE="$procedure_file"
  # 문서 확장 목록에서 합성 PostgreSQL에 없는 vector·vchord만 뺀다.
  IMMICH_RESTORE_TEST_EXTENSIONS="$(
    bash -c '. "$1" >/dev/null 2>&1; printf "%s" "${IMMICH_REQUIRED_EXTENSIONS:-}"' _ "$procedure_file"
  )"
  case " $IMMICH_RESTORE_TEST_EXTENSIONS " in
    *" vector "*) ;;
    *) fail "문서 확장 목록에 vector가 없다: $IMMICH_RESTORE_TEST_EXTENSIONS" ;;
  esac
  case " $IMMICH_RESTORE_TEST_EXTENSIONS " in
    *" vchord "*) ;;
    *) fail "문서 확장 목록에 vchord가 없다: $IMMICH_RESTORE_TEST_EXTENSIONS" ;;
  esac
  # shellcheck disable=SC2086  # 공백 구분 목록을 단어로 나눈다.
  IMMICH_RESTORE_TEST_EXTENSIONS="$(printf '%s\n' $IMMICH_RESTORE_TEST_EXTENSIONS | grep -Evx 'vector|vchord' | tr '\n' ' ')"
  export IMMICH_RESTORE_TEST_EXTENSIONS

  PATH="$sandbox/bin:$PATH" sudo systemctl start podman-immich-ml.service podman-immich-server.service
  [ "$(_immich_restore_app_connections)" = 1 ] || fail "앱 대역이 immich DB에 연결되지 않았다"
  : > "$FAKE_TRACE"
}

_immich_restore_make_backups() {
  local sandbox="$IMMICH_RESTORE_SANDBOX"
  # 일일 백업처럼 pg_dump -Fc 출력을 파이프로 받아(offset 없는 archive) 파일로 만든다.
  pg_dump -Fc -U immich immich | cat > "$sandbox/src.dump"
  pg_dump -U immich immich | gzip > "$sandbox/src.sql.gz"
  IMMICH_RESTORE_DUMP="$(_immich_restore_place_backup "$sandbox/src.dump" mnt/data/backups/immich/immich-db-2026-09-27_053000.dump)"
  IMMICH_RESTORE_SQL_GZ="$(_immich_restore_place_backup "$sandbox/src.sql.gz" var/lib/immich-update/backups/backup-20260927-030000.sql.gz)"
}

# 백업 뒤 원본을 바꾼다: 행 삭제·추가, 제약·인덱스 삭제, 소유자 변경.
_immich_restore_mutate_original() {
  _immich_restore_psql -d immich <<'SQL'
DELETE FROM asset WHERE "originalFileName" = 'IMG_1.jpg';
INSERT INTO "user" (email, name) VALUES ('late@example.invalid', 'Late');
ALTER TABLE asset DROP CONSTRAINT asset_name_nonempty;
DROP INDEX exif_gist_earthcoord;
ALTER TABLE album OWNER TO immich_mutator;
SQL
}

# 문서 함수를 사용자 셸(bash 또는 zsh)에서 실행한다. $1 셸, $2 백업(일반 사용자 시점 경로), $3 명령.
_immich_restore_run() {
  local shell="$1" backup="$2" commands="$3"
  local -a shell_cmd
  case "$shell" in
    bash) shell_cmd=(bash -c) ;;
    zsh) shell_cmd=(zsh -f -c) ;;
    *) fail "unknown shell: $shell" ;;
  esac
  IMMICH_RESTORE_BACKUP="$backup" PATH="$IMMICH_RESTORE_SANDBOX/bin:$PATH" "${shell_cmd[@]}" \
    '[ "$(command -v sudo)" = "$IMMICH_RESTORE_FAKE_BIN/sudo" ] || { echo "fake sudo is not first on PATH" >&2; exit 97; }
FAKE_OPERATOR_PID=$$
export FAKE_OPERATOR_PID
. "$IMMICH_RESTORE_PROCEDURE"
BACKUP="$IMMICH_RESTORE_BACKUP"
IMMICH_REQUIRED_EXTENSIONS="$IMMICH_RESTORE_TEST_EXTENSIONS"
'"$commands"
}

# $4에 --no-start를 주면 전환이 앱을 멈춘 채 두는지(시작 호출 없음, 다음 단계 안내) 본다.
_immich_restore_assert_success_flow() {
  local shell="$1" backup="$2" before_backup_snapshot="$3" switch_args="${4:-}"
  local mutated_snapshot file_state output rc old

  _immich_restore_mutate_original
  mutated_snapshot="$(_immich_restore_snapshot immich)"
  [ "$mutated_snapshot" != "$before_backup_snapshot" ] || fail "fixture mutation did not change the original DB"
  file_state="$(_immich_restore_file_state)"
  if cat "$backup" >/dev/null 2>&1; then
    fail "일반 사용자 시점에서 백업을 읽을 수 있다 — 권한 대역이 성립하지 않는다"
  fi

  set +e
  output="$(_immich_restore_run "$shell" "$backup" 'immich_restore_db' 2>&1)"
  rc=$?
  set -e
  [ "$rc" = 0 ] || fail "immich_restore_db failed ($shell, $backup): $output"
  assert_contains "$output" "검증 통과"
  _immich_restore_db_exists immich_restore || fail "immich_restore DB가 없다"
  [ "$(_immich_restore_snapshot immich)" = "$mutated_snapshot" ] || fail "복원 단계가 기존 immich DB를 바꿨다"
  [ "$(_immich_restore_app_connections)" = 1 ] || fail "복원 단계가 앱을 멈췄다"
  if grep -q '^systemctl' "$FAKE_TRACE"; then
    fail "복원 단계가 systemctl을 호출했다: $(cat "$FAKE_TRACE")"
  fi

  set +e
  output="$(_immich_restore_run "$shell" "$backup" "immich_switch_to_restore $switch_args" 2>&1)"
  rc=$?
  set -e
  [ "$rc" = 0 ] || fail "immich_switch_to_restore $switch_args failed ($shell): $output"
  assert_contains "$output" "복원한 백업: ${backup##*/}"
  assert_contains "$output" "백업 시점 Immich 버전: 3.0.0"
  old="$(_immich_restore_before_dbs)"
  case "$old" in
    immich_before_restore_[0-9]*_[0-9]*) ;;
    *) fail "이전 DB 이름이 예상과 다르다: '$old'" ;;
  esac
  assert_contains "$output" "$old"
  [ "$(_immich_restore_snapshot immich)" = "$before_backup_snapshot" ] \
    || fail "전환 뒤 immich DB가 백업 시점(행·스키마·제약·소유자)과 다르다"
  [ "$(_immich_restore_snapshot "$old")" = "$mutated_snapshot" ] || fail "전환 전 DB가 보존되지 않았다"
  _immich_restore_db_exists immich_restore && fail "전환 뒤 immich_restore가 남았다"
  grep -Eq '^systemctl stop .*podman-immich-server\.service' "$FAKE_TRACE" \
    && grep -Eq '^systemctl stop .*podman-immich-ml\.service' "$FAKE_TRACE" \
    || fail "전환이 앱(server·ml)을 멈추지 않았다: $(cat "$FAKE_TRACE")"
  if [ "$switch_args" = --no-start ]; then
    if grep -q '^systemctl start' "$FAKE_TRACE"; then
      fail "--no-start 전환이 앱을 시작했다: $(cat "$FAKE_TRACE")"
    fi
    [ "$(_immich_restore_app_connections)" = 0 ] || fail "--no-start 전환 뒤 앱이 immich DB에 붙어 있다"
    assert_contains "$output" "이름 변경 완료 — 이전 DB: $old"
    assert_contains "$output" "nrs 뒤 앱이 떠 있지 않으면: sudo systemctl start podman-immich-ml.service podman-immich-server.service"
    assert_contains "$output" "immich_revert_restore --no-start $old"
    assert_contains "$output" "태그를 아직 바꾸지 않았다면 --no-start 없이 immich_revert_restore $old"
    assert_not_contains "$output" "전환 완료"
  else
    assert_contains "$output" "전환 완료"
    [ "$(_immich_restore_app_connections)" = 1 ] || fail "전환 뒤 앱이 immich DB에 다시 연결되지 않았다"
    grep -Eq '^systemctl start .*podman-immich-server\.service' "$FAKE_TRACE" \
      && grep -Eq '^systemctl start .*podman-immich-ml\.service' "$FAKE_TRACE" \
      || fail "전환이 앱(server·ml)을 시작하지 않았다: $(cat "$FAKE_TRACE")"
  fi
  [ "$(_immich_restore_file_state)" = "$file_state" ] || fail "백업 파일·디렉터리의 권한이나 소유자, 내용이 바뀌었다"

  IMMICH_RESTORE_OLD_DB="$old"
  IMMICH_RESTORE_MUTATED_SNAPSHOT="$mutated_snapshot"
}

# 전환 직후(이전 DB가 실제로 있을 때) 부른다. 인자 형태가 틀리면 앱·DB를 건드리기 전에 종료 코드
# 2로 끝나야 한다 — 뒤에 붙은 --no-start나 남는 인자를 무시하면 앱을 시작한 채 성공으로 끝난다.
_immich_restore_assert_usage_errors() {
  local shell="$1" backup="$2" old="$3" snapshot args output rc
  snapshot="$(_immich_restore_snapshot immich)"
  for args in \
    'immich_switch_to_restore --now' \
    'immich_switch_to_restore extra' \
    'immich_switch_to_restore --no-start extra' \
    'immich_revert_restore' \
    'immich_revert_restore --no-start' \
    "immich_revert_restore $old --no-start" \
    "immich_revert_restore --no-start $old extra" \
    "immich_revert_restore $old $old"; do
    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run "$shell" "$backup" "$args" 2>&1)"
    rc=$?
    set -e
    [ "$rc" = 2 ] || fail "사용법 오류가 종료 코드 2로 끝나지 않았다($shell: $args): rc=$rc $output"
    assert_contains "$output" "사용법:"
    [ ! -s "$FAKE_TRACE" ] || fail "사용법 오류에서 명령을 실행했다($shell: $args): $(cat "$FAKE_TRACE")"
  done
  [ "$(_immich_restore_snapshot immich)" = "$snapshot" ] || fail "사용법 오류가 immich DB를 바꿨다($shell)"
  [ "$(_immich_restore_before_dbs)" = "$old" ] || fail "사용법 오류가 DB 이름을 바꿨다($shell)"
}

# 계약 1·2·4: 일일 custom dump를 zsh에서 복원·전환한 뒤 복귀한다.
test_immich_restore_dump_switch_and_revert() {
  _immich_restore_require_tools || return 0
  (
    local sandbox before output rc
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    before="$(_immich_restore_snapshot immich)"
    _immich_restore_make_backups
    _immich_restore_lock_user_view

    _immich_restore_assert_success_flow zsh "$IMMICH_RESTORE_DUMP" "$before"
    _immich_restore_assert_usage_errors zsh "$IMMICH_RESTORE_DUMP" "$IMMICH_RESTORE_OLD_DB"

    # 없는 이전 DB 이름이면 앱을 멈추기 전에 거부한다.
    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run zsh "$IMMICH_RESTORE_DUMP" 'immich_revert_restore immich_before_restore_19990101_000000' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "없는 이전 DB로 복귀가 성공했다: $output"
    assert_contains "$output" "immich_before_restore_19990101_000000"
    if grep -q '^systemctl' "$FAKE_TRACE"; then
      fail "없는 이전 DB로 복귀하면서 앱을 멈췄다: $(cat "$FAKE_TRACE")"
    fi

    set +e
    output="$(_immich_restore_run zsh "$IMMICH_RESTORE_DUMP" "immich_revert_restore $IMMICH_RESTORE_OLD_DB" 2>&1)"
    rc=$?
    set -e
    [ "$rc" = 0 ] || fail "immich_revert_restore failed: $output"
    assert_contains "$output" "복귀 완료"
    [ "$(_immich_restore_snapshot immich)" = "$IMMICH_RESTORE_MUTATED_SNAPSHOT" ] \
      || fail "복귀 뒤 immich DB가 전환 전 DB와 다르다"
    [ "$(_immich_restore_snapshot immich_restore)" = "$before" ] || fail "복귀 뒤 복원 DB가 immich_restore로 남지 않았다"
    [ -z "$(_immich_restore_before_dbs)" ] || fail "복귀 뒤 immich_before_restore_* DB가 남았다"
    [ "$(_immich_restore_app_connections)" = 1 ] || fail "복귀 뒤 앱이 immich DB에 연결되지 않았다"

    # 복귀 뒤 남은 immich_restore(전환 기간의 쓰기가 들어 있을 수 있다)는 다시 전환하지 않는다.
    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run zsh "$IMMICH_RESTORE_DUMP" 'immich_switch_to_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "복귀 뒤 남은 immich_restore로 다시 전환했다: $output"
    assert_contains "$output" "검증 완료 표식이 없다"
    if grep -q '^systemctl' "$FAKE_TRACE"; then
      fail "재전환 거부에서 앱을 멈추거나 시작했다: $(cat "$FAKE_TRACE")"
    fi
    [ "$(_immich_restore_snapshot immich)" = "$IMMICH_RESTORE_MUTATED_SNAPSHOT" ] || fail "재전환 거부가 immich DB를 바꿨다"
    [ "$(_immich_restore_snapshot immich_restore)" = "$before" ] || fail "재전환 거부가 immich_restore를 바꾸거나 지웠다"
  )
}

# 계약 1·2: 업데이트 직전 plain SQL gzip을 bash에서 복원·전환한다.
test_immich_restore_sql_gz_switch() {
  _immich_restore_require_tools || return 0
  (
    local sandbox before output rc
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    before="$(_immich_restore_snapshot immich)"
    _immich_restore_make_backups
    _immich_restore_lock_user_view

    # 이미지 태그가 백업 시점과 다른 경우의 흐름: 앱을 멈춘 채 전환하고, 복귀도 앱을 시작하지 않는다.
    _immich_restore_assert_success_flow bash "$IMMICH_RESTORE_SQL_GZ" "$before" --no-start
    _immich_restore_assert_usage_errors bash "$IMMICH_RESTORE_SQL_GZ" "$IMMICH_RESTORE_OLD_DB"

    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" "immich_revert_restore --no-start $IMMICH_RESTORE_OLD_DB" 2>&1)"
    rc=$?
    set -e
    [ "$rc" = 0 ] || fail "immich_revert_restore --no-start failed: $output"
    assert_contains "$output" "태그를 전환 전 버전으로 되돌리고 nrs한다"
    assert_contains "$output" "nrs 뒤 앱이 떠 있지 않으면: sudo systemctl start podman-immich-ml.service podman-immich-server.service"
    assert_not_contains "$output" "복귀 완료"
    if grep -q '^systemctl start' "$FAKE_TRACE"; then
      fail "--no-start 복귀가 앱을 시작했다: $(cat "$FAKE_TRACE")"
    fi
    [ "$(_immich_restore_app_connections)" = 0 ] || fail "--no-start 복귀 뒤 앱이 immich DB에 붙어 있다"
    [ "$(_immich_restore_snapshot immich)" = "$IMMICH_RESTORE_MUTATED_SNAPSHOT" ] \
      || fail "--no-start 복귀 뒤 immich DB가 전환 전 DB와 다르다"
    [ -z "$(_immich_restore_before_dbs)" ] || fail "--no-start 복귀 뒤 immich_before_restore_* DB가 남았다"
  )
}

# 계약 2: 일반 사용자 셸이 백업을 여는 옛 형태는 root 전용 백업에서 실패한다.
test_immich_restore_legacy_forms_fail_on_root_only_backup() {
  _immich_restore_require_tools || return 0
  (
    local sandbox snapshot file_state output rc
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    _immich_restore_make_backups
    _immich_restore_lock_user_view
    _immich_restore_mutate_original
    snapshot="$(_immich_restore_snapshot immich)"
    file_state="$(_immich_restore_file_state)"

    # 옛 .sql.gz 형태: 파이프 앞단 gunzip이 일반 사용자 권한으로 파일을 연다. pipefail이 없으면
    # 빈 입력을 받은 psql의 성공이 전체 종료 코드가 되어 실패가 가려진다.
    set +e
    output="$(PATH="$sandbox/bin:$PATH" bash -c \
      'gunzip -c "$1" | sudo podman exec -i immich-postgres psql -U immich -d immich' _ "$IMMICH_RESTORE_SQL_GZ" 2>&1)"
    rc=$?
    set -e
    [ "$rc" = 0 ] || fail "옛 .sql.gz 형태가 pipefail 없이 실패를 드러냈다(예상: 가려진 성공): rc=$rc $output"
    assert_contains "$output" "Permission denied"
    [ "$(_immich_restore_snapshot immich)" = "$snapshot" ] || fail "옛 .sql.gz 형태가 DB를 바꿨다"

    set +e
    output="$(PATH="$sandbox/bin:$PATH" bash -o pipefail -c \
      'gunzip -c "$1" | sudo podman exec -i immich-postgres psql -U immich -d immich' _ "$IMMICH_RESTORE_SQL_GZ" 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "옛 .sql.gz 형태가 pipefail에서도 성공했다: $output"

    # 옛 .dump 형태: 입력 리다이렉션을 일반 사용자 셸이 열어 sudo가 실행되기 전에 실패한다.
    : > "$FAKE_TRACE"
    set +e
    output="$(PATH="$sandbox/bin:$PATH" bash -c \
      'sudo podman exec -i immich-postgres pg_restore -U immich -d immich --clean --if-exists < "$1"' _ "$IMMICH_RESTORE_DUMP" 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "옛 .dump 형태가 root 전용 백업에서 성공했다: $output"
    assert_contains "$output" "Permission denied"
    [ ! -s "$FAKE_TRACE" ] || fail "옛 .dump 형태에서 sudo가 실행됐다: $(cat "$FAKE_TRACE")"
    [ "$(_immich_restore_snapshot immich)" = "$snapshot" ] || fail "옛 .dump 형태가 DB를 바꿨다"
    [ "$(_immich_restore_file_state)" = "$file_state" ] || fail "백업 파일·디렉터리의 권한이나 소유자, 내용이 바뀌었다"
  )
}

# 복원 또는 검증 실패: 전체 실패, 전환·앱 재시작 없음, 기존 DB 그대로, immich_restore 없음.
# 운영자가 실패를 무시하고 전환까지 실행해도 전환하지 않아야 한다. $4는 첫 오류에서 멈췄다면
# 나오지 않아야 하는 출력(선택).
_immich_restore_assert_failure_case() {
  local label="$1" backup="$2" expected="$3" unexpected="${4:-}"
  local snapshot output rc
  snapshot="$(_immich_restore_snapshot immich)"
  : > "$FAKE_TRACE"
  set +e
  output="$(_immich_restore_run bash "$backup" 'immich_restore_db' 2>&1)"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "$label: immich_restore_db가 성공했다: $output"
  assert_contains "$output" "$expected"
  assert_not_contains "$output" "검증 통과"
  [ -z "$unexpected" ] || assert_not_contains "$output" "$unexpected"
  _immich_restore_db_exists immich_restore && fail "$label: 실패 뒤 immich_restore가 남았다"

  set +e
  output="$(_immich_restore_run bash "$backup" 'immich_switch_to_restore' 2>&1)"
  rc=$?
  set -e
  [ "$rc" != 0 ] || fail "$label: 실패한 복원 뒤 immich_switch_to_restore가 성공했다: $output"
  assert_not_contains "$output" "전환 완료"
  if grep -q '^systemctl' "$FAKE_TRACE"; then
    fail "$label: 실패 뒤 앱을 멈추거나 시작했다: $(cat "$FAKE_TRACE")"
  fi
  [ -z "$(_immich_restore_before_dbs)" ] || fail "$label: 실패 뒤 이름을 바꿨다"
  [ "$(_immich_restore_snapshot immich)" = "$snapshot" ] || fail "$label: 기존 immich DB가 바뀌었다"
  [ "$(_immich_restore_app_connections)" = 1 ] || fail "$label: 앱이 immich DB에서 떨어졌다"
}

# 계약 3: 손상된 gzip, 중간 SQL 오류, pg_restore 실패, 검증 실패(행·확장·테이블).
test_immich_restore_failures_keep_existing_db() {
  _immich_restore_require_tools || return 0
  (
    local sandbox plain cut backup file_state
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    _immich_restore_make_backups
    plain="$sandbox/plain.sql"
    gzip -dc "$sandbox/src.sql.gz" > "$plain"

    # (a) 손상된 gzip: 앞쪽 멤버는 마지막 제약(FK) 직전까지의 완결된 SQL이고, 뒤쪽 멤버는 헤더만
    #     남아 압축 해제가 실패한다. psql만 보면 성공하고 검증(테이블·PK·FK·인덱스·행)도 통과하는
    #     부분 복원이므로, 압축 해제 실패가 pipefail로 전달돼야만 전환을 막는다.
    cut="$(awk '/^    ADD CONSTRAINT /{ last = NR - 2 } END { print last }' "$plain")"
    [ -n "$cut" ] && [ "$cut" -gt 0 ] || fail "plain dump에서 마지막 제약 경계를 찾지 못했다"
    { head -n "$cut" "$plain" | gzip; printf 'SELECT 1;\n' | gzip | head -c 10; } > "$sandbox/corrupt.sql.gz"
    backup="$(_immich_restore_place_backup "$sandbox/corrupt.sql.gz" var/lib/immich-update/backups/backup-20260927-040000.sql.gz)"

    # (b) 중간 SQL 오류: 첫 COPY 데이터 뒤에 이미지에 없는 확장을 만드는 문장을 넣는다.
    awk '{ print } /^\\\.$/ && !done { print "CREATE EXTENSION immich_missing_extension;"; done = 1 }' "$plain" \
      | gzip > "$sandbox/midfail.sql.gz"
    _immich_restore_place_backup "$sandbox/midfail.sql.gz" var/lib/immich-update/backups/backup-20260927-041000.sql.gz >/dev/null

    # (c) pg_restore 실패: 백업 뒤 사라진 역할이 소유한 테이블이 있는 custom dump.
    _immich_restore_psql -d postgres -c 'CREATE ROLE immich_gone'
    _immich_restore_make_db scratch
    _immich_restore_psql -d scratch -c 'ALTER TABLE album OWNER TO immich_gone'
    pg_dump -Fc -U immich scratch | cat > "$sandbox/rolefail.dump"
    _immich_restore_psql -d postgres -c 'DROP DATABASE scratch' -c 'DROP ROLE immich_gone'
    _immich_restore_place_backup "$sandbox/rolefail.dump" mnt/data/backups/immich/immich-db-2026-09-27_054000.dump >/dev/null

    # (d) 검증 실패: 복원은 되지만 asset이 빈 백업. (g) user만 빈 백업(asset의 user FK를 뺀다).
    _immich_restore_make_db scratch
    _immich_restore_psql -d scratch -c 'DELETE FROM asset'
    pg_dump -Fc -U immich scratch | cat > "$sandbox/empty.dump"
    _immich_restore_psql -d postgres -c 'DROP DATABASE scratch'
    _immich_restore_place_backup "$sandbox/empty.dump" mnt/data/backups/immich/immich-db-2026-09-27_055000.dump >/dev/null
    _immich_restore_make_db scratch
    _immich_restore_psql -d scratch -c 'ALTER TABLE asset DROP CONSTRAINT "asset_ownerId_fkey"' \
      -c 'DELETE FROM album' -c 'DELETE FROM "user"'
    pg_dump -Fc -U immich scratch | cat > "$sandbox/nouser.dump"
    _immich_restore_psql -d postgres -c 'DROP DATABASE scratch'
    _immich_restore_place_backup "$sandbox/nouser.dump" mnt/data/backups/immich/immich-db-2026-09-27_058000.dump >/dev/null

    # (h) 검증 실패: PK·인덱스까지는 있고 FK만 없는 백업(첫 FOREIGN KEY 직전에서 끊은 완결된 SQL).
    cut="$(awk '/^    ADD CONSTRAINT .* FOREIGN KEY /{ print NR - 2; exit }' "$plain")"
    [ -n "$cut" ] && [ "$cut" -gt 0 ] || fail "plain dump에서 첫 FOREIGN KEY 경계를 찾지 못했다"
    head -n "$cut" "$plain" | gzip > "$sandbox/nofk.sql.gz"
    _immich_restore_place_backup "$sandbox/nofk.sql.gz" var/lib/immich-update/backups/backup-20260927-042000.sql.gz >/dev/null

    # (e) 검증 실패: 필수 확장(unaccent)이 없는 백업. (f) 검증 실패: 핵심 테이블(album)이 없는 백업.
    _immich_restore_make_db scratch
    PGOPTIONS='-c client_min_messages=warning' _immich_restore_psql -d scratch -c 'DROP EXTENSION unaccent CASCADE'
    pg_dump -Fc -U immich scratch | cat > "$sandbox/noext.dump"
    _immich_restore_psql -d scratch -c 'DROP TABLE album'
    pg_dump -Fc -U immich scratch | cat > "$sandbox/notable.dump"
    _immich_restore_psql -d postgres -c 'DROP DATABASE scratch'
    _immich_restore_place_backup "$sandbox/noext.dump" mnt/data/backups/immich/immich-db-2026-09-27_056000.dump >/dev/null
    _immich_restore_place_backup "$sandbox/notable.dump" mnt/data/backups/immich/immich-db-2026-09-27_057000.dump >/dev/null

    _immich_restore_lock_user_view
    file_state="$(_immich_restore_file_state)"

    _immich_restore_assert_failure_case "손상된 gzip" "$backup" "unexpected end of file"
    _immich_restore_assert_failure_case "중간 SQL 오류" \
      "$sandbox/fs/var/lib/immich-update/backups/backup-20260927-041000.sql.gz" "immich_missing_extension" \
      "current transaction is aborted"
    _immich_restore_assert_failure_case "pg_restore 실패" \
      "$sandbox/fs/mnt/data/backups/immich/immich-db-2026-09-27_054000.dump" 'role "immich_gone" does not exist' \
      "errors ignored on restore"
    _immich_restore_assert_failure_case "검증 실패(asset 행)" \
      "$sandbox/fs/mnt/data/backups/immich/immich-db-2026-09-27_055000.dump" "asset 테이블이 비어 있다"
    _immich_restore_assert_failure_case "검증 실패(user 행)" \
      "$sandbox/fs/mnt/data/backups/immich/immich-db-2026-09-27_058000.dump" "user 테이블이 비어 있다"
    _immich_restore_assert_failure_case "검증 실패(확장)" \
      "$sandbox/fs/mnt/data/backups/immich/immich-db-2026-09-27_056000.dump" "확장이 없다: unaccent"
    _immich_restore_assert_failure_case "검증 실패(FK)" \
      "$sandbox/fs/var/lib/immich-update/backups/backup-20260927-042000.sql.gz" "외래 키가 없다"
    _immich_restore_assert_failure_case "검증 실패(테이블)" \
      "$sandbox/fs/mnt/data/backups/immich/immich-db-2026-09-27_057000.dump" "핵심 테이블이 없다: album"
    [ "$(_immich_restore_file_state)" = "$file_state" ] || fail "백업 파일·디렉터리의 권한이나 소유자, 내용이 바뀌었다"
  )
}

_immich_restore_client_count() {
  psql -X -At -U immich -d postgres -c "SELECT count(*) FROM pg_stat_activity WHERE application_name = '$1'"
}

# $1 application_name, $2 DB — 앱 대역 밖의 연결을 연다.
_immich_restore_open_client() {
  PGAPPNAME="$1" nohup psql -X -q -U immich -d "$2" -c 'SELECT pg_sleep(86400)' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$FAKE_APP_PIDS"
  for _ in $(seq 1 100); do
    [ "$(_immich_restore_client_count "$1")" = 1 ] && return 0
    sleep 0.1
  done
  fail "$1 연결을 열지 못했다"
}

_immich_restore_close_client() {
  _immich_restore_psql -d postgres -o /dev/null \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name = '$1'"
  for _ in $(seq 1 100); do
    [ "$(_immich_restore_client_count "$1")" = 0 ] && return 0
    sleep 0.1
  done
  fail "$1 연결이 닫히지 않았다"
}

# 전환 전제: 이미 있는 immich_restore는 지우지 않고, 남은 연결이 있으면 이름을 바꾸지 않는다.
# 연결 확인 뒤 생긴 연결로 두 번째 이름 변경이 실패해도 첫 번째 변경까지 되돌린다(한 트랜잭션).
test_immich_restore_switch_refuses_open_connections() {
  _immich_restore_require_tools || return 0
  (
    local sandbox before mutated restored output rc old
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    before="$(_immich_restore_snapshot immich)"
    _immich_restore_make_backups
    _immich_restore_lock_user_view
    _immich_restore_mutate_original
    mutated="$(_immich_restore_snapshot immich)"

    _immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_restore_db' >/dev/null 2>&1 \
      || fail "immich_restore_db failed"
    restored="$(_immich_restore_snapshot immich_restore)"

    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_restore_db' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "immich_restore가 있는데 immich_restore_db가 성공했다"
    assert_contains "$output" 'database "immich_restore" already exists'
    [ "$(_immich_restore_snapshot immich_restore)" = "$restored" ] || fail "이미 있던 immich_restore를 바꾸거나 지웠다"

    _immich_restore_open_client lingering-client immich

    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "연결이 남았는데 전환이 성공했다: $output"
    assert_contains "$output" "연결"
    assert_contains "$output" "lingering-client"
    assert_contains "$output" "sudo systemctl start podman-immich-ml.service podman-immich-server.service"
    assert_not_contains "$output" "전환 완료"
    [ -z "$(_immich_restore_before_dbs)" ] || fail "연결이 남았는데 이름을 바꿨다"
    _immich_restore_db_exists immich_restore || fail "전환 실패가 검증된 immich_restore를 지웠다"
    if grep -q '^systemctl start' "$FAKE_TRACE"; then
      fail "전환 실패 뒤 앱을 시작했다: $(cat "$FAKE_TRACE")"
    fi

    _immich_restore_close_client lingering-client

    : > "$FAKE_TRACE"
    set +e
    output="$(
      export FAKE_RACE_DB=immich_restore
      _immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1
    )"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "이름 변경 중 연결이 생겼는데 전환이 성공했다: $output"
    [ -e "$FAKE_TRACE.race" ] || fail "경합 연결을 주입하지 못했다: $(cat "$FAKE_TRACE")"
    assert_contains "$output" 'database "immich_restore" is being accessed by other users'
    _immich_restore_db_exists immich || fail "두 번째 이름 변경 실패 뒤 immich DB가 사라졌다(이름 변경이 한 트랜잭션이 아니다)"
    [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "두 번째 이름 변경 실패 뒤 immich DB가 바뀌었다"
    [ -z "$(_immich_restore_before_dbs)" ] || fail "두 번째 이름 변경 실패 뒤 이전 DB 이름이 남았다"
    if grep -q '^systemctl start' "$FAKE_TRACE"; then
      fail "전환 실패 뒤 앱을 시작했다: $(cat "$FAKE_TRACE")"
    fi
    _immich_restore_close_client race-client

    # 표식 확인 뒤 이름 변경 직전에 표식이 사라지면, 이름 변경 트랜잭션이 다시 확인해 거부한다.
    : > "$FAKE_TRACE"
    set +e
    output="$(
      export FAKE_RACE_CLEAR_MARKER=1
      _immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1
    )"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "이름 변경 직전에 표식이 사라졌는데 전환했다: $output"
    [ -e "$FAKE_TRACE.clear" ] || fail "표식 삭제를 주입하지 못했다: $(cat "$FAKE_TRACE")"
    assert_contains "$output" "검증 완료 표식이 없다"
    [ -z "$(_immich_restore_before_dbs)" ] || fail "표식이 사라졌는데 이름을 바꿨다"
    [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "표식이 사라진 전환이 immich DB를 바꿨다"
    _immich_restore_db_exists immich_restore || fail "표식이 사라진 전환이 immich_restore를 지웠다"
    if grep -q '^systemctl start' "$FAKE_TRACE"; then
      fail "표식이 사라진 전환 뒤 앱을 시작했다: $(cat "$FAKE_TRACE")"
    fi
    # 이 경합은 테스트가 만든 것이므로 표식을 되돌리고 이어 간다.
    _immich_restore_psql -d postgres -c "COMMENT ON DATABASE immich_restore IS 'verified:backup-20260927-030000.sql.gz'"

    # 재실행: 이름 변경은 성공하고 앱 시작만 실패하면, 이전 DB 이름과 복귀 명령을 안내한다.
    set +e
    output="$(
      export FAKE_START_FAIL=1
      _immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1
    )"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "앱 시작이 실패했는데 전환이 성공으로 끝났다: $output"
    old="$(_immich_restore_before_dbs)"
    case "$old" in
      immich_before_restore_[0-9]*_[0-9]*) ;;
      *) fail "재실행한 전환이 이름을 바꾸지 않았다: '$old' $output" ;;
    esac
    assert_contains "$output" "이전 DB: $old"
    assert_contains "$output" "immich_revert_restore $old"
    assert_not_contains "$output" "전환 완료"
    [ "$(_immich_restore_snapshot immich)" = "$before" ] || fail "재실행한 전환 뒤 immich DB가 백업 시점과 다르다"

    # 복귀도 남은 연결이 있으면 이름을 바꾸지 않고, 앱 시작 명령을 안내한다.
    _immich_restore_open_client lingering-client immich
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" "immich_revert_restore $old" 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "연결이 남았는데 복귀가 성공했다: $output"
    assert_contains "$output" "lingering-client"
    assert_contains "$output" "sudo systemctl start podman-immich-ml.service podman-immich-server.service"
    [ "$(_immich_restore_before_dbs)" = "$old" ] || fail "복귀 실패 뒤 이전 DB 이름이 바뀌었다"
    [ "$(_immich_restore_snapshot immich)" = "$before" ] || fail "복귀 실패 뒤 immich DB가 바뀌었다"
    _immich_restore_close_client lingering-client

    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" "immich_revert_restore $old" 2>&1)"
    rc=$?
    set -e
    [ "$rc" = 0 ] || fail "연결을 정리한 뒤 복귀가 실패했다: $output"
    [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "복귀 뒤 immich DB가 전환 전 DB와 다르다"
    [ "$(_immich_restore_app_connections)" = 1 ] || fail "복귀 뒤 앱이 immich DB에 연결되지 않았다"
  )
}

# 1(차단): 검증 완료 표식이 없거나 post-data(PK·FK·인덱스)가 빠진 immich_restore는 앱을 건드리지
# 않고 전환을 거부한다. 잔재는 복원이 도중에 끊기거나(SSH 끊김·Ctrl-C, psql -1은 입력이 끝나면
# COMMIT한다) 실패 뒤 DROP도 실패할 때 생긴다.
test_immich_restore_switch_refuses_unverified_restore() {
  _immich_restore_require_tools || return 0
  (
    local sandbox mutated plain cut output rc
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    _immich_restore_make_backups
    _immich_restore_lock_user_view
    _immich_restore_mutate_original
    mutated="$(_immich_restore_snapshot immich)"

    plain="$sandbox/plain.sql"
    gzip -dc "$sandbox/src.sql.gz" > "$plain"
    cut="$(awk '/^    ADD CONSTRAINT /{ print NR - 2; exit }' "$plain")"
    [ -n "$cut" ] && [ "$cut" -gt 0 ] || fail "plain dump에서 post-data 경계를 찾지 못했다"
    _immich_restore_psql -d postgres -c 'CREATE DATABASE immich_restore OWNER immich TEMPLATE template0'
    head -n "$cut" "$plain" | _immich_restore_psql -1 -o /dev/null -d immich_restore
    [ "$(psql -X -At -U immich -d immich_restore -c "SELECT count(*) FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND contype IN ('p', 'f')")" = 0 ] \
      || fail "부분 복원 fixture에 post-data가 들어갔다"

    # 검증 함수는 판정만 한다. 단독으로 불러 실패해도 immich_restore를 지우지 않는다.
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_verify_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "post-data 없는 immich_restore가 검증을 통과했다: $output"
    _immich_restore_db_exists immich_restore || fail "단독으로 부른 검증이 immich_restore를 지웠다"

    # 표식 없음: 거부하고 immich_restore를 지우지 않는다(내용 확인 뒤 수동 DROP).
    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "표식 없는 부분 복원으로 전환했다: $output"
    assert_contains "$output" "검증 완료 표식이 없다"
    assert_contains "$output" "immich_restore_db로 다시 복원"
    assert_not_contains "$output" "이름 변경 완료"
    if grep -q '^systemctl' "$FAKE_TRACE"; then
      fail "표식 없는 immich_restore에서 앱을 멈추거나 시작했다: $(cat "$FAKE_TRACE")"
    fi
    [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "전환 거부가 immich DB를 바꿨다"
    [ "$(_immich_restore_app_connections)" = 1 ] || fail "전환 거부 뒤 앱이 immich DB에서 떨어졌다"
    _immich_restore_db_exists immich_restore || fail "표식 없는 immich_restore를 지웠다"

    # 표식이 있어도 post-data가 없으면 검증에서 멈춘다(검증 실패는 immich_restore를 지운다).
    _immich_restore_psql -d postgres -c "COMMENT ON DATABASE immich_restore IS 'verified:forged.dump'"
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "post-data 없는 immich_restore로 전환했다: $output"
    assert_contains "$output" "기본 키가 없다"
    assert_not_contains "$output" "이름 변경 완료"
    if grep -q '^systemctl' "$FAKE_TRACE"; then
      fail "post-data 없는 immich_restore에서 앱을 멈추거나 시작했다: $(cat "$FAKE_TRACE")"
    fi
    [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "전환 거부가 immich DB를 바꿨다"
    [ "$(_immich_restore_app_connections)" = 1 ] || fail "전환 거부 뒤 앱이 immich DB에서 떨어졌다"
    _immich_restore_db_exists immich_restore && fail "검증에 실패한 immich_restore가 남았다"
    [ -z "$(_immich_restore_before_dbs)" ] || fail "전환 거부 뒤 이름을 바꿨다"
  )
}

# 복원 도중 운영자 셸이 죽으면(SSH 끊김) 검증 완료 표식 없이 부분 복원만 남고, 전환은 이를 거부한다.
# 부분 복원은 마지막 FK만 빠져 검증은 통과하므로, 표식이 복원·검증 뒤에 기록돼야만 막힌다.
test_immich_restore_interrupted_restore_is_not_switched() {
  _immich_restore_require_tools || return 0
  (
    local sandbox mutated output rc
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"
    _immich_restore_make_backups
    _immich_restore_lock_user_view
    _immich_restore_mutate_original
    mutated="$(_immich_restore_snapshot immich)"

    set +e
    output="$(
      export FAKE_INTERRUPT_RESTORE=1
      _immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_restore_db; echo "operator shell survived"' 2>&1
    )"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "끊긴 복원이 성공으로 끝났다: $output"
    assert_not_contains "$output" "operator shell survived"
    _immich_restore_db_exists immich_restore || fail "부분 복원 fixture가 남지 않았다"
    [ "$(psql -X -At -U immich -d immich_restore -c "SELECT count(*) FROM pg_constraint WHERE connamespace = 'public'::regnamespace AND contype = 'f'")" -gt 0 ] \
      || fail "부분 복원에 FK가 하나도 없다 — 검증이 통과하는 부분 복원이 아니다"

    : > "$FAKE_TRACE"
    set +e
    output="$(_immich_restore_run bash "$IMMICH_RESTORE_SQL_GZ" 'immich_switch_to_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" != 0 ] || fail "끊긴 복원으로 전환했다: $output"
    assert_contains "$output" "검증 완료 표식이 없다"
    if grep -q '^systemctl' "$FAKE_TRACE"; then
      fail "끊긴 복원에서 앱을 멈추거나 시작했다: $(cat "$FAKE_TRACE")"
    fi
    [ -z "$(_immich_restore_before_dbs)" ] || fail "끊긴 복원으로 이름을 바꿨다"
    [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "끊긴 복원 뒤 immich DB가 바뀌었다"
    [ "$(_immich_restore_app_connections)" = 1 ] || fail "끊긴 복원 뒤 앱이 immich DB에서 떨어졌다"
  )
}

# VectorChord 전환 뒤 Immich 1.133.0 미만으로의 다운그레이드(immich.nix 이미지 주석)는 전환하지
# 않는다. 백업 시점 버전은 immich_restore의 version_history 최근 행으로 보고, 읽지 못하면 거부한다.
# 비교는 버전 성분별 정수 비교다: 1.99.0은 거부하고(문자열로는 1.133.0보다 크다), 1.133.0은 받는다.
test_immich_restore_switch_refuses_forbidden_downgrade() {
  _immich_restore_require_tools || return 0
  (
    local sandbox mutated label backup expected output rc args
    sandbox="$(new_sandbox)"
    IMMICH_RESTORE_SANDBOX="$sandbox"
    FAKE_APP_PIDS="$sandbox/app.pids"
    trap _immich_restore_teardown EXIT
    _immich_restore_setup "$sandbox"

    _immich_restore_make_db scratch
    _immich_restore_psql -d scratch -c "UPDATE version_history SET version = '1.133.0' WHERE version = '3.0.0'"
    pg_dump -Fc -U immich scratch | cat > "$sandbox/boundary.dump"
    _immich_restore_psql -d scratch -c "UPDATE version_history SET version = '1.99.0' WHERE version = '1.133.0'"
    pg_dump -Fc -U immich scratch | cat > "$sandbox/lexical.dump"
    _immich_restore_psql -d scratch -c "DELETE FROM version_history WHERE version = '1.99.0'"
    pg_dump -Fc -U immich scratch | cat > "$sandbox/old.dump"
    _immich_restore_psql -d scratch -c "INSERT INTO version_history (\"createdAt\", version) VALUES ('2026-08-01T00:00:00Z', 'dev')"
    pg_dump -Fc -U immich scratch | cat > "$sandbox/garbled.dump"
    _immich_restore_psql -d scratch -c 'DROP TABLE version_history'
    pg_dump -Fc -U immich scratch | cat > "$sandbox/nohistory.dump"
    _immich_restore_psql -d postgres -c 'DROP DATABASE scratch'
    _immich_restore_place_backup "$sandbox/boundary.dump" mnt/data/backups/immich/immich-db-2025-06-15_053000.dump >/dev/null
    _immich_restore_place_backup "$sandbox/lexical.dump" mnt/data/backups/immich/immich-db-2025-05-01_053000.dump >/dev/null
    _immich_restore_place_backup "$sandbox/old.dump" mnt/data/backups/immich/immich-db-2025-06-01_053000.dump >/dev/null
    _immich_restore_place_backup "$sandbox/garbled.dump" mnt/data/backups/immich/immich-db-2026-08-01_053000.dump >/dev/null
    _immich_restore_place_backup "$sandbox/nohistory.dump" mnt/data/backups/immich/immich-db-2026-08-02_053000.dump >/dev/null
    _immich_restore_lock_user_view
    _immich_restore_mutate_original
    mutated="$(_immich_restore_snapshot immich)"

    for label in old lexical garbled nohistory; do
      case "$label" in
        old) backup=immich-db-2025-06-01_053000.dump; expected="1.133.0 미만" ;;
        lexical) backup=immich-db-2025-05-01_053000.dump; expected="백업 시점 버전 1.99.0: 1.133.0 미만" ;;
        garbled) backup=immich-db-2026-08-01_053000.dump; expected="백업 시점 버전을 읽지 못했다" ;;
        nohistory) backup=immich-db-2026-08-02_053000.dump; expected="version_history 테이블이 없다" ;;
      esac
      backup="$sandbox/fs/mnt/data/backups/immich/$backup"
      _immich_restore_run bash "$backup" 'immich_restore_db' >/dev/null 2>&1 \
        || fail "$label: 버전과 무관한 복원·검증이 실패했다"
      : > "$FAKE_TRACE"
      for args in "" --no-start; do
        set +e
        output="$(_immich_restore_run bash "$backup" "immich_switch_to_restore $args" 2>&1)"
        rc=$?
        set -e
        [ "$rc" != 0 ] || fail "$label: 금지된 버전의 백업으로 전환했다($args): $output"
        assert_contains "$output" "$expected"
        assert_not_contains "$output" "이름 변경 완료"
      done
      if grep -q '^systemctl' "$FAKE_TRACE"; then
        fail "$label: 버전 거부에서 앱을 멈추거나 시작했다: $(cat "$FAKE_TRACE")"
      fi
      [ -z "$(_immich_restore_before_dbs)" ] || fail "$label: 버전 거부 뒤 이름을 바꿨다"
      [ "$(_immich_restore_snapshot immich)" = "$mutated" ] || fail "$label: 버전 거부가 immich DB를 바꿨다"
      [ "$(_immich_restore_app_connections)" = 1 ] || fail "$label: 버전 거부 뒤 앱이 immich DB에서 떨어졌다"
      _immich_restore_db_exists immich_restore || fail "$label: 버전 거부가 immich_restore를 지웠다"
      _immich_restore_psql -d postgres -c 'DROP DATABASE immich_restore'
    done

    # 하한 1.133.0 자체는 받는다.
    backup="$sandbox/fs/mnt/data/backups/immich/immich-db-2025-06-15_053000.dump"
    _immich_restore_run bash "$backup" 'immich_restore_db' >/dev/null 2>&1 \
      || fail "boundary: 버전과 무관한 복원·검증이 실패했다"
    set +e
    output="$(_immich_restore_run bash "$backup" 'immich_switch_to_restore' 2>&1)"
    rc=$?
    set -e
    [ "$rc" = 0 ] || fail "boundary: 1.133.0 백업으로 전환하지 못했다: $output"
    assert_contains "$output" "백업 시점 Immich 버전: 1.133.0"
    assert_contains "$output" "전환 완료"
  )
}

# 문서의 실행 블록이 이 스위트가 부르는 함수와 같은지 고정한다.
test_immich_restore_doc_invocations_match_suite() {
  local doc procedure restore_fn restore_line verify_line marker_line
  doc="$(_immich_restore_doc)"
  grep -Fxq 'immich_restore_db' "$doc" || fail "immich-update.md에 immich_restore_db 실행 줄이 없다"
  grep -Fxq 'immich_switch_to_restore' "$doc" || fail "immich-update.md에 immich_switch_to_restore 실행 줄이 없다"
  grep -Fxq 'immich_switch_to_restore --no-start' "$doc" \
    || fail "immich-update.md에 immich_switch_to_restore --no-start 실행 줄이 없다"
  grep -Eq '^immich_revert_restore immich_before_restore_' "$doc" \
    || fail "immich-update.md에 immich_revert_restore 실행 줄이 없다"
  # 동작 테스트가 결과로 구분하지 못하는 방어(부분 커밋 방지, 빈 템플릿, autovacuum worker를 세지
  # 않는 연결 확인)를 정적으로 고정한다.
  procedure="$(_immich_restore_extract_procedure)"
  assert_contains "$procedure" "-v ON_ERROR_STOP=1 --single-transaction -U immich -d immich_restore"
  assert_contains "$procedure" "CREATE DATABASE immich_restore OWNER immich TEMPLATE template0;"
  assert_contains "$procedure" "WHERE backend_type = 'client backend'"
  # 검증 완료 표식은 immich_restore_db 안에서 복원(esac)과 검증 성공 뒤에만 기록한다.
  restore_fn="$(printf '%s\n' "$procedure" | awk '/^immich_restore_db\(\) \{$/{ f = 1 } f { print } f && /^}$/{ exit }')"
  restore_line="$(printf '%s\n' "$restore_fn" | awk '/^  esac \|\|/{ print NR; exit }')"
  verify_line="$(printf '%s\n' "$restore_fn" | awk '$0 == "  if ! immich_verify_restore; then" { print NR; exit }')"
  marker_line="$(printf '%s\n' "$restore_fn" | awk -v l="COMMENT ON DATABASE immich_restore IS :'marker';" '$0 == l { print NR; exit }')"
  [ -n "$restore_line" ] && [ -n "$verify_line" ] && [ -n "$marker_line" ] \
    || fail "immich_restore_db에서 복원·검증·표식 기록 줄을 찾지 못했다: restore=$restore_line verify=$verify_line marker=$marker_line"
  [ "$restore_line" -lt "$verify_line" ] && [ "$verify_line" -lt "$marker_line" ] \
    || fail "검증 완료 표식이 복원·검증 뒤에 기록되지 않는다: restore=$restore_line verify=$verify_line marker=$marker_line"
  # 옛 형태(일반 사용자 셸이 백업을 여는 복원 명령)가 문서에 남지 않아야 한다.
  if grep -Eq '^gunzip -c .*\| *\\?$|^gunzip -c .*\| *sudo|< /mnt/data/backups/|< /var/lib/immich-update/' "$doc"; then
    fail "immich-update.md에 일반 사용자 셸이 백업을 여는 옛 복원 형태가 남아 있다"
  fi
}
