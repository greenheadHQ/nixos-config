#!/usr/bin/env bash
set -euo pipefail

# 회선 공인 IP는 개인정보이므로 저장소에 하드코딩하지 않는다.
# 자동 비교가 필요하면 로컬에서 TOSS_WHITELIST_IP env로 지정한다 (미설정 시 현재 IP만 표시).
TOSS_WHITELIST_IP="${TOSS_WHITELIST_IP:-}"

toss_darwin_exit_node_on() {
  toss_is_darwin || return 1
  command -v tailscale >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local status_json
  status_json="$(tailscale status --json 2>/dev/null || true)"
  [ -n "$status_json" ] || return 1

  jq -e '
    (.Self.ExitNodeID? // .Self.ExitNode? // "") as $exitNode
    | ($exitNode | type == "string" and length > 0)
  ' <<<"$status_json" >/dev/null 2>&1
}

toss_preflight_network_context() {
  local requires_order_safeguards="$1"
  local dry_run="${2:-0}"

  [ "$dry_run" != "1" ] || return 0
  [ "${TOSS_SKIP_PREFLIGHT:-0}" != "1" ] || return 0
  toss_is_darwin || return 0

  if toss_darwin_exit_node_on; then
    if [ "$requires_order_safeguards" = "1" ]; then
      echo "error: Tailscale exit node appears to be ON; Toss may see a non-whitelisted IP" >&2
      echo "hint: disable the exit node before sending Toss order/unknown API calls" >&2
      return 1
    fi
    echo "warning: Tailscale exit node appears to be ON; Toss may reject by IP whitelist" >&2
  fi
}

toss_doctor_check_exit_node() {
  if ! toss_is_darwin; then
    echo "exit-node: skipped (not macOS)"
    return 0
  fi

  if ! command -v tailscale >/dev/null 2>&1; then
    echo "exit-node: unknown (tailscale command not found)"
    return 0
  fi

  if toss_darwin_exit_node_on; then
    echo "exit-node: warning ON (disable before Toss order calls)"
  else
    echo "exit-node: ok/off-or-unknown"
  fi
}

toss_doctor_check_public_ip() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "public-ip: unknown (curl not found)"
    return 0
  fi

  local ip
  ip="$(curl -fsS --proto =https --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    echo "public-ip: unknown (lookup failed)"
  elif [ -z "$TOSS_WHITELIST_IP" ]; then
    echo "public-ip: $ip (compare with your Toss console whitelist; set TOSS_WHITELIST_IP to auto-verify)"
  elif [ "$ip" = "$TOSS_WHITELIST_IP" ]; then
    echo "public-ip: ok $ip"
  else
    echo "public-ip: warning $ip (expected $TOSS_WHITELIST_IP)"
  fi
}

toss_doctor_check_credentials() {
  if toss_is_darwin; then
    local sa_file="${TOSS_OP_SA_TOKEN_FILE:-$HOME/.config/op/sa-token-mac}"
    if [ -r "$sa_file" ] && command -v op >/dev/null 2>&1; then
      echo "credentials: ok (op + SA token file present)"
    elif [ -r "$sa_file" ]; then
      echo "credentials: warning (SA token present, op command missing)"
    else
      echo "credentials: warning (SA token file not readable)"
    fi
    return 0
  fi

  local user_name="${USER:-$(id -un)}"
  local id_file="${TOSS_CLIENT_ID_FILE:-/run/opnix/$user_name/toss-client-id}"
  local secret_file="${TOSS_CLIENT_SECRET_FILE:-/run/opnix/$user_name/toss-client-secret}"
  if [ -r "$id_file" ] && [ -r "$secret_file" ]; then
    echo "credentials: ok (opnix files readable)"
  else
    echo "credentials: warning (opnix files not readable)"
  fi
}

toss_doctor_check_token_cache() {
  local status
  status="$(toss_token_cache_status 2>/dev/null || echo "unavailable")"
  echo "token-cache: $status"
}

toss_cmd_doctor() {
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help)
        echo "usage: toss doctor"
        return 0
        ;;
      *)
        echo "error: doctor does not accept arguments" >&2
        return 2
        ;;
    esac
  fi

  toss_doctor_check_exit_node
  toss_doctor_check_public_ip
  toss_doctor_check_credentials
  toss_doctor_check_token_cache
}
