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

# jq는 표준 JSON을 초과하는 확장을 조용히 다른 값으로 바꾸고(NaN→null, Infinity→큰수,
# +1/01→1, 값 0개·2개 이상 stream 통과), jq≤1.6에서는 2^53 초과 정수까지 손실시킨다.
# 금융 요청 body가 이렇게 왜곡·이중화되면 안 되므로, 검증과 정규화를 모두 표준 JSON
# 파서(python3)로 통일한다: "정확히 표준 JSON 값 하나"만 통과(다중 문서=Extra data 거부,
# NaN/Infinity=parse_constant 거부, +1/01=JSONDecodeError 거부)시키고, 큰 정수를 임의
# 정밀도 int로 보존한 채 compact JSON으로 재직렬화한다. 정규화 출력이 downstream(실제
# 전송 body·ledger·dry-run)의 단일 SoT다. python3는 --data(주문 경로) 전용 의존이며
# 부재 시 fail-closed. rc: 0=정규화 값 stdout, 1=비표준/다중, 2=python3 부재.
toss_normalize_json_single_value() {
  # 배포 wrapper는 TOSS_PYTHON에 Nix store 절대경로를 주입한다(ambient PATH의 mise shim
  # python이 dry-run을 hang시키는 것을 방지). repo 직접 실행/테스트는 python3로 fallback.
  local py="${TOSS_PYTHON:-python3}"
  command -v "$py" >/dev/null 2>&1 || return 2
  "$py" -c '
import sys, json
from decimal import Decimal
def _reject_constant(_):
    raise ValueError("non-finite JSON constant")
# 정수는 임의정밀도 int로, 소수는 Decimal로 파싱해 원래 numeric lexeme를 보존한다
# (json.loads 기본 float는 2^53 초과 정수·긴 소수를 IEEE754로 손실시킨다). 표준 인코더는
# Decimal을 numeric으로 못 내므로 직접 compact 직렬화한다(json.dump와 동일 표현 유지).
def _dump(o):
    if isinstance(o, bool):
        return "true" if o else "false"
    if o is None:
        return "null"
    if isinstance(o, Decimal):
        return str(o)
    if isinstance(o, int):
        return str(o)
    if isinstance(o, str):
        return json.dumps(o, ensure_ascii=False)
    if isinstance(o, list):
        return "[" + ",".join(_dump(v) for v in o) + "]"
    if isinstance(o, dict):
        return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + _dump(v) for k, v in o.items()) + "}"
    raise ValueError("unexpected JSON type")
data = sys.stdin.read()
try:
    obj = json.loads(data, parse_constant=_reject_constant, parse_float=Decimal)
except ValueError:
    sys.exit(1)
sys.stdout.write(_dump(obj))
'
}

toss_validate_json_body() {
  local raw="$1"
  local normalized rc
  normalized="$(printf '%s' "$raw" | toss_normalize_json_single_value)"
  rc=$?
  if [ "$rc" = "2" ]; then
    echo "error: python3 (TOSS_PYTHON) is required to validate --data as strict JSON" >&2
    return 1
  fi
  [ "$rc" = "0" ] || return 1
  printf '%s' "$normalized"
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

  # `jq -e .`는 여러 JSON 값 stream(`1\n2`)에도 성공해 downstream 단일 문서 소비가
  # 깨지므로, 정확히 JSON 값 하나일 때만 parseable로 취급한다 (null/boolean 포함).
  if printf '%s' "$response_body" | jq -es 'length == 1' >/dev/null 2>&1; then
    jq -c . <<<"$response_body"
    return 0
  fi

  local max_chars
  max_chars="$(toss_ledger_raw_response_max_chars)"

  # 응답 원문이 jq argv(ps 노출면)에 오르지 않도록 stdin으로 전달한다.
  printf '%s' "$response_body" | jq -cRs \
    --argjson max "$max_chars" '
      def redact_raw:
        gsub("(?<prefix>authorization:[[:space:]]*bearer[[:space:]]+)[^[:space:]<>\"=,]+"; "\(.prefix)<redacted>"; "i")
        | gsub("(?<prefix>\"?(access[_-]?token|client[_-]?secret|secret|password)\"?[[:space:]]*[:=][[:space:]]*\"?)[^\"&<>,[:space:]]+"; "\(.prefix)<redacted>"; "i");

      (. | redact_raw) as $redacted
      | {
          raw: ($redacted[:$max]),
          parseableJson: false,
          truncated: (($redacted | length) > $max)
        }
    '
}

