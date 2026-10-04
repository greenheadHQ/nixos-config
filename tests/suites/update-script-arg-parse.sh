# tests/suites/update-script-arg-parse.sh — 업데이트 스크립트 인자 선행 검증 fixture 테스트 (sourced)
# shellcheck shell=bash
# SC2154: REPO_ROOT/FIXTURE_DIR/TEST_TMP_FILE는 aggregator가 정의.
# shellcheck disable=SC2154

# ─── 공통 대역(double) 설치 ──────────────────────────────────────────
# 세 명령(podman/systemctl/curl) 호출을 하나의 로그 파일(calls.log)에 순서대로 기록한다.
# 스크립트별로 두 갈래 테스트를 쓴다.
#   (1) env·PATH를 전혀 주지 않고 직접 실행 — --help가 자격 파일·환경변수 없이도 동작하는지만
#       본다(이슈 검증 절차 3). 대역이 연결돼 있지 않으므로 calls.log는 보지 않는다.
#   (2) `_<svc>_update_run`으로 env·PATH·대역을 모두 연결해 실행(`_with_env` 접미사) —
#       --help·잘못된 인자가 실제로 잠금·조회·백업 경계를 건드리지 않는지 calls.log가 비어
#       있는지, STATE_DIR/lock 아래에 아무것도 생기지 않는지로 확인한다. (1)만으로는 파서
#       앞에 몰래 들어간 curl 호출이나 별도 fd로 여는 잠금 같은 변이를 잡지 못한다.
# 무인자/--ack-bridge-risk/--dry-run 테스트는 항상 (2)를 쓰고, calls.log의 상대 순서로 기존
# 순서가 유지되는지도 함께 검증한다 — 그 실행이 로그를 남긴다는 사실 자체가 (2) 계열 테스트에서
# 대역이 실제로 연결돼 있음을 증명한다.

_update_arg_parse_install_podman_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'podman %s\n' "$*" >> "$UPDATE_TEST_CALL_LOG"
case "${1:-}" in
  container)
    echo "true"
    ;;
  inspect)
    echo "${UPDATE_TEST_PODMAN_CURRENT_DIGEST:-digest-old}"
    ;;
  image)
    echo "${UPDATE_TEST_PODMAN_NEW_DIGEST:-digest-new}"
    ;;
  exec)
    # pg_dump 대역 — 압축 후에도 크기 검증(>=1024 bytes)을 통과할 만큼 채운다.
    head -c 4000 /dev/urandom | base64
    ;;
  *)
    :
    ;;
esac
exit 0
STUB
  chmod +x "$path"
}

_update_arg_parse_install_systemctl_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "$UPDATE_TEST_CALL_LOG"
case "${1:-}" in
  stop|start)
    exit 0
    ;;
  is-enabled)
    exit "${UPDATE_TEST_SYSTEMCTL_IS_ENABLED_EXIT:-1}"
    ;;
  is-active)
    exit "${UPDATE_TEST_SYSTEMCTL_IS_ACTIVE_EXIT:-0}"
    ;;
  *)
    exit 0
    ;;
esac
STUB
  chmod +x "$path"
}

_update_arg_parse_install_curl_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >> "$UPDATE_TEST_CALL_LOG"
args=("$@")
last="${args[${#args[@]}-1]}"
case "$last" in
  */api/server/version)
    echo '{"major":1,"minor":2,"patch":3}'
    ;;
  https://api.github.com/repos/*/releases/latest)
    echo '{"tag_name":"v9.9.9"}'
    ;;
  https://api.pushover.net/*)
    cat >> "$UPDATE_TEST_CALL_LOG"
    ;;
  *)
    :
    ;;
esac
exit 0
STUB
  chmod +x "$path"
}

# ═══════════════════════════════════════════════════════════════════
# Immich
# ═══════════════════════════════════════════════════════════════════

_immich_update_script_original="$REPO_ROOT/modules/nixos/programs/immich-update/files/update-script.sh"

