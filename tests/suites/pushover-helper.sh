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
  # helper는 민감값을 argv가 아닌 0600 config(-K)로 전달하므로, stub은 argv와
  # config 내용을 각각 기록해 두 불변식(argv 미노출 / 필드 전달)을 함께 검증한다.
  cat > "$dir/curl" <<'EOF_STUB'
#!/usr/bin/env bash
set -euo pipefail
: "${PUSHOVER_CURL_LOG:?}"
printf '%s\n' "$@" >> "$PUSHOVER_CURL_LOG"
if [ -n "${PUSHOVER_CURL_ARGV_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$PUSHOVER_CURL_ARGV_LOG"
fi
config_file=""
prev=""
for arg in "$@"; do
  [ "$prev" = "-K" ] && config_file="$arg"
  prev="$arg"
done
if [ -n "$config_file" ] && [ -r "$config_file" ]; then
  cat "$config_file" >> "$PUSHOVER_CURL_LOG"
fi
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
  local sandbox stub_dir log argv_log cred argv_line
  sandbox=$(new_sandbox)
  stub_dir="$sandbox/bin"
  log="$sandbox/curl.log"
  argv_log="$sandbox/curl.argv"
  cred="$sandbox/cred"
  _write_pushover_curl_stub "$stub_dir"
  _write_pushover_cred "$cred"
  # shellcheck source=/dev/null
  source "$(_pushover_helper_path)"

  export PUSHOVER_CURL_LOG="$log"
  export PUSHOVER_CURL_ARGV_LOG="$argv_log"
  export PUSHOVER_CURL_EXIT=0
  PATH="$stub_dir:$PATH" pushover_send "$cred" "Test title" "Test message" 1 \
    || fail "pushover_send must succeed when curl succeeds"

  assert_file_contains "$log" 'form-string = "token=token value"'
  assert_file_contains "$log" 'form-string = "user=user value"'
  assert_file_contains "$log" 'form-string = "title=Test title"'
  assert_file_contains "$log" 'form-string = "message=Test message"'
  assert_file_contains "$log" 'form-string = "priority=1"'
  assert_file_contains "$log" 'url = "https://api.pushover.net/1/messages.json"'
  assert_not_contains "$(cat "$log")" "sound="

  # 민감값은 config 파일에만 있어야 하고 argv(ps 노출면)에는 없어야 한다.
  argv_line="$(cat "$argv_log")"
  assert_not_contains "$argv_line" "token value"
  assert_not_contains "$argv_line" "user value"
  case "$argv_line" in
    "-q -g "*) ;;
    *) fail "expected curl argv to start with '-q -g' (curlrc/glob off), got: $argv_line" ;;
  esac
  unset PUSHOVER_CURL_ARGV_LOG
}

test_pushover_send_escapes_curl_config_metacharacters() {
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
  PATH="$stub_dir:$PATH" pushover_send "$cred" 'Quo"te' 'a\b
url = "https://evil.example"' 0 \
    || fail "pushover_send must succeed with metacharacters in fields"

  # 값이 quote를 탈출해 추가 url 지시자로 해석되면 config에 raw 개행 + url 줄이 생긴다.
  assert_file_contains "$log" 'form-string = "title=Quo\"te"'
  assert_file_contains "$log" 'form-string = "message=a\\b\nurl = \"https://evil.example\""'
  [ "$(grep -c '^url = ' "$log")" = "1" ] \
    || fail "escaped message must not inject an extra url directive"
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

  assert_file_contains "$log" 'form-string = "sound=falling"'
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
  assert_file_contains "$log" 'form-string = "title=Fail title"'
}
