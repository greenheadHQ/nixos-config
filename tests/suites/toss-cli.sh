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
  false-body)
    printf 'false' > "$output_path"
    ;;
  auth-header-json)
    printf '<html>{"Authorization":"Bearer RAW_JSON_SENTINEL"}</html>' > "$output_path"
    ;;
  retry-401)
    if [ "$api_count" = "1" ]; then
      printf '{"error":"invalid_token"}' > "$output_path"
      printf '401'
      exit 0
    fi
    printf '{"ok":true}' > "$output_path"
    ;;
  non2xx-token-body)
    # 5xx는 서버가 주문을 반영한 뒤 응답했을 수 있으므로, token-like body여도 재시도 금지.
    printf '{"error":{"code":"invalid-token"}}' > "$output_path"
    printf '500'
    exit 0
    ;;
  transport-failure)
    # curl 전송/연결 실패(exit≠0, http_status 000): 응답만 유실됐을 수 있어 재시도 금지.
    printf '000'
    exit 7
    ;;
  ok-200-with-invalid-token-body)
    # 2xx는 side effect가 이미 성공했으므로 body에 invalid_token이 있어도 재시도 금지.
    printf '{"ok":true,"error":"invalid_token","nested":{"code":"invalid-token"}}' > "$output_path"
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

_run_toss_order_api_fixture_with_count() {
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
    TOSS_TEST_API_COUNT_FILE="$sandbox/api.count" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930","quantity":1}' > "$stdout_path"
}

test_toss_api_records_json_response_ledger() {
  local sandbox response_body metadata_status
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  _run_toss_order_api_fixture "$sandbox" json "$sandbox/stdout"

  response_body="$(jq -c 'select(.phase == "response") | .response.body' "$sandbox/orders.jsonl")"
  [ "$response_body" = '{"ok":true,"access_token":"<redacted>","nested":{"message":"client_secret=<redacted> password=<redacted>"}}' ] \
    || fail "expected JSON response body to be recorded with redaction, got: $response_body"
  metadata_status="$(jq -r 'select(.phase == "response") | .request.metadataStatus' "$sandbox/orders.jsonl")"
  [ "$metadata_status" = "exact" ] || fail "expected deployed endpoint metadata lookup, got: $metadata_status"
}

test_toss_api_records_scalar_json_response_ledger() {
  local sandbox response_body
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  _run_toss_order_api_fixture "$sandbox" scalar-json "$sandbox/stdout"

  response_body="$(jq -r 'select(.phase == "response") | .response.body' "$sandbox/orders.jsonl")"
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

  response_body="$(jq -c 'select(.phase == "response") | .response.body' "$sandbox/orders.jsonl")"
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

test_toss_api_does_not_retry_on_non_2xx_token_body() {
  local sandbox api_calls
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # 5xx는 서버가 주문을 반영한 뒤 응답했을 수 있으므로, body에 invalid-token이 있어도
  # 같은 POST를 재전송하면 이중 주문 위험이 있다. 정확히 1회 호출이어야 한다.
  set +e
  _run_toss_order_api_fixture_with_count "$sandbox" non2xx-token-body "$sandbox/stdout"
  set -e

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "1" ] || fail "expected no retry on non-2xx token-like body (double-order risk), got api calls: $api_calls"
}

test_toss_api_does_not_retry_on_transport_failure() {
  local sandbox api_calls
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # curl 전송 실패(exit≠0, http_status 000)는 서버 도달 후 응답만 유실됐을 수 있으므로
  # 재시도 금지. http_status가 우연히 000이어도 완결된 401이 아니면 재시도하지 않는다.
  set +e
  _run_toss_order_api_fixture_with_count "$sandbox" transport-failure "$sandbox/stdout"
  set -e

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "1" ] || fail "expected no retry on transport failure, got api calls: $api_calls"
}

test_toss_api_preserves_large_integer_data() {
  local sandbox quantity
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  # 2^53(9007199254740992) 초과 정수는 jq≤1.6 정규화에서 손실된다. python 정규화로
  # 통일했으므로 --data의 큰 정수가 전송/표시 경로에서 보존되어야 한다.
  HOME="$sandbox/home" TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 \
      --data '{"quantity":9007199254740993}' --dry-run > "$sandbox/stdout"

  quantity="$(jq -r '.body.quantity' "$sandbox/stdout")"
  [ "$quantity" = "9007199254740993" ] \
    || fail "expected large integer to be preserved through normalization, got: $quantity"
}

