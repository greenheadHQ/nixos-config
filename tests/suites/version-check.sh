# tests/suites/version-check.sh — 공용 service-lib 기반 version-check 스크립트의 최초 성공 기록/워치독 테스트
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# 재사용 가능한 fixture: 가짜 시계, 상태 디렉터리, curl(GitHub·Pushover) 대역.
# 다른 version-check 테스트도 아래 헬퍼를 재사용할 수 있다.
#   - _write_fake_clock_stub dir clock_file        : date +%s 를 clock_file의 epoch로 고정
#   - _write_version_check_curl_stub dir github_status_file github_body_file notify_log
#                                                   : GitHub/Pushover 요청을 상태 파일로 대역
#   - _run_generic_version_check stub_dir service_lib pushover_cred state_dir \
#         container_name container_image github_repo display_name
#                                                   : generic-version-check.sh 1회 실행
#   - _write_immich_version_check_curl_stub / _run_immich_version_check
#                                                   : 위와 동일 계약 + Immich API 현재 버전 조회 대역

_version_check_service_lib_path() {
  printf '%s\n' "$REPO_ROOT/modules/nixos/lib/service-lib.sh"
}

_version_check_generic_script_path() {
  printf '%s\n' "$REPO_ROOT/modules/nixos/lib/generic-version-check.sh"
}

_immich_version_check_script_path() {
  printf '%s\n' "$REPO_ROOT/modules/nixos/programs/immich-update/files/version-check.sh"
}

# date +%s 를 clock_file에 적힌 epoch로 고정한다. 그 외 호출은 테스트가 잘못된 date 사용을
# 놓치지 않도록 실패시킨다(silent fallback으로 system date를 부르지 않음).
_write_fake_clock_stub() {
  local dir="$1"
  local clock_file="$2"

  mkdir -p "$dir"
  cat > "$dir/date" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "+%s" ]; then
  cat "$clock_file"
  exit 0
fi
echo "unexpected fake date args: \$*" >&2
exit 1
EOF_STUB
  chmod +x "$dir/date"
}

_write_version_check_curl_stub() {
  local dir="$1"
  local github_status_file="$2"
  local github_body_file="$3"
  local notify_log="$4"

  mkdir -p "$dir"
  cat > "$dir/curl" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
url="\${@: -1}"
case "\$url" in
  https://api.github.com/*)
    status="\$(cat "$github_status_file")"
    if [ "\$status" != "0" ]; then
      exit "\$status"
    fi
    cat "$github_body_file"
    ;;
  https://api.pushover.net/*)
    printf '%s\n' "\$@" >> "$notify_log"
    printf -- '---\n' >> "$notify_log"
    ;;
  *)
    echo "unexpected curl url: \$url" >&2
    exit 1
    ;;
esac
EOF_STUB
  chmod +x "$dir/curl"
}

_run_generic_version_check() {
  local stub_dir="$1" service_lib="$2" pushover_cred="$3" state_dir="$4"
  local container_name="$5" container_image="$6" github_repo="$7" display_name="$8"

  PATH="$stub_dir:$PATH" \
    PUSHOVER_CRED_FILE="$pushover_cred" \
    SERVICE_LIB="$service_lib" \
    STATE_DIR="$state_dir" \
    CONTAINER_NAME="$container_name" \
    CONTAINER_IMAGE="$container_image" \
    GITHUB_REPO="$github_repo" \
    SERVICE_DISPLAY_NAME="$display_name" \
    bash "$(_version_check_generic_script_path)"
}

_write_version_check_pushover_cred() {
  local path="$1"
  printf 'PUSHOVER_TOKEN=test-token\nPUSHOVER_USER=test-user\n' > "$path"
}

# immich-update/files/version-check.sh는 자체 curl 호출(Immich API 현재 버전 조회)이 하나
# 더 있다는 점만 다르고 GitHub/Pushover 대역은 동일 계약이다.
_write_immich_version_check_curl_stub() {
  local dir="$1" immich_url="$2" immich_status_file="$3" immich_body_file="$4"
  local github_status_file="$5" github_body_file="$6" notify_log="$7"

  mkdir -p "$dir"
  cat > "$dir/curl" <<EOF_STUB
#!/usr/bin/env bash
set -euo pipefail
url="\${@: -1}"
case "\$url" in
  "$immich_url/api/server/version")
    status="\$(cat "$immich_status_file")"
    if [ "\$status" != "0" ]; then
      exit "\$status"
    fi
    cat "$immich_body_file"
    ;;
  https://api.github.com/*)
    status="\$(cat "$github_status_file")"
    if [ "\$status" != "0" ]; then
      exit "\$status"
    fi
    cat "$github_body_file"
    ;;
  https://api.pushover.net/*)
    printf '%s\n' "\$@" >> "$notify_log"
    printf -- '---\n' >> "$notify_log"
    ;;
  *)
    echo "unexpected curl url: \$url" >&2
    exit 1
    ;;
