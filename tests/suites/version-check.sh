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

# ─────────────────────────────────────────────────────────────────
# 릴리즈 노트 절단 회귀 (#1385): 예전에는 jq 출력을 head -20으로 끊어서, 본문이
# 크면 head가 파이프를 먼저 닫아 jq가 SIGPIPE(141)로 죽고 pipefail 때문에 새 버전
# 알림 자체가 실패했다. 아래 테스트는 그 재현과, 20줄·1024자 제한이 절단 방식이
# 바뀐 뒤에도 그대로 유지되는지를 검증한다.
# ─────────────────────────────────────────────────────────────────

# curl 스텁의 notify_log는 curl argv를 한 줄에 하나씩 기록한다(_write_version_check_curl_stub
# 참고). "--form-string" "message=<내용>" 은 서로 다른 두 argv라서, message 값 자체에 개행이
# 있으면 로그에서도 여러 줄로 나온다. message= 로 시작하는 줄부터, 그다음에 나오는 단독
# "--form-string" 줄(바로 뒤의 form-string, 여기서는 priority) 전까지가 message 값이다.
# 한 테스트에서 여러 번 알림을 보내면 이 블록이 로그에 여러 번 나오므로, 마지막 블록만
# 골라야 한다(sed의 /시작/,/끝/ 범위는 첫 블록에서 멈춘다 — awk로 한 번 훑으며 매번 덮어쓴다).
_extract_last_pushover_message() {
  local notify_log="$1"
  awk '
    /^message=/ { collecting = 1; buf = $0; sub(/^message=/, "", buf); next }
    collecting && $0 == "--form-string" { collecting = 0; result = buf; next }
    collecting { buf = buf "\n" $0; next }
    END { printf "%s", result }
  ' "$notify_log"
}

# 400줄 x 240자('A')로 약 96KB 본문을 만든다. head -20 파이프에서 SIGPIPE를
# 안정적으로 재현하는 크기(이슈 #1385 재현 조건)다.
_write_large_ascii_release_body_github_json() {
  local out="$1" tag="$2"
  local body
  body=$(python3 - <<'PY'
print("\n".join("A" * 240 for _ in range(400)), end="")
PY
)
  jq -n --arg tag "$tag" --arg body "$body" '{tag_name: $tag, body: $body}' > "$out"
}

# 위 본문을 "앞 20줄, 이어서 최대 1024자"로 절단한 결과를 손계산한 값.
# 240자 줄 4개(각 줄 뒤 개행 포함, 241자 x 4 = 964자) + 5번째 줄의 앞 60자 = 1024자.
_expected_large_ascii_release_body() {
  local line
  line=$(printf 'A%.0s' $(seq 1 240))
  printf '%s\n%s\n%s\n%s\n%s' "$line" "$line" "$line" "$line" "${line:0:60}"
}

test_version_check_new_version_large_release_body_notifies_without_sigpipe() {
  local expected_release_body expected_message attempt
  expected_release_body=$(_expected_large_ascii_release_body)
  expected_message="v9.9.9 출시됨

${expected_release_body}

업데이트: sudo demo-update"

  for attempt in $(seq 1 20); do
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
    jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
    _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
      "demo" "demo:1.2" "demo/demo" "Demo" \
      || fail "attempt $attempt: initial run must exit 0"

    printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
    _write_large_ascii_release_body_github_json "$github_body" "9.9.9"
    _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
      "demo" "demo:1.2" "demo/demo" "Demo" \
      || fail "attempt $attempt: large release body must not abort the script (exit $?, SIGPIPE=141)"

    assert_file_contains "$state_dir/last-notified-version" "9.9.9"
    local actual_message
    actual_message=$(_extract_last_pushover_message "$notify_log")
    [ "$actual_message" = "$expected_message" ] \
      || fail "attempt $attempt: notified message does not match the expected 20-line/1024-char truncation"
  done
}

test_immich_version_check_new_version_large_release_body_notifies_without_sigpipe() {
  local expected_release_body expected_message attempt
  expected_release_body=$(_expected_large_ascii_release_body)
  expected_message="현재: v1.0.0 → 최신: v9.9.9

${expected_release_body}

업데이트: sudo immich-update"

  for attempt in $(seq 1 20); do
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
    printf '{"major":1,"minor":0,"patch":0}\n' > "$immich_body"
    printf '0\n' > "$github_status"
    jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
    _run_immich_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
      "$immich_url" "$api_key_file" \
      || fail "attempt $attempt: immich initial run must exit 0"

    printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
    _write_large_ascii_release_body_github_json "$github_body" "9.9.9"
    _run_immich_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
      "$immich_url" "$api_key_file" \
      || fail "attempt $attempt: immich large release body must not abort the script (exit $?, SIGPIPE=141)"

    assert_file_contains "$state_dir/last-notified-version" "9.9.9"
    local actual_message
    actual_message=$(_extract_last_pushover_message "$notify_log")
    [ "$actual_message" = "$expected_message" ] \
      || fail "attempt $attempt: immich notified message does not match the expected 20-line/1024-char truncation"
  done
}