test_toss_api_rejects_non_standard_json_numbers() {
  local sandbox v rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # jq는 NaN→null, Infinity→큰수, +1/01→1로 조용히 바꾼다. 금융 body가 왜곡되지
  # 않도록 요청 전에 rc 2로 거부되고 curl config도 만들어지지 않아야 한다.
  for v in '{"quantity":NaN}' 'Infinity' '+1' '01'; do
    rm -f "$sandbox/curl.config"
    set +e
    HOME="$sandbox/home" \
      PATH="$sandbox/bin:$PATH" \
      TOSS_ACCESS_TOKEN="mock-token" \
      TOSS_SKIP_PREFLIGHT=1 \
      TOSS_NOTIFY=0 \
      TOSS_TEST_RESPONSE_KIND=json \
      TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
      TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
      "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data "$v" > "$sandbox/stdout" 2> "$sandbox/stderr"
    rc=$?
    set -e
    [ "$rc" = "2" ] || fail "expected non-standard JSON '$v' to be rejected rc=2, got: $rc"
    [ ! -e "$sandbox/curl.config" ] || fail "non-standard JSON '$v' must be rejected before any request"
  done
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "exactly one valid JSON value"
}

test_toss_api_rejects_dot_segment_path() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # /api/../oauth2/token은 metadata unknown + auth guard를 통과하지만 curl이
  # /oauth2/token으로 정규화해 금지된 token endpoint에 도달한다. 입력 단계에서 거부.
  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api GET '/api/../oauth2/token' --account ACC123 > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected dot-segment path rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "'.'/'..' segments"
  [ ! -e "$sandbox/curl.config" ] || fail "dot-segment path must be rejected before any request"
}

test_toss_api_auth_reject_sanitizes_query_secret() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  # 요청 전 거부 경로도 토큰/시크릿 출력 금지 계약을 지켜야 한다.
  set +e
  HOME="$sandbox/home" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api POST '/oauth2/token?client_secret=SPEC_SENTINEL' --data '{}' > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected auth endpoint rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "does not call Toss auth endpoints"
  assert_contains "$stderr" "?<redacted>"
  assert_not_contains "$stderr" "SPEC_SENTINEL"
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

test_toss_endpoint_metadata_fails_on_unresolved_ref() {
  local sandbox input output rc stderr
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # AccountSeq ref를 존재하지 않는 이름으로 바꾸면(docs-refresh의 broken/external ref),
  # account-required endpoint가 조용히 account-free로 생성돼선 안 된다 — generator 실패.
  cat > "$input" <<'JSON'
{
  "info": {"version": "test"},
  "components": {"parameters": {"AccountSeq": {"name": "X-Tossinvest-Account", "in": "header"}}},
  "paths": {
    "/api/v1/holdings": {
      "get": {
        "operationId": "listHoldings",
        "description": "**Rate Limits Group**: `ASSET`",
        "parameters": [{"$ref": "#/components/parameters/AccountSeqTypo"}]
      }
    }
  }
}
JSON

  set +e
  stderr="$(bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output" 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "expected generator to fail on unresolved parameter \$ref, got rc=$rc"
  assert_contains "$stderr" "unresolved parameter"
  [ ! -s "$output" ] || fail "generator must not write metadata when a ref is unresolved"
}

test_toss_endpoint_metadata_fails_on_shortcut_broken_ref() {
  local sandbox input output rc
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # raw `$ref == AccountSeq` shortcut을 제거했으므로, AccountSeq component가 없으면
  # (fixture처럼) generation이 실패해야 한다 (shortcut이 통과시키면 안 됨).
  cat > "$input" <<'JSON'
{"info": {"version": "test"},
 "paths": {"/api/v1/x": {"get": {"operationId": "x", "description": "**Rate Limits Group**: `ASSET`",
   "parameters": [{"$ref": "#/components/parameters/AccountSeq"}]}}}}
JSON

  set +e
  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "expected generator to fail on shortcut broken ref, got rc=$rc"
  [ ! -s "$output" ] || fail "generator must not write metadata for a broken AccountSeq shortcut ref"
}

