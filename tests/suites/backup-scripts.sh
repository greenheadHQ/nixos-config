# tests/suites/backup-scripts.sh — backup script characterization tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

_immich_backup_script="$REPO_ROOT/modules/nixos/programs/docker/immich-backup/files/immich-db-backup.sh"
_karakeep_backup_script="$REPO_ROOT/modules/nixos/programs/docker/karakeep-backup/files/karakeep-backup.sh"

_backup_scripts_install_podman_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

# 호출 순서 회귀 검사용 — PODMAN_STUB_CALL_LOG가 설정된 테스트에서만 기록한다.
if [ -n "${PODMAN_STUB_CALL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$PODMAN_STUB_CALL_LOG"
fi

if [ "${1:-}" = "inspect" ]; then
  printf 'running\n'
  exit 0
fi

if [ "${1:-}" = "exec" ]; then
  shift
  if [ "${1:-}" = "-i" ]; then
    shift
  fi
  container="${1:-}"
  shift || true
  if [ "$container" != "immich-postgres" ]; then
    echo "unexpected podman container: $container" >&2
    exit 99
  fi

  case "${1:-}" in
    pg_dump)
      head -c 20480 /dev/zero
      ;;
    pg_restore)
      cat >/dev/null
      exit "${STUB_PG_RESTORE_EXIT:-0}"
      ;;
    *)
      echo "unexpected podman exec command: ${1:-}" >&2
      exit 99
      ;;
  esac
  exit 0
fi

echo "unexpected podman invocation: $*" >&2
exit 99
STUB
  chmod +x "$path"
}

_backup_scripts_install_sqlite3_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

db_file="${1:-}"
backup_command="${2:-}"

if [ ! -f "$db_file" ]; then
  echo "sqlite source missing: $db_file" >&2
  exit 2
fi

case "$backup_command" in
  ".backup '"*"'" )
    target="${backup_command#".backup '"}"
    target="${target%"'"}"
    mkdir -p "$(dirname "$target")"
    printf 'sqlite backup fixture for %s\n' "$db_file" > "$target"
    ;;
  *)
    echo "unexpected sqlite3 command: $backup_command" >&2
    exit 99
    ;;
esac
STUB
  chmod +x "$path"
}

_backup_scripts_install_mountpoint_stub() {
  local path="$1"
  local exit_code="${2:-0}"
  cat > "$path" <<STUB
#!/usr/bin/env bash
# argv 검증용 — MOUNTPOINT_STUB_ARGV_LOG가 설정된 테스트에서만 기록한다.
# (BACKUP_DIR·DEST_DIR로 인자를 바꿔치는 변이가 exit code만 보는 검사를 통과하는 것을 막는다.)
if [ -n "\${MOUNTPOINT_STUB_ARGV_LOG:-}" ]; then
  printf '%s\n' "\$*" >> "\$MOUNTPOINT_STUB_ARGV_LOG"
fi
exit $exit_code
STUB
  chmod +x "$path"
}

_backup_scripts_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/stub-bin" "$sandbox/backup" "$sandbox/src"
  printf '# stub pushover credentials\n' > "$sandbox/pushover"
  : > "$sandbox/notifications.log"
  cat > "$sandbox/service-lib" <<'STUB'
send_notification() {
  printf '%s\n' "$*" >> "$BACKUP_TEST_NOTIFICATIONS"
}
STUB
  _backup_scripts_install_podman_stub "$sandbox/stub-bin/podman"
  _backup_scripts_install_sqlite3_stub "$sandbox/stub-bin/sqlite3"
  # 기본은 "정상 마운트"(exit 0) — #1369 마운트 가드를 넣어도 기존 happy-path 테스트가
  # 그대로 초록을 유지해야 한다. 미마운트 시나리오만 개별 테스트에서 exit 1로 덮어쓴다.
  _backup_scripts_install_mountpoint_stub "$sandbox/stub-bin/mountpoint" 0
}

