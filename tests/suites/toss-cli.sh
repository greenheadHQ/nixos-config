# tests/suites/toss-cli.sh — Toss CLI fixture tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# shellcheck disable=SC2154

_toss_cli_script() {
  local sandbox="$1"
  printf '%s\n' "$sandbox/home/.local/bin/toss"
}

_prepare_toss_cli_sandbox() {
  local sandbox="$1"
  install_deployed_layout "$sandbox" "$REPO_ROOT"
}

_write_toss_api_curl_stub() {
  local dir="$1"

  mkdir -p "$dir"
  cat > "$dir/curl" <<'EOF_STUB'
#!/usr/bin/env bash
set -euo pipefail

config_file=""
original_argv="$*"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -K)
      config_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

[ -n "$config_file" ] || { echo "missing -K" >&2; exit 97; }
if [ -n "${TOSS_TEST_CURL_ARGV_LOG:-}" ]; then
  printf '%s\n' "$original_argv" >> "$TOSS_TEST_CURL_ARGV_LOG"
fi
cp "$config_file" "${TOSS_TEST_CURL_CONFIG:?}"
if [ -n "${TOSS_TEST_CURL_CONFIG_LOG:-}" ]; then
  {
    printf '%s\n' "--- curl config ---"
    cat "$config_file"
  } >> "$TOSS_TEST_CURL_CONFIG_LOG"
fi
url="$(awk -F ' = ' '$1 == "url" { print $2 }' "$config_file" | jq -r .)"
if [[ "$url" == */oauth2/token ]]; then
  if [ -n "${TOSS_TEST_TOKEN_BODY_LOG:-}" ]; then
    data_binary="$(awk -F ' = ' '$1 == "data-binary" { print $2 }' "$config_file" | jq -r .)"
    case "$data_binary" in
      @*) cat "${data_binary#@}" >> "$TOSS_TEST_TOKEN_BODY_LOG" ;;
    esac
  fi
  printf '{"access_token":"fresh-token","expires_in":7200}'
  exit 0
fi
output_path="$(awk -F ' = ' '$1 == "output" { print $2 }' "$config_file" | jq -r .)"

dump_header="$(awk -F ' = ' '$1 == "dump-header" { print $2 }' "$config_file" | jq -r .)"
if [ -n "$dump_header" ] && [ "${TOSS_TEST_RATE_LIMIT_HEADERS:-0}" = "1" ]; then
  printf 'HTTP/1.1 200 OK\r\nX-RateLimit-Limit: 10\r\nX-RateLimit-Remaining: 9\r\nRetry-After: 1\r\nX-Secret-Header: nope\r\n\r\n' > "$dump_header"
fi

if [ -n "${TOSS_TEST_API_COUNT_FILE:-}" ]; then
  api_count="$(cat "$TOSS_TEST_API_COUNT_FILE" 2>/dev/null || printf '0')"
  api_count=$((api_count + 1))
  printf '%s' "$api_count" > "$TOSS_TEST_API_COUNT_FILE"
else
  api_count=1
fi

case "${TOSS_TEST_RESPONSE_KIND:-json}" in
  json)
    printf '{"ok":true,"access_token":"SECRET","nested":{"message":"client_secret=HIDDEN password=PASS"}}' > "$output_path"
    ;;
  scalar-json)
    printf '"access_token=SECRET client_secret=HIDDEN Authorization: Bearer BEARER"' > "$output_path"
    ;;
  html)
    printf '<html>client_secret=HIDDEN access_token=SECRET</html>' > "$output_path"
    ;;
  multi-json)
    printf '1\n2' > "$output_path"
    ;;
  retry-401)
    if [ "$api_count" = "1" ]; then
      printf '{"error":"invalid_token"}' > "$output_path"
      printf '401'
      exit 0
    fi
    printf '{"ok":true}' > "$output_path"
    ;;
  retry-nested-invalid-token)
    if [ "$api_count" = "1" ]; then
      printf '{"error":"invalid_token","nested":{"code":"still_valid"}}' > "$output_path"
      printf '200'
      exit 0
    fi
    printf '{"ok":true}' > "$output_path"
    ;;
  *)
    echo "unknown TOSS_TEST_RESPONSE_KIND" >&2
    exit 98
    ;;