# .body 필드 부재와 .body:null 은 둘 다 기존 기본 문구("릴리즈 노트 없음")로 대체돼야 한다.
test_version_check_release_body_default_text_for_missing_or_null_body() {
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
  jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  # .body 필드 자체가 없음
  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  jq -n --arg tag "2.0.0" '{tag_name: $tag}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "missing .body field must still exit 0"
  assert_contains "$(_extract_last_pushover_message "$notify_log")" "릴리즈 노트 없음"
  : > "$notify_log"

  # .body: null
  printf '%s\n' "$((1000000 + 7200))" > "$clock_file"
  jq -n --arg tag "3.0.0" '{tag_name: $tag, body: null}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "null .body must still exit 0"
  assert_contains "$(_extract_last_pushover_message "$notify_log")" "릴리즈 노트 없음"
}

# 빈 문자열 본문("")은 (null과 달리) 기본 문구로 대체되지 않고 그대로 빈 값으로 남아야 한다.
test_version_check_release_body_preserves_empty_string() {
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
  jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  jq -n --arg tag "2.0.0" --arg body "" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "empty string body must still exit 0"

  local release_body="" expected_message actual_message
  expected_message="v2.0.0 출시됨

${release_body}

업데이트: sudo demo-update"
  actual_message=$(_extract_last_pushover_message "$notify_log")
  [ "$actual_message" = "$expected_message" ] \
    || fail "empty string body must not be replaced by the missing/null default text"
}

# head -20 이 그랬던 것과 동일하게: 정확히 20줄은 그대로, 21줄 이상은 앞 20줄만 남아야 한다.
test_version_check_release_body_line_limit_matches_head_boundary() {
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
  jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  # 정확히 20줄: 전부 남아야 한다.
  local body_20 expected_20 actual_20
  body_20=$(python3 -c "print('\n'.join(f'line{i}' for i in range(1, 21)), end='')")
  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  jq -n --arg tag "2.0.0" --arg body "$body_20" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "exactly-20-line body must still exit 0"
  expected_20="v2.0.0 출시됨

${body_20}

업데이트: sudo demo-update"
  actual_20=$(_extract_last_pushover_message "$notify_log")
  [ "$actual_20" = "$expected_20" ] || fail "exactly 20 lines must be forwarded unmodified"
  : > "$notify_log"

  # 21줄 이상: 앞 20줄만 남고 21번째 줄 이후는 잘려야 한다.
  local body_25 expected_body_25 expected_25 actual_25
  body_25=$(python3 -c "print('\n'.join(f'line{i}' for i in range(1, 26)), end='')")
  expected_body_25=$(python3 -c "print('\n'.join(f'line{i}' for i in range(1, 21)), end='')")
  printf '%s\n' "$((1000000 + 7200))" > "$clock_file"
  jq -n --arg tag "3.0.0" --arg body "$body_25" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "25-line body must still exit 0"
  expected_25="v3.0.0 출시됨

${expected_body_25}

업데이트: sudo demo-update"
  actual_25=$(_extract_last_pushover_message "$notify_log")
  [ "$actual_25" = "$expected_25" ] || fail "line 21 and beyond must be truncated, matching head -20's line counting"
  assert_not_contains "$actual_25" "line21"
}