esac
EOF_STUB
  chmod +x "$dir/curl"
}

_run_immich_version_check() {
  local stub_dir="$1" service_lib="$2" pushover_cred="$3" state_dir="$4"
  local immich_url="$5" api_key_file="$6"

  PATH="$stub_dir:$PATH" \
    IMMICH_URL="$immich_url" \
    API_KEY_FILE="$api_key_file" \
    PUSHOVER_CRED_FILE="$pushover_cred" \
    STATE_DIR="$state_dir" \
    SERVICE_LIB="$service_lib" \
    bash "$(_immich_version_check_script_path)"
}

test_version_check_initial_success_records_last_success_without_notification() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_version_check_curl_stub "$stub_dir" "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"

  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"

  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  assert_file_contains "$state_dir/last-notified-version" "1.2.3"
  [ -f "$state_dir/last-success" ] || fail "initial success run must record last-success"
  assert_file_contains "$state_dir/last-success" "1000000"
  [ ! -s "$notify_log" ] || fail "initial run must not send any notification"
}

test_version_check_subsequent_failure_below_threshold_keeps_last_success() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_version_check_curl_stub "$stub_dir" "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"

  # 최초 정상 조회로 last-success를 만든다 (T0).
  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"
  : > "$notify_log"

  # T0 + 2일, GitHub 조회 실패.
  printf '%s\n' "$((1000000 + 2 * 86400))" > "$clock_file"
  printf '1\n' > "$github_status"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "GitHub fetch failure must still exit 0"

  [ ! -s "$notify_log" ] || fail "watchdog must not warn before 3-day threshold"
  assert_file_contains "$state_dir/last-success" "1000000"
}

test_version_check_failure_at_threshold_triggers_watchdog_warning() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_version_check_curl_stub "$stub_dir" "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"

  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"
  : > "$notify_log"

  # 정확히 72시간(3일) 경과, 조회는 계속 실패.
  printf '%s\n' "$((1000000 + 3 * 86400))" > "$clock_file"
  printf '1\n' > "$github_status"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "GitHub fetch failure must still exit 0"

  assert_file_contains "$state_dir/last-success" "1000000"
  # 제목("Version Check")은 ERR trap 알림과도 겹치므로 워치독 특유의 메시지 본문을 리터럴로 확인한다.
  assert_file_contains "$notify_log" "message=버전 체크가 3일간 성공하지 못했습니다. 서비스 상태를 확인하세요."
}

test_version_check_failure_just_before_threshold_no_warning() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_version_check_curl_stub "$stub_dir" "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"

  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"
  : > "$notify_log"

  # 72시간에서 1초 모자란 시점(259199초 경과), 조회는 계속 실패.
  printf '%s\n' "$((1000000 + 259199))" > "$clock_file"
  printf '1\n' > "$github_status"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "GitHub fetch failure must still exit 0"

  [ ! -s "$notify_log" ] || fail "watchdog must not warn one second before the 3-day threshold"
  assert_file_contains "$state_dir/last-success" "1000000"
}

test_version_check_recovery_updates_last_success_without_new_version_notification() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_version_check_curl_stub "$stub_dir" "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"

  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  # 3일 넘게 실패하다가(경고 발생) 같은 버전으로 조회가 다시 성공한다.
  printf '%s\n' "$((1000000 + 4 * 86400))" > "$clock_file"
  printf '1\n' > "$github_status"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "GitHub fetch failure must still exit 0"
  assert_file_contains "$notify_log" "message=버전 체크가 4일간 성공하지 못했습니다. 서비스 상태를 확인하세요."
  : > "$notify_log"

  local recovery_time=$((1000000 + 4 * 86400 + 3600))
  printf '%s\n' "$recovery_time" > "$clock_file"
  printf '0\n' > "$github_status"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "recovery run must exit 0"

  assert_file_contains "$state_dir/last-success" "$recovery_time"
  assert_not_contains "$(cat "$notify_log" 2>/dev/null || true)" "업데이트 알림"

  # 성공 시각이 갱신됐으므로 곧바로 다음 점검을 해도 과거 시각 기준 경고가 재발하지 않아야 한다.
  : > "$notify_log"
  printf '%s\n' "$((recovery_time + 60))" > "$clock_file"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "follow-up run must exit 0"
  [ ! -s "$notify_log" ] || fail "watchdog must not warn right after last-success was refreshed"
}

