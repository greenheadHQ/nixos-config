#!@bashBin@
# shellcheck shell=bash
set -euo pipefail

# shellcheck source=/dev/null
source "@runtimeLibrary@"
CLAUDEX_SERVICE_NAME="@serviceName@"
CLAUDEX_PROXY_BIN="@proxyBin@"

json=false
case "$#" in
  0) ;;
  1)
    [ "$1" = --json ] || { echo "usage: claudex status [--json]" >&2; exit 2; }
    json=true
    ;;
  *)
    echo "usage: claudex status [--json]" >&2
    exit 2
    ;;
esac

service_state="unregistered"
auth_state="missing"
proxy_state="stopped"
readiness_state="unreachable"
catalog_state="unavailable"
generation_state="unknown"
reason="proxy가 중지되어 있습니다"
next_command="claudex"

if [ "$CLAUDEX_PLATFORM" = darwin ]; then
  if "$CLAUDEX_LAUNCHCTL" print "gui/$($CLAUDEX_ID -u)/$CLAUDEX_LABEL" >/dev/null 2>&1; then
    service_state="registered"
  fi
else
  load_state="$("$CLAUDEX_SYSTEMCTL" --user show "$CLAUDEX_SERVICE_NAME" \
    --property LoadState --value 2>/dev/null || true)"
  [ "$load_state" != loaded ] || service_state="registered"
fi

if [ -d "$CLAUDEX_AUTH_DIR" ] && [ ! -L "$CLAUDEX_AUTH_DIR" ]; then
  count="$(credential_count 2>/dev/null || printf 'invalid')"
  if [ "$count" != "0" ]; then
    if assert_credential_set "$CLAUDEX_AUTH_DIR" default >/dev/null 2>&1; then
      auth_state="ready"
    else
      auth_state="invalid"
    fi
  fi
fi

snapshot=""
if snapshot="$(_claudex_gate_inspect 2>/dev/null)"; then
  mode="$("$CLAUDEX_JQ" -r '.mode // empty' <<< "$snapshot")"
  gate_state="$("$CLAUDEX_JQ" -r '.state // empty' <<< "$snapshot")"
  gate_generation="$("$CLAUDEX_JQ" -r '.generation // empty' <<< "$snapshot")"
  identity_ok=false
  if [ "$gate_generation" = "$CLAUDEX_GENERATION" ]; then
    generation_state="current"
  else
    generation_state="outdated"
    proxy_state="outdated"
    reason="실행 중인 proxy가 이전 Nix generation입니다"
    next_command="claudex proxy restart"
  fi
  if [ "$mode" = managed ]; then
    if _claudex_managed_snapshot_owned \
      "$snapshot" "$CLAUDEX_SERVICE_NAME" "$CLAUDEX_GATE_BIN" "$CLAUDEX_PROXY_BIN"; then
      identity_ok=true
    else
      proxy_state="unknown"
      reason="managed proxy의 service identity를 확인할 수 없습니다"
      next_command="상태를 공유하고 수동 확인"
    fi
  elif [ "$mode" = foreground ]; then
    if [ "$generation_state" = current ] \
      && _claudex_snapshot_executables_current \
        "$snapshot" "$CLAUDEX_GATE_BIN" "$CLAUDEX_PROXY_BIN"; then
      identity_ok=true
    elif [ "$generation_state" = outdated ] \
      && _claudex_snapshot_executables_pinned "$snapshot"; then
      identity_ok=true
      next_command="실행 중인 터미널에서 Ctrl-C 후 다시 실행"
    else
      proxy_state="unknown"
      reason="foreground proxy의 executable identity를 확인할 수 없습니다"
      next_command="실행 중인 터미널에서 Ctrl-C 후 다시 실행"
    fi
  else
    proxy_state="unknown"
    reason="proxy mode를 확인할 수 없습니다"
    next_command="상태를 공유하고 수동 확인"
  fi
  if [ "$identity_ok" = true ] && [ "$generation_state" = current ]; then
    if [ "$gate_state" != open ] || { [ "$mode" != managed ] && [ "$mode" != foreground ]; }; then
      proxy_state="unhealthy"
      case "$gate_state" in
        starting | draining | stopping)
          reason="proxy 상태 전환이 진행 중입니다. 잠시 후 다시 확인하세요"
          next_command="claudex status"
          ;;
        *)
          reason="proxy process는 있지만 상태를 안전하게 자동 복구할 수 없습니다"
          next_command="상태를 공유하고 수동 확인"
          ;;
      esac
    elif payload="$(curl_loopback /v1/models 2>/dev/null)"; then
      if "$CLAUDEX_JQ" -e '.data | type == "array"' <<< "$payload" >/dev/null 2>&1; then
        proxy_state="ready"
        readiness_state="ready"
        if "$CLAUDEX_JQ" -e --arg model "$CLAUDEX_DEFAULT_MAIN_MODEL" \
          '.data | any(.id == $model)' <<< "$payload" >/dev/null 2>&1; then
          catalog_state="ready"
          reason="로컬 proxy와 모델 catalog가 준비됐습니다"
          next_command="claudex"
        else
          catalog_state="missing"
          reason="기본 모델이 proxy catalog에 없습니다"
          next_command="claudex proxy restart"
        fi
      else
        proxy_state="unhealthy"
        readiness_state="invalid"
        catalog_state="invalid"
        reason="proxy readiness 응답 형식이 올바르지 않습니다"
        next_command="claudex proxy restart"
      fi
    else
      proxy_state="unhealthy"
      reason="proxy가 readiness 요청에 응답하지 않습니다"
      next_command="claudex proxy restart"
    fi
  fi
