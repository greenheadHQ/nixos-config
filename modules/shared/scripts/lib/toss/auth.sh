#!/usr/bin/env bash
set -euo pipefail

TOSS_API_BASE_URL="${TOSS_API_BASE_URL:-https://openapi.tossinvest.com}"
TOSS_TOKEN_REFRESH_MARGIN_SECONDS="${TOSS_TOKEN_REFRESH_MARGIN_SECONDS:-3600}"
TOSS_TOKEN_LOCK_TIMEOUT_SECONDS="${TOSS_TOKEN_LOCK_TIMEOUT_SECONDS:-30}"
# Home Manager 배포 CLI는 libraries/constants.nix의 onePassword.tossOpenApi에서
# 이 값을 env로 주입한다. 아래 fallback은 repo checkout에서 직접 실행할 때의 기존 동작 보존용이며,
# constants SSOT와 tests/eval-tests.nix 회귀 테스트로 동기화를 강제한다.
TOSS_OP_CLIENT_ID_REF="${TOSS_OP_CLIENT_ID_REF:-op://Automation/토스증권 Open API/자격 증명}"
TOSS_OP_CLIENT_SECRET_REF="${TOSS_OP_CLIENT_SECRET_REF:-op://Automation/토스증권 Open API/Secret Key}"

# Home Manager 배포 CLI는 libraries/constants.nix의
# onePassword.tossOpenApi.opnix*FileName에서 TOSS_CLIENT_*_FILE을 env로 주입한다.
# 아래 fallback은 repo checkout 직접 실행/테스트용 기존 동작 보존 경로다.
toss_opnix_user_name() {
  printf '%s\n' "${USER:-$(id -un)}"
}

toss_opnix_client_id_file() {
  local user_name="${1:-$(toss_opnix_user_name)}"
  printf '%s\n' "${TOSS_CLIENT_ID_FILE:-/run/opnix/$user_name/toss-client-id}"
}

toss_opnix_client_secret_file() {
  local user_name="${1:-$(toss_opnix_user_name)}"
  printf '%s\n' "${TOSS_CLIENT_SECRET_FILE:-/run/opnix/$user_name/toss-client-secret}"
}

toss_is_darwin() {
  [ "$(uname -s)" = "Darwin" ]
}