test_version_check_initial_failure_records_nothing() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_version_check_curl_stub "$stub_dir" "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"

  printf '1000000\n' > "$clock_file"
  printf '1\n' > "$github_status"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "GitHub fetch failure must still exit 0"

  [ ! -e "$state_dir/last-notified-version" ] || fail "failed initial fetch must not record notified version"
  [ ! -e "$state_dir/last-success" ] || fail "failed initial fetch must not record last-success"
  [ ! -s "$notify_log" ] || fail "failed initial fetch must not send any notification"
}

# check_initial_run은 immich-update/files/version-check.sh도 함께 쓴다. service-lib.sh의
# 수정이 이 호출자에도 적용되는지 별도로 검증한다.
test_immich_version_check_initial_success_records_last_success() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  local immich_status immich_body api_key_file immich_url
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"
  immich_status="$sandbox/immich-status"
  immich_body="$sandbox/immich-body"
  api_key_file="$sandbox/api-key"
  immich_url="http://immich.invalid:2283"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_immich_version_check_curl_stub "$stub_dir" "$immich_url" "$immich_status" "$immich_body" \
    "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"
  printf 'IMMICH_API_KEY=test-key\n' > "$api_key_file"

  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$immich_status"
  printf '{"major":1,"minor":2,"patch":3}\n' > "$immich_body"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"

  _run_immich_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "$immich_url" "$api_key_file" \
    || fail "immich initial run must exit 0"

  assert_file_contains "$state_dir/last-notified-version" "1.2.3"
  [ -f "$state_dir/last-success" ] || fail "immich initial success run must record last-success"
  assert_file_contains "$state_dir/last-success" "1000000"
  [ ! -s "$notify_log" ] || fail "immich initial run must not send any notification"
}

# 위 테스트의 "알림 없음" 단언이 대역 연결로 성립함을 보이기 위해, 새 버전을 한 번 실제로
# 알리는 양성 사례를 별도로 둔다.
test_immich_version_check_new_version_notifies_and_records() {
  local sandbox stub_dir state_dir clock_file github_status github_body notify_log cred
  local immich_status immich_body api_key_file immich_url
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  state_dir="$sandbox/state"
  clock_file="$sandbox/clock"
  github_status="$sandbox/github-status"
  github_body="$sandbox/github-body"
  notify_log="$sandbox/notify.log"
  cred="$sandbox/pushover-cred"
  immich_status="$sandbox/immich-status"
  immich_body="$sandbox/immich-body"
  api_key_file="$sandbox/api-key"
  immich_url="http://immich.invalid:2283"

  mkdir -p "$state_dir"
  _write_fake_clock_stub "$stub_dir" "$clock_file"
  _write_immich_version_check_curl_stub "$stub_dir" "$immich_url" "$immich_status" "$immich_body" \
    "$github_status" "$github_body" "$notify_log"
  _write_version_check_pushover_cred "$cred"
  printf 'IMMICH_API_KEY=test-key\n' > "$api_key_file"

  printf '1000000\n' > "$clock_file"
  printf '0\n' > "$immich_status"
  printf '{"major":1,"minor":2,"patch":3}\n' > "$immich_body"
  printf '0\n' > "$github_status"
  printf '{"tag_name":"v1.2.3","body":"first release notes"}\n' > "$github_body"
  _run_immich_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "$immich_url" "$api_key_file" \
    || fail "immich initial run must exit 0"

  # 현재 버전은 그대로(1.2.3)이고 GitHub에 새 버전(1.3.0)이 올라온 경우.
  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  printf '{"tag_name":"v1.3.0","body":"second release notes"}\n' > "$github_body"
  _run_immich_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "$immich_url" "$api_key_file" \
    || fail "immich new-version run must exit 0"

  assert_file_contains "$notify_log" "title=Immich 업데이트 알림"
  assert_file_contains "$state_dir/last-notified-version" "1.3.0"
  assert_file_contains "$state_dir/last-success" "$((1000000 + 3600))"
}
