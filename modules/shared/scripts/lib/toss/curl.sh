#!/usr/bin/env bash
set -euo pipefail

toss_private_tmpfile() {
  local prefix="${1:-toss-private}"
  local tmp_root="${TMPDIR:-/tmp}"
  case "$tmp_root" in
    /*) ;;
    *) tmp_root="/tmp" ;;
  esac

  ( umask 077; mktemp "${tmp_root%/}/${prefix}.XXXXXX" )
}

toss_write_private_tempfile() {
  local file="$1"
  local content="$2"

  (
    umask 077
    printf '%s' "$content" >"$file"
  )
  chmod 600 "$file" 2>/dev/null || true
}

# 민감값(Authorization 헤더 등)이 외부 프로세스 argv(ps 노출면)에 오르지 않도록
# jq에는 stdin으로만 전달한다. shell 함수 인자는 프로세스 argv가 아니므로 안전.
toss_curl_config_quote() {
  printf '%s' "$1" | jq -Rs -r '@json'
}

toss_curl_config_append() {
  local config_file="$1"
  local option="$2"
  local value="$3"
  local quoted_value

  quoted_value="$(toss_curl_config_quote "$value")"
  printf '%s = %s\n' "$option" "$quoted_value" >>"$config_file"
  chmod 600 "$config_file" 2>/dev/null || true
}