toss_api_dry_run_output() {
  local method="$1"
  local display_url="$2"
  local metadata="$3"
  local account_seq="$4"
  local body_json="$5"
  local body_provided="$6"
  local redacted_body url_json
  redacted_body="$(jq -c . <<<"$body_json" | toss_ledger_redact_json 2>/dev/null || echo 'null')"
  url_json="$(printf '%s' "$display_url" | jq -Rs .)"

  # display_url은 query가 sanitize된 표시용 URL이다 (실제 요청 URL과 별개).
  # url·body 모두 jq argv(ps 노출면)에 오르지 않도록 stdin JSON stream으로 전달한다.
  printf '%s\n%s\n%s\n' "$metadata" "$redacted_body" "$url_json" | jq -s \
    --arg method "$method" \
    --arg accountSeq "$account_seq" \
    --arg bodyProvided "$body_provided" '
      .[0] as $metadata | .[1] as $body | .[2] as $displayUrl
      | ($bodyProvided == "1") as $hasBody
      | {
        dryRun: true,
        method: $method,
        url: $displayUrl,
        headers: (
          ["Authorization: <redacted>", "Accept: application/json"]
          + (if $accountSeq == "" then [] else ["X-Tossinvest-Account: <redacted>"] end)
          + (if $hasBody then ["Content-Type: application/json"] else [] end)
        ),
        bodyProvided: $hasBody,
        body: (if $hasBody then $body else null end),
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
  local body_provided="$6"
  local response_file="$7"

  local config_file body_file
  body_file=""
  config_file="$(toss_private_tmpfile "toss-api-curl")"
  trap 'rm -f "$config_file"; if [ -n "$body_file" ]; then rm -f "$body_file"; fi' EXIT

  toss_curl_config_append "$config_file" "request" "$method"
  toss_curl_config_append "$config_file" "header" "Authorization: Bearer $token"
  toss_curl_config_append "$config_file" "header" "Accept: application/json"
  toss_curl_config_append "$config_file" "output" "$response_file"
  toss_curl_config_append "$config_file" "dump-header" "$response_file.headers"
  toss_curl_config_append "$config_file" "write-out" "%{http_code}"
  toss_curl_config_append "$config_file" "url" "$url"
  if [ -n "$account_seq" ]; then
    toss_curl_config_append "$config_file" "header" "X-Tossinvest-Account: $account_seq"
  fi
  # 명시적 `--data null`(body_json="null", body_provided=1)과 body 미제공을 구분한다.
  if [ "$body_provided" = "1" ]; then
    body_file="$(toss_private_tmpfile "toss-api-body")"
    toss_write_private_tempfile "$body_file" "$body_json"
    toss_curl_config_append "$config_file" "header" "Content-Type: application/json"
    toss_curl_config_append "$config_file" "data-binary" "@$body_file"
  fi

  local status curl_rc
  set +e
  # -q(첫 인자)는 사용자 기본 .curlrc 개입을, -g는 URL glob({a,b} → 다중 실요청 확장)을 차단한다.
  status="$(curl -q -g -sS --proto =https --max-time "${TOSS_CURL_MAX_TIME_SECONDS:-30}" -K "$config_file")"
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

# 재시도는 같은 요청(주문 mutation 포함)을 재전송하므로, side effect가 이미 반영됐을
# 수 있는 응답에는 절대 트리거되면 안 된다 (이중 주문). vendored OpenAPI는 인증 실패를
# 오직 401 UNAUTHORIZED로만 정의하므로(body code `invalid-token`/`expired-token`),
# 재시도는 **완결된 HTTP 401**로만 좁힌다:
#   - 2xx: side effect 성공 → 재시도 금지
#   - 4xx(≠401)/5xx: 서버가 주문을 반영한 뒤 응답한 경우를 배제할 수 없음 → 재시도 금지
#   - curlExit≠0(전송/연결 실패, http_status가 000/빈값): 서버 도달 후 응답만 유실됐을
#     수 있음 → 재시도 금지 (401 판정은 전송이 완결됐을 때만 의미)
# body code substring 기반 재시도는 이 안전 경계를 넘으므로 사용하지 않는다.
toss_response_is_invalid_token() {
  local http_status="$1"
  local curl_exit="$2"

  [ "$curl_exit" = "0" ] || return 1
  [ "$http_status" = "401" ]
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

  # 요청 전 거부 경로도 토큰/시크릿 출력 금지 계약을 지켜야 하므로, path의 query를
  # sanitize한 값만 출력한다 (?client_secret=... 같은 값이 stderr로 새지 않도록).
  echo "error: toss api does not call Toss auth endpoints: $(toss_ledger_sanitized_path "$path")" >&2
  echo "hint: issue or refresh tokens with 'toss token'" >&2
  return 2
}

# curl은 `/api/../oauth2/token`을 `/oauth2/token`으로 정규화하므로, dot-segment가
# 있으면 metadata unknown + auth guard를 통과해 금지된 token endpoint에 도달할 수 있다.
# 서버측 정규화 여지까지 감안해 입력 단계에서 dot-segment(인코딩 변형 포함)를 거부한다.
toss_api_path_has_dot_segment() {
  local path="$1"
  local path_without_query="${path%%\?*}"
  local lowered
  # %2e(.)·%2f(/) 인코딩 변형을 소문자로 정규화해 함께 검사한다.
  lowered="$(printf '%s' "$path_without_query" | tr '[:upper:]' '[:lower:]')"
  lowered="${lowered//%2e/.}"
  lowered="${lowered//%2f//}"
  case "/$lowered/" in
    */../*|*/./*) return 0 ;;
    *) return 1 ;;
  esac
}

# 한 번의 toss api 호출을 식별하는 correlation ID. response record와 notify record가
# 같은 값을 공유해야 동일 method/path 주문이 동시 실행돼도 어느 주문의 알림 실패인지
# 판별할 수 있다. 감사 흔적 상관용이며 보안 강도를 요구하지 않는다.
toss_new_invocation_id() {
  printf '%s-%s-%s\n' "$(date -u '+%Y%m%dT%H%M%SZ')" "$$" "${RANDOM:-0}${RANDOM:-0}"
}

toss_api_request_context() {
  local method="$1"
  local path="$2"
  local account_seq="$3"
  local metadata="$4"
  local body_json="$5"
  local body_provided="$6"
  local invocation_id="$7"

  # request_context는 ledger/알림 전용이므로 path의 query를 여기서 sanitize한다
  # (실제 요청 URL은 raw path로 별도 구성). body는 jq argv에 오르지 않게 stdin으로.
  local sanitized_path
  sanitized_path="$(toss_ledger_sanitized_path "$path")"

  printf '%s\n%s\n' "$metadata" "$body_json" | jq -cs \
    --arg method "$method" \
    --arg path "$sanitized_path" \
    --arg accountSeq "$account_seq" \
    --arg bodyProvided "$body_provided" \
    --arg invocationId "$invocation_id" '
      {
        invocationId: $invocationId,
        method: $method,
        path: $path,
        accountSeq: (if $accountSeq == "" then null else $accountSeq end),
        metadata: .[0],
        bodyProvided: ($bodyProvided == "1"),
        body: (if $bodyProvided == "1" then .[1] else null end)
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
  local rate_limit_headers="${7:-}"
  local response_body_json

  response_body_json="$(toss_ledger_response_body_json "$response_body")" || {
    response_body_json='{"raw":"<unrecordable response body>","parseableJson":false,"truncated":true}'
  }

  # 요청/응답 문서가 jq argv(ps 노출면)에 오르지 않도록 stdin JSON stream으로 전달한다.
  printf '%s\n%s\n' "$request_context" "$response_body_json" | jq -cs \
    --arg phase "$phase" \
    --arg dryRun "$dry_run" \
    --arg httpStatus "$http_status" \
    --arg curlExit "$curl_exit" \
    --arg rateLimitHeaders "$rate_limit_headers" '
      {
        phase: $phase,
        dryRun: ($dryRun == "1"),
        request: .[0],
        response: {
          httpStatus: (if $httpStatus == "" then null else $httpStatus end),
          curlExit: (if $curlExit == "" then null else ($curlExit | tonumber) end),
          rateLimitHeaders: (if $rateLimitHeaders == "" then null else ($rateLimitHeaders | split("\n")) end),
          body: .[1]
        }
      }
    '
}

toss_record_dry_run_ledger() {
  local request_context="$1"
  local record_input

  record_input="$(toss_ledger_record_input "dry-run" "1" "$request_context" "null")" || {
    toss_ledger_warn_write_failed "build dry-run record input"
    return 0
  }
  toss_ledger_record "$record_input"
}

toss_record_response_ledger() {
  local request_context="$1"
  local response_body="$2"
  local http_status="$3"
  local curl_exit="$4"
  local rate_limit_headers="${5:-}"
  local record_input

  record_input="$(toss_ledger_record_input "response" "0" "$request_context" "$response_body" "$http_status" "$curl_exit" "$rate_limit_headers")" || {
    toss_ledger_warn_write_failed "build response record input"
    return 0
  }
  toss_ledger_record "$record_input"
}

toss_api_handle_dry_run() {
  local requires_order_safeguards="$1"
  local request_context="$2"
  local method path account_seq metadata body_json body_provided display_url

  method="$(jq -r '.method' <<<"$request_context")"
  # context의 path는 이미 query가 sanitize되어 있으므로 dry-run 표시 URL에도
  # raw query secret이 실리지 않는다 (실제 요청 URL은 별도 raw path로 구성).
  path="$(jq -r '.path' <<<"$request_context")"
  account_seq="$(jq -r '.accountSeq // ""' <<<"$request_context")"
  metadata="$(jq -c '.metadata' <<<"$request_context")"
  body_json="$(jq -c '.body' <<<"$request_context")"
  if jq -e '.bodyProvided == true' <<<"$request_context" >/dev/null 2>&1; then
    body_provided=1
  else
    body_provided=0
  fi
  display_url="$TOSS_API_BASE_URL$path"

  toss_api_dry_run_output "$method" "$display_url" "$metadata" "$account_seq" "$body_json" "$body_provided"
  if [ "$requires_order_safeguards" = "1" ]; then
    toss_record_dry_run_ledger "$request_context"
  fi
}

toss_call_with_single_token_retry() {
  local method="$1"
  local url="$2"
  local account_seq="$3"
  local body_json="$4"
  local body_provided="$5"
  local response_file="$6"
  local token call_result http_status curl_exit

  token="$(toss_get_access_token 0)"
  call_result="$(toss_api_call_once "$method" "$url" "$token" "$account_seq" "$body_json" "$body_provided" "$response_file")"
  http_status="$(toss_call_result_http_status "$call_result")"
  curl_exit="$(toss_call_result_curl_exit "$call_result")"

  if toss_response_is_invalid_token "$http_status" "$curl_exit"; then
    # CAS 갱신: 다른 프로세스가 이미 갱신한 token을 재삭제·재발급(상호 무효화)하지 않는다.
    token="$(toss_refresh_token_after_auth_failure "$token")"
    : >"$response_file"
    rm -f "$response_file.headers" 2>/dev/null || true
    call_result="$(toss_api_call_once "$method" "$url" "$token" "$account_seq" "$body_json" "$body_provided" "$response_file")"
  fi

  printf '%s\n' "$call_result"
}

# 운영 가이드(스킬)는 rate-limit 판단의 SoT로 실제 응답 헤더를 지정한다.
# 민감 header 혼입을 막기 위해 X-RateLimit-*와 Retry-After만 whitelist로 선별한다.
toss_rate_limit_headers_from_file() {
  local header_file="$1"
  [ -r "$header_file" ] || return 0
  { grep -iE '^(x-ratelimit-[a-z0-9-]+|retry-after):' "$header_file" 2>/dev/null || true; } | tr -d '\r'
}

toss_emit_rate_limit_headers() {
  local headers="$1"
  [ -n "$headers" ] || return 0
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "toss-rate-limit: $line" >&2
  done <<<"$headers"
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
  local method path account_seq invocation_id

  [ "$requires_order_safeguards" = "1" ] || return 0
  method="$(jq -r '.method' <<<"$request_context")"
  path="$(jq -r '.path' <<<"$request_context")"
  account_seq="$(jq -r '.accountSeq // ""' <<<"$request_context")"
  invocation_id="$(jq -r '.invocationId // ""' <<<"$request_context")"
  toss_notify_safeguarded_api_success "$no_notify" "$method" "$path" "$account_seq" "$http_status" "$invocation_id"
}

toss_api_execute() {
  local method="$1"
  local path="$2"
  local account_arg="$3"
  local body_json="$4"
  local body_provided="$5"
  local dry_run="$6"
  local no_notify="$7"

  # origin-relative 강제: 선행 '/' 없는 PATH는 base URL과 결합 시 userinfo(@) 등으로
  # 호스트가 바뀔 수 있고, curl glob과 결합하면 의도치 않은 다중 요청이 된다.
  case "$path" in
    /*) ;;
    *)
      echo "error: toss api PATH must be origin-relative and start with '/': $(toss_ledger_sanitized_path "$path")" >&2
      return 2
      ;;
  esac

  # 빈 path segment(`//`) 거부: `//oauth2/token`은 origin-relative(`/*`)를 통과하지만
  # auth 판정(`/oauth2/*`)엔 안 맞는데, 서버는 이를 `/oauth2/token`으로 라우팅해 auth guard를
  # 우회한다. 연속 슬래시는 정상 endpoint에 없으므로 fail-closed로 거부한다 (query 앞부분만).
  case "${path%%\?*}" in
    *//*)
      echo "error: toss api PATH must not contain empty '//' segments: $(toss_ledger_sanitized_path "$path")" >&2
      return 2
      ;;
  esac

  # percent-encoding 거부: `/%6fauth2/token`·`/oauth%32/token` 등은 raw 문자열 auth 판정을
  # 통과하지만 서버가 RFC 3986 unreserved 문자를 decode해 실제 token endpoint로 라우팅한다.
  # 공식 endpoints.json path는 모두 percent-encoding이 없으므로, path segment의 '%'를
  # fail-closed로 거부한다 (query의 '%'는 정상이므로 query 앞부분만 검사).
  case "${path%%\?*}" in
    *%*)
      echo "error: toss api PATH must not contain percent-encoding: $(toss_ledger_sanitized_path "$path")" >&2
      return 2
      ;;
  esac

  # dot-segment 거부: curl/서버 정규화로 auth guard를 우회해 token endpoint에 도달하는
  # 경로를 metadata·auth 검사 전에 입력 단계에서 차단한다.
  if toss_api_path_has_dot_segment "$path"; then
    echo "error: toss api PATH must not contain '.'/'..' segments: $(toss_ledger_sanitized_path "$path")" >&2
    return 2
  fi

  local metadata
  metadata="$(toss_metadata_lookup "$method" "$path")"
  if toss_api_is_auth_endpoint "$metadata" "$path"; then
    toss_api_reject_auth_endpoint "$path"
    return 2
  fi

  local requires_order_safeguards account_seq request_context invocation_id
  requires_order_safeguards="$(toss_api_requires_order_safeguards "$metadata")"
  account_seq="$(toss_resolve_account "$metadata" "$account_arg")" || return 1
  invocation_id="$(toss_new_invocation_id)"
  request_context="$(toss_api_request_context "$method" "$path" "$account_seq" "$metadata" "$body_json" "$body_provided" "$invocation_id")"

  # origin 고정은 credential/network 접근과 무관한 문자열 검증이므로 dry-run 앞에서 수행한다
  # — dry-run이 untrusted base로 실제 호출 구성(URL)을 출력하지 않도록, 요청 구성 단계에서
  # 함께 거부한다. Bearer token 전송 전 confused-deputy 차단이자 dry-run 구성 검증이다.
  toss_require_trusted_base_url || return 1

  toss_preflight_network_context "$requires_order_safeguards" "$dry_run" || return 1

  local url="$TOSS_API_BASE_URL$path"
  if [ "$dry_run" = "1" ]; then
    toss_api_handle_dry_run "$requires_order_safeguards" "$request_context"
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

  call_result="$(toss_call_with_single_token_retry "$method" "$url" "$account_seq" "$body_json" "$body_provided" "$response_file")" || {
    rc=$?
    toss_api_tmp_dir_cleanup "$tmp_dir" "$old_exit_trap" "$old_int_trap" "$old_term_trap"
    return "$rc"
  }
  http_status="$(toss_call_result_http_status "$call_result")"
  curl_exit="$(toss_call_result_curl_exit "$call_result")"

  local rate_limit_headers
  rate_limit_headers="$(toss_rate_limit_headers_from_file "$response_file.headers")"
  toss_emit_rate_limit_headers "$rate_limit_headers"

  local response_body
  response_body="$(toss_response_body_or_null "$response_file")"
  if [ "$requires_order_safeguards" = "1" ]; then
    toss_record_response_ledger "$request_context" "$response_body" "$http_status" "$curl_exit" "$rate_limit_headers"
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
  local body_provided=0
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
        body_provided=1
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
  if [ "$body_provided" = "1" ]; then
    body_json="$(toss_validate_json_body "$data_arg")" || {
      echo "error: --data must be exactly one valid JSON value" >&2
      return 2
    }
  fi

  toss_api_execute "$method" "$path" "$account_arg" "$body_json" "$body_provided" "$dry_run" "$no_notify"
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
  response="$(toss_api_execute "GET" "/api/v1/accounts" "" "null" "0" "0" "1")"
  printf '%s\n' "$response"

  local account_seq
  account_seq="$(jq -r '.result[0].accountSeq // empty' <<<"$response" 2>/dev/null || true)"
  if [ -n "$account_seq" ]; then
    toss_write_default_account "$account_seq"
  fi
}
