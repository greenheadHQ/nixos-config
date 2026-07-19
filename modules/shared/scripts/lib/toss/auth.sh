#!/usr/bin/env bash
set -euo pipefail

TOSS_TOKEN_REFRESH_MARGIN_SECONDS="${TOSS_TOKEN_REFRESH_MARGIN_SECONDS:-3600}"
TOSS_TOKEN_LOCK_TIMEOUT_SECONDS="${TOSS_TOKEN_LOCK_TIMEOUT_SECONDS:-30}"

# confused-deputy 방지: 이 CLI는 LLM에 1Password credential authority를 위임하는 경로다.
# TOSS_API_BASE_URL은 ambient env로 override 가능하므로, 검증 없이는 caller가 destination만
# 정해 client secret/access token(bearer)을 임의 host로 빼돌릴 수 있다(--proto =https는 scheme만
# 제한, host는 pin 안 함). credential/token을 전송하는 모든 경로 진입 전에 base URL을 공식
# origin과 **정확히 일치**시킨다 — host-only 비교는 `.../oauth2` 같은 path 접미사를 허용해
# raw PATH `/token`이 `/oauth2/token`으로 합성되고, escape hatch는 같은 ambient caller가
# pin을 해제하는 우회로가 되므로 둘 다 두지 않는다. 테스트는 curl stub이라 비공식 origin이
# 필요 없으므로 모두 이 공식 base URL을 쓴다.
# 공식 origin literal은 여기 한 곳에서만 정의하고 TOSS_API_BASE_URL 기본값을 여기서
# 파생한다 (중복 정의 시 origin 변경 때 한쪽만 갱신되면 기본 invocation이 스스로 거부됨).
TOSS_TRUSTED_API_BASE_URL="https://openapi.tossinvest.com"
TOSS_API_BASE_URL="${TOSS_API_BASE_URL:-$TOSS_TRUSTED_API_BASE_URL}"

toss_require_trusted_base_url() {
  if [ "$TOSS_API_BASE_URL" != "$TOSS_TRUSTED_API_BASE_URL" ]; then
    echo "error: TOSS_API_BASE_URL must be exactly the official Toss origin ($TOSS_TRUSTED_API_BASE_URL)" >&2
    echo "hint: credential/token transmission is pinned to the official origin; base URL override is not permitted" >&2
    return 1
  fi
}
# Home Manager 배포 CLI는 libraries/constants.nix의 onePassword.tossOpenApi에서
# 이 값을 env로 주입한다. 아래 fallback은 repo checkout에서 직접 실행할 때의 기존 동작 보존용이며,
# constants SSOT와 tests/eval-tests.nix 회귀 테스트로 동기화를 강제한다.
TOSS_OP_CLIENT_ID_REF="${TOSS_OP_CLIENT_ID_REF:-op://Automation/토스증권 Open API/자격 증명}"
TOSS_OP_CLIENT_SECRET_REF="${TOSS_OP_CLIENT_SECRET_REF:-op://Automation/토스증권 Open API/Secret Key}"

# Home Manager 배포 CLI는 libraries/constants.nix의
# onePassword.tossOpenApi.opnix*FileName + paths.opnixRuntimeRoot에서 TOSS_CLIENT_*_FILE을
# env로 주입한다. 아래 fallback은 repo checkout 직접 실행/doctor용 기존 동작 보존 경로이며,
# constants SoT(opnixRuntimeRoot + filename)와의 동기화는 tests/eval-tests.nix(Test 5b-3c)가
# 강제한다 — root/filename 변경 시 이 fallback도 함께 갱신하지 않으면 eval-tests가 실패한다.
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

# Mac SA token 파일 경로. 실제 producer는 secrets/default.nix의
# `${config.xdg.configHome}/op/sa-token-mac`이며 배포 wrapper가 그 값을 TOSS_OP_SA_TOKEN_FILE로
# 주입한다. repo-direct/doctor fallback은 XDG_CONFIG_HOME을 반영해 producer와 동기화한다
# (auth·doctor 공통 helper로 경로 SoT 중복 제거).
toss_sa_token_file() {
  printf '%s\n' "${TOSS_OP_SA_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/op/sa-token-mac}"
}