_backup_scripts_run() {
  local script="$1"
  local sandbox="$2"
  local stdout_path="$3"
  local stderr_path="$4"
  local retention_days="${5:-30}"
  # 기본 MOUNT_ROOT는 BACKUP_DIR의 부모(=sandbox)다 — 프로덕션(mediaData가 마운트, BACKUP_DIR은
  # 그 아래 하위 디렉터리)과 같은 모양으로 두 값을 서로 다르게 유지해야, "가드가 MOUNT_ROOT가
  # 아니라 BACKUP_DIR을 검사하는" 변이를 argv 검증 테스트가 잡을 수 있다.
  local mount_root="${6:-$sandbox}"

  env \
    PATH="$sandbox/stub-bin:$PATH" \
    BACKUP_DIR="$sandbox/backup" \
    MOUNT_ROOT="$mount_root" \
    RETENTION_DAYS="$retention_days" \
    SRC_DIR="$sandbox/src" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$sandbox/service-lib" \
    BACKUP_TEST_NOTIFICATIONS="$sandbox/notifications.log" \
    STUB_PG_RESTORE_EXIT="${STUB_PG_RESTORE_EXIT:-}" \
    bash -eu -o pipefail "$script" > "$stdout_path" 2> "$stderr_path"
}

_backup_scripts_require_immich_disk_space() {
  local backup_dir="$1"
  local avail_kb avail_gb
  avail_kb=$(df --output=avail "$backup_dir" | tail -1)
  avail_gb=$((avail_kb / 1024 / 1024))
  if [ "$avail_gb" -lt 5 ]; then
    echo "SKIP: immich backup script requires 5GB free in BACKUP_DIR; df branch is outside this characterization suite" >&2
    return 1
  fi
}

test_immich_backup_happy_path_creates_dump_atomically() {
  local sandbox stdout_path stderr_path dump_count tmp_count
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  _backup_scripts_require_immich_disk_space "$sandbox/backup" || return 0
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected immich backup happy path to exit 0"

  dump_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name 'immich-db-*.dump' | wc -l)
  tmp_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name '*.tmp' | wc -l)
  [ "$dump_count" = "1" ] || fail "expected exactly one immich dump, got $dump_count"
  [ "$tmp_count" = "0" ] || fail "expected no immich tmp files, got $tmp_count"
  [ ! -s "$sandbox/notifications.log" ] || fail "expected no success notification"
}

test_immich_backup_integrity_failure_exits_nonzero() {
  local sandbox stdout_path stderr_path status dump_count tmp_count notifications
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  _backup_scripts_require_immich_disk_space "$sandbox/backup" || return 0
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  status=0
  STUB_PG_RESTORE_EXIT=1 _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" || status=$?
  [ "$status" -ne 0 ] || fail "expected immich integrity failure to exit non-zero"

  dump_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name 'immich-db-*.dump' | wc -l)
  tmp_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name '*.tmp' | wc -l)
  [ "$dump_count" = "0" ] || fail "expected no completed immich dump after integrity failure"
  [ "$tmp_count" = "0" ] || fail "expected immich tmp file cleanup after integrity failure"
  notifications=$(cat "$sandbox/notifications.log")
  assert_contains "$notifications" "백업 실패"
}

test_immich_backup_retention_deletes_only_old_dumps_in_dir() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  _backup_scripts_require_immich_disk_space "$sandbox/backup" || return 0
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  printf 'old\n' > "$sandbox/backup/immich-db-old.dump"
  printf 'new\n' > "$sandbox/backup/immich-db-new.dump"
  mkdir -p "$sandbox/backup/sub"
  printf 'nested old\n' > "$sandbox/backup/sub/immich-db-old2.dump"
  touch -d '40 days ago' "$sandbox/backup/immich-db-old.dump" "$sandbox/backup/sub/immich-db-old2.dump"

  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected immich backup retention case to exit 0"

  [ ! -e "$sandbox/backup/immich-db-old.dump" ] || fail "expected old top-level immich dump to be deleted"
  [ -e "$sandbox/backup/immich-db-new.dump" ] || fail "expected new top-level immich dump to remain"
  [ -e "$sandbox/backup/sub/immich-db-old2.dump" ] || fail "expected nested immich dump to remain"
}