_immich_update_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/stub-bin" "$sandbox/lock" "$sandbox/backups"
  _update_arg_parse_install_podman_stub "$sandbox/stub-bin/podman"
  _update_arg_parse_install_systemctl_stub "$sandbox/stub-bin/systemctl"
  _update_arg_parse_install_curl_stub "$sandbox/stub-bin/curl"
  printf 'IMMICH_API_KEY=test-key\n' > "$sandbox/api-key"
  printf 'PUSHOVER_TOKEN=test-token\nPUSHOVER_USER=test-user\n' > "$sandbox/pushover"
  : > "$sandbox/calls.log"
  # 잠금 경로가 하드코딩(/var/lib/immich-update/.lock)이라 격리 재현처럼 사본에서 경로만 바꾼다.
  sed "s#/var/lib/immich-update/\.lock#$sandbox/lock/.lock#" \
    "$_immich_update_script_original" > "$sandbox/update-script.sh"

  # sed 치환이 조용히 no-op이 되면(원본의 하드코딩 경로 문구가 바뀌는 등) 아래 모든 lock 부재
  # 단언이 원본 경로를 한 번도 건드리지 않아 항상 거짓으로 통과하므로, 여기서 치환 자체를 가드한다.
  grep -Fq "$sandbox/lock/.lock" "$sandbox/update-script.sh" \
    || fail "expected immich sandbox copy to use the substituted lock path"
  ! grep -Fq "/var/lib/immich-update/.lock" "$sandbox/update-script.sh" \
    || fail "expected immich sandbox copy to have no leftover hardcoded lock path"
}

_immich_update_run() {
  local sandbox="$1" stdout_path="$2" stderr_path="$3"
  shift 3
  env \
    PATH="$sandbox/stub-bin:$PATH" \
    IMMICH_URL="http://immich.local" \
    API_KEY_FILE="$sandbox/api-key" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    BACKUP_DIR="$sandbox/backups" \
    SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$REPO_ROOT/modules/shared/scripts/lib/pushover.sh" \
    SERVER_IMAGE="ghcr.io/immich-app/immich-server:v1.2.3" \
    ML_IMAGE="ghcr.io/immich-app/immich-machine-learning:v1.2.3" \
    GITHUB_REPO="immich-app/immich" \
    UPDATE_TEST_CALL_LOG="$sandbox/calls.log" \
    bash "$sandbox/update-script.sh" "$@" > "$stdout_path" 2> "$stderr_path"
}

test_immich_update_help_flag_exits_zero_without_side_effects() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # 필수 환경변수·자격 파일을 전혀 주지 않은 상태로 --help만 호출한다.
  bash "$sandbox/update-script.sh" --help > "$stdout_path" 2> "$stderr_path" \
    || fail "expected --help to exit 0 even without required env/credentials"

  assert_file_contains "$stdout_path" "Usage: immich-update [--dry-run]"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected --help not to create the lock file"
}

test_immich_update_rejects_unknown_option() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$sandbox/update-script.sh" --dryrun > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected rejected option not to create the lock file"
}

test_immich_update_rejects_excess_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$sandbox/update-script.sh" --dry-run extra > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument after --dry-run to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected rejected excess argument not to create the lock file"
}

test_immich_update_rejects_bare_positional_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # --dryrun(오타)과는 별개로, 옵션 형태가 아닌 위치 인자도 거부되는지 확인한다(이슈 절차 2).
  rc=0
  _immich_update_run "$sandbox" "$stdout_path" "$stderr_path" foo || rc=$?
  [ "$rc" -ne 0 ] || fail "expected bare positional argument foo to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: foo"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected positional argument not to call podman/systemctl/curl"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected rejected positional argument not to create the lock file"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected rejected positional argument not to touch backups dir"
}

test_immich_update_help_flag_avoids_boundaries_with_env() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # env·PATH·대역을 모두 연결한 경로로 --help를 실행해, 파서 앞에 몰래 들어간 curl 호출이나
  # 별도 fd로 여는 잠금 같은 변이를 calls.log/lock/backups로 잡을 수 있는지 확인한다.
  _immich_update_run "$sandbox" "$stdout_path" "$stderr_path" --help \
    || fail "expected --help to exit 0 with full env/double wired"

  assert_file_contains "$stdout_path" "Usage: immich-update [--dry-run]"
  [ ! -s "$sandbox/calls.log" ] || fail "expected --help not to call podman/systemctl/curl"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected --help not to create the lock file"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected --help not to touch backups dir"
}

test_immich_update_rejects_unknown_option_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _immich_update_run "$sandbox" "$stdout_path" "$stderr_path" --dryrun || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected option not to call podman/systemctl/curl"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected rejected option not to create the lock file"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected rejected option not to touch backups dir"
}