# GitHub 릴리즈 노트는 CRLF로 오는 경우가 흔하다. head -20 은 LF 기준으로만 줄을 세므로
# (CR은 그 줄의 내용으로 남는다) jq 쪽 split("\n")도 동일하게 LF 기준이어야 한다.
test_version_check_release_body_crlf_line_split_matches_head() {
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
  jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  # 기대값은 25줄 CRLF 본문 전체를 "\n" 기준으로만 나눠 앞 20개를 다시 "\n"으로 이은 것이다
  # (head -20과 동일한 규칙). 20번째 조각은 원본에서 그다음에도 줄이 more 있었으므로 자기
  # 앞의 "\r"을 그대로 지니고 있다 — 20줄만 있는 본문을 "\r\n"으로 새로 이어붙이면(끝에는
  # 구분자가 없음) 이 트레일링 "\r"이 빠지므로 기대값을 그렇게 따로 재구성하지 않는다.
  local body_crlf expected_body_crlf expected_message actual_message
  body_crlf=$(python3 -c "print('\r\n'.join(f'line{i}' for i in range(1, 26)), end='')")
  expected_body_crlf=$(python3 -c "
import sys
body = '\r\n'.join(f'line{i}' for i in range(1, 26))
lines = body.split('\n')[:20]
sys.stdout.write('\n'.join(lines))
")
  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  jq -n --arg tag "2.0.0" --arg body "$body_crlf" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "CRLF body must still exit 0"

  expected_message="v2.0.0 출시됨

${expected_body_crlf}

업데이트: sudo demo-update"
  actual_message=$(_extract_last_pushover_message "$notify_log")
  [ "$actual_message" = "$expected_message" ] \
    || fail "CRLF body's line-20 boundary must match head -20's LF-based line counting"
}

# 1024자 경계가 한글/이모지 같은 멀티바이트 문자 중간에서 문자열을 깨서는 안 된다.
# jq의 문자열 슬라이스는 유니코드 코드포인트 단위로 동작해 실행 환경 로케일과 무관하므로,
# LC_ALL=C(로케일 미설정에 가까운 최소 환경)에서 실행해도 결과가 달라지지 않아야 한다.
# 기대값은 프로덕션이 쓰는 jq 표현식이 아니라 Python의 코드포인트 슬라이스로 독립 계산한다.
test_version_check_release_body_unicode_boundary_not_corrupted() {
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
  jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
  LC_ALL=C LANG=C _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"

  # 한 줄짜리 본문(개행 없음)이라 20줄 제한은 걸리지 않고 1024자 제한만 걸린다.
  # "한글이모지🎉테스트" 9코드포인트 x 130 = 1170코드포인트로 1024자 경계를 넘는다.
  local body_unicode expected_release_body expected_message actual_message
  body_unicode=$(python3 -c "print('한글이모지🎉테스트' * 130, end='')")
  expected_release_body=$(python3 - "$body_unicode" <<'PY'
import sys
body = sys.argv[1]
lines = body.split("\n")[:20]
joined = "\n".join(lines)
sys.stdout.write(joined[:1024])
PY
)

  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  jq -n --arg tag "2.0.0" --arg body "$body_unicode" '{tag_name: $tag, body: $body}' > "$github_body"
  LC_ALL=C LANG=C _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "unicode body must still exit 0 under LC_ALL=C"

  expected_message="v2.0.0 출시됨

${expected_release_body}

업데이트: sudo demo-update"
  actual_message=$(_extract_last_pushover_message "$notify_log")
  [ "$actual_message" = "$expected_message" ] \
    || fail "unicode boundary truncation does not match Python's independent codepoint slice"

  # 코드포인트 경계에서 잘렸다면 유효한 UTF-8 이 아니게 된다(멀티바이트 시퀀스 중간 절단).
  printf '%s' "$actual_message" | python3 -c "
import sys
data = sys.stdin.buffer.read()
data.decode('utf-8')
" || fail "truncated message is not valid UTF-8 (cut mid multi-byte character)"
}

# 잘못된 JSON은 정상적인 빈 본문(.body 없음/null)과 구별되는 실패로 남아야 한다. GitHub 응답이
# 깨졌을 때 태그(tag_name) 추출(fetch_github_release, service-lib.sh)부터 실패하므로, 이 시점
# 이후의 상태(last-notified-version)는 바뀌지 않아야 한다. (참고: 이 실패는 함수 안에서
# 일어나는데 스크립트가 set -o errtrace 를 켜지 않아 최상단 ERR trap이 여기서는 실행되지
# 않는다 — 이 테스트에서는 "실패로 종료되고 정상 흐름처럼 진행되지 않는지"만 확인한다.)
test_version_check_invalid_github_json_fails_loudly_not_treated_as_empty_body() {
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
  jq -n --arg tag "1.0.0" --arg body "first release" '{tag_name: $tag, body: $body}' > "$github_body"
  _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
    "demo" "demo:1.2" "demo/demo" "Demo" \
    || fail "initial run must exit 0"
  : > "$notify_log"

  printf '%s\n' "$((1000000 + 3600))" > "$clock_file"
  printf 'this is not valid json{{{' > "$github_body"
  if _run_generic_version_check "$stub_dir" "$(_version_check_service_lib_path)" "$cred" "$state_dir" \
       "demo" "demo:1.2" "demo/demo" "Demo"; then
    fail "invalid GitHub JSON must not be treated as a normal (empty-body) response"
  fi

  assert_file_contains "$state_dir/last-notified-version" "1.0.0"
  [ ! -s "$notify_log" ] || fail "invalid JSON must not send a normal 업데이트 알림 (no false new-version notification)"
}