test_immich_backup_retention_zero_keeps_todays_dump_deletes_stale() {
  local sandbox stdout_path stderr_path dump_count
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  _backup_scripts_require_immich_disk_space "$sandbox/backup" || return 0
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # stale: -mtime +0(1일 초과)에 걸리는 최소 나이. RETENTION_DAYS를 0→1로 바꾸는 변이를
  # 잡으려면(+0은 매치, +1은 미매치) '2 days ago'처럼 여유 있는 값이 아니라 경계에 붙여야 한다.
  printf 'stale\n' > "$sandbox/backup/immich-db-stale.dump"
  touch -d '25 hours ago' "$sandbox/backup/immich-db-stale.dump"
  # fresh: 24시간 미만이라 RETENTION_DAYS=0에서도 항상 남아야 하는 기존 백업.
  printf 'fresh\n' > "$sandbox/backup/immich-db-fresh.dump"
  touch -d '1 hour ago' "$sandbox/backup/immich-db-fresh.dump"

  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" 0 \
    || fail "expected immich backup with RETENTION_DAYS=0 to exit 0"

  [ ! -e "$sandbox/backup/immich-db-stale.dump" ] || fail "expected >24h-old immich dump to be deleted with RETENTION_DAYS=0"
  [ -e "$sandbox/backup/immich-db-fresh.dump" ] || fail "expected <24h-old immich dump to remain with RETENTION_DAYS=0"
  dump_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name 'immich-db-*.dump' | wc -l)
  [ "$dump_count" = "2" ] || fail "expected pre-existing fresh dump + today's new dump to remain with RETENTION_DAYS=0, got $dump_count dump(s)"
}

test_immich_backup_unmounted_target_blocks_write_and_exits_nonzero() {
  local sandbox stdout_path stderr_path status dump_count tmp_count notifications
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  # #1369: 대상 HDD(MOUNT_ROOT)가 일반 디렉터리로만 존재하는 미마운트 상황을 흉내낸다.
  _backup_scripts_install_mountpoint_stub "$sandbox/stub-bin/mountpoint" 1
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  status=0
  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" || status=$?
  [ "$status" -ne 0 ] || fail "expected immich backup to fail when target HDD is not mounted"

  dump_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name 'immich-db-*.dump' | wc -l)
  tmp_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name '*.tmp' | wc -l)
  [ "$dump_count" = "0" ] || fail "expected no immich dump written when target HDD is unmounted"
  [ "$tmp_count" = "0" ] || fail "expected no immich tmp file left when target HDD is unmounted"
  notifications=$(cat "$sandbox/notifications.log")
  assert_contains "$notifications" "마운트"
}

# 리뷰: 가드가 mountpoint를 부를 때 실제로 MOUNT_ROOT를 넘기는지 확인한다 — exit code만 보는
# 검사는 "BACKUP_DIR을 검사하도록 바꿔치는" 변이도 통과시킨다(모두 항상 마운트됨 스텁이므로).
# mountpoint 호출은 디스크 공간 검사(아래 _backup_scripts_require_immich_disk_space 대상)보다
# 항상 앞서 실행되므로, 이 테스트는 argv만 확인하고 스크립트 전체 종료 코드는 보지 않는다 —
# 그렇지 않으면 여유 공간 5GB 미만인 호스트에서 이 테스트만 무관한 이유로 거짓 실패한다.
test_immich_backup_mount_guard_checks_mount_root_not_backup_dir() {
  local sandbox stdout_path stderr_path argv_log
  local MOUNTPOINT_STUB_ARGV_LOG
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  argv_log="$sandbox/mountpoint-argv.log"
  : > "$argv_log"
  MOUNTPOINT_STUB_ARGV_LOG="$argv_log"
  export MOUNTPOINT_STUB_ARGV_LOG
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" || true

  [ "$(cat "$argv_log")" = "-q $sandbox" ] \
    || fail "expected mountpoint to be called as '-q $sandbox' (MOUNT_ROOT), got: $(cat "$argv_log")"
}

