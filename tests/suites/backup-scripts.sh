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
}

_backup_scripts_run() {
  local script="$1"
  local sandbox="$2"
  local stdout_path="$3"
  local stderr_path="$4"

  env \
    PATH="$sandbox/stub-bin:$PATH" \
    BACKUP_DIR="$sandbox/backup" \
    RETENTION_DAYS=30 \
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