toss_read_credentials_from_op() {
  local sa_file
  sa_file="$(toss_sa_token_file)"
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
  # op는 OP_CONNECT_HOST/TOKEN을 SA token보다 우선 적용하므로, 잔존 Connect env(원격/LLM
  # 셸 오염 또는 opnix systemd env)가 있으면 SA 조회가 의도와 다른 backend로 가거나 실패한다.
  # 이 repo는 Connect 서버 미도입이라 Connect env는 항상 오염 — 각 op read를 unset 서브셸로
  # 격리한다 (main op_get의 SA 경로 계약과 동형, managing-secrets 1password.md 참조).
  client_id="$( (unset OP_CONNECT_HOST OP_CONNECT_TOKEN; env OP_SERVICE_ACCOUNT_TOKEN="$sa_token" op read --no-newline "$TOSS_OP_CLIENT_ID_REF") 2>/dev/null || true )"
  client_secret="$( (unset OP_CONNECT_HOST OP_CONNECT_TOKEN; env OP_SERVICE_ACCOUNT_TOKEN="$sa_token" op read --no-newline "$TOSS_OP_CLIENT_SECRET_REF") 2>/dev/null || true )"

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
  # client_secret이 jq argv(ps 노출면)에 오르지 않도록 stdin으로 전달한다.
  printf '%s' "$1" | jq -Rs -r '@uri'
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

  # -q는 첫 인자여야 사용자 기본 .curlrc(proxy/insecure/추가 url 등)를 차단한다.
  curl -q -g -sS --proto =https --max-time 20 -K "$config_file"
)

toss_issue_token_locked() {
  local force="${1:-0}"
  if [ "$force" != "1" ]; then
    toss_read_cached_token && return 0
  fi

  # client secret을 전송하기 전에 origin을 공식 호스트로 고정한다 (confused-deputy 차단).
  toss_require_trusted_base_url || return 1

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

  # access token은 jq argv(ps 노출면)에 오르지 않도록 stdin으로 전달한다.
  token_json="$(
    printf '%s' "$access_token" | jq -cRs \
      --argjson issued_at "$now" \
      --argjson expires_at "$expires_at" \
      --argjson expires_in "$expires_in" \
      '{
        access_token: .,
        token_type: "Bearer",
        issued_at: $issued_at,
        expires_at: $expires_at,
        expires_in: $expires_in
      }'
  )"

  toss_write_private_file "$(toss_token_cache_file)" "$token_json"
  printf '%s\n' "$access_token"
}

# 401 이후 token 갱신 CAS: Toss는 client당 유효 token이 하나뿐이라(재발급 시 기존 무효화)
# 동시 401 처리에서 무조건 delete+재발급하면 다른 프로세스가 방금 갱신한 token을 다시
# 무효화하는 ping-pong이 생긴다. lock 안에서 "실패한 token == 현재 cache token"일 때만
# 재발급하고, 이미 다른 token으로 갱신돼 있으면 그 token을 재사용한다.
# 호스트 간(Mac/MiniPC) 동시성은 lock을 공유하지 않아 이 CAS 밖이며, MiniPC 활성화(#1044) 시
# 별도 client 분리로 다룬다.
toss_refresh_token_cas_locked() {
  local failed_token="$1"
  local cached
  cached="$(toss_read_cached_token 2>/dev/null || true)"
  if [ -n "$cached" ] && [ "$cached" != "$failed_token" ]; then
    printf '%s\n' "$cached"
    return 0
  fi
  toss_delete_token_cache
  toss_issue_token_locked 1
}

toss_refresh_token_after_auth_failure() {
  local failed_token="$1"
  local runtime_dir lock_file
  runtime_dir="$(toss_runtime_dir)"
  toss_secure_mkdir "$runtime_dir"
  lock_file="$(toss_token_lock_file)"
  with_file_lock "$lock_file" "$TOSS_TOKEN_LOCK_TIMEOUT_SECONDS" toss_refresh_token_cas_locked "$failed_token"
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
    printf '%s' "$account_seq" | jq -cRs \
      --argjson cachedAt "$now" \
      '{accountSeq: ., cachedAt: $cachedAt}'
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