esac

printf '200'
EOF_STUB
  chmod +x "$dir/curl"
}

_run_toss_order_api_fixture() {
  local sandbox="$1"
  local response_kind="$2"
  local stdout_path="$3"

  HOME="$sandbox/home" \
  PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND="$response_kind" \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$stdout_path"
}

test_toss_api_records_json_response_ledger() {
  local sandbox response_body metadata_status
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  _run_toss_order_api_fixture "$sandbox" json "$sandbox/stdout"

  response_body="$(jq -c '.response.body' "$sandbox/orders.jsonl")"
  [ "$response_body" = '{"ok":true,"access_token":"<redacted>","nested":{"message":"client_secret=<redacted> password=<redacted>"}}' ] \
    || fail "expected JSON response body to be recorded with redaction, got: $response_body"
  metadata_status="$(jq -r '.request.metadataStatus' "$sandbox/orders.jsonl")"
  [ "$metadata_status" = "exact" ] || fail "expected deployed endpoint metadata lookup, got: $metadata_status"
}

test_toss_api_records_scalar_json_response_ledger() {
  local sandbox response_body
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  _run_toss_order_api_fixture "$sandbox" scalar-json "$sandbox/stdout"

  response_body="$(jq -r '.response.body' "$sandbox/orders.jsonl")"
  [ "$response_body" = "access_token=<redacted> client_secret=<redacted> Authorization: Bearer <redacted>" ] \
    || fail "expected scalar JSON string response to be recorded with redaction, got: $response_body"
  assert_not_contains "$response_body" "SECRET"
  assert_not_contains "$response_body" "HIDDEN"
  assert_not_contains "$response_body" "BEARER"
}

test_toss_api_records_non_json_response_ledger() {
  local sandbox response_body
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  _run_toss_order_api_fixture "$sandbox" html "$sandbox/stdout"

  response_body="$(jq -c '.response.body' "$sandbox/orders.jsonl")"
  assert_contains "$response_body" '"parseableJson":false'
  assert_contains "$response_body" '"raw":"<html>client_secret=<redacted> access_token=<redacted></html>"'
  assert_not_contains "$response_body" "SECRET"
  assert_not_contains "$response_body" "HIDDEN"
}

test_toss_api_rejects_auth_endpoint() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  set +e
  HOME="$sandbox/home" \
  TOSS_ACCESS_TOKEN="mock-token" \
    "$(_toss_cli_script "$sandbox")" api POST /oauth2/token --data '{"grant_type":"client_credentials"}' > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected toss api auth endpoint rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "toss api does not call Toss auth endpoints"
  assert_contains "$stderr" "toss token"
}

test_toss_api_dry_run_without_token_uses_deployed_layout() {
  local sandbox output
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  HOME="$sandbox/home" \
    TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api GET /api/v1/orders --account ACC123 --dry-run > "$sandbox/stdout"

  output="$(cat "$sandbox/stdout")"
  jq -e '
    .dryRun == true
    and .metadata.status == "exact"
    and (.headers | index("Authorization: <redacted>") != null)
  ' <<<"$output" >/dev/null || fail "expected dry-run output from deployed toss layout"
}

test_toss_api_retries_once_after_401() {
  local sandbox runtime_dir future token_file api_calls first_auth final_old_auth final_fresh_auth
  sandbox=$(new_sandbox)
  runtime_dir="$sandbox/runtime"
  token_file="$runtime_dir/toss/token.json"
  future=$(( $(date +%s) + 7200 ))
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  cat > "$sandbox/bin/op" <<'EOF_OP'
#!/usr/bin/env bash
set -euo pipefail
ref=""
for arg in "$@"; do
  ref="$arg"
done
case "$ref" in
  *client-id) printf 'mock-client-id' ;;
  *client-secret) printf 'mock-client-secret' ;;
  *) printf 'mock-op-value' ;;
