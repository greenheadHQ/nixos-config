#!/usr/bin/env bash
set -euo pipefail

# 회선 공인 IP는 개인정보이므로 저장소에 하드코딩하지 않는다.
# 자동 비교가 필요하면 로컬에서 TOSS_WHITELIST_IP env로 지정한다 (미설정 시 현재 IP만 표시).
TOSS_WHITELIST_IP="${TOSS_WHITELIST_IP:-}"

# 공식 tailscale status JSON에서 사용 중인 exit node는 top-level `.ExitNodeStatus`
# (object)로 제공되고, `PeerStatus.ExitNode`는 boolean이다.
# https://github.com/tailscale/tailscale/blob/main/ipn/ipnstate/ipnstate.go
# 반환: 0=ON, 1=OFF, 2=unknown(조회/파싱 실패 — safeguarded 호출은 fail-closed)
toss_darwin_exit_node_state() {
  toss_is_darwin || return 1
  command -v tailscale >/dev/null 2>&1 || return 2
  command -v jq >/dev/null 2>&1 || return 2

  local status_json
  status_json="$(tailscale status --json 2>/dev/null || true)"
  [ -n "$status_json" ] || return 2

  local verdict
  verdict="$(
    jq -r '
      if (.ExitNodeStatus? // null) != null then "on"
      elif (.Self.ExitNode? == true)
        or ([(.Peer? // {})[]? | .ExitNode? == true] | any) then "on"
      else "off"
      end
    ' <<<"$status_json" 2>/dev/null || echo "unknown"
  )"

  case "$verdict" in
    on) return 0 ;;
    off) return 1 ;;
    *) return 2 ;;
  esac
}

toss_preflight_network_context() {
  local requires_order_safeguards="$1"
  local dry_run="${2:-0}"

  [ "$dry_run" != "1" ] || return 0
  [ "${TOSS_SKIP_PREFLIGHT:-0}" != "1" ] || return 0
  toss_is_darwin || return 0

  local state=0
  toss_darwin_exit_node_state || state=$?

  if [ "$state" = "0" ]; then
    if [ "$requires_order_safeguards" = "1" ]; then
      echo "error: Tailscale exit node appears to be ON; Toss may see a non-whitelisted IP" >&2
      echo "hint: disable the exit node before sending Toss order/unknown API calls" >&2
      return 1
    fi
    echo "warning: Tailscale exit node appears to be ON; Toss may reject by IP whitelist" >&2
    return 0
  fi

  if [ "$state" = "2" ] && [ "$requires_order_safeguards" = "1" ]; then
    echo "error: could not determine Tailscale exit-node state; refusing safeguarded Toss call (fail-closed)" >&2
    echo "hint: check 'tailscale status --json', or set TOSS_SKIP_PREFLIGHT=1 to bypass after verifying your egress IP" >&2
    return 1
  fi
}

toss_doctor_check_exit_node() {
  if ! toss_is_darwin; then
    echo "exit-node: skipped (not macOS)"
    return 0
  fi

  local state=0
  toss_darwin_exit_node_state || state=$?
  case "$state" in
    0) echo "exit-node: warning ON (disable before Toss order calls)" ;;
    1) echo "exit-node: ok off" ;;
    *) echo "exit-node: unknown (tailscale status unavailable; safeguarded calls fail closed)" ;;
  esac
}

toss_doctor_check_public_ip() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "public-ip: unknown (curl not found)"
    return 0
  fi

  local ip
  ip="$(curl -q -g -fsS --proto =https --max-time 5 https://api.ipify.org 2>/dev/null || true)"
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

# doctor는 side-effect-free 오프라인 진단만 수행한다. 존재/만료 검사만으로는
# SA revoke·타 호스트 재발급으로 인한 서버측 무효화를 알 수 없으므로,
# 출력 문구는 실제 보장 수준(present / locally-unexpired)까지만 주장한다.
toss_doctor_check_credentials() {
  if toss_is_darwin; then
    local sa_file
    sa_file="$(toss_sa_token_file)"
    if [ -r "$sa_file" ] && command -v op >/dev/null 2>&1; then
      echo "credentials: present (op + SA token file; op access not verified)"
    elif [ -r "$sa_file" ]; then
      echo "credentials: warning (SA token present, op command missing)"
    else
      echo "credentials: warning (SA token file not readable)"
    fi
    return 0
  fi

  local user_name id_file secret_file
  user_name="$(toss_opnix_user_name)"
  id_file="$(toss_opnix_client_id_file "$user_name")"
  secret_file="$(toss_opnix_client_secret_file "$user_name")"
  if [ -r "$id_file" ] && [ -r "$secret_file" ]; then
    echo "credentials: present (opnix files readable)"
  else
    echo "credentials: warning (opnix files not readable)"
  fi
}

toss_doctor_check_token_cache() {
  local status
  status="$(toss_token_cache_status 2>/dev/null || echo "unavailable")"
  if [ "$status" = "valid" ]; then
    echo "token-cache: locally-unexpired (server-side validity not verified)"
  else
    echo "token-cache: $status"
  fi
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
