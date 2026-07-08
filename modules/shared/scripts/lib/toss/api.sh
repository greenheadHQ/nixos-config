#!/usr/bin/env bash
set -euo pipefail

toss_usage_api() {
  cat <<'EOF'
usage: toss api <METHOD> <PATH> [--account ACCOUNT_SEQ] [--data JSON] [--dry-run] [--no-notify]
EOF
}

toss_restore_trap() {
  local signal="$1"
  local saved_trap="$2"

  if [ -n "$saved_trap" ]; then
    eval "$saved_trap"
  else
    trap - "$signal"
  fi
}

toss_api_tmp_dir_cleanup() {
  local tmp_dir="$1"
  local old_exit_trap="$2"
  local old_int_trap="$3"
  local old_term_trap="$4"

  rm -rf "$tmp_dir"
  toss_restore_trap EXIT "$old_exit_trap"
  toss_restore_trap INT "$old_int_trap"
  toss_restore_trap TERM "$old_term_trap"
}

toss_metadata_bool() {
  local metadata="$1"
  local key="$2"
  jq -er --arg key "$key" '.[$key] == true' <<<"$metadata" >/dev/null
}

toss_metadata_value() {
  local metadata="$1"
  local key="$2"
  jq -r --arg key "$key" '.[$key] // empty' <<<"$metadata"
}

toss_validate_json_body() {
  local raw="$1"
  jq -c . <<<"$raw"
}

toss_ledger_raw_response_max_chars() {
  local max_chars="${TOSS_LEDGER_RAW_RESPONSE_MAX_CHARS:-4096}"

  case "$max_chars" in
    ''|*[!0-9]*) max_chars=4096 ;;
  esac

  printf '%s\n' "$max_chars"
}

toss_ledger_response_body_json() {
  local response_body="$1"

  if jq -e . <<<"$response_body" >/dev/null 2>&1 \
    || jq -e 'type == "null" or type == "boolean"' <<<"$response_body" >/dev/null 2>&1; then
    jq -c . <<<"$response_body"
    return 0
  fi

  local max_chars
  max_chars="$(toss_ledger_raw_response_max_chars)"

  jq -cn \
    --arg raw "$response_body" \
    --argjson max "$max_chars" '
      def redact_raw:
        gsub("(?<prefix>authorization:[[:space:]]*bearer[[:space:]]+)[^[:space:]<>\"=,]+"; "\(.prefix)<redacted>"; "i")
        | gsub("(?<prefix>\"?(access[_-]?token|client[_-]?secret|secret|password)\"?[[:space:]]*[:=][[:space:]]*\"?)[^\"&<>,[:space:]]+"; "\(.prefix)<redacted>"; "i");

      ($raw | redact_raw) as $redacted
      | {
          raw: ($redacted[:$max]),
          parseableJson: false,
          truncated: (($redacted | length) > $max)
        }
    '
}

toss_api_dry_run_output() {
  local method="$1"
  local url="$2"
  local metadata="$3"
  local account_seq="$4"
  local body_json="$5"
  local redacted_body
  redacted_body="$(jq -c . <<<"$body_json" | toss_ledger_redact_json 2>/dev/null || echo 'null')"

  jq -n \
    --arg method "$method" \
    --arg url "$url" \
    --arg accountSeq "$account_seq" \
    --argjson metadata "$metadata" \
    --argjson body "$redacted_body" '
      {
        dryRun: true,
        method: $method,
        url: $url,
        headers: (
          ["Authorization: <redacted>", "Accept: application/json"]
          + (if $accountSeq == "" then [] else ["X-Tossinvest-Account: <redacted>"] end)
          + (if $body == null then [] else ["Content-Type: application/json"] end)
        ),
        body: $body,
        metadata: {
          status: $metadata.metadataStatus,
          matchedPath: $metadata.matchedPath,
          operationId: $metadata.operationId,
          requiresAccount: $metadata.requiresAccount,
          isKnownOrderMutation: $metadata.isKnownOrderMutation,
          requiresOrderSafeguards: $metadata.requiresOrderSafeguards
        }
      }
    '
}