esac
EOF_OP
  chmod +x "$sandbox/bin/op"
  mkdir -p "$(dirname "$token_file")"
  printf 'mock-sa-token' > "$sandbox/sa-token"
  jq -cn \
    --argjson expires_at "$future" \
    '{access_token:"old-token", token_type:"Bearer", issued_at:0, expires_at:$expires_at, expires_in:7200}' \
    > "$token_file"
  printf 'mock-client-id' > "$sandbox/client-id"
  printf 'mock-client-secret' > "$sandbox/client-secret"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_RUNTIME_DIR="$runtime_dir" \
    TOSS_CLIENT_ID_FILE="$sandbox/client-id" \
    TOSS_CLIENT_SECRET_FILE="$sandbox/client-secret" \
    TOSS_OP_SA_TOKEN_FILE="$sandbox/sa-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND="retry-401" \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_TEST_CURL_CONFIG_LOG="$sandbox/curl.config.log" \
    TOSS_TEST_API_COUNT_FILE="$sandbox/api.count" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "2" ] || fail "expected exactly one retry after 401, got api calls: $api_calls"
  first_auth="$(grep -Fxc 'header = "Authorization: Bearer old-token"' "$sandbox/curl.config.log" || true)"
  final_old_auth="$(grep -Fxc 'header = "Authorization: Bearer old-token"' "$sandbox/curl.config" || true)"
  final_fresh_auth="$(grep -Fxc 'header = "Authorization: Bearer fresh-token"' "$sandbox/curl.config" || true)"
  [ "$first_auth" = "1" ] || fail "expected initial request to use cached old token"
  [ "$final_old_auth" = "0" ] || fail "final curl config should come from retried request"
  [ "$final_fresh_auth" = "1" ] || fail "expected retried request to use refreshed token"
}

test_toss_api_env_override_401_force_refresh_uses_credentials() {
  local sandbox runtime_dir api_calls expired_auth fresh_auth token_requests token_body argv_log
  sandbox=$(new_sandbox)
  runtime_dir="$sandbox/runtime"
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  cat > "$sandbox/bin/op" <<'EOF_OP'
#!/usr/bin/env bash
set -euo pipefail
ref=""
for arg in "$@"; do
  ref="$arg"
done
case "$ref" in
  *client-id) printf 'mock-client-id' ;;
  *client-secret) printf 'mock-client-secret' ;;
  *) printf 'mock-op-value' ;;
esac
EOF_OP
  chmod +x "$sandbox/bin/op"
  printf 'mock-sa-token' > "$sandbox/sa-token"
  printf 'mock-client-id' > "$sandbox/client-id"
  printf 'mock-client-secret' > "$sandbox/client-secret"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_API_BASE_URL="https://openapi.tossinvest.com" \
    TOSS_ACCESS_TOKEN="expired-env-token" \
    TOSS_RUNTIME_DIR="$runtime_dir" \
    TOSS_CLIENT_ID_FILE="$sandbox/client-id" \
    TOSS_CLIENT_SECRET_FILE="$sandbox/client-secret" \
    TOSS_OP_SA_TOKEN_FILE="$sandbox/sa-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND="retry-401" \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_TEST_CURL_CONFIG_LOG="$sandbox/curl.config.log" \
    TOSS_TEST_TOKEN_BODY_LOG="$sandbox/token.body" \
    TOSS_TEST_CURL_ARGV_LOG="$sandbox/curl.argv" \
    TOSS_TEST_API_COUNT_FILE="$sandbox/api.count" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "2" ] || fail "expected exactly one retry after 401, got api calls: $api_calls"
  expired_auth="$(grep -Fxc 'header = "Authorization: Bearer expired-env-token"' "$sandbox/curl.config.log" || true)"
  fresh_auth="$(grep -Fxc 'header = "Authorization: Bearer fresh-token"' "$sandbox/curl.config.log" || true)"
  token_requests="$(grep -Fxc 'url = "https://openapi.tossinvest.com/oauth2/token"' "$sandbox/curl.config.log" || true)"
  [ "$expired_auth" = "1" ] || fail "expected initial request to use TOSS_ACCESS_TOKEN override"
  [ "$fresh_auth" = "1" ] || fail "expected retried request to use refreshed credential token"
  [ "$token_requests" = "1" ] || fail "expected force refresh to call token endpoint once"
  token_body="$(cat "$sandbox/token.body")"
  assert_contains "$token_body" "client_id=mock-client-id"
  assert_contains "$token_body" "client_secret=mock-client-secret"
  argv_log="$(cat "$sandbox/curl.argv")"
  assert_not_contains "$argv_log" "expired-env-token"
  assert_not_contains "$argv_log" "fresh-token"
  assert_not_contains "$argv_log" "mock-client-secret"
}

