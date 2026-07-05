# tests/suites/webhook-bridge.sh — Karakeep webhook bridge fixture tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

_webhook_bridge_script="$REPO_ROOT/modules/nixos/programs/docker/karakeep-notify/files/webhook-bridge.sh"

_webhook_bridge_prepare_sandbox() {
  local sandbox="$1"
  printf '# stub pushover credentials\n' > "$sandbox/pushover"
  cat > "$sandbox/service-lib" <<'STUB'
send_notification() {
  printf '%s\n' "$*" > "$WEBHOOK_TEST_MARKER"
}
STUB
}

_webhook_bridge_run() {
  local sandbox="$1"
  local headers="$2"
  local body="$3"
  local token_file="$4"
  local stdout_path="$5"
  local stderr_path="$6"
  local content_length

  content_length=${#body}

  local -a env_vars=(
    PUSHOVER_CRED_FILE="$sandbox/pushover"
    SERVICE_LIB="$sandbox/service-lib"
    WEBHOOK_TEST_MARKER="$sandbox/notification-marker"
  )
  if [ -n "$token_file" ]; then
    env_vars+=(WEBHOOK_TOKEN_FILE="$token_file")
  fi

  {
    printf 'POST / HTTP/1.1\r\n'
    printf '%s' "$headers"
    printf 'Content-Length: %s\r\n\r\n' "$content_length"
    printf '%s' "$body"
  } | env "${env_vars[@]}" bash "$_webhook_bridge_script" > "$stdout_path" 2> "$stderr_path"
}

test_webhook_bridge_crawled_payload_sends_notification() {
  local sandbox stdout_path stderr_path marker output
  sandbox=$(new_sandbox)
  _webhook_bridge_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  marker="$sandbox/notification-marker"

  _webhook_bridge_run "$sandbox" "" '{"operation":"crawled","url":"https://example.com/path?x=1"}' "" "$stdout_path" "$stderr_path"

  output=$(cat "$stdout_path")
  assert_contains "$output" "HTTP/1.1 200 OK"
  [ -f "$marker" ] || fail "expected webhook bridge to call send_notification"
}

test_webhook_bridge_non_crawled_payload_skips_notification() {
  local sandbox stdout_path stderr_path marker output
  sandbox=$(new_sandbox)
  _webhook_bridge_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  marker="$sandbox/notification-marker"

  _webhook_bridge_run "$sandbox" "" '{"operation":"created","url":"https://example.com/path"}' "" "$stdout_path" "$stderr_path"

  output=$(cat "$stdout_path")
  assert_contains "$output" "HTTP/1.1 200 OK"
  [ ! -e "$marker" ] || fail "expected webhook bridge to skip non-crawled notification"
}

test_webhook_bridge_invalid_json_keeps_200_without_notification() {
  local sandbox stdout_path stderr_path marker output
  sandbox=$(new_sandbox)
  _webhook_bridge_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  marker="$sandbox/notification-marker"

  _webhook_bridge_run "$sandbox" "" 'not-json' "" "$stdout_path" "$stderr_path"

  output=$(cat "$stdout_path")
  assert_contains "$output" "HTTP/1.1 200 OK"
  [ ! -e "$marker" ] || fail "expected webhook bridge to skip invalid JSON notification"
}

test_webhook_bridge_matching_token_sends_notification() {
  local sandbox stdout_path stderr_path marker output token_file
  sandbox=$(new_sandbox)
  _webhook_bridge_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  marker="$sandbox/notification-marker"
  token_file="$sandbox/webhook-token"
  # 트레일링 뉴라인 포함 — 브리지의 토큰 정규화(tr -d '\r\n') 경로까지 검증한다.
  printf 'expected-token\n' > "$token_file"

  _webhook_bridge_run "$sandbox" $'Authorization: Bearer expected-token\r\n' '{"operation":"crawled","url":"https://example.com/path"}' "$token_file" "$stdout_path" "$stderr_path"

  output=$(cat "$stdout_path")
  assert_contains "$output" "HTTP/1.1 200 OK"
  [ -f "$marker" ] || fail "expected webhook bridge to send notification for matching token"
}

test_webhook_bridge_wrong_token_keeps_200_and_warns() {
  local sandbox stdout_path stderr_path marker output stderr_output token_file
  sandbox=$(new_sandbox)
  _webhook_bridge_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  marker="$sandbox/notification-marker"
  token_file="$sandbox/webhook-token"
  printf 'expected-token\n' > "$token_file"

  _webhook_bridge_run "$sandbox" $'Authorization: Bearer wrong-token\r\n' '{"operation":"crawled","url":"https://example.com/path"}' "$token_file" "$stdout_path" "$stderr_path"

  output=$(cat "$stdout_path")
  stderr_output=$(cat "$stderr_path")
  assert_contains "$output" "HTTP/1.1 200 OK"
  assert_contains "$stderr_output" "WARN"
  [ ! -e "$marker" ] || fail "expected webhook bridge to skip wrong-token notification"
}
