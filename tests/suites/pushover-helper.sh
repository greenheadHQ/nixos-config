# tests/suites/pushover-helper.sh — shared Pushover helper unit tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# SC2016: bash -c의 변수는 fixture 자식 셸에서 해석한다.
# shellcheck disable=SC2154,SC2016

_pushover_helper_path() {
  printf '%s\n' "$REPO_ROOT/modules/shared/scripts/lib/pushover.sh"
}

_write_pushover_curl_stub() {
  local dir="$1"

  mkdir -p "$dir"
  cat > "$dir/curl" <<'EOF_STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${PUSHOVER_CURL_LOG:?}"
printf '%s\n' "$@" >> "$PUSHOVER_CURL_LOG"
if [ -n "${PUSHOVER_CURL_ARGV_LOG:-}" ]; then
  printf '%s\n' "$@" >> "$PUSHOVER_CURL_ARGV_LOG"
fi
# helper는 자격·필드를 argv가 아니라 --config - stdin으로 전달한다 — 함께 기록해야
# 기존 필드 assertion이 성립한다.
if [ -n "${PUSHOVER_CURL_STDIN_LOG:-}" ]; then
  cat > "$PUSHOVER_CURL_STDIN_LOG"
  cat "$PUSHOVER_CURL_STDIN_LOG" >> "$PUSHOVER_CURL_LOG"
else
  cat >> "$PUSHOVER_CURL_LOG"
fi
printf '%s\n' 'fake curl response'
printf '%s\n' 'fake curl stderr' >&2
exit "${PUSHOVER_CURL_EXIT:-0}"
EOF_STUB
  chmod +x "$dir/curl"
}

_write_pushover_cred() {
  local path="$1"

  cat > "$path" <<'EOF_CRED'
PUSHOVER_TOKEN='token value'
PUSHOVER_USER='user value'
EOF_CRED
}

test_pushover_send_missing_cred_returns_1_without_curl() {
  local sandbox stub_dir log
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  log="$sandbox/curl.log"
  _write_pushover_curl_stub "$stub_dir"
  # shellcheck source=/dev/null
  source "$(_pushover_helper_path)"

  export PUSHOVER_CURL_LOG="$log"
  export PUSHOVER_CURL_EXIT=0
  if PATH="$stub_dir:$PATH" pushover_send "$sandbox/missing" "Title" "Body" 0; then
    fail "pushover_send must fail when credential file is missing"
  fi
  [ ! -e "$log" ] || fail "curl must not be called when credential file is missing"
}

test_pushover_send_success_passes_expected_fields() {
  local sandbox stub_dir log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  log="$sandbox/curl.log"
  cred="$sandbox/cred"
  _write_pushover_curl_stub "$stub_dir"
  _write_pushover_cred "$cred"
  # shellcheck source=/dev/null
  source "$(_pushover_helper_path)"

  export PUSHOVER_CURL_LOG="$log"
  export PUSHOVER_CURL_EXIT=0
  PATH="$stub_dir:$PATH" pushover_send "$cred" "Test title" "Test message" 1 \
    || fail "pushover_send must succeed when curl succeeds"

  assert_file_contains "$log" "form-string = \"token=token value\""
  assert_file_contains "$log" "form-string = \"user=user value\""
  assert_file_contains "$log" "form-string = \"title=Test title\""
  assert_file_contains "$log" "form-string = \"message=Test message\""
  assert_file_contains "$log" "form-string = \"priority=1\""
  assert_file_contains "$log" "https://api.pushover.net/1/messages.json"
  assert_not_contains "$(cat "$log")" "sound="
}

test_pushover_send_passes_optional_sound() {
  local sandbox stub_dir log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  log="$sandbox/curl.log"
  cred="$sandbox/cred"
  _write_pushover_curl_stub "$stub_dir"
  _write_pushover_cred "$cred"
  # shellcheck source=/dev/null
  source "$(_pushover_helper_path)"

  export PUSHOVER_CURL_LOG="$log"
  export PUSHOVER_CURL_EXIT=0
  PATH="$stub_dir:$PATH" pushover_send "$cred" "Sound title" "Sound message" 0 "falling" \
    || fail "pushover_send must succeed with optional sound"

  assert_file_contains "$log" "form-string = \"sound=falling\""
}