test_toss_endpoint_metadata_account_header_case_insensitive() {
  local sandbox input output
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # RFC 9110 field name은 case-insensitive이므로 lowercase inline header도 requiresAccount=true.
  cat > "$input" <<'JSON'
{"info": {"version": "test"},
 "paths": {"/api/v1/y": {"get": {"operationId": "y", "description": "**Rate Limits Group**: `ASSET`",
   "parameters": [{"name": "x-tossinvest-account", "in": "header", "required": true}]}}}}
JSON

  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output"
  [ "$(jq -r '.endpoints[0].requiresAccount' "$output")" = "true" ] \
    || fail "expected case-insensitive account header to yield requiresAccount=true"
}

test_toss_endpoint_metadata_fails_on_broken_ref_after_account_true() {
  local sandbox input output rc
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # 첫 parameter가 account(true)여도 뒤의 broken ref를 평가해야 한다 (any short-circuit 제거).
  cat > "$input" <<'JSON'
{"info": {"version": "test"},
 "components": {"parameters": {"Acc": {"name": "X-Tossinvest-Account", "in": "header"}}},
 "paths": {"/api/v1/z": {"get": {"operationId": "z", "description": "**Rate Limits Group**: `ASSET`",
   "parameters": [
     {"$ref": "#/components/parameters/Acc"},
     {"$ref": "#/components/parameters/DoesNotExist"}
   ]}}}}
JSON

  set +e
  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "expected broken ref after account=true to still fail (no short-circuit), got rc=$rc"
  [ ! -s "$output" ] || fail "generator must not write metadata when a later ref is broken"
}

test_toss_endpoint_metadata_keeps_marker_missing_operation() {
  local sandbox input output
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # rate-limit marker/description이 없는 유효 operation은 drop되지 않고 rateLimitGroup:null로
  # 유지되어야 한다 (jq capture no-match의 empty stream이 endpoint를 조용히 삭제하던 문제).
  cat > "$input" <<'JSON'
{"info": {"version": "test"}, "paths": {"/api/v1/new": {"get": {"operationId": "getNew"}}}}
JSON

  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output"
  [ "$(jq '.endpoints | length' "$output")" = "1" ] \
    || fail "expected marker-missing operation to be kept, not dropped"
  [ "$(jq -r '.endpoints[0].rateLimitGroup' "$output")" = "null" ] \
    || fail "expected marker-missing operation to have rateLimitGroup:null"
}

test_toss_endpoint_metadata_fails_on_cross_component_ref() {
  local sandbox input output rc
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # parameter ref가 #/components/parameters/ 밖(여기선 apiKey Security Scheme)을 가리키면,
  # terminal shape(name+in)이 겹쳐도 generation을 실패시켜야 한다.
  cat > "$input" <<'JSON'
{"info": {"version": "test"},
 "components": {"parameters": {"Alias": {"$ref": "#/components/securitySchemes/Other"}},
   "securitySchemes": {"Other": {"type": "apiKey", "name": "X-Other", "in": "header"}}},
 "paths": {"/api/v1/w": {"get": {"operationId": "w", "description": "**Rate Limits Group**: `ASSET`",
   "parameters": [{"$ref": "#/components/parameters/Alias"}]}}}}
JSON

  set +e
  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "expected cross-component (non-parameters) ref to fail, got rc=$rc"
  [ ! -s "$output" ] || fail "generator must not write metadata for a cross-component parameter ref"
}

test_toss_metadata_override_cannot_disable_order_safeguards() {
  local sandbox metadata safeguards
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  # TOSS_ENDPOINTS_FILE로 주문 endpoint의 isKnownOrderMutation을 false로 변조해도,
  # order-path mutation runtime hard floor가 requiresOrderSafeguards를 켜야 한다 (보상 통제 우회 차단).
  cat > "$sandbox/evil-endpoints.json" <<'JSON'
{"schema_version": "1", "endpoints": [
  {"method": "POST", "path": "/api/v1/orders", "operationId": "x", "requiresAccount": true,
   "rateLimitGroup": "OTHER", "pathRegex": "^/api/v1/orders$", "isKnownOrderMutation": false}]}
JSON

  metadata="$(HOME="$sandbox/home" TOSS_ENDPOINTS_FILE="$sandbox/evil-endpoints.json" \
    bash "$REPO_ROOT/modules/shared/scripts/lib/toss/metadata.sh" POST /api/v1/orders 2>/dev/null)"
  safeguards="$(jq -r '.requiresOrderSafeguards' <<<"$metadata")"
  [ "$safeguards" = "true" ] \
    || fail "expected order-path mutation hard floor to force requiresOrderSafeguards=true, got: $safeguards"
}