test_immich_update_rejects_excess_argument_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _immich_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run extra || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected excess argument not to call podman/systemctl/curl"
  [ ! -e "$sandbox/lock/.lock" ] || fail "expected rejected excess argument not to create the lock file"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected rejected excess argument not to touch backups dir"
}

test_immich_update_no_args_preserves_existing_update_flow() {
  local sandbox stdout_path stderr_path output backup_line pull_line stop_line start_line
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _immich_update_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected no-args real run to succeed: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "Update completed successfully"
  [ -e "$sandbox/lock/.lock" ] || fail "expected real run to create the lock file"

  # 기존 순서(백업 → pull → stop → start)가 이번 변경으로 흐트러지지 않았는지 확인한다. 이 실행이
  # calls.log를 채운다는 사실 자체가 위 _with_env 테스트들의 "빈 로그" 단언이 실제로 대역에
  # 연결돼 있음을 증명한다.
  backup_line=$(grep -n "^podman exec" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  pull_line=$(grep -n "^podman pull" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  stop_line=$(grep -n "^systemctl stop" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  start_line=$(grep -n "^systemctl start" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  [ -n "$backup_line" ] && [ -n "$pull_line" ] && [ -n "$stop_line" ] && [ -n "$start_line" ] \
    || fail "expected backup/pull/stop/start boundaries to be recorded"
  [ "$backup_line" -lt "$pull_line" ] || fail "expected backup to precede pull"
  [ "$pull_line" -lt "$stop_line" ] || fail "expected pull to precede stop"
  [ "$stop_line" -lt "$start_line" ] || fail "expected stop to precede start"
}

test_immich_update_dry_run_skips_mutating_boundaries() {
  local sandbox stdout_path stderr_path output
  sandbox=$(new_sandbox)
  _immich_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _immich_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run \
    || fail "expected --dry-run to exit 0: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "=== DRY RUN MODE ==="
  assert_contains "$output" "Dry Run Summary"
  assert_not_contains "$output" "Update completed successfully"
  ! grep -Fq "podman pull" "$sandbox/calls.log" || fail "expected dry-run not to pull images"
  ! grep -Fq "systemctl stop" "$sandbox/calls.log" || fail "expected dry-run not to stop containers"
  ! grep -Fq "systemctl start" "$sandbox/calls.log" || fail "expected dry-run not to start containers"
  ! grep -Fq "podman exec" "$sandbox/calls.log" || fail "expected dry-run not to run DB backup"
}

# ═══════════════════════════════════════════════════════════════════
# Copyparty
# ═══════════════════════════════════════════════════════════════════

_copyparty_update_script="$REPO_ROOT/modules/nixos/programs/copyparty-update/files/update-script.sh"

_copyparty_update_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/stub-bin" "$sandbox/state"
  _update_arg_parse_install_podman_stub "$sandbox/stub-bin/podman"
  _update_arg_parse_install_systemctl_stub "$sandbox/stub-bin/systemctl"
  _update_arg_parse_install_curl_stub "$sandbox/stub-bin/curl"
  printf 'PUSHOVER_TOKEN=test-token\nPUSHOVER_USER=test-user\n' > "$sandbox/pushover"
  : > "$sandbox/calls.log"
}

_copyparty_update_run() {
  local sandbox="$1" stdout_path="$2" stderr_path="$3"
  shift 3
  env \
    PATH="$sandbox/stub-bin:$PATH" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$REPO_ROOT/modules/shared/scripts/lib/pushover.sh" \
    STATE_DIR="$sandbox/state" \
    CONTAINER_NAME="copyparty" \
    CONTAINER_IMAGE="ghcr.io/9001/copyparty:v1.2.3" \
    SERVICE_UNIT="podman-copyparty.service" \
    HEALTH_URL="http://localhost:3923/" \
    GITHUB_REPO="9001/copyparty" \
    SERVICE_DISPLAY_NAME="Copyparty" \
    UPDATE_TEST_CALL_LOG="$sandbox/calls.log" \
    bash "$_copyparty_update_script" "$@" > "$stdout_path" 2> "$stderr_path"
}

test_copyparty_update_help_flag_exits_zero_without_side_effects() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  bash "$_copyparty_update_script" --help > "$stdout_path" 2> "$stderr_path" \
    || fail "expected --help to exit 0 even without required env/credentials"

  assert_file_contains "$stdout_path" "Usage: copyparty-update [--dry-run]"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected --help not to create the lock file"
}

test_copyparty_update_rejects_unknown_option() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$_copyparty_update_script" --dryrun > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected rejected option not to create the lock file"
}

test_copyparty_update_rejects_excess_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$_copyparty_update_script" --dry-run extra > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument after --dry-run to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected rejected excess argument not to create the lock file"
}