toss_require_absolute_dir() {
  local dir="$1"
  local what="$2"
  case "$dir" in
    /*) printf '%s\n' "${dir%/}" ;;
    *)
      echo "error: $what is not an absolute path; refusing to store Toss secrets" >&2
      return 1
      ;;
  esac
}

toss_runtime_root() {
  if [ -n "${TOSS_RUNTIME_DIR:-}" ]; then
    toss_require_absolute_dir "$TOSS_RUNTIME_DIR" "TOSS_RUNTIME_DIR"
    return
  fi

  if toss_is_darwin; then
    local tmp
    tmp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    toss_require_absolute_dir "$tmp" "DARWIN_USER_TEMP_DIR"
    return
  fi

  local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  toss_require_absolute_dir "$runtime_dir" "XDG_RUNTIME_DIR"
}

toss_runtime_dir() {
  local root
  root="$(toss_runtime_root)"
  printf '%s/toss\n' "$root"
}

toss_secure_mkdir() {
  local dir="$1"
  ( umask 077; mkdir -p "$dir" )
  chmod 700 "$dir" 2>/dev/null || true
}

toss_write_private_file() {
  local file="$1"
  local content="$2"
  local dir
  dir="$(dirname "$file")"
  toss_secure_mkdir "$dir"

  local tmp
  tmp="$(mktemp "${file}.tmp.XXXXXX")"
  (
    umask 077
    printf '%s' "$content" >"$tmp"
  )
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$file"
  chmod 600 "$file" 2>/dev/null || true
}

toss_token_cache_file() {
  local dir
  dir="$(toss_runtime_dir)"
  printf '%s/token.json\n' "$dir"
}

toss_token_lock_file() {
  local dir
  dir="$(toss_runtime_dir)"
  printf '%s/token.lock\n' "$dir"
}

toss_default_account_file() {
  local dir
  dir="$(toss_runtime_dir)"
  printf '%s/default-account.json\n' "$dir"
}

toss_cached_token_is_valid() {
  local file="$1"
  [ -r "$file" ] || return 1

  local now
  now="$(date +%s)"
  jq -e --argjson now "$now" --argjson margin "$TOSS_TOKEN_REFRESH_MARGIN_SECONDS" '
    (.access_token | type == "string" and length > 0)
    and ((.expires_at // 0) > ($now + $margin))
  ' "$file" >/dev/null
}

toss_read_cached_token() {
  local file
  file="$(toss_token_cache_file)"
  toss_cached_token_is_valid "$file" || return 1
  jq -er '.access_token' "$file"
}

toss_delete_token_cache() {
  local file
  file="$(toss_token_cache_file)"
  rm -f "$file" 2>/dev/null || true
}

toss_read_credentials_from_op() {
  local sa_file="${TOSS_OP_SA_TOKEN_FILE:-$HOME/.config/op/sa-token-mac}"
  if [ ! -r "$sa_file" ]; then
    echo "error: Toss 1Password service-account token file is not readable: $sa_file" >&2
    return 1
  fi
  if ! command -v op >/dev/null 2>&1; then
    echo "error: op CLI not found" >&2
    return 1
  fi

  local sa_token client_id client_secret
  sa_token="$(cat "$sa_file")"
  client_id="$(OP_SERVICE_ACCOUNT_TOKEN="$sa_token" op read --no-newline "$TOSS_OP_CLIENT_ID_REF" 2>/dev/null || true)"
  client_secret="$(OP_SERVICE_ACCOUNT_TOKEN="$sa_token" op read --no-newline "$TOSS_OP_CLIENT_SECRET_REF" 2>/dev/null || true)"

  if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
    echo "error: failed to read Toss client credentials from 1Password" >&2
    return 1
  fi

  printf '%s\n%s\n' "$client_id" "$client_secret"
}

toss_read_credentials_from_opnix() {
  local user_name id_file secret_file
  user_name="$(toss_opnix_user_name)"
  id_file="$(toss_opnix_client_id_file "$user_name")"
  secret_file="$(toss_opnix_client_secret_file "$user_name")"

  if [ ! -r "$id_file" ] || [ ! -r "$secret_file" ]; then
    echo "error: Toss opnix credential files are not readable" >&2
    echo "hint: expected $id_file and $secret_file" >&2
    return 1
  fi

  printf '%s\n%s\n' "$(cat "$id_file")" "$(cat "$secret_file")"
}

toss_read_client_credentials() {
  if toss_is_darwin; then
    toss_read_credentials_from_op
  else
    toss_read_credentials_from_opnix
  fi
}

toss_urlencode() {
  jq -rn --arg value "$1" '$value | @uri'
}

toss_request_access_token() (
  local form_body="$1"
  local body_file config_file
  body_file="$(toss_private_tmpfile "toss-token-body")"
  config_file="$(toss_private_tmpfile "toss-token-curl")"
  trap 'rm -f "$body_file" "$config_file"' EXIT

  toss_write_private_tempfile "$body_file" "$form_body"
  toss_curl_config_append "$config_file" "request" "POST"
  toss_curl_config_append "$config_file" "header" "Content-Type: application/x-www-form-urlencoded"
  toss_curl_config_append "$config_file" "data-binary" "@$body_file"
  toss_curl_config_append "$config_file" "url" "$TOSS_API_BASE_URL/oauth2/token"

  curl -sS --proto =https --max-time 20 -K "$config_file"
)

toss_issue_token_locked() {
  local force="${1:-0}"
  if [ "$force" != "1" ]; then
    toss_read_cached_token && return 0
  fi

  local credentials client_id client_secret
  credentials="$(toss_read_client_credentials)"
  client_id="$(printf '%s\n' "$credentials" | sed -n '1p')"
  client_secret="$(printf '%s\n' "$credentials" | sed -n '2p')"

  local form_body response curl_rc
  form_body="grant_type=client_credentials"
  form_body="${form_body}&client_id=$(toss_urlencode "$client_id")"
  form_body="${form_body}&client_secret=$(toss_urlencode "$client_secret")"

  set +e
  response="$(toss_request_access_token "$form_body")"
  curl_rc=$?
  set -e

  if [ "$curl_rc" -ne 0 ]; then
    echo "error: Toss token request failed" >&2
    return "$curl_rc"
  fi

  local access_token expires_in now expires_at token_json
  access_token="$(jq -er '.access_token | select(type == "string" and length > 0)' <<<"$response")" || {
    echo "error: Toss token response did not contain an access token" >&2
    return 1
  }
  expires_in="$(jq -er '.expires_in | tonumber' <<<"$response")" || {
    echo "error: Toss token response did not contain expires_in" >&2
    return 1
  }
  now="$(date +%s)"
  expires_at=$((now + expires_in))

  token_json="$(
    jq -cn \
      --arg access_token "$access_token" \
      --argjson issued_at "$now" \
      --argjson expires_at "$expires_at" \
      --argjson expires_in "$expires_in" \
      '{
        access_token: $access_token,
        token_type: "Bearer",
        issued_at: $issued_at,
        expires_at: $expires_at,
        expires_in: $expires_in
      }'
  )"

  toss_write_private_file "$(toss_token_cache_file)" "$token_json"
  printf '%s\n' "$access_token"
}

toss_get_access_token() {
  local force="${1:-0}"

  # TOSS_ACCESS_TOKEN is a test/debug shortcut only for non-forced reads; force=1 must refresh via credentials.
  if [ "$force" != "1" ] && [ -n "${TOSS_ACCESS_TOKEN:-}" ]; then
    printf '%s\n' "$TOSS_ACCESS_TOKEN"
    return 0
  fi

  if [ "$force" != "1" ]; then
    toss_read_cached_token && return 0
  fi

  local runtime_dir lock_file
  runtime_dir="$(toss_runtime_dir)"
  toss_secure_mkdir "$runtime_dir"
  lock_file="$(toss_token_lock_file)"
  with_file_lock "$lock_file" "$TOSS_TOKEN_LOCK_TIMEOUT_SECONDS" toss_issue_token_locked "$force"
}

toss_cmd_token() {
  local force=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      -h|--help)
        echo "usage: toss token [--force]"
        return 0
        ;;
      *)
        echo "error: unknown token option: $1" >&2
        return 2
        ;;
    esac
  done

  toss_get_access_token "$force" >/dev/null
  if [ "$force" != "1" ] && [ -n "${TOSS_ACCESS_TOKEN:-}" ]; then
    echo "token ready (TOSS_ACCESS_TOKEN override)"
  elif [ "$force" = "1" ]; then
    echo "token ready (refreshed)"
  else
    echo "token ready"
  fi
}

toss_read_default_account() {
  local file
  file="$(toss_default_account_file)"
  [ -r "$file" ] || return 1
  jq -er '.accountSeq | tostring | select(length > 0)' "$file"
}

toss_write_default_account() {
  local account_seq="$1"
  local now
  now="$(date +%s)"
  local content
  content="$(
    jq -cn \
      --arg accountSeq "$account_seq" \
      --argjson cachedAt "$now" \
      '{accountSeq: $accountSeq, cachedAt: $cachedAt}'
  )"
  toss_write_private_file "$(toss_default_account_file)" "$content"
}

toss_token_cache_status() {
  local file
  file="$(toss_token_cache_file)"
  if [ ! -f "$file" ]; then
    echo "missing"
  elif toss_cached_token_is_valid "$file"; then
    echo "valid"
  else
    echo "stale"
  fi
}