test_toss_api_records_attempt_ledger_before_send() {
  local sandbox attempt_id response_id
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # safeguarded 호출은 전송 직전 phase:"attempt"를 남겨, 전송 후 crash로 response가 없어도
  # "접수됐을 수 있음" 흔적을 보존한다. attempt와 response는 같은 invocationId를 공유한다.
  _run_toss_order_api_fixture "$sandbox" json "$sandbox/stdout"

  attempt_id="$(jq -r 'select(.phase == "attempt") | .invocationId' "$sandbox/orders.jsonl")"
  response_id="$(jq -r 'select(.phase == "response") | .invocationId' "$sandbox/orders.jsonl")"
  [ -n "$attempt_id" ] && [ "$attempt_id" != "null" ] \
    || fail "expected an attempt ledger record before send"
  [ "$attempt_id" = "$response_id" ] \
    || fail "expected attempt and response to share invocationId ($attempt_id vs $response_id)"
}

test_toss_ledger_redacts_quoted_json_authorization() {
  local sandbox ledger
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # 비정상 HTML/JSON-like 응답이 `{"Authorization":"Bearer ..."}`처럼 header를 반사해도
  # raw redaction이 Bearer를 0600 ledger에 남기지 않아야 한다.
  _run_toss_order_api_fixture "$sandbox" auth-header-json "$sandbox/stdout"

  ledger="$(cat "$sandbox/orders.jsonl")"
  assert_not_contains "$ledger" "RAW_JSON_SENTINEL"
  assert_contains "$ledger" "Bearer <redacted>"
}

test_toss_auth_isolates_connect_env() {
  # Connect env 격리는 Mac op read 경로(toss_read_credentials_from_op) 전용이다.
  # 비-darwin은 opnix 파일 경로라 op를 부르지 않으므로 이 검증 대상이 아니다.
  [ "$(uname -s)" = "Darwin" ] || return 0
  local sandbox runtime_dir connect_log
  sandbox=$(new_sandbox)
  runtime_dir="$sandbox/runtime"
  connect_log="$sandbox/connect.log"
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  # op stub이 SA 조회 시점의 OP_CONNECT_HOST 유무를 기록한다.
  cat > "$sandbox/bin/op" <<EOF_OP
#!/usr/bin/env bash
set -euo pipefail
printf 'connect_host=%s\n' "\${OP_CONNECT_HOST:-none}" >> "$connect_log"
ref=""
for arg in "\$@"; do ref="\$arg"; done
case "\$ref" in
  *자격*|*client-id) printf 'mock-client-id' ;;
  *Secret*|*client-secret) printf 'mock-client-secret' ;;
  *) printf 'mock-op-value' ;;
esac
EOF_OP
  chmod +x "$sandbox/bin/op"
  printf 'mock-sa-token' > "$sandbox/sa-token"

  # 오염된 Connect env를 넣고 강제 발급 — SA 조회는 이를 unset한 서브셸에서 실행되어야 한다.
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    OP_CONNECT_HOST="https://evil.connect.invalid" \
    OP_CONNECT_TOKEN="evil-connect-token" \
    TOSS_RUNTIME_DIR="$runtime_dir" \
    TOSS_OP_SA_TOKEN_FILE="$sandbox/sa-token" \
    "$(_toss_cli_script "$sandbox")" token --force >/dev/null 2>&1 || true

  [ -s "$connect_log" ] || fail "expected op to be invoked for credential read"
  grep -q "connect_host=none" "$connect_log" \
    || fail "expected SA op read to run with OP_CONNECT_HOST unset, got: $(cat "$connect_log")"
  ! grep -q "evil.connect.invalid" "$connect_log" \
    || fail "SA op read must not inherit ambient OP_CONNECT_HOST"
}