toss_api_call_once() (
  local method="$1"
  local url="$2"
  local token="$3"
  local account_seq="$4"
  local body_json="$5"
  local response_file="$6"

  local config_file body_file
  body_file=""
  config_file="$(toss_private_tmpfile "toss-api-curl")"
  trap 'rm -f "$config_file"; if [ -n "$body_file" ]; then rm -f "$body_file"; fi' EXIT

  toss_curl_config_append "$config_file" "request" "$method"
  toss_curl_config_append "$config_file" "header" "Authorization: Bearer $token"
  toss_curl_config_append "$config_file" "header" "Accept: application/json"
  toss_curl_config_append "$config_file" "output" "$response_file"
  toss_curl_config_append "$config_file" "write-out" "%{http_code}"
  toss_curl_config_append "$config_file" "url" "$url"
  if [ -n "$account_seq" ]; then
    toss_curl_config_append "$config_file" "header" "X-Tossinvest-Account: $account_seq"
  fi
  if [ "$body_json" != "null" ]; then
    body_file="$(toss_private_tmpfile "toss-api-body")"
    toss_write_private_tempfile "$body_file" "$body_json"
    toss_curl_config_append "$config_file" "header" "Content-Type: application/json"
    toss_curl_config_append "$config_file" "data-binary" "@$body_file"
  fi

  local status curl_rc
  set +e
  status="$(curl -sS --proto =https --max-time "${TOSS_CURL_MAX_TIME_SECONDS:-30}" -K "$config_file")"
  curl_rc=$?
  set -e

  jq -cn \
    --arg httpStatus "$status" \
    --argjson curlExit "$curl_rc" \
    '{httpStatus: $httpStatus, curlExit: $curlExit}'
)

toss_call_result_http_status() {
  jq -er '.httpStatus // ""' <<<"$1"
}

toss_call_result_curl_exit() {
  jq -er '.curlExit | tostring' <<<"$1"
}