test_toss_api_retries_on_nested_invalid_token_body() {
  local sandbox runtime_dir future token_file api_calls first_auth final_fresh_auth
  sandbox=$(new_sandbox)
  runtime_dir="$sandbox/runtime"
  token_file="$runtime_dir/toss/token.json"
  future=$(( $(date +%s) + 7200 ))
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  cat > "$sandbox/bin/op" <<'EOF_OP'
#!/usr/bin/env bash
set -euo pipefail
ref=""
for arg in "$@"; do
  ref="$arg"
done
case "$ref" in
  *client-id) printf 'mock-client-id' ;;
  *client-secret) printf 'mock-client-secret' ;;
  *) printf 'mock-op-value' ;;
esac
EOF_OP
  chmod +x "$sandbox/bin/op"
  mkdir -p "$(dirname "$token_file")"
  printf 'mock-sa-token' > "$sandbox/sa-token"
  jq -cn \
    --argjson expires_at "$future" \
    '{access_token:"old-token", token_type:"Bearer", issued_at:0, expires_at:$expires_at, expires_in:7200}' \
    > "$token_file"
  printf 'mock-client-id' > "$sandbox/client-id"
  printf 'mock-client-secret' > "$sandbox/client-secret"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_RUNTIME_DIR="$runtime_dir" \
    TOSS_OP_SA_TOKEN_FILE="$sandbox/sa-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND="retry-nested-invalid-token" \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_TEST_CURL_CONFIG_LOG="$sandbox/curl.config.log" \
    TOSS_TEST_API_COUNT_FILE="$sandbox/api.count" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "2" ] || fail "expected nested invalid_token body to trigger one retry, got api calls: $api_calls"
  first_auth="$(grep -Fxc 'header = "Authorization: Bearer old-token"' "$sandbox/curl.config.log" || true)"
  final_fresh_auth="$(grep -Fxc 'header = "Authorization: Bearer fresh-token"' "$sandbox/curl.config" || true)"
  [ "$first_auth" = "1" ] || fail "expected initial request to use cached old token"
  [ "$final_fresh_auth" = "1" ] || fail "expected retried request to use refreshed token"
}

test_toss_endpoint_metadata_fail_closed_order_path_mutations() {
  local sandbox input output
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  cat > "$input" <<'JSON'
{
  "info": {"version": "test"},
  "paths": {
    "/api/v1/orders": {
      "get": {
        "operationId": "listOrders",
        "description": "**Rate Limits Group**: `ORDER_HISTORY`"
      },
      "post": {
        "operationId": "createOrderWithDriftedGroup",
        "description": "**Rate Limits Group**: `OTHER`"
      }
    },
    "/api/v1/conditional-orders/{conditionalOrderId}": {
      "patch": {
        "operationId": "patchConditionalOrderWithDriftedGroup",
        "description": "**Rate Limits Group**: `OTHER`"
      }
    },
    "/api/v1/orderbook": {
      "delete": {
        "operationId": "deleteOrderbookShouldNotMatchOrderPath",
        "description": "**Rate Limits Group**: `OTHER`"
      }
    },
    "/api/v1/positions": {
      "post": {
        "operationId": "postPositionShouldNotMatchOrderPath",
        "description": "**Rate Limits Group**: `OTHER`"
      }
    }
  }
}
JSON

  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output"
  jq -e '
    def endpoint($method; $path):
      first(.endpoints[] | select(.method == $method and .path == $path));
    (endpoint("POST"; "/api/v1/orders").isKnownOrderMutation == true)
    and (endpoint("PATCH"; "/api/v1/conditional-orders/{conditionalOrderId}").isKnownOrderMutation == true)
    and (endpoint("GET"; "/api/v1/orders").isKnownOrderMutation == false)
    and (endpoint("DELETE"; "/api/v1/orderbook").isKnownOrderMutation == false)
    and (endpoint("POST"; "/api/v1/positions").isKnownOrderMutation == false)
  ' "$output" >/dev/null || fail "expected fail-closed order-path mutation classification"
}

