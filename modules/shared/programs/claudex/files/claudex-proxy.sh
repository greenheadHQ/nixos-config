#!@bashBin@
# shellcheck shell=bash
set -euo pipefail
umask 077

# shellcheck source=/dev/null
source "@runtimeLibrary@"

CLAUDEX_PROXY_LAUNCHER="@proxyLauncher@"
CLAUDEX_LAUNCHD_PLIST="@launchdPlist@"
CLAUDEX_SERVICE_NAME="@serviceName@"
CLAUDEX_STATUS_HANDLER="@statusHandler@"
CLAUDEX_TAIL="@tailBin@"
CLAUDEX_GRACEFUL_DRAIN_SECONDS="@gracefulDrainSeconds@"

proxy_usage() {
  cat <<'EOF'
사용법:
  claudex proxy
  claudex proxy start
  claudex proxy stop [--force]
  claudex proxy restart [--force]
  claudex proxy foreground
  claudex proxy logs [-f]
EOF
}

_claudex_manager_registered() {
  [ "$CLAUDEX_PLATFORM" = darwin ] || return 1
  "$CLAUDEX_LAUNCHCTL" print "gui/$($CLAUDEX_ID -u)/$CLAUDEX_LABEL" >/dev/null 2>&1
}

_claudex_manager_start() {
  if [ "$CLAUDEX_PLATFORM" = darwin ]; then
    domain="gui/$($CLAUDEX_ID -u)"
    # A private launchd definition survives a clean process exit. Replace any inactive
    # registration before starting so a Nix generation change cannot kickstart stale
    # ProgramArguments. The lifecycle caller has already proved that no owned gate is live.
    if _claudex_manager_registered; then
      "$CLAUDEX_LAUNCHCTL" bootout "$domain/$CLAUDEX_LABEL"
    fi
    "$CLAUDEX_LAUNCHCTL" bootstrap "$domain" "$CLAUDEX_LAUNCHD_PLIST"
    "$CLAUDEX_LAUNCHCTL" kickstart "$domain/$CLAUDEX_LABEL"
  else
    "$CLAUDEX_SYSTEMCTL" --user start "$CLAUDEX_SERVICE_NAME"
  fi
}

_claudex_manager_stop() {
  if [ "$CLAUDEX_PLATFORM" = darwin ]; then
    if _claudex_manager_registered; then
      "$CLAUDEX_LAUNCHCTL" bootout "gui/$($CLAUDEX_ID -u)/$CLAUDEX_LABEL"
    fi
  else
    "$CLAUDEX_SYSTEMCTL" --user stop "$CLAUDEX_SERVICE_NAME"
  fi
}

_claudex_wait_for_gate() {
  local attempt snapshot
  for ((attempt = 0; attempt < CLAUDEX_READY_ATTEMPTS; attempt++)); do
    if snapshot="$(_claudex_gate_inspect 2>/dev/null)" \
      && "$CLAUDEX_JQ" -e --arg generation "$CLAUDEX_GENERATION" '
        .generation == $generation and .state == "open"
      ' <<< "$snapshot" >/dev/null 2>&1; then
      wait_for_proxy_ready
      return
    fi
    "$CLAUDEX_SLEEP" "$CLAUDEX_READY_DELAY_SECONDS"
  done
  _claudex_error "managed proxy did not become ready"
  return 1
}

_claudex_start_stopped_locked() {
  prepare_state
  assert_credential_set "$CLAUDEX_AUTH_DIR" default
  echo "claudex: proxy를 시작하는 중입니다..." >&2
  _claudex_manager_start
  _claudex_wait_for_gate
}

_claudex_ensure_locked() {
  local snapshot mode state generation instance
  if snapshot="$(_claudex_gate_inspect 2>/dev/null)"; then
    mode="$("$CLAUDEX_JQ" -r '.mode' <<< "$snapshot")"
    state="$("$CLAUDEX_JQ" -r '.state' <<< "$snapshot")"
    generation="$("$CLAUDEX_JQ" -r '.generation' <<< "$snapshot")"
    instance="$("$CLAUDEX_JQ" -r '.instance' <<< "$snapshot")"
    if [ "$mode" = foreground ]; then
      if [ "$state" = open ] && [ "$generation" = "$CLAUDEX_GENERATION" ]; then
        wait_for_proxy_ready
        return
      fi
      _claudex_error "foreground proxy가 오래됐거나 준비되지 않았습니다. 실행 중인 터미널에서 Ctrl-C 후 다시 시도하세요"
      return 1
    fi
    if [ "$mode" != managed ]; then
      _claudex_error "unknown proxy mode"
      return 1
    fi
    if [ "$state" = open ] && [ "$generation" = "$CLAUDEX_GENERATION" ]; then
      wait_for_proxy_ready
      return
    fi
    if [ "$state" = open ] && [ "$generation" != "$CLAUDEX_GENERATION" ]; then
      if ! "$CLAUDEX_GATE_BIN" control drain-stop \
        --socket "$CLAUDEX_CONTROL_SOCKET" \
        --instance "$instance" \
        --generation "$generation" \
        --timeout-seconds "$CLAUDEX_GRACEFUL_DRAIN_SECONDS" >/dev/null 2>&1; then
        echo "claudex: 사용 중인 기존 proxy는 유지하고 갱신을 다음 세션으로 미룹니다" >&2
        return
      fi
      _claudex_manager_stop
      _claudex_start_stopped_locked
      return
    fi
    _claudex_error "proxy 상태를 안전하게 자동 복구할 수 없습니다: $state"
    return 1
  fi

  if [ -e "$CLAUDEX_CONTROL_SOCKET" ] || [ -L "$CLAUDEX_CONTROL_SOCKET" ]; then
    _claudex_error "proxy control socket의 소유 상태를 확인할 수 없습니다"
    return 1
  fi
  if _claudex_loopback_responding 2>/dev/null; then
    _claudex_error "8317 포트를 알 수 없는 process가 사용 중입니다"
    return 1
  fi
  _claudex_start_stopped_locked
}