test_copyparty_update_rejects_bare_positional_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # --dryrun(오타)과는 별개로, 옵션 형태가 아닌 위치 인자도 거부되는지 확인한다(이슈 절차 2).
  rc=0
  _copyparty_update_run "$sandbox" "$stdout_path" "$stderr_path" foo || rc=$?
  [ "$rc" -ne 0 ] || fail "expected bare positional argument foo to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: foo"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected positional argument not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected positional argument not to touch state dir"
}

test_copyparty_update_help_flag_avoids_boundaries_with_env() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # env·PATH·대역을 모두 연결한 경로로 --help를 실행해, 파서 앞에 몰래 들어간 curl 호출이나
  # 별도 fd로 여는 잠금 같은 변이를 calls.log/state 디렉터리로 잡을 수 있는지 확인한다.
  _copyparty_update_run "$sandbox" "$stdout_path" "$stderr_path" --help \
    || fail "expected --help to exit 0 with full env/double wired"

  assert_file_contains "$stdout_path" "Usage: copyparty-update [--dry-run]"
  [ ! -s "$sandbox/calls.log" ] || fail "expected --help not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected --help not to touch state dir"
}

test_copyparty_update_rejects_unknown_option_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _copyparty_update_run "$sandbox" "$stdout_path" "$stderr_path" --dryrun || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected option not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected option not to touch state dir"
}

test_copyparty_update_rejects_excess_argument_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _copyparty_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run extra || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected excess argument not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected excess argument not to touch state dir"
}

test_copyparty_update_no_args_preserves_existing_update_flow() {
  local sandbox stdout_path stderr_path output pull_line stop_line start_line
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _copyparty_update_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected no-args real run to succeed: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "Update completed successfully"
  [ -e "$sandbox/state/.lock" ] || fail "expected real run to create the lock file"

  # 이 실행이 calls.log를 채운다는 사실 자체가 위 _with_env 테스트들의 "빈 로그" 단언이 실제로
  # 대역에 연결돼 있음을 증명한다.
  pull_line=$(grep -n "^podman pull" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  stop_line=$(grep -n "^systemctl stop" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  start_line=$(grep -n "^systemctl start" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  [ -n "$pull_line" ] && [ -n "$stop_line" ] && [ -n "$start_line" ] \
    || fail "expected pull/stop/start boundaries to be recorded"
  [ "$pull_line" -lt "$stop_line" ] || fail "expected pull to precede stop"
  [ "$stop_line" -lt "$start_line" ] || fail "expected stop to precede start"
}

test_copyparty_update_dry_run_skips_mutating_boundaries() {
  local sandbox stdout_path stderr_path output
  sandbox=$(new_sandbox)
  _copyparty_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _copyparty_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run \
    || fail "expected --dry-run to exit 0: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "=== DRY RUN MODE ==="
  assert_contains "$output" "Dry Run Summary"
  assert_not_contains "$output" "Update completed successfully"
  ! grep -Fq "podman pull" "$sandbox/calls.log" || fail "expected dry-run not to pull images"
  ! grep -Fq "systemctl stop" "$sandbox/calls.log" || fail "expected dry-run not to stop containers"
  ! grep -Fq "systemctl start" "$sandbox/calls.log" || fail "expected dry-run not to start containers"
}

# ═══════════════════════════════════════════════════════════════════
# Uptime Kuma
# ═══════════════════════════════════════════════════════════════════

_uptime_kuma_update_script="$REPO_ROOT/modules/nixos/programs/uptime-kuma-update/files/update-script.sh"

_uptime_kuma_update_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/stub-bin" "$sandbox/state" "$sandbox/backups" "$sandbox/data"
  _update_arg_parse_install_podman_stub "$sandbox/stub-bin/podman"
  _update_arg_parse_install_systemctl_stub "$sandbox/stub-bin/systemctl"
  _update_arg_parse_install_curl_stub "$sandbox/stub-bin/curl"
  printf 'PUSHOVER_TOKEN=test-token\nPUSHOVER_USER=test-user\n' > "$sandbox/pushover"
  head -c 4000 /dev/urandom | base64 > "$sandbox/data/kuma.db"
  : > "$sandbox/calls.log"
}

_uptime_kuma_update_run() {
  local sandbox="$1" stdout_path="$2" stderr_path="$3"
  shift 3
  env \
    PATH="$sandbox/stub-bin:$PATH" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$REPO_ROOT/modules/shared/scripts/lib/pushover.sh" \
    STATE_DIR="$sandbox/state" \
    BACKUP_DIR="$sandbox/backups" \
    CONTAINER_NAME="uptime-kuma" \
    CONTAINER_IMAGE="louislam/uptime-kuma:1.23.0" \
    SERVICE_UNIT="podman-uptime-kuma.service" \
    HEALTH_URL="http://localhost:3001/" \
    DATA_DIR="$sandbox/data" \
    GITHUB_REPO="louislam/uptime-kuma" \
    SERVICE_DISPLAY_NAME="Uptime Kuma" \
    UPDATE_TEST_CALL_LOG="$sandbox/calls.log" \
    bash "$_uptime_kuma_update_script" "$@" > "$stdout_path" 2> "$stderr_path"
}

test_uptime_kuma_update_help_flag_exits_zero_without_side_effects() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  bash "$_uptime_kuma_update_script" --help > "$stdout_path" 2> "$stderr_path" \
    || fail "expected --help to exit 0 even without required env/credentials"

  assert_file_contains "$stdout_path" "Usage: uptime-kuma-update [--dry-run]"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected --help not to create the lock file"
}

test_uptime_kuma_update_rejects_unknown_option() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$_uptime_kuma_update_script" --dryrun > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected rejected option not to create the lock file"
}