test_pushover_send_curl_failure_returns_1() {
  local sandbox stub_dir log cred
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  log="$sandbox/curl.log"
  cred="$sandbox/cred"
  _write_pushover_curl_stub "$stub_dir"
  _write_pushover_cred "$cred"
  # shellcheck source=/dev/null
  source "$(_pushover_helper_path)"

  export PUSHOVER_CURL_LOG="$log"
  export PUSHOVER_CURL_EXIT=22
  if PATH="$stub_dir:$PATH" pushover_send "$cred" "Fail title" "Fail message" 0; then
    fail "pushover_send must fail when curl fails"
  fi
  assert_file_contains "$log" "form-string = \"title=Fail title\""
}

_service_notification_fixture() {
  local sandbox="$1"
  _write_pushover_curl_stub "$sandbox/bin"
  _write_pushover_cred "$sandbox/cred"
}

_run_service_notification() {
  local sandbox="$1" function_name="$2"
  shift 2
  env \
    PATH="$sandbox/bin:$PATH" \
    SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="${PUSHOVER_TEST_LIB:-$(_pushover_helper_path)}" \
    PUSHOVER_CRED_FILE="${PUSHOVER_TEST_CRED:-$sandbox/cred}" \
    CREDENTIALS_DIRECTORY="$sandbox/load-credentials" \
    PUSHOVER_CURL_LOG="$sandbox/curl.log" \
    PUSHOVER_CURL_ARGV_LOG="$sandbox/curl.argv" \
    PUSHOVER_CURL_STDIN_LOG="$sandbox/curl.stdin" \
    PUSHOVER_CURL_EXIT="${PUSHOVER_TEST_CURL_EXIT:-0}" \
    bash -eu -o pipefail -c 'source "$SERVICE_LIB"; "$@"' bash "$function_name" "$@" \
    > "$sandbox/stdout" 2> "$sandbox/stderr"
}

test_service_notification_uses_stdin_without_credentials_in_argv() {
  local sandbox
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"

  _run_service_notification "$sandbox" send_notification_strict "Test title" "Test message"
  grep -Fqx -- '-q' "$sandbox/curl.argv" || fail "curl must ignore user curlrc"
  grep -Fqx -- '--config' "$sandbox/curl.argv" || fail "curl must read the stdin config"
  grep -Fqx -- '-' "$sandbox/curl.argv" || fail "curl config source must be stdin"
  assert_not_contains "$(cat "$sandbox/curl.argv")" 'token value'
  assert_not_contains "$(cat "$sandbox/curl.argv")" 'user value'
  assert_not_contains "$(cat "$sandbox/curl.argv")" 'Test title'
  assert_not_contains "$(cat "$sandbox/curl.argv")" 'Test message'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "token=token value"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "user=user value"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "title=Test title"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "message=Test message"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "priority=-1"'
  [ ! -s "$sandbox/stdout" ] || fail "notification response must remain suppressed"
  [ ! -s "$sandbox/stderr" ] || fail "successful notification must remain silent"

  _run_service_notification "$sandbox" send_notification "Title" "Body" 1
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "priority=1"'
}

test_service_notification_escapes_multiline_fields() {
  local sandbox title message
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"
  printf 'PUSHOVER_TOKEN=%q\nPUSHOVER_USER=%q\n' \
    $'tok\\en"one\nnext' $'user\r\tvalue' > "$sandbox/cred"
  title=$'title "quote" \\ path\nsecond\r\tend'
  message=$'body\n"quoted"\\\r\tend'

  _run_service_notification "$sandbox" send_notification_strict "$title" "$message" 0
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "token=tok\\en\"one\nnext"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "user=user\r\tvalue"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "title=title \"quote\" \\ path\nsecond\r\tend"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "message=body\n\"quoted\"\\\r\tend"'
  [ "$(wc -l < "$sandbox/curl.stdin")" -eq 5 ] || fail "multiline fields must each occupy one curl config line"
}