test_with_file_lock_fails_closed_without_backend() {
  local sandbox minbin rc c
  sandbox=$(new_sandbox)
  minbin="$sandbox/minbin"
  mkdir -p "$minbin"
  # flock/lockf를 제외한 최소 PATH — with_file_lock이 lock 없이 실행(fail-open)하지 않고
  # non-zero로 fail-closed해야 한다.
  for c in mkdir dirname; do ln -s "$(command -v "$c")" "$minbin/$c" 2>/dev/null || true; done

  set +e
  ( PATH="$minbin" bash -c 'source "'"$REPO_ROOT"'/modules/shared/scripts/lib/file-lock.sh"; with_file_lock "'"$sandbox"'/lock" 1 :' )
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "expected with_file_lock to fail-closed when no lock backend is available"
}

test_toss_api_dry_run_rejects_untrusted_base_url() {
  local sandbox rc
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  # dry-run은 실제 호출 구성을 검증하는 경로이므로, untrusted base의 dry-run도
  # non-network exact-origin 검증에서 거부되어야 한다 (evil URL을 출력하면 안 됨).
  set +e
  HOME="$sandbox/home" \
    TOSS_API_BASE_URL="https://evil.invalid" \
    TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api GET /api/v1/accounts --dry-run > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" != "0" ] || fail "expected untrusted base URL dry-run to be rejected"
  assert_not_contains "$(cat "$sandbox/stdout")" "evil.invalid"
}

test_toss_api_rejects_untrusted_base_url() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # confused-deputy 차단: bearer token을 비공식 host로 보내려 하면 전송 전에 거부.
  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_API_BASE_URL="https://evil.invalid" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api GET /api/v1/orders --account ACC123 > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" != "0" ] || fail "expected untrusted TOSS_API_BASE_URL to be rejected"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "exactly the official Toss origin"
  [ ! -e "$sandbox/curl.config" ] || fail "untrusted base URL must be rejected before any request"
}

test_toss_api_rejects_base_url_with_path_suffix() {
  local sandbox rc
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # host-only 비교는 `.../oauth2` path 접미사를 허용해 raw PATH `/token`이 `/oauth2/token`으로
  # 합성된다. exact base 비교로 path/port가 붙은 base를 거부해야 한다.
  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_API_BASE_URL="https://openapi.tossinvest.com/oauth2" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api GET '/token' --account ACC123 > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" != "0" ] || fail "expected base URL with path suffix to be rejected"
  [ ! -e "$sandbox/curl.config" ] || fail "base URL with path suffix must be rejected before any request"
}

test_toss_api_rejects_empty_slash_segment_path() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # //oauth2/token 은 origin-relative(/*)를 통과하지만 서버는 /oauth2/token으로 라우팅해
  # auth guard를 우회한다. 빈 '//' segment를 입력 단계에서 거부한다.
  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api GET '//oauth2/token' --account ACC123 > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected empty '//' segment rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "empty '//' segments"
  [ ! -e "$sandbox/curl.config" ] || fail "empty '//' segment path must be rejected before any request"
}

test_toss_endpoint_metadata_resolves_chained_ref() {
  local sandbox input output
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # AccountAlias -> $ref AccountSeq chain은 재귀 resolve되어 requiresAccount=true여야 한다
  # (첫 resolve가 다시 Reference Object라 type==object만으론 부족).
  cat > "$input" <<'JSON'
{
  "info": {"version": "test"},
  "components": {"parameters": {
    "AccountAlias": {"$ref": "#/components/parameters/AccountSeq"},
    "AccountSeq": {"name": "X-Tossinvest-Account", "in": "header"}
  }},
  "paths": {
    "/api/v1/holdings": {
      "get": {
        "operationId": "listHoldings",
        "description": "**Rate Limits Group**: `ASSET`",
        "parameters": [{"$ref": "#/components/parameters/AccountAlias"}]
      }
    }
  }
}
JSON

  bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output"
  [ "$(jq -r '.endpoints[0].requiresAccount' "$output")" = "true" ] \
    || fail "expected chained AccountSeq ref to resolve to requiresAccount=true"
}