test_uptime_kuma_update_rejects_excess_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$_uptime_kuma_update_script" --dry-run extra > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument after --dry-run to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected rejected excess argument not to create the lock file"
}

test_uptime_kuma_update_rejects_bare_positional_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # --dryrun(오타)과는 별개로, 옵션 형태가 아닌 위치 인자도 거부되는지 확인한다(이슈 절차 2).
  rc=0
  _uptime_kuma_update_run "$sandbox" "$stdout_path" "$stderr_path" foo || rc=$?
  [ "$rc" -ne 0 ] || fail "expected bare positional argument foo to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: foo"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected positional argument not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected positional argument not to touch state dir"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected rejected positional argument not to touch backups dir"
}

test_uptime_kuma_update_help_flag_avoids_boundaries_with_env() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # env·PATH·대역을 모두 연결한 경로로 --help를 실행해, 파서 앞에 몰래 들어간 curl 호출이나
  # 별도 fd로 여는 잠금 같은 변이를 calls.log/state/backups 디렉터리로 잡을 수 있는지 확인한다.
  _uptime_kuma_update_run "$sandbox" "$stdout_path" "$stderr_path" --help \
    || fail "expected --help to exit 0 with full env/double wired"

  assert_file_contains "$stdout_path" "Usage: uptime-kuma-update [--dry-run]"
  [ ! -s "$sandbox/calls.log" ] || fail "expected --help not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected --help not to touch state dir"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected --help not to touch backups dir"
}

test_uptime_kuma_update_rejects_unknown_option_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _uptime_kuma_update_run "$sandbox" "$stdout_path" "$stderr_path" --dryrun || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected option not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected option not to touch state dir"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected rejected option not to touch backups dir"
}

test_uptime_kuma_update_rejects_excess_argument_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _uptime_kuma_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run extra || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected excess argument not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected excess argument not to touch state dir"
  [ -z "$(ls -A "$sandbox/backups")" ] || fail "expected rejected excess argument not to touch backups dir"
}

