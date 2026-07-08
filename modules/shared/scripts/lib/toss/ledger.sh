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

toss_ledger_prepare() {
  local file="$1"
  local dir
  dir="$(dirname "$file")"
  ( umask 077; mkdir -p "$dir" ) || return 1
  chmod 700 "$dir" 2>/dev/null || true
  if [ ! -e "$file" ]; then
    ( umask 077; : >"$file" ) || return 1
  fi
  chmod 600 "$file" 2>/dev/null || true
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

  jq -cn \
    --arg ts "$now" \
    --argjson input "$input" \
    --argjson request "$request_json" \
    --argjson response_body "$response_json" '
      {
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
          body: $response_body
        }
      }
    '
}

toss_ledger_append_unlocked() {
  local file="$1"
  local line="$2"
  printf '%s\n' "$line" >>"$file"
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