test_service_notification_preserves_curl_status_and_fail_soft_return() {
  local sandbox status=0
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"

  PUSHOVER_TEST_CURL_EXIT=22 _run_service_notification "$sandbox" send_notification_strict "Private title" "Private body" \
    || status=$?
  [ "$status" -eq 22 ] || fail "strict notification must preserve curl exit 22, got $status"
  assert_file_contains "$sandbox/stderr" 'WARNING: Pushover notification failed (exit 22)'
  assert_not_contains "$(cat "$sandbox/stderr")" 'token value'
  assert_not_contains "$(cat "$sandbox/stderr")" 'user value'
  assert_not_contains "$(cat "$sandbox/stderr")" 'Private title'
  assert_not_contains "$(cat "$sandbox/stderr")" 'Private body'
  assert_not_contains "$(cat "$sandbox/stderr")" 'fake curl stderr'
  [ ! -s "$sandbox/stdout" ] || fail "failed notification response must remain suppressed"

  PUSHOVER_TEST_CURL_EXIT=22 _run_service_notification "$sandbox" send_notification "Private title" "Private body" \
    || fail "fail-soft notification must return 0 on curl failure"
}

test_service_notification_missing_or_invalid_credentials_skip_curl() {
  local sandbox scenario status
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"
  for scenario in missing empty-token empty-user source-failure; do
    rm -f "$sandbox/invalid-cred" "$sandbox/curl.log"
    case "$scenario" in
      empty-token) printf 'PUSHOVER_USER=synthetic-user\n' > "$sandbox/invalid-cred" ;;
      empty-user) printf 'PUSHOVER_TOKEN=synthetic-token\n' > "$sandbox/invalid-cred" ;;
      source-failure) printf 'false\n' > "$sandbox/invalid-cred" ;;
    esac
    status=0
    PUSHOVER_TOKEN=outer-token PUSHOVER_USER=outer-user \
      PUSHOVER_TEST_CRED="$sandbox/invalid-cred" \
      _run_service_notification "$sandbox" send_notification_strict "Private title" "Private body" || status=$?
    [ "$status" -ne 0 ] || fail "strict notification must fail for $scenario credentials"
    [ ! -e "$sandbox/curl.log" ] || fail "curl must not run for $scenario credentials"
    assert_contains "$(cat "$sandbox/stderr")" 'WARNING: Pushover'
    assert_not_contains "$(cat "$sandbox/stderr")" 'synthetic-'
    assert_not_contains "$(cat "$sandbox/stderr")" 'outer-'
    assert_not_contains "$(cat "$sandbox/stderr")" 'Private body'
    PUSHOVER_TEST_CRED="$sandbox/invalid-cred" \
      _run_service_notification "$sandbox" send_notification "Title" "Body" \
      || fail "fail-soft notification must return 0 for $scenario credentials"
  done
}

test_service_notification_helper_failure_is_lazy_and_fail_soft() {
  local sandbox helper status
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"
  mkdir -p "$sandbox/state"
  env PUSHOVER_LIB="$sandbox/missing-helper" \
    SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" STATE_DIR="$sandbox/state" \
    bash -eu -o pipefail -c 'source "$SERVICE_LIB"; check_initial_run "$STATE_DIR" "1.2.3"' \
    > "$sandbox/stdout" 2> "$sandbox/stderr"
  assert_file_contains "$sandbox/state/last-notified-version" '1.2.3'
  [ ! -s "$sandbox/stderr" ] || fail "source-only service use must not load the notification helper"

  printf 'false\n' > "$sandbox/broken-helper"
  printf ':\n' > "$sandbox/empty-helper"
  for helper in missing-helper broken-helper empty-helper; do
    status=0
    PUSHOVER_TEST_LIB="$sandbox/$helper" \
      _run_service_notification "$sandbox" send_notification_strict "Private title" "Private body" || status=$?
    [ "$status" -ne 0 ] || fail "strict notification must fail with $helper"
    [ ! -e "$sandbox/curl.log" ] || fail "helper failure must not invoke curl"
    assert_contains "$(cat "$sandbox/stderr")" 'WARNING: Pushover helper'
    assert_not_contains "$(cat "$sandbox/stderr")" 'Private body'
    PUSHOVER_TEST_LIB="$sandbox/$helper" _run_service_notification "$sandbox" send_notification "Title" "Body" \
      || fail "fail-soft notification must return 0 with $helper"
  done
}

