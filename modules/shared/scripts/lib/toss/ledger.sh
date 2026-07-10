#!/usr/bin/env bash
set -euo pipefail

toss_ledger_warn_write_failed() {
  local reason="$1"
  echo "warning: toss ledger write failed ($reason); audit entry not recorded" >&2
}

toss_state_root() {
  local state_dir="${TOSS_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}}"
  case "$state_dir" in
    /*) printf '%s\n' "${state_dir%/}" ;;
    *)
      echo "error: TOSS_STATE_DIR/XDG_STATE_HOME must be absolute for ledger writes" >&2
      return 1
      ;;
  esac
}

toss_ledger_file() {
  if [ -n "${TOSS_LEDGER_FILE:-}" ]; then
    printf '%s\n' "$TOSS_LEDGER_FILE"
    return 0
  fi

  local state_root
  state_root="$(toss_state_root)" || return 1
  printf '%s/toss/orders.jsonl\n' "$state_root"
}

# 디렉터리만 lock 밖에서 준비한다. 파일 생성은 lock 안 append(`>>`)가 담당 —
# `[ ! -e ] && : >` 방식은 동시 최초 기록에서 늦은 프로세스가 앞선 레코드를
# truncate하는 TOCTOU가 있었다. `>>`는 truncate 없이 umask 077로 생성한다.
toss_ledger_prepare() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  ( umask 077; mkdir -p "$dir" ) || return 1
  chmod 700 "$dir" 2>/dev/null || true
}

# ledger·알림 등 기록/전파 경로에 남기는 요청 path에서 query string을 제거한다.
# query에 민감값(access_token 등)이 오면 body/response redactor와 무관하게
# 평문 전파되므로, 존재 여부만 <redacted> 마커로 남긴다.
toss_ledger_sanitized_path() {
  local path="$1"
  local base="${path%%\?*}"
  if [ "$base" = "$path" ]; then
    printf '%s\n' "$path"
  else
    printf '%s?<redacted>\n' "$base"
  fi
}

toss_ledger_redact_json() {
  jq -c '
    def redact_raw_string:
      gsub("(?<prefix>authorization:[[:space:]]*bearer[[:space:]]+)[^[:space:]<>\"=,]+"; "\(.prefix)<redacted>"; "i")
      | gsub("(?<prefix>authorization[[:space:]]*=[[:space:]]*\"?bearer[[:space:]]+)[^\"&<>,[:space:]]+"; "\(.prefix)<redacted>"; "i")
      | gsub("(?<prefix>\"?(access[_-]?token|client[_-]?secret|secret|password)\"?[[:space:]]*[:=][[:space:]]*\"?)[^\"&<>,[:space:]]+"; "\(.prefix)<redacted>"; "i");

    def redact:
      if type == "object" then
        with_entries(
          if (.key | test("authorization|access[_-]?token|client[_-]?secret|secret|password"; "i")) then
            .value = "<redacted>"
          else
            .value |= redact
          end
        )
      elif type == "array" then
        map(redact)
      elif type == "string" then
        redact_raw_string
      else
        .
      end;
    redact
  '
}

toss_ledger_build_record() {
  local input="$1"

  local now request_json response_json
  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  request_json="$(jq -c '.request.body // null' <<<"$input" | toss_ledger_redact_json 2>/dev/null || echo 'null')"
  response_json="$(jq -c '.response.body // null' <<<"$input" | toss_ledger_redact_json 2>/dev/null || echo 'null')"

  # 주문 body/응답이 jq argv(ps 노출면)에 오르지 않도록 stdin JSON stream으로 전달한다.
  printf '%s\n%s\n%s\n' "$input" "$request_json" "$response_json" | jq -cs \
    --arg ts "$now" '
      .[0] as $input | .[1] as $request | .[2] as $response_body
      | {
        timestamp: $ts,
        phase: $input.phase,
        dryRun: ($input.dryRun == true),
        request: {
          method: $input.request.method,
          path: $input.request.path,
          accountSeq: $input.request.accountSeq,
          metadataStatus: $input.request.metadata.metadataStatus,
          matchedPath: $input.request.metadata.matchedPath,
          operationId: $input.request.metadata.operationId,
          requiresOrderSafeguards: $input.request.metadata.requiresOrderSafeguards,
          body: $request
        },
        response: {
          httpStatus: $input.response.httpStatus,
          curlExit: (
            $input.response.curlExit as $curlExit
            | if $curlExit == null or $curlExit == "" then null
              elif ($curlExit | type) == "number" then $curlExit
              else ($curlExit | tonumber)
              end
          ),
          rateLimitHeaders: ($input.response.rateLimitHeaders // null),
          body: $response_body
        }
      }
    '
}

# 안전장치 대상 호출의 성공 알림(보상 통제) 결과를 원장에 남긴다.
# 알림 실패가 조용히 유실되면 운영자가 미전송을 모르므로 sent/failed-*를 기록한다.
toss_ledger_record_notification() {
  local method="$1"
  local path="$2"
  local status="$3"
  local now record

  now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  record="$(
    jq -cn \
      --arg ts "$now" \
      --arg method "$method" \
      --arg path "$path" \
      --arg status "$status" \
      '{timestamp: $ts, phase: "notify", notificationStatus: $status, request: {method: $method, path: $path}}'
  )" || {
    toss_ledger_warn_write_failed "build notification record"
    return 0
  }
  toss_ledger_append_record "$record"
}

toss_ledger_append_unlocked() {
  local file="$1"
  local line="$2"
  ( umask 077; printf '%s\n' "$line" >>"$file" ) || return 1
  chmod 600 "$file" 2>/dev/null || true
}

toss_ledger_append_record() {
  local record="$1"
  local file lock_file
  file="$(toss_ledger_file)" || { toss_ledger_warn_write_failed "resolve ledger file"; return 0; }
  toss_ledger_prepare "$file" || { toss_ledger_warn_write_failed "prepare ledger file"; return 0; }
  lock_file="${file}.lock"
  with_file_lock "$lock_file" "${TOSS_LEDGER_LOCK_TIMEOUT_SECONDS:-5}" toss_ledger_append_unlocked "$file" "$record" || {
    toss_ledger_warn_write_failed "append with file lock"
    return 0
  }
}

toss_ledger_record() {
  local input="$1"

  local record

  record="$(toss_ledger_build_record "$input")" || { toss_ledger_warn_write_failed "build ledger record"; return 0; }

  toss_ledger_append_record "$record"
}