test_uptime_kuma_update_no_args_preserves_existing_update_flow() {
  local sandbox stdout_path stderr_path output pull_line stop_line start_line
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _uptime_kuma_update_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected no-args real run to succeed: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "Update completed successfully"
  [ -e "$sandbox/state/.lock" ] || fail "expected real run to create the lock file"

  # 이 실행이 calls.log를 채운다는 사실 자체가 위 _with_env 테스트들의 "빈 로그" 단언이 실제로
  # 대역에 연결돼 있음을 증명한다.
  pull_line=$(grep -n "^podman pull" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  stop_line=$(grep -n "^systemctl stop" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  start_line=$(grep -n "^systemctl start" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  [ -n "$pull_line" ] && [ -n "$stop_line" ] && [ -n "$start_line" ] \
    || fail "expected pull/stop/start boundaries to be recorded"
  [ "$pull_line" -lt "$stop_line" ] || fail "expected pull to precede stop"
  [ "$stop_line" -lt "$start_line" ] || fail "expected stop to precede start"
}

test_uptime_kuma_update_dry_run_skips_mutating_boundaries() {
  local sandbox stdout_path stderr_path output
  sandbox=$(new_sandbox)
  _uptime_kuma_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _uptime_kuma_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run \
    || fail "expected --dry-run to exit 0: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "=== DRY RUN MODE ==="
  assert_contains "$output" "Dry Run Summary"
  assert_not_contains "$output" "Update completed successfully"
  ! grep -Fq "podman pull" "$sandbox/calls.log" || fail "expected dry-run not to pull images"
  ! grep -Fq "systemctl stop" "$sandbox/calls.log" || fail "expected dry-run not to stop containers"
  ! grep -Fq "systemctl start" "$sandbox/calls.log" || fail "expected dry-run not to start containers"
}

# ═══════════════════════════════════════════════════════════════════
# Karakeep (G1 확장 — 잠금은 이미 파서 뒤에 있으나 source/환경검증이 파서보다 앞이라 --help가
# 자격 파일에 묶여 있었다. --ack-bridge-risk 요구 자체는 이 이슈와 무관한 기존 결정이라 보존한다)
# ═══════════════════════════════════════════════════════════════════

_karakeep_update_script="$REPO_ROOT/modules/nixos/programs/karakeep-update/files/update-script.sh"

_karakeep_update_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/stub-bin" "$sandbox/state"
  _update_arg_parse_install_podman_stub "$sandbox/stub-bin/podman"
  _update_arg_parse_install_systemctl_stub "$sandbox/stub-bin/systemctl"
  _update_arg_parse_install_curl_stub "$sandbox/stub-bin/curl"
  printf 'PUSHOVER_TOKEN=test-token\nPUSHOVER_USER=test-user\n' > "$sandbox/pushover"
  : > "$sandbox/calls.log"
}

_karakeep_update_run() {
  local sandbox="$1" stdout_path="$2" stderr_path="$3"
  shift 3
  env \
    PATH="$sandbox/stub-bin:$PATH" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$REPO_ROOT/modules/shared/scripts/lib/pushover.sh" \
    STATE_DIR="$sandbox/state" \
    CONTAINER_NAME="karakeep" \
    CONTAINER_IMAGE="ghcr.io/karakeep-app/karakeep:1.2.3" \
    SERVICE_UNIT="podman-karakeep.service" \
    HEALTH_URL="http://localhost:3000" \
    GITHUB_REPO="karakeep-app/karakeep" \
    SERVICE_DISPLAY_NAME="Karakeep" \
    UPDATE_TEST_CALL_LOG="$sandbox/calls.log" \
    bash "$_karakeep_update_script" "$@" > "$stdout_path" 2> "$stderr_path"
}

test_karakeep_update_help_flag_exits_zero_without_side_effects() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  bash "$_karakeep_update_script" --help > "$stdout_path" 2> "$stderr_path" \
    || fail "expected --help to exit 0 even without required env/credentials"

  assert_file_contains "$stdout_path" "Usage: karakeep-update [--dry-run] [--ack-bridge-risk]"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected --help not to create the lock file"
}

test_karakeep_update_rejects_unknown_option() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$_karakeep_update_script" --dryrun > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected rejected option not to create the lock file"
}

test_karakeep_update_rejects_excess_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  bash "$_karakeep_update_script" --dry-run extra > "$stdout_path" 2> "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument after --dry-run to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected rejected excess argument not to create the lock file"
}

test_karakeep_update_rejects_bare_positional_argument() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # --dryrun(오타)과는 별개로, 옵션 형태가 아닌 위치 인자도 거부되는지 확인한다(이슈 절차 2).
  rc=0
  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" foo || rc=$?
  [ "$rc" -ne 0 ] || fail "expected bare positional argument foo to exit non-zero"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: foo"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected positional argument not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected positional argument not to touch state dir"
}