test_toss_api_rejects_non_origin_relative_path() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  set +e
  HOME="$sandbox/home" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api POST 'api/v1/orders' --data '{}' > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected non-origin-relative path rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "origin-relative"
}

test_toss_api_curl_blocks_curlrc_and_globbing() {
  local sandbox argv_line
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_TEST_CURL_ARGV_LOG="$sandbox/curl.argv" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  argv_line="$(head -1 "$sandbox/curl.argv")"
  case "$argv_line" in
    "-q -g "*) ;;
    *) fail "expected curl argv to start with '-q -g' (curlrc/glob off), got: $argv_line" ;;
  esac
}

test_toss_api_401_reuses_token_refreshed_by_other_process() {
  local sandbox runtime_dir future token_file api_calls token_requests reused_auth
  sandbox=$(new_sandbox)
  runtime_dir="$sandbox/runtime"
  token_file="$runtime_dir/toss/token.json"
  future=$(( $(date +%s) + 7200 ))
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  mkdir -p "$(dirname "$token_file")"
  jq -cn \
    --argjson expires_at "$future" \
    '{access_token:"other-token", token_type:"Bearer", issued_at:0, expires_at:$expires_at, expires_in:7200}' \
    > "$token_file"

  # 초기 호출은 env override token으로 401을 받는다. cache에는 이미 다른 프로세스가
  # 갱신한 유효 token이 있으므로 CAS는 재발급 없이 그 token을 재사용해야 한다.
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_API_BASE_URL="https://openapi.tossinvest.com" \
    TOSS_ACCESS_TOKEN="expired-env-token" \
    TOSS_RUNTIME_DIR="$runtime_dir" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND="retry-401" \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_TEST_CURL_CONFIG_LOG="$sandbox/curl.config.log" \
    TOSS_TEST_API_COUNT_FILE="$sandbox/api.count" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "2" ] || fail "expected exactly one retry after 401, got api calls: $api_calls"
  token_requests="$(grep -Fxc 'url = "https://openapi.tossinvest.com/oauth2/token"' "$sandbox/curl.config.log" || true)"
  [ "$token_requests" = "0" ] || fail "expected CAS to reuse concurrently refreshed token without reissue, got token requests: $token_requests"
  reused_auth="$(grep -Fxc 'header = "Authorization: Bearer other-token"' "$sandbox/curl.config.log" || true)"
  [ "$reused_auth" = "1" ] || fail "expected retry to reuse cached token refreshed by other process"
}

test_toss_ledger_records_multi_json_response_as_raw() {
  local sandbox response_body
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  _run_toss_order_api_fixture "$sandbox" multi-json "$sandbox/stdout"

  response_body="$(jq -c '.response.body' "$sandbox/orders.jsonl")"
  assert_contains "$response_body" '"parseableJson":false'
  [ "$(jq -r '.response.body.raw' "$sandbox/orders.jsonl")" = "$(printf '1\n2')" ] \
    || fail "expected multi-JSON response to be recorded as raw wrapper, got: $response_body"
}

test_toss_ledger_append_preserves_existing_records() {
  local sandbox line_count first_line
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  printf '{"sentinel":true}\n' > "$sandbox/orders.jsonl"

  _run_toss_order_api_fixture "$sandbox" json "$sandbox/stdout"

  line_count="$(wc -l < "$sandbox/orders.jsonl" | tr -d ' ')"
  [ "$line_count" = "2" ] || fail "expected append to preserve existing ledger records, got $line_count lines"
  first_line="$(head -1 "$sandbox/orders.jsonl")"
  [ "$first_line" = '{"sentinel":true}' ] || fail "expected first ledger record to survive, got: $first_line"
}