test_toss_endpoint_metadata_fails_on_path_item_ref() {
  local sandbox input output rc stderr
  sandbox=$(new_sandbox)
  input="$sandbox/openapi.json"
  output="$sandbox/endpoints.json"
  # Path Item $ref는 operation iteration이 조용히 무시해 endpoint를 누락시킨다 → 실패해야 한다.
  cat > "$input" <<'JSON'
{"info": {"version": "test"}, "paths": {"/api/v1/y": {"$ref": "#/components/x"}}}
JSON

  set +e
  stderr="$(bash "$REPO_ROOT/scripts/toss/generate-endpoint-metadata.sh" "$input" "$output" 2>&1 >/dev/null)"
  rc=$?
  set -e
  [ "$rc" != "0" ] || fail "expected generator to fail on Path Item \$ref, got rc=$rc"
  assert_contains "$stderr" "Path Item \$ref"
  [ ! -s "$output" ] || fail "generator must not write metadata when a Path Item ref is present"
}

test_toss_api_rejects_percent_encoded_path() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # /%6fauth2/token 은 raw 문자열 auth 판정을 통과하지만 서버가 decode해 token endpoint로
  # 라우팅된다. path segment의 percent-encoding은 입력 단계에서 거부한다.
  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api GET '/%6fauth2/token' --account ACC123 > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected percent-encoded path rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "percent-encoding"
  [ ! -e "$sandbox/curl.config" ] || fail "percent-encoded path must be rejected before any request"
}

test_toss_normalize_preserves_decimal_lexeme() {
  local sandbox out
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  # 정규화가 전송 body의 단일 SoT이므로, 소수 lexeme가 float 손실 없이 보존되어야 한다.
  # json.dump 기본 float는 이 값을 1234567890.1234567로 손실시킨다 (Decimal 파싱으로 방지).
  out="$(
    TOSS_PYTHON="$(toss_test_python3)" bash -c '
      set +e
      source "$1" 2>/dev/null
      printf "%s" "{\"quantity\":1234567890.12345678901234567890}" | toss_normalize_json_single_value
    ' _ "$sandbox/home/.local/lib/toss/api.sh"
  )"
  [ "$out" = '{"quantity":1234567890.12345678901234567890}' ] \
    || fail "expected decimal lexeme to be preserved, got: $out"
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

  response_body="$(jq -c 'select(.phase == "response") | .response.body' "$sandbox/orders.jsonl")"
  assert_contains "$response_body" '"parseableJson":false'
  [ "$(jq -r 'select(.phase == "response") | .response.body.raw' "$sandbox/orders.jsonl")" = "$(printf '1\n2')" ] \
    || fail "expected multi-JSON response to be recorded as raw wrapper, got: $response_body"
}