# 이슈 최소 수정 범위: "목적지가 기대한 마운트 아래에 있는지 검증". MOUNT_ROOT는 마운트돼 있어도
# BACKUP_DIR이 그 아래가 아니면(설정 오류) 마운트 확인만으로는 잡지 못한다. 이 소속 가드는 디스크
# 공간 검사보다 먼저 실행되므로 podman은 절대 불리지 않아야 하고, 실패 사유가 다른 분기(디스크
# 공간 등)로 새지 않았는지 stderr의 가드 고유 문구로도 확인한다.
test_immich_backup_destination_outside_mount_blocks_write_and_exits_nonzero() {
  local sandbox stdout_path stderr_path status dump_count other_mount
  local PODMAN_STUB_CALL_LOG
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  other_mount="$sandbox/other-mount"
  mkdir -p "$other_mount"
  PODMAN_STUB_CALL_LOG="$sandbox/podman-calls.log"
  : > "$PODMAN_STUB_CALL_LOG"
  export PODMAN_STUB_CALL_LOG
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  status=0
  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" 30 "$other_mount" \
    || status=$?
  [ "$status" -ne 0 ] || fail "expected immich backup to fail when BACKUP_DIR is outside MOUNT_ROOT"

  dump_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name 'immich-db-*.dump' | wc -l)
  [ "$dump_count" = "0" ] || fail "expected no immich dump written when BACKUP_DIR is outside MOUNT_ROOT"
  [ ! -s "$PODMAN_STUB_CALL_LOG" ] \
    || fail "expected podman to never be called when BACKUP_DIR is outside MOUNT_ROOT (got: $(cat "$PODMAN_STUB_CALL_LOG"))"
  assert_contains "$(cat "$stderr_path")" "is not under MOUNT_ROOT"
}

# 리뷰: case 패턴에서 슬래시를 빼는 변이(`"$MOUNT_ROOT"/*` → `"$MOUNT_ROOT"*`)는 MOUNT_ROOT가
# BACKUP_DIR의 문자열 접두사이기만 해도(디렉터리 경계가 아니어도) 통과시켜 버린다. MOUNT_ROOT를
# BACKUP_DIR("$sandbox/backup")과 문자열은 겹치지만 디렉터리 경계가 아닌 "$sandbox/back"으로
# 둬서, 그 변이를 이 테스트가 잡는지 고정한다.
test_immich_backup_mount_prefix_without_directory_boundary_is_rejected() {
  local sandbox stdout_path stderr_path status dump_count prefix_mount
  local PODMAN_STUB_CALL_LOG
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  prefix_mount="${sandbox}/back"
  mkdir -p "$prefix_mount"
  PODMAN_STUB_CALL_LOG="$sandbox/podman-calls.log"
  : > "$PODMAN_STUB_CALL_LOG"
  export PODMAN_STUB_CALL_LOG
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  status=0
  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" 30 "$prefix_mount" \
    || status=$?
  [ "$status" -ne 0 ] \
    || fail "expected immich backup to fail when BACKUP_DIR shares only a string prefix with MOUNT_ROOT (no directory boundary)"

  dump_count=$(find "$sandbox/backup" -maxdepth 1 -type f -name 'immich-db-*.dump' | wc -l)
  [ "$dump_count" = "0" ] || fail "expected no immich dump written for the string-prefix MOUNT_ROOT case"
  [ ! -s "$PODMAN_STUB_CALL_LOG" ] \
    || fail "expected podman to never be called for the string-prefix MOUNT_ROOT case (got: $(cat "$PODMAN_STUB_CALL_LOG"))"
  assert_contains "$(cat "$stderr_path")" "is not under MOUNT_ROOT"
}

# 순서 회귀: 마운트 가드가 podman 호출·보관 정리보다 앞서야 한다 — 미마운트 시 기존(보관 기간을
# 넘긴) 백업도 그대로 남고, podman이 한 번도 불리지 않아야 한다.
test_immich_backup_unmounted_target_preserves_existing_backups_and_skips_pg_dump() {
  local sandbox stdout_path stderr_path status old_dump
  local PODMAN_STUB_CALL_LOG
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  _backup_scripts_install_mountpoint_stub "$sandbox/stub-bin/mountpoint" 1
  PODMAN_STUB_CALL_LOG="$sandbox/podman-calls.log"
  : > "$PODMAN_STUB_CALL_LOG"
  export PODMAN_STUB_CALL_LOG
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  old_dump="$sandbox/backup/immich-db-old.dump"
  printf 'old\n' > "$old_dump"
  touch -d '40 days ago' "$old_dump"

  status=0
  _backup_scripts_run "$_immich_backup_script" "$sandbox" "$stdout_path" "$stderr_path" || status=$?
  [ "$status" -ne 0 ] || fail "expected immich backup to fail when target HDD is not mounted"

  [ -e "$old_dump" ] \
    || fail "expected pre-existing old dump to survive when target HDD is unmounted (mount guard must run before retention cleanup)"
  [ ! -s "$PODMAN_STUB_CALL_LOG" ] \
    || fail "expected podman to never be called when target HDD is not mounted (got: $(cat "$PODMAN_STUB_CALL_LOG"))"
}