test_toss_ledger_sanitizes_query_string_in_path() {
  local sandbox recorded_path
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST '/api/v1/orders?access_token=QUERYSECRET' --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  recorded_path="$(jq -r '.request.path' "$sandbox/orders.jsonl")"
  [ "$recorded_path" = '/api/v1/orders?<redacted>' ] \
    || fail "expected ledger path query to be sanitized, got: $recorded_path"
  assert_not_contains "$(cat "$sandbox/orders.jsonl")" "QUERYSECRET"
}

test_toss_notify_failure_warns_and_records_status() {
  local sandbox stderr notify_status
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_PUSHOVER_HELPER="$sandbox/nonexistent-pushover.sh" \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout" 2> "$sandbox/stderr"

  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "notification not sent"
  notify_status="$(jq -r 'select(.phase == "notify") | .notificationStatus' "$sandbox/orders.jsonl")"
  [ "$notify_status" = "failed-helper-missing" ] \
    || fail "expected notify failure status in ledger, got: $notify_status"
}

test_toss_notify_sent_uses_sanitized_path_and_records_status() {
  local sandbox pushover_log notify_status
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  pushover_log="$sandbox/pushover.log"
  cat > "$sandbox/pushover-stub.sh" <<'EOF_PUSHOVER'
pushover_send() {
  printf '%s|%s\n' "$2" "$3" >> "${TOSS_TEST_PUSHOVER_LOG:?}"
  return 0
}
EOF_PUSHOVER
  printf 'PUSHOVER_TOKEN=t\nPUSHOVER_USER=u\n' > "$sandbox/pushover-cred"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_PUSHOVER_HELPER="$sandbox/pushover-stub.sh" \
    TOSS_PUSHOVER_CRED_FILE="$sandbox/pushover-cred" \
    TOSS_TEST_PUSHOVER_LOG="$pushover_log" \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST '/api/v1/orders?access_token=SECRETQ' --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout"

  assert_contains "$(cat "$pushover_log")" '/api/v1/orders?<redacted>'
  assert_not_contains "$(cat "$pushover_log")" "SECRETQ"
  notify_status="$(jq -r 'select(.phase == "notify") | .notificationStatus' "$sandbox/orders.jsonl")"
  [ "$notify_status" = "sent" ] || fail "expected notify sent status in ledger, got: $notify_status"
}

test_toss_api_emits_whitelisted_rate_limit_headers() {
  local sandbox stderr ledger_headers
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_RATE_LIMIT_HEADERS=1 \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout" 2> "$sandbox/stderr"

  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "toss-rate-limit: X-RateLimit-Limit: 10"
  assert_contains "$stderr" "toss-rate-limit: Retry-After: 1"
  assert_not_contains "$stderr" "X-Secret-Header"
  ledger_headers="$(jq -c '.response.rateLimitHeaders' "$sandbox/orders.jsonl")"
  assert_contains "$ledger_headers" "X-RateLimit-Remaining: 9"
  assert_not_contains "$ledger_headers" "X-Secret-Header"
}

_write_toss_tailscale_stub() {
  local dir="$1"
  local payload="$2"
  cat > "$dir/tailscale" <<EOF_TS
#!/usr/bin/env bash
printf '%s' '$payload'
EOF_TS
  chmod +x "$dir/tailscale"
}

test_toss_preflight_blocks_active_exit_node() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  _write_toss_tailscale_stub "$sandbox/bin" '{"ExitNodeStatus":{"ID":"x","Online":true},"Self":{"ExitNode":false}}'

  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" != "0" ] || fail "expected active exit node to block safeguarded call"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "exit node appears to be ON"
}

test_toss_preflight_fails_closed_on_unknown_exit_node_state() {
  [ "$(uname -s)" = "Darwin" ] || return 0
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  _write_toss_tailscale_stub "$sandbox/bin" 'not-json-at-all'

  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" != "0" ] || fail "expected unknown exit-node state to fail closed for safeguarded call"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "fail-closed"
}