test_karakeep_update_help_flag_avoids_boundaries_with_env() {
  local sandbox stdout_path stderr_path
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # env·PATH·대역을 모두 연결한 경로로 --help를 실행해, 파서 앞에 몰래 들어간 curl 호출이나
  # 별도 fd로 여는 잠금 같은 변이를 calls.log/state 디렉터리로 잡을 수 있는지 확인한다.
  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" --help \
    || fail "expected --help to exit 0 with full env/double wired"

  assert_file_contains "$stdout_path" "Usage: karakeep-update [--dry-run] [--ack-bridge-risk]"
  [ ! -s "$sandbox/calls.log" ] || fail "expected --help not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected --help not to touch state dir"
}

test_karakeep_update_rejects_unknown_option_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" --dryrun || rc=$?
  [ "$rc" -ne 0 ] || fail "expected unknown option --dryrun to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: --dryrun"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected option not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected option not to touch state dir"
}

test_karakeep_update_rejects_excess_argument_with_env() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  rc=0
  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run extra || rc=$?
  [ "$rc" -ne 0 ] || fail "expected excess argument to exit non-zero with full env/double wired"

  assert_file_contains "$stdout_path" "ERROR: Unknown option: extra"
  [ ! -s "$sandbox/calls.log" ] || fail "expected rejected excess argument not to call podman/systemctl/curl"
  [ -z "$(ls -A "$sandbox/state")" ] || fail "expected rejected excess argument not to touch state dir"
}

test_karakeep_update_no_args_still_requires_ack_bridge_risk() {
  local sandbox stdout_path stderr_path rc
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # 이 게이트는 #1383 범위 밖의 기존 결정이다 — 파서를 앞으로 옮겨도 그대로 보존되는지 확인한다.
  rc=0
  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected no-args to still require --ack-bridge-risk"

  assert_file_contains "$stdout_path" "ERROR: karakeep-update requires --ack-bridge-risk"
  [ ! -e "$sandbox/state/.lock" ] || fail "expected ack-bridge-risk gate to run before the lock"
  [ ! -s "$sandbox/calls.log" ] || fail "expected ack-bridge-risk gate not to call podman/systemctl/curl"
}

test_karakeep_update_ack_bridge_risk_preserves_existing_update_flow() {
  local sandbox stdout_path stderr_path output pull_line stop_line start_line
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" --ack-bridge-risk \
    || fail "expected --ack-bridge-risk real run to succeed: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "Update completed successfully"
  [ -e "$sandbox/state/.lock" ] || fail "expected real run to create the lock file"

  # 이 실행이 calls.log를 채운다는 사실 자체가 위 _with_env 테스트들의 "빈 로그" 단언이 실제로
  # 대역에 연결돼 있음을 증명한다.
  pull_line=$(grep -n "^podman pull" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  stop_line=$(grep -n "^systemctl stop" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  start_line=$(grep -n "^systemctl start" "$sandbox/calls.log" | head -1 | cut -d: -f1)
  [ -n "$pull_line" ] && [ -n "$stop_line" ] && [ -n "$start_line" ] \
    || fail "expected pull/stop/start boundaries to be recorded"
  [ "$pull_line" -lt "$stop_line" ] || fail "expected pull to precede stop"
  [ "$stop_line" -lt "$start_line" ] || fail "expected stop to precede start"
}

test_karakeep_update_dry_run_skips_mutating_boundaries() {
  local sandbox stdout_path stderr_path output
  sandbox=$(new_sandbox)
  _karakeep_update_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"

  # --dry-run은 --ack-bridge-risk 없이도 허용된다(기존 계약).
  _karakeep_update_run "$sandbox" "$stdout_path" "$stderr_path" --dry-run \
    || fail "expected --dry-run to exit 0: $(cat "$stderr_path")"

  output=$(cat "$stdout_path")
  assert_contains "$output" "=== DRY RUN MODE ==="
  assert_contains "$output" "Dry Run Summary"
  assert_not_contains "$output" "Update completed successfully"
  ! grep -Fq "podman pull" "$sandbox/calls.log" || fail "expected dry-run not to pull images"
  ! grep -Fq "systemctl stop" "$sandbox/calls.log" || fail "expected dry-run not to stop containers"
  ! grep -Fq "systemctl start" "$sandbox/calls.log" || fail "expected dry-run not to start containers"
}