toss_response_is_invalid_token() {
  local http_status="$1"
  local response_file="$2"
  [ "$http_status" = "401" ] && return 0
  [ -s "$response_file" ] || return 1
  jq -e '
    [.. | objects | (.error? // .code? // empty) | tostring]
    | any(test("invalid_token"; "i"))
  ' "$response_file" >/dev/null 2>&1
}

toss_resolve_account() {
  local metadata="$1"
  local account_arg="$2"
  local metadata_status requires_account account_seq

  metadata_status="$(toss_metadata_value "$metadata" "metadataStatus")"
  if toss_metadata_bool "$metadata" "requiresAccount"; then
    requires_account=1
  else
    requires_account=0
  fi

  account_seq=""
  if [ "$requires_account" = "1" ] || [ "$metadata_status" = "unknown" ]; then
    account_seq="$account_arg"
    if [ -z "$account_seq" ]; then
      account_seq="$(toss_read_default_account 2>/dev/null || true)"
    fi
    if [ -z "$account_seq" ]; then
      echo "error: Toss account sequence is required for this endpoint" >&2
      echo "hint: pass --account ACCOUNT_SEQ or run 'toss accounts' to cache a default account" >&2
      return 1
    fi
  fi

  printf '%s\n' "$account_seq"
}

toss_api_requires_order_safeguards() {
  local metadata="$1"
  if toss_metadata_bool "$metadata" "requiresOrderSafeguards"; then
    printf '1\n'
  else
    printf '0\n'
  fi
}

toss_api_is_auth_endpoint() {
  local metadata="$1"
  local path="$2"
  local rate_limit_group path_without_query

  rate_limit_group="$(toss_metadata_value "$metadata" "rateLimitGroup")"
  path_without_query="${path%%\?*}"

  [ "$rate_limit_group" = "AUTH" ] && return 0
  case "$path_without_query" in
    /oauth2|/oauth2/*|/auth|/auth/*) return 0 ;;
    *) return 1 ;;
  esac
}

toss_api_reject_auth_endpoint() {
  local path="$1"

  echo "error: toss api does not call Toss auth endpoints: $path" >&2
  echo "hint: issue or refresh tokens with 'toss token'" >&2
  return 2
}

toss_api_request_context() {
  local method="$1"
  local path="$2"
  local account_seq="$3"
  local metadata="$4"
  local body_json="$5"

  jq -cn \
    --arg method "$method" \
    --arg path "$path" \
    --arg accountSeq "$account_seq" \
    --argjson metadata "$metadata" \
    --argjson body "$body_json" '
      {
        method: $method,
        path: $path,
        accountSeq: (if $accountSeq == "" then null else $accountSeq end),
        metadata: $metadata,
        body: $body
      }
    '
}

toss_ledger_record_input() {
  local phase="$1"
  local dry_run="$2"
  local request_context="$3"
  local response_body="$4"
  local http_status="${5:-}"
  local curl_exit="${6:-}"
  local response_body_json

  response_body_json="$(toss_ledger_response_body_json "$response_body")" || {
    response_body_json='{"raw":"<unrecordable response body>","parseableJson":false,"truncated":true}'
  }

  jq -cn \
    --arg phase "$phase" \
    --arg dryRun "$dry_run" \
    --argjson request "$request_context" \
    --argjson responseBody "$response_body_json" \
    --arg httpStatus "$http_status" \
    --arg curlExit "$curl_exit" '
      {
        phase: $phase,
        dryRun: ($dryRun == "1"),
        request: $request,
        response: {
          httpStatus: (if $httpStatus == "" then null else $httpStatus end),
          curlExit: (if $curlExit == "" then null else ($curlExit | tonumber) end),
          body: $responseBody
        }
      }
    '
}

toss_record_dry_run_ledger() {
  local request_context="$1"
  local record_input

  record_input="$(toss_ledger_record_input "dry-run" "1" "$request_context" "null")" || return 0
  toss_ledger_record "$record_input"
}

toss_record_response_ledger() {
  local request_context="$1"
  local response_body="$2"
  local http_status="$3"
  local curl_exit="$4"
  local record_input

  record_input="$(toss_ledger_record_input "response" "0" "$request_context" "$response_body" "$http_status" "$curl_exit")" || return 0
  toss_ledger_record "$record_input"
}

toss_api_handle_dry_run() {
  local url="$1"
  local requires_order_safeguards="$2"
  local request_context="$3"
  local method path account_seq metadata body_json

  method="$(jq -r '.method' <<<"$request_context")"
  path="$(jq -r '.path' <<<"$request_context")"
  account_seq="$(jq -r '.accountSeq // ""' <<<"$request_context")"
  metadata="$(jq -c '.metadata' <<<"$request_context")"
  body_json="$(jq -c '.body' <<<"$request_context")"

  toss_api_dry_run_output "$method" "$url" "$metadata" "$account_seq" "$body_json"
  if [ "$requires_order_safeguards" = "1" ]; then
    toss_record_dry_run_ledger "$request_context"
  fi
}

toss_call_with_single_token_retry() {
  local method="$1"
  local url="$2"
  local account_seq="$3"
  local body_json="$4"
  local response_file="$5"
  local token call_result http_status curl_exit

  token="$(toss_get_access_token 0)"
  call_result="$(toss_api_call_once "$method" "$url" "$token" "$account_seq" "$body_json" "$response_file")"
  http_status="$(toss_call_result_http_status "$call_result")"
  curl_exit="$(toss_call_result_curl_exit "$call_result")"

  if toss_response_is_invalid_token "$http_status" "$response_file"; then
    toss_delete_token_cache
    token="$(toss_get_access_token 1)"
    : >"$response_file"
    call_result="$(toss_api_call_once "$method" "$url" "$token" "$account_seq" "$body_json" "$response_file")"
    http_status="$(toss_call_result_http_status "$call_result")"
    curl_exit="$(toss_call_result_curl_exit "$call_result")"
  fi

  printf '%s\n' "$call_result"
}

toss_response_body_or_null() {
  local response_file="$1"
  local response_body

  response_body="$(cat "$response_file" 2>/dev/null || true)"
  [ -n "$response_body" ] || response_body="null"
  printf '%s\n' "$response_body"
}

toss_emit_response() {
  local response_file="$1"
  local http_status="$2"
  local curl_exit="$3"
  cat "$response_file" 2>/dev/null || true
  [ -s "$response_file" ] && printf '\n'

  if [ "$curl_exit" != "0" ]; then
    echo "error: Toss API request failed before receiving a response" >&2
    return "$curl_exit"
  fi

  case "$http_status" in
    2??)
      return 0
      ;;
    *)
      echo "error: Toss API returned HTTP $http_status" >&2
      return 1
      ;;
  esac
}

toss_notify_safeguarded_api_success_for_context() {
  local request_context="$1"
  local requires_order_safeguards="$2"
  local no_notify="$3"
  local http_status="$4"
  local method path account_seq

  [ "$requires_order_safeguards" = "1" ] || return 0
  method="$(jq -r '.method' <<<"$request_context")"
  path="$(jq -r '.path' <<<"$request_context")"
  account_seq="$(jq -r '.accountSeq // ""' <<<"$request_context")"
  toss_notify_safeguarded_api_success "$no_notify" "$method" "$path" "$account_seq" "$http_status"
}

toss_api_execute() {
  local method="$1"
  local path="$2"
  local account_arg="$3"
  local body_json="$4"
  local dry_run="$5"
  local no_notify="$6"

  local metadata
  metadata="$(toss_metadata_lookup "$method" "$path")"
  if toss_api_is_auth_endpoint "$metadata" "$path"; then
    toss_api_reject_auth_endpoint "$path"
    return 2
  fi

  local requires_order_safeguards account_seq request_context
  requires_order_safeguards="$(toss_api_requires_order_safeguards "$metadata")"
  account_seq="$(toss_resolve_account "$metadata" "$account_arg")" || return 1
  request_context="$(toss_api_request_context "$method" "$path" "$account_seq" "$metadata" "$body_json")"

  toss_preflight_network_context "$requires_order_safeguards" "$dry_run"

  local url="$TOSS_API_BASE_URL$path"
  if [ "$dry_run" = "1" ]; then
    toss_api_handle_dry_run "$url" "$requires_order_safeguards" "$request_context"
    return 0
  fi

  local tmp_dir response_file call_result http_status curl_exit rc
  local old_exit_trap old_int_trap old_term_trap
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/toss-api.XXXXXX")"
  old_exit_trap="$(trap -p EXIT)"
  old_int_trap="$(trap -p INT)"
  old_term_trap="$(trap -p TERM)"
  trap 'toss_api_tmp_dir_cleanup "$tmp_dir" "$old_exit_trap" "$old_int_trap" "$old_term_trap"' EXIT
  trap 'toss_api_tmp_dir_cleanup "$tmp_dir" "$old_exit_trap" "$old_int_trap" "$old_term_trap"; exit 130' INT
  trap 'toss_api_tmp_dir_cleanup "$tmp_dir" "$old_exit_trap" "$old_int_trap" "$old_term_trap"; exit 143' TERM
  response_file="$tmp_dir/response.json"

  call_result="$(toss_call_with_single_token_retry "$method" "$url" "$account_seq" "$body_json" "$response_file")" || {
    rc=$?
    toss_api_tmp_dir_cleanup "$tmp_dir" "$old_exit_trap" "$old_int_trap" "$old_term_trap"
    return "$rc"
  }
  http_status="$(toss_call_result_http_status "$call_result")"
  curl_exit="$(toss_call_result_curl_exit "$call_result")"

  local response_body
  response_body="$(toss_response_body_or_null "$response_file")"
  if [ "$requires_order_safeguards" = "1" ]; then
    toss_record_response_ledger "$request_context" "$response_body" "$http_status" "$curl_exit"
  fi

  if toss_emit_response "$response_file" "$http_status" "$curl_exit"; then
    toss_notify_safeguarded_api_success_for_context "$request_context" "$requires_order_safeguards" "$no_notify" "$http_status"
    rc=0
  else
    rc=$?
  fi
  toss_api_tmp_dir_cleanup "$tmp_dir" "$old_exit_trap" "$old_int_trap" "$old_term_trap"
  return "$rc"
}

toss_cmd_api() {
  if [ "$#" -lt 2 ]; then
    toss_usage_api >&2
    return 2
  fi

  local method="$1"
  local path="$2"
  shift 2
  method="$(printf '%s' "$method" | tr '[:lower:]' '[:upper:]')"

  local account_arg=""
  local data_arg=""
  local dry_run=0
  local no_notify=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --account)
        [ "$#" -ge 2 ] || { echo "error: --account requires a value" >&2; return 2; }
        account_arg="$2"
        shift 2
        ;;
      --data)
        [ "$#" -ge 2 ] || { echo "error: --data requires a JSON value" >&2; return 2; }
        data_arg="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --no-notify)
        no_notify=1
        shift
        ;;
      -h|--help)
        toss_usage_api
        return 0
        ;;
      *)
        echo "error: unknown api option: $1" >&2
        return 2
        ;;
    esac
  done

  local body_json="null"
  if [ -n "$data_arg" ]; then
    body_json="$(toss_validate_json_body "$data_arg")" || {
      echo "error: --data must be valid JSON" >&2
      return 2
    }
  fi

  toss_api_execute "$method" "$path" "$account_arg" "$body_json" "$dry_run" "$no_notify"
}

toss_cmd_accounts() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help)
        echo "usage: toss accounts"
        return 0
        ;;
      *)
        echo "error: accounts does not accept arguments" >&2
        return 2
        ;;
    esac
  fi

  local response
  response="$(toss_api_execute "GET" "/api/v1/accounts" "" "null" "0" "1")"
  printf '%s\n' "$response"

  local account_seq
  account_seq="$(jq -r '.result[0].accountSeq // empty' <<<"$response" 2>/dev/null || true)"
  if [ -n "$account_seq" ]; then
    toss_write_default_account "$account_seq"
  fi
}