test_service_notification_loadcredential_fallback_is_command_scoped() {
  local sandbox
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"
  mkdir -p "$sandbox/load-credentials"
  printf 'PUSHOVER_TOKEN=fallback-token\nPUSHOVER_USER=fallback-user\n' \
    > "$sandbox/load-credentials/pushover-system-monitor"
  env \
    PATH="$sandbox/bin:$PATH" SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CURL_LOG="$sandbox/curl.log" \
    PUSHOVER_CURL_STDIN_LOG="$sandbox/curl.stdin" CREDENTIALS_DIRECTORY="$sandbox/load-credentials" \
    PUSHOVER_CRED_FILE='' PUSHOVER_CURL_EXIT=0 \
    bash -eu -o pipefail -c '
      source "$SERVICE_LIB"
      send_notification_strict "Title" "Body"
      [ "$PUSHOVER_CRED_FILE" = "" ]
    ' > "$sandbox/stdout" 2> "$sandbox/stderr"
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "token=fallback-token"'
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "user=fallback-user"'
  # 명시 경로는 유효한 LoadCredential 경로보다 우선한다. 명시 파일 부재를 fallback으로 숨기지 않는다.
  _run_service_notification "$sandbox" send_notification_strict "Title" "Body"
  assert_file_contains "$sandbox/curl.stdin" 'form-string = "token=token value"'
  if PUSHOVER_TEST_CRED="$sandbox/missing-override" \
    _run_service_notification "$sandbox" send_notification_strict "Title" "Body"; then
    fail "an explicit missing credential path must not silently fall back"
  fi
}

test_service_notification_temp_monitor_records_cooldown_only_after_success() {
  local sandbox status
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"
  mkdir -p "$sandbox/state"
  cat > "$sandbox/bin/sensors" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '{"coretemp-fixture":{"Package id 0":{"temp1_input":85}}}'
STUB
  chmod +x "$sandbox/bin/sensors"
  for status in 22 0; do
    env \
      PATH="$sandbox/bin:$PATH" SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
      PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CRED_FILE="$sandbox/cred" \
      PUSHOVER_CURL_LOG="$sandbox/curl.log" PUSHOVER_CURL_EXIT="$status" STATE_DIR="$sandbox/state" \
      CPU_WARN=80 CPU_CRIT=90 NVME_WARN=70 NVME_CRIT=80 COOLDOWN_WARNING=3600 COOLDOWN_CRITICAL=600 \
      bash -eu -o pipefail "$REPO_ROOT/modules/nixos/programs/temp-monitor/files/check-temp.sh" \
      > "$sandbox/stdout" 2> "$sandbox/stderr"
    if [ "$status" -eq 22 ]; then
      [ ! -e "$sandbox/state/last-alert-CPU-warning" ] || fail "failed temperature alert must not record cooldown"
      assert_contains "$(cat "$sandbox/stderr")" 'Pushover 알림 전송 실패'
    else
      [ -s "$sandbox/state/last-alert-CPU-warning" ] || fail "successful temperature alert must record cooldown"
    fi
  done
  # 성공 후 재실행은 cooldown 동안 curl을 다시 호출하지 않는다.
  : > "$sandbox/curl.log"
  env \
    PATH="$sandbox/bin:$PATH" SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CRED_FILE="$sandbox/cred" \
    PUSHOVER_CURL_LOG="$sandbox/curl.log" STATE_DIR="$sandbox/state" \
    CPU_WARN=80 CPU_CRIT=90 NVME_WARN=70 NVME_CRIT=80 COOLDOWN_WARNING=3600 COOLDOWN_CRITICAL=600 \
    bash -eu -o pipefail "$REPO_ROOT/modules/nixos/programs/temp-monitor/files/check-temp.sh" \
    > "$sandbox/stdout" 2> "$sandbox/stderr"
  [ ! -s "$sandbox/curl.log" ] || fail "temperature cooldown must suppress another notification"
}