test_karakeep_backup_happy_path_dated_dir() {
  local sandbox stdout_path stderr_path today
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  today=$(date +%Y-%m-%d)
  printf 'main db\n' > "$sandbox/src/db.db"

  _backup_scripts_run "$_karakeep_backup_script" "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected karakeep backup happy path to exit 0"

  [ -f "$sandbox/backup/$today/db.db.gz" ] || fail "expected karakeep dated db.db.gz backup"
  [ ! -s "$sandbox/notifications.log" ] || fail "expected no success notification"
}

test_karakeep_backup_missing_db_exits_nonzero() {
  local sandbox stdout_path stderr_path status notifications
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  status=0
  _backup_scripts_run "$_karakeep_backup_script" "$sandbox" "$stdout_path" "$stderr_path" || status=$?
  [ "$status" -ne 0 ] || fail "expected karakeep missing db to exit non-zero"
  notifications=$(cat "$sandbox/notifications.log")
  assert_contains "$notifications" "백업 실패"
}

test_karakeep_backup_retention_scopes_to_backup_dir() {
  local sandbox stdout_path stderr_path today old_dir today_dir
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  today=$(date +%Y-%m-%d)
  old_dir="$sandbox/backup/20200101"
  today_dir="$sandbox/backup/$today"
  printf 'main db\n' > "$sandbox/src/db.db"
  mkdir -p "$old_dir" "$today_dir"
  printf 'old backup\n' > "$old_dir/db.db.gz"
  printf 'current backup\n' > "$today_dir/existing"
  touch -d '40 days ago' "$old_dir"

  _backup_scripts_run "$_karakeep_backup_script" "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected karakeep retention case to exit 0"

  [ ! -e "$old_dir" ] || fail "expected old karakeep backup dir to be deleted"
  [ -d "$today_dir" ] || fail "expected current karakeep backup dir to remain"
  [ -f "$today_dir/db.db.gz" ] || fail "expected current karakeep db.db.gz backup"
}

test_karakeep_backup_retention_zero_keeps_today_deletes_stale() {
  local sandbox stdout_path stderr_path today stale_dir fresh_dir today_dir
  sandbox=$(new_sandbox)
  _backup_scripts_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  today=$(date +%Y-%m-%d)
  stale_dir="$sandbox/backup/20200101"
  fresh_dir="$sandbox/backup/20200102"
  today_dir="$sandbox/backup/$today"
  printf 'main db\n' > "$sandbox/src/db.db"
  mkdir -p "$stale_dir" "$fresh_dir"
  printf 'stale backup\n' > "$stale_dir/db.db.gz"
  printf 'fresh backup\n' > "$fresh_dir/db.db.gz"
  # stale: -mtime +0(1일 초과)에 걸리는 최소 나이. RETENTION_DAYS를 0→1로 바꾸는 변이를
  # 잡으려면(+0은 매치, +1은 미매치) '2 days ago'처럼 여유 있는 값이 아니라 경계에 붙여야 한다.
  touch -d '25 hours ago' "$stale_dir"
  # fresh: 24시간 미만이라 RETENTION_DAYS=0에서도 항상 남아야 하는 기존 백업 디렉터리.
  touch -d '1 hour ago' "$fresh_dir"

  _backup_scripts_run "$_karakeep_backup_script" "$sandbox" "$stdout_path" "$stderr_path" 0 \
    || fail "expected karakeep backup with RETENTION_DAYS=0 to exit 0"

  [ ! -e "$stale_dir" ] || fail "expected >24h-old karakeep backup dir to be deleted with RETENTION_DAYS=0"
  [ -d "$fresh_dir" ] || fail "expected <24h-old karakeep backup dir to remain with RETENTION_DAYS=0"
  [ -d "$today_dir" ] || fail "expected today's karakeep backup dir to remain with RETENTION_DAYS=0"
  [ -f "$today_dir/db.db.gz" ] || fail "expected today's karakeep db.db.gz backup to remain with RETENTION_DAYS=0"
}