elif [ -e "$CLAUDEX_CONTROL_SOCKET" ] || [ -L "$CLAUDEX_CONTROL_SOCKET" ]; then
  proxy_state="unknown"
  reason="control socket의 identity를 확인할 수 없습니다"
  next_command="상태를 공유하고 수동 확인"
elif _claudex_loopback_responding 2>/dev/null; then
  proxy_state="foreign"
  reason="$CLAUDEX_PORT 포트가 응답하지만 Claudex가 관리하는 process가 아닙니다"
  next_command="해당 process를 확인한 뒤 다시 실행"
fi

if [ "$auth_state" = missing ]; then
  reason="Codex 인증 파일이 없습니다"
  next_command="claudex login"
elif [ "$auth_state" = invalid ]; then
  reason="인증 파일 구조가 올바르지 않습니다"
  next_command="상태 출력을 공유하고 인증 파일을 확인"
fi

overall="not_ready"
if [ "$auth_state" = ready ] && [ "$proxy_state" = ready ] && [ "$catalog_state" = ready ]; then
  overall="ready"
fi

if [ "$json" = true ]; then
  "$CLAUDEX_JQ" -n \
    --arg overall "$overall" \
    --arg auth "$auth_state" \
    --arg proxy "$proxy_state" \
    --arg service "$service_state" \
    --arg readiness "$readiness_state" \
    --arg catalog "$catalog_state" \
    --arg generation "$generation_state" \
    --arg reason "$reason" \
    --arg nextCommand "$next_command" \
    '{
      schema: 1,
      overall: $overall,
      auth: $auth,
      auth_live_validity: "unchecked",
      proxy: $proxy,
      service: $service,
      readiness: $readiness,
      catalog: $catalog,
      generation: $generation,
      reason: $reason,
      next_command: $nextCommand
    }'
else
  if [ "$overall" = ready ]; then
    echo "전체 상태: 준비됨"
  else
    echo "전체 상태: 조치 필요"
  fi
  echo "인증 파일: $auth_state (upstream 실제 유효성은 확인하지 않음)"
  echo "proxy: $proxy_state"
  echo "서비스: $service_state"
  echo "readiness: $readiness_state"
  echo "catalog: $catalog_state"
  echo "generation: $generation_state"
  echo "이유: $reason"
  echo "다음 명령: $next_command"
fi

[ "$overall" = ready ]
