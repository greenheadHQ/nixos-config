# tests/suites/pushover-helper.sh — shared Pushover helper unit tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# shellcheck disable=SC2154

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
# helper는 자격·필드를 argv가 아니라 --config - stdin으로 전달한다 — 함께 기록해야
# 기존 필드 assertion이 성립한다.
[ -t 0 ] || cat >> "$PUSHOVER_CURL_LOG"
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