_claudex_stop_locked() {
  local force="$1" snapshot mode state generation instance
  if ! snapshot="$(_claudex_gate_inspect 2>/dev/null)"; then
    if [ -e "$CLAUDEX_CONTROL_SOCKET" ] || [ -L "$CLAUDEX_CONTROL_SOCKET" ] \
      || _claudex_loopback_responding 2>/dev/null; then
      _claudex_error "proxy identity를 확인할 수 없어 중지하지 않았습니다"
      return 1
    fi
    _claudex_manager_stop
    echo "claudex: proxy는 이미 중지되어 있습니다" >&2
    return
  fi
  mode="$("$CLAUDEX_JQ" -r '.mode' <<< "$snapshot")"
  state="$("$CLAUDEX_JQ" -r '.state' <<< "$snapshot")"
  generation="$("$CLAUDEX_JQ" -r '.generation' <<< "$snapshot")"
  instance="$("$CLAUDEX_JQ" -r '.instance' <<< "$snapshot")"
  if [ "$mode" = foreground ]; then
    _claudex_error "foreground proxy는 실행 중인 터미널에서 Ctrl-C로 중지하세요"
    return 1
  fi
  if [ "$mode" != managed ] || [ "$state" != open ]; then
    _claudex_error "proxy 상태를 안전하게 중지할 수 없습니다: $state"
    return 1
  fi
  args=(
    control drain-stop
    --socket "$CLAUDEX_CONTROL_SOCKET"
    --instance "$instance"
    --generation "$generation"
    --timeout-seconds 0
  )
  [ "$force" = false ] || args+=(--force)
  "$CLAUDEX_GATE_BIN" "${args[@]}" >/dev/null
  _claudex_manager_stop
  echo "claudex: proxy를 중지했습니다" >&2
}

_claudex_restart_locked() {
  local force="$1"
  _claudex_stop_locked "$force"
  _claudex_start_stopped_locked
}

_claudex_foreground_prepare_locked() {
  local snapshot
  if snapshot="$(_claudex_gate_inspect 2>/dev/null)"; then
    _claudex_error "이미 proxy가 실행 중입니다"
    return 1
  fi
  if [ -e "$CLAUDEX_CONTROL_SOCKET" ] || [ -L "$CLAUDEX_CONTROL_SOCKET" ] \
    || _claudex_loopback_responding 2>/dev/null; then
    _claudex_error "기존 listener의 identity를 확인할 수 없습니다"
    return 1
  fi
  prepare_state
  assert_credential_set "$CLAUDEX_AUTH_DIR" default
}

command="${1-}"
case "$command" in
  "")
    "$CLAUDEX_STATUS_HANDLER" || true
    echo
    proxy_usage
    ;;
  ensure)
    [ "$#" -eq 1 ] || exit 2
    with_lifecycle_lock _claudex_ensure_locked
    ;;
  start)
    [ "$#" -eq 1 ] || { proxy_usage >&2; exit 2; }
    with_lifecycle_lock _claudex_ensure_locked
    ;;
  stop | restart)
    shift
    force=false
    if [ "$#" -eq 1 ] && [ "$1" = --force ]; then
      force=true
      shift
    fi
    [ "$#" -eq 0 ] || { proxy_usage >&2; exit 2; }
    if [ "$command" = stop ]; then
      with_lifecycle_lock _claudex_stop_locked "$force"
    else
      with_lifecycle_lock _claudex_restart_locked "$force"
    fi
    ;;
  foreground)
    [ "$#" -eq 1 ] || { proxy_usage >&2; exit 2; }
    with_lifecycle_lock _claudex_foreground_prepare_locked
    exec "$CLAUDEX_PROXY_LAUNCHER" --foreground
    ;;
  logs)
    shift
    follow=false
    if [ "$#" -eq 1 ] && [ "$1" = -f ]; then
      follow=true
      shift
    fi
    [ "$#" -eq 0 ] || { proxy_usage >&2; exit 2; }
    if [ -L "$CLAUDEX_LOG_FILE" ] \
      || { [ -e "$CLAUDEX_LOG_FILE" ] && [ ! -f "$CLAUDEX_LOG_FILE" ]; }; then
      _claudex_error "refusing unsafe proxy log path"
      exit 1
    fi
    if [ ! -e "$CLAUDEX_LOG_FILE" ]; then
      echo "claudex: 아직 proxy 로그가 없습니다" >&2
      exit 0
    fi
    if [ "$follow" = true ]; then
      exec "$CLAUDEX_TAIL" -n 100 -F "$CLAUDEX_LOG_FILE"
    fi
    exec "$CLAUDEX_TAIL" -n 100 "$CLAUDEX_LOG_FILE"
    ;;
  help | --help)
    [ "$#" -eq 1 ] || { proxy_usage >&2; exit 2; }
    proxy_usage
    ;;
  *)
    proxy_usage >&2
    exit 2
    ;;
esac
