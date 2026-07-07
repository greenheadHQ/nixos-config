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

toss_curl_config_quote() {
  jq -Rn -r --arg value "$1" '$value | @json'
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
