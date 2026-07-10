# shellcheck shell=bash
# Shared Pushover transport helper.
# Callers decide whether a failed notification is fatal or best-effort.

# curl config 값 quoting. config 파일의 값은 큰따옴표 안에서 백슬래시 이스케이프를
# 해석하므로, 값이 config 지시자를 벗어나 추가 옵션/URL로 해석되지 않도록 escape한다.
# jq를 쓰지 않는 이유: 이 helper의 호출자(smartd, opnix-rotate 등)에 jq 의존을 새로
# 도입하지 않기 위해서다.
_pushover_curl_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

_pushover_config_append() {
  local config_file="$1"
  local option="$2"
  local value="$3"
  printf '%s = %s\n' "$option" "$(_pushover_curl_quote "$value")" >> "$config_file"
}

# token/user/title/message는 curl argv(같은 사용자 `ps` 노출면)에 올리지 않고
# 0600 config 파일로만 전달한다. `-q`는 첫 인자여야 사용자 기본 `.curlrc`의
# proxy/insecure/추가 URL 개입을 차단하고, `-g`는 URL glob 확장을 막는다.
pushover_send() {
  local cred_file="$1"
  local title="$2"
  local message="$3"
  local priority="$4"
  local sound="${5-}"
  local has_sound=0
  local PUSHOVER_TOKEN=""
  local PUSHOVER_USER=""

  [ "$#" -ge 5 ] && has_sound=1

  [ -r "$cred_file" ] || return 1

  # shellcheck source=/dev/null
  if ! source "$cred_file" 2>/dev/null; then
    return 1
  fi

  [ -n "${PUSHOVER_TOKEN:-}" ] || return 1
  [ -n "${PUSHOVER_USER:-}" ] || return 1

  local config_file
  config_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/pushover-curl.XXXXXX")" || return 1
  chmod 600 "$config_file" 2>/dev/null || true

  local rc=0
  (
    trap 'rm -f "$config_file"' EXIT

    _pushover_config_append "$config_file" "form-string" "token=${PUSHOVER_TOKEN}"
    _pushover_config_append "$config_file" "form-string" "user=${PUSHOVER_USER}"
    _pushover_config_append "$config_file" "form-string" "title=${title}"
    _pushover_config_append "$config_file" "form-string" "message=${message}"
    _pushover_config_append "$config_file" "form-string" "priority=${priority}"
    if [ "$has_sound" = "1" ]; then
      _pushover_config_append "$config_file" "form-string" "sound=${sound}"
    fi
    _pushover_config_append "$config_file" "url" "https://api.pushover.net/1/messages.json"

    curl -q -g -sf --proto =https --max-time 10 -K "$config_file" > /dev/null 2>&1
  ) || rc=$?
  return "$rc"
}