test_toss_ledger_append_preserves_existing_records() {
  local sandbox line_count first_line
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"
  printf '{"sentinel":true}\n' > "$sandbox/orders.jsonl"

  _run_toss_order_api_fixture "$sandbox" json "$sandbox/stdout"

  # sentinel(1) + safeguarded 주문의 attempt(1) + response(1) = 3줄. 핵심은 기존 sentinel이
  # truncate되지 않고 살아남는 것(TOCTOU 방지)이며, 라인 수는 append record 수에 따른다.
  line_count="$(wc -l < "$sandbox/orders.jsonl" | tr -d ' ')"
  [ "$line_count" = "3" ] || fail "expected append to preserve existing record and add attempt+response, got $line_count lines"
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

  recorded_path="$(jq -r 'select(.phase == "response") | .request.path' "$sandbox/orders.jsonl")"
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
  ledger_headers="$(jq -c 'select(.phase == "response") | .response.rateLimitHeaders' "$sandbox/orders.jsonl")"
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

test_toss_api_does_not_retry_on_2xx_invalid_token_body() {
  local sandbox api_calls
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  # 200 응답은 주문 side effect가 이미 성공한 상태다. body에 invalid_token substring이
  # 있다고 같은 POST를 재전송하면 이중 주문이 된다.
  _run_toss_order_api_fixture_with_count "$sandbox" ok-200-with-invalid-token-body "$sandbox/stdout"

  api_calls="$(cat "$sandbox/api.count")"
  [ "$api_calls" = "1" ] || fail "expected no retry on 2xx invalid_token body (double-order risk), got api calls: $api_calls"
}

test_toss_api_rejects_multi_document_data() {
  local sandbox rc stderr
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  set +e
  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=json \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 \
      --data "$(printf '{"quantity":1}\n{"quantity":999}')" > "$sandbox/stdout" 2> "$sandbox/stderr"
  rc=$?
  set -e

  [ "$rc" = "2" ] || fail "expected multi-document --data rejection rc=2, got: $rc"
  stderr="$(cat "$sandbox/stderr")"
  assert_contains "$stderr" "exactly one valid JSON value"
  [ ! -e "$sandbox/curl.config" ] || fail "multi-document --data must be rejected before any request"
}

test_toss_api_dry_run_distinguishes_explicit_null_body() {
  local sandbox with_null without_body
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  HOME="$sandbox/home" TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data null --dry-run > "$sandbox/with-null"
  HOME="$sandbox/home" TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --dry-run > "$sandbox/without-body"

  with_null="$(jq -c '{bodyProvided, body, hasContentType: (.headers | index("Content-Type: application/json") != null)}' "$sandbox/with-null")"
  without_body="$(jq -c '{bodyProvided, body, hasContentType: (.headers | index("Content-Type: application/json") != null)}' "$sandbox/without-body")"

  [ "$with_null" = '{"bodyProvided":true,"body":null,"hasContentType":true}' ] \
    || fail "expected explicit --data null to be sent as a body, got: $with_null"
  [ "$without_body" = '{"bodyProvided":false,"body":null,"hasContentType":false}' ] \
    || fail "expected omitted body to send no Content-Type, got: $without_body"
}

test_toss_api_dry_run_sanitizes_query_in_url() {
  local sandbox url
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"

  HOME="$sandbox/home" TOSS_NOTIFY=0 \
    "$(_toss_cli_script "$sandbox")" api POST '/api/v1/orders?access_token=QUERYSECRET' --account ACC123 --dry-run > "$sandbox/stdout"

  url="$(jq -r '.url' "$sandbox/stdout")"
  assert_contains "$url" '/api/v1/orders?<redacted>'
  assert_not_contains "$(cat "$sandbox/stdout")" "QUERYSECRET"
}

test_toss_ledger_preserves_boolean_false_bodies() {
  local sandbox request_body response_body
  sandbox=$(new_sandbox)
  _prepare_toss_cli_sandbox "$sandbox"
  _write_toss_api_curl_stub "$sandbox/bin"

  HOME="$sandbox/home" \
    PATH="$sandbox/bin:$PATH" \
    TOSS_ACCESS_TOKEN="mock-token" \
    TOSS_SKIP_PREFLIGHT=1 \
    TOSS_NOTIFY=0 \
    TOSS_TEST_RESPONSE_KIND=false-body \
    TOSS_TEST_CURL_CONFIG="$sandbox/curl.config" \
    TOSS_LEDGER_FILE="$sandbox/orders.jsonl" \
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data false > "$sandbox/stdout"

  request_body="$(jq -c 'select(.phase == "response") | .request.body' "$sandbox/orders.jsonl")"
  response_body="$(jq -c 'select(.phase == "response") | .response.body' "$sandbox/orders.jsonl")"
  [ "$request_body" = "false" ] || fail "expected JSON false request body to survive the ledger, got: $request_body"
  [ "$response_body" = "false" ] || fail "expected JSON false response body to survive the ledger, got: $response_body"
}

test_toss_notify_record_shares_invocation_id_with_response() {
  local sandbox response_id notify_id
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
    "$(_toss_cli_script "$sandbox")" api POST /api/v1/orders --account ACC123 --data '{"symbol":"005930"}' > "$sandbox/stdout" 2>/dev/null

  response_id="$(jq -r 'select(.phase == "response") | .invocationId' "$sandbox/orders.jsonl")"
  notify_id="$(jq -r 'select(.phase == "notify") | .invocationId' "$sandbox/orders.jsonl")"
  [ -n "$response_id" ] && [ "$response_id" != "null" ] || fail "expected response record to carry an invocationId"
  [ "$response_id" = "$notify_id" ] \
    || fail "expected notify record to share the response invocationId ($response_id vs $notify_id)"
  [ "$(jq -r 'select(.phase == "notify") | .request.accountSeq' "$sandbox/orders.jsonl")" = "ACC123" ] \
    || fail "expected notify record to carry accountSeq for correlation"
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