test_service_notification_purge_reminder_fails_when_transport_fails() {
  local sandbox status=0
  sandbox=$(new_sandbox)
  _service_notification_fixture "$sandbox"
  # Nix 모듈이 패키징하는 실제 본문을 추출한다. fixture에 소비자 로직을 복제하지 않는다.
  python3 - "$REPO_ROOT/modules/nixos/programs/pushover-purge-reminder.nix" "$sandbox/purge.sh" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
match = re.search(r"    text = ''\n(.*?)\n    '';", source, re.S)
assert match is not None, "purge reminder script body must exist"
Path(sys.argv[2]).write_text(match.group(1).replace("''${", "${"))
PY
  env \
    PATH="$sandbox/bin:$PATH" SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CRED_FILE="$sandbox/cred" \
    PUSHOVER_CURL_LOG="$sandbox/curl.log" PUSHOVER_CURL_EXIT=22 ARCHIVE_PATH="$sandbox/archive" \
    bash -eu -o pipefail "$sandbox/purge.sh" > "$sandbox/stdout" 2> "$sandbox/stderr" || status=$?
  [ "$status" -eq 1 ] || fail "purge reminder must return 1 when notification fails"
  assert_file_contains "$sandbox/stderr" 'WARNING: Pushover send failed'
  env \
    PATH="$sandbox/bin:$PATH" SERVICE_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" \
    PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CRED_FILE="$sandbox/cred" \
    PUSHOVER_CURL_LOG="$sandbox/curl.log" PUSHOVER_CURL_EXIT=0 ARCHIVE_PATH="$sandbox/archive" \
    bash -eu -o pipefail "$sandbox/purge.sh" > "$sandbox/stdout" 2> "$sandbox/stderr"
  assert_file_contains "$sandbox/stdout" 'Pushover purge reminder sent'
}

test_service_notification_fallback_retries_after_transport_failure() {
  local sandbox
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  cp "$REPO_ROOT/modules/nixos/lib/service-lib.sh" "$sandbox/service-lib"
  printf 'PUSHOVER_TOKEN=synthetic-token\nPUSHOVER_USER=synthetic-user\n' >> "$sandbox/pushover"
  printf '<html><body>No original URL</body></html>\n' > "$sandbox/fallback/fixture.html"
  printf 'https://example.com/unmatched\n' > "$sandbox/state/failed-urls.txt"
  _write_pushover_curl_stub "$sandbox/stub-bin"

  PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CURL_LOG="$sandbox/transport.log" PUSHOVER_CURL_EXIT=22 \
    _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr"
  [ ! -s "$sandbox/state/fallback-unmatched-notified.tsv" ] \
    || fail "failed fallback alert must not mark the file as notified"
  assert_contains "$(cat "$sandbox/stdout")" 'notification failed; will retry later'
  assert_file_contains "$sandbox/state/failed-urls.txt" 'https://example.com/unmatched'
  [ ! -s "$sandbox/state/fallback-processed.tsv" ] || fail "held fallback file must not be marked processed"

  PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CURL_LOG="$sandbox/transport.log" PUSHOVER_CURL_EXIT=0 \
    _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr"
  [ -s "$sandbox/state/fallback-unmatched-notified.tsv" ] \
    || fail "successful retry must mark the fallback alert as notified"
  : > "$sandbox/transport.log"
  PUSHOVER_LIB="$(_pushover_helper_path)" PUSHOVER_CURL_LOG="$sandbox/transport.log" PUSHOVER_CURL_EXIT=0 \
    _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr"
  [ ! -s "$sandbox/transport.log" ] || fail "successful fallback alert must be deduplicated on the next run"
}
