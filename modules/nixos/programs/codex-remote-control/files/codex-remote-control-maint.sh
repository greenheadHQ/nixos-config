#!/usr/bin/env bash
# Maintain remote control using the CLI version selected by the user.
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-$HOME/.local/bin/codex}"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
STATE_DIR="${STATE_DIR:-/var/lib/codex-remote-control}"
CODEX_SETTINGS_HELPER="${CODEX_SETTINGS_HELPER:-$(dirname "${BASH_SOURCE[0]}")/codex-daemon-settings.py}"
STATUS_FILE="$STATE_DIR/status.json"
LOCK_FILE="$STATE_DIR/maintenance.lock"
MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"
DAEMON_SETTINGS_LOCK_TIMEOUT_SECONDS="${DAEMON_SETTINGS_LOCK_TIMEOUT_SECONDS:-120}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"
ALERT_REPEAT_SECONDS="${ALERT_REPEAT_SECONDS:-21600}"
PUSHOVER_CRED_FILE="${PUSHOVER_CRED_FILE:-}"
SERVICE_LIB="${SERVICE_LIB:-}"
CODEX_REMOTE_CONTROL_PS_FILE="${CODEX_REMOTE_CONTROL_PS_FILE:-}"
DAEMON_LOG_PATH="${DAEMON_LOG_PATH:-$CODEX_HOME/app-server-daemon/daemon.stderr.log}"
DAEMON_LOG_OFFSET=0

readonly ACTION_NONE="none"
readonly RC_OPERATOR_CODEX_NOT_FOUND=25
readonly RC_OPERATOR_VERSION_FAILED=26
readonly RC_DAEMON_SETTINGS_FAILED=27
readonly RC_AUTH_API_KEY=30
readonly RC_AUTH_NOT_CHATGPT=31
readonly RC_DAEMON_MALFORMED_JSON=40
readonly RC_DAEMON_NOT_RUNNING=41
readonly RC_REMOTE_START_NOT_CONNECTED=50
readonly RC_REMOTE_START_MALFORMED_JSON=51
readonly RC_REMOTE_START_FAILED=52
readonly RC_REMOTE_START_VERSION_DRIFT=54
readonly RC_DAEMON_START_FAILED=55
readonly RC_DAEMON_UPDATE_FAILED=56
readonly RC_UPDATE_DEFERRED=62
readonly RC_PROCESS_QUERY_FAILED=63
readonly RC_UNMANAGED=75

LAST_ACTION="$ACTION_NONE"
LAST_REPAIR_REASON=""
OPERATOR_CLI=""
OPERATOR_CLI_RESOLVED=""
DESIRED_VERSION=""
LOGIN_STATUS=""
AUTH_MODE="unknown"
DAEMON_STATUS="unknown"
MANAGED_CODEX_VERSION=""
APP_SERVER_VERSION=""
REMOTE_CONTROL_ENABLED="null"
SERVER_NAME=""
PID_EVIDENCE=""
START_STDERR=""
DAEMON_STDERR=""

set_last_action_if_none() {
  local action="$1"
  [ "$LAST_ACTION" != "$ACTION_NONE" ] || LAST_ACTION="$action"
}

mkdir_state() {
  mkdir -p "$STATE_DIR"
}

with_lock() {
  mkdir_state || {
    LAST_REPAIR_REASON="state-dir-unavailable"
    return 1
  }
  exec 9>"$LOCK_FILE" || {
    LAST_REPAIR_REASON="lock-open-failed"
    return 1
  }
  flock --timeout "$MAINT_LOCK_TIMEOUT_SECONDS" 9 || {
    LAST_REPAIR_REASON="lock-acquire-timeout"
    return 1
  }
  # fd 9는 이 셸이 락을 유지하는 동안만 살아야 한다. 리다이렉트 없이 실행하면
  # codex remote-control start가 detach하는 app-server 데몬이 fd 9를 상속해
  # 스크립트 종료 후에도 락을 영구 점유하고, 이후 모든 타이머 실행이
  # lock-acquire-timeout으로 실패한다. 9>&-는 명령 스코프에서만 fd 9를 닫으므로
  # (bash가 원본 fd를 CLOEXEC 임시 fd로 보존) 이 셸의 락은 유지된다.
  "$@" 9>&-
}

resolve_operator_cli() {
  [ -x "$CODEX_BIN" ] || {
    LAST_REPAIR_REASON="operator-codex-not-found"
    return "$RC_OPERATOR_CODEX_NOT_FOUND"
  }
  OPERATOR_CLI="$CODEX_BIN"
  OPERATOR_CLI_RESOLVED="$(readlink -f "$CODEX_BIN" 2>/dev/null || printf '%s' "$CODEX_BIN")"
  local version_output
  version_output="$("$CODEX_BIN" --version 2>/dev/null)" || {
    LAST_REPAIR_REASON="operator-version-failed"
    return "$RC_OPERATOR_VERSION_FAILED"
  }
  if [[ "$version_output" =~ ^codex-cli[[:space:]]+([^[:space:]]+)$ ]]; then
    DESIRED_VERSION="${BASH_REMATCH[1]}"
  else
    LAST_REPAIR_REASON="operator-version-malformed"
    return "$RC_OPERATOR_VERSION_FAILED"
  fi
}

# The CLI owns package selection and installation. The only external policy is
# disabling its autonomous daemon updater; user-selected CLI updates are applied
# below through the official --from-cli command.
ensure_daemon_policy() {
  guard_no_ssh_proxy || return $?
  if ! python3 "$CODEX_SETTINGS_HELPER" "$CODEX_HOME" "$DAEMON_SETTINGS_LOCK_TIMEOUT_SECONDS"; then
    LAST_REPAIR_REASON="daemon-settings-failed"
    return "$RC_DAEMON_SETTINGS_FAILED"
  fi
}

has_dedicated_selection() {
  [ -e "$CODEX_HOME/packages/app-server-daemon/current" ] || [ -L "$CODEX_HOME/packages/app-server-daemon/current" ]
}

has_local_daemon_selection() {
  local root="$CODEX_HOME/packages/app-server-daemon" selected releases
  has_dedicated_selection || return 1
  [ ! -e "$root/auto-update-version" ] && [ ! -L "$root/auto-update-version" ] || return 1
  selected="$(readlink -f "$root/current" 2>/dev/null)" || return 1
  releases="$(readlink -f "$root/releases" 2>/dev/null)" || return 1
  [ "$(dirname "$selected")" = "$releases" ] || return 1
  # --from-cli owns local-<digest>-<target> releases and removes the public
  # latest-channel marker. A same-version latest install still needs migration.
  case "${selected##*/}" in local-*) return 0 ;; *) return 1 ;; esac
}

has_selected_daemon() {
  has_dedicated_selection && return 0
  local state="$CODEX_HOME/app-server-daemon" artifact
  # Match upstream's package-root precedence: a frontend standalone selection
  # alone is not a daemon installation, and dedicated launch history wins.
  for artifact in daemon.pid daemon.stderr.log daemon-updater.pid daemon-updater.stderr.log; do
    if [ -e "$state/$artifact" ] || [ -L "$state/$artifact" ]; then
      return 1
    fi
  done
  for artifact in app-server.pid app-server.stderr.log app-server-updater.pid app-server-updater.stderr.log; do
    if [ -e "$state/$artifact" ] || [ -L "$state/$artifact" ]; then
      [ -e "$CODEX_HOME/packages/standalone/current" ] || [ -L "$CODEX_HOME/packages/standalone/current" ]
      return $?
    fi
  done
  return 1
}

capture_login_status() {
  local raw_status
  raw_status="$("$OPERATOR_CLI" login status 2>&1 || true)"
  case "$raw_status" in
    *"Logged in using ChatGPT"*)
      AUTH_MODE="chatgpt"
      LOGIN_STATUS="$AUTH_MODE"
      return 0
      ;;
    *"API key"* | *"api key"* | *"API_KEY"*)
      AUTH_MODE="api-key"
      LOGIN_STATUS="$AUTH_MODE"
      LAST_REPAIR_REASON="auth-not-chatgpt"
      return "$RC_AUTH_API_KEY"
      ;;
    *)
      AUTH_MODE="unknown"
      LOGIN_STATUS="$AUTH_MODE"
      LAST_REPAIR_REASON="auth-status-not-chatgpt"
      return "$RC_AUTH_NOT_CHATGPT"
      ;;
  esac
}

capture_daemon_version() {
  local out
  local err
  err="$(mktemp)"
  if out="$("$OPERATOR_CLI" app-server daemon version 2>"$err")"; then
    DAEMON_STDERR="$(cat "$err")"
    rm -f "$err"
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
      DAEMON_STATUS="$(jq -r '.status // "unknown"' <<<"$out")"
      MANAGED_CODEX_VERSION="$(jq -r '.managedCodexVersion // ""' <<<"$out")"
      APP_SERVER_VERSION="$(jq -r '.appServerVersion // ""' <<<"$out")"
      return 0
    fi
    DAEMON_STATUS="malformed-json"
    DAEMON_STDERR="$out"
    return "$RC_DAEMON_MALFORMED_JSON"
  fi

  DAEMON_STDERR="$(cat "$err")"
  rm -f "$err"
  DAEMON_STATUS="not-running"
  return "$RC_DAEMON_NOT_RUNNING"
}

contains_unmanaged_error() {
  local text="$1"
  case "$text" in
    *"not managed by codex app-server daemon"* | *"WebSocket protocol error"* | *"Connection reset without closing handshake"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

remote_start_versions_current() {
  [ "$MANAGED_CODEX_VERSION" = "$DESIRED_VERSION" ] && [ "$APP_SERVER_VERSION" = "$DESIRED_VERSION" ]
}

remote_start() {
  guard_no_ssh_proxy || return $?
  local out
  local err
  err="$(mktemp)"
  if out="$("$OPERATOR_CLI" remote-control start --json 2>"$err")"; then
    START_STDERR="$(cat "$err")"
    rm -f "$err"
    if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$out"; then
      SERVER_NAME="$(jq -r '.serverName // ""' <<<"$out")"
      MANAGED_CODEX_VERSION="$(jq -r '.daemon.managedCodexVersion // .managedCodexVersion // ""' <<<"$out")"
      APP_SERVER_VERSION="$(jq -r '.daemon.appServerVersion // .appServerVersion // ""' <<<"$out")"
      DAEMON_STATUS="$(jq -r '.daemon.status // .status // "unknown"' <<<"$out")"
      if jq -e '(.remoteControlEnabled == true) or (.status == "connected")' >/dev/null 2>&1 <<<"$out"; then
        if ! remote_start_versions_current; then
          REMOTE_CONTROL_ENABLED="false"
          LAST_REPAIR_REASON="remote-control-start-version-drift:${MANAGED_CODEX_VERSION:-missing}/${APP_SERVER_VERSION:-missing}"
          return "$RC_REMOTE_START_VERSION_DRIFT"
        fi
        REMOTE_CONTROL_ENABLED="true"
        return 0
      fi
      REMOTE_CONTROL_ENABLED="false"
      LAST_REPAIR_REASON="remote-control-start-not-connected"
      return "$RC_REMOTE_START_NOT_CONNECTED"
    fi
    REMOTE_CONTROL_ENABLED="false"
    LAST_REPAIR_REASON="remote-control-start-malformed-json"
    return "$RC_REMOTE_START_MALFORMED_JSON"
  fi

  START_STDERR="$(cat "$err")"
  rm -f "$err"
  REMOTE_CONTROL_ENABLED="false"
  if contains_unmanaged_error "$START_STDERR"; then
    LAST_REPAIR_REASON="remote-control-start-unmanaged"
    return "$RC_UNMANAGED"
  fi
  LAST_REPAIR_REASON="remote-control-start-failed"
  return "$RC_REMOTE_START_FAILED"
}

collect_pid_evidence() {
  if [ -n "$CODEX_REMOTE_CONTROL_PS_FILE" ]; then
    PID_EVIDENCE="$(cat "$CODEX_REMOTE_CONTROL_PS_FILE" 2>/dev/null)" || return "$RC_PROCESS_QUERY_FAILED"
  else
    local current_user processes rc=0
    current_user="$(id -un)" || return "$RC_PROCESS_QUERY_FAILED"
    processes="$(pgrep -a -u "$(id -u)" -f 'codex .*app-server|app-server --listen unix://')" || rc=$?
    [ "$rc" -le 1 ] || return "$RC_PROCESS_QUERY_FAILED"
    PID_EVIDENCE="$(
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s %s %s\n' "$(awk '{print $1}' <<<"$line")" "$current_user" "$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//' <<<"$line")"
      done <<<"$processes"
    )"
  fi
}

parse_pid_line() {
  local line="$1"
  CMD_FIELD="$(sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+//' <<<"$line")"
}

is_ssh_proxy_line() {
  case "$1" in
    *" app-server proxy" | *" app-server proxy "*) return 0 ;;
    *) return 1 ;;
  esac
}

ssh_proxy_exists() {
  collect_pid_evidence || return $?
  local line
  while IFS= read -r line; do
    parse_pid_line "$line"
    is_ssh_proxy_line "$CMD_FIELD" && return 0
  done <<<"$PID_EVIDENCE"
  return 1
}

guard_no_ssh_proxy() {
  local proxy_rc=0
  ssh_proxy_exists || proxy_rc=$?
  case "$proxy_rc" in
    0)
      LAST_ACTION="deferred-ssh-connected"
      LAST_REPAIR_REASON="version-update-deferred-ssh-connected"
      REMOTE_CONTROL_ENABLED="null"
      return "$RC_UPDATE_DEFERRED"
      ;;
    1) return 0 ;;
    *)
      LAST_REPAIR_REASON="process-query-failed"
      return "$RC_PROCESS_QUERY_FAILED"
      ;;
  esac
}

start_daemon() {
  guard_no_ssh_proxy || return $?
  if ! "$OPERATOR_CLI" app-server daemon start >/dev/null 2>&1; then
    LAST_REPAIR_REASON="daemon-start-failed"
    return "$RC_DAEMON_START_FAILED"
  fi
}

update_daemon_from_cli() {
  guard_no_ssh_proxy || return $?
  local err
  err="$(mktemp)" || return 1
  if ! "$OPERATOR_CLI" app-server daemon update --from-cli --yes >/dev/null 2>"$err"; then
    START_STDERR="$(cat "$err")"
    rm -f "$err"
    LAST_REPAIR_REASON="daemon-update-from-cli-failed"
    return "$RC_DAEMON_UPDATE_FAILED"
  fi
  rm -f "$err"
  LAST_ACTION="updated-daemon-from-cli"
}

ensure_running_core() {
  resolve_operator_cli || return $?
  local daemon_rc=0
  capture_daemon_version || daemon_rc=$?
  # Even remote-control start may restart an existing daemon. A connected SSH
  # client therefore permits only the passive version probe above.
  guard_no_ssh_proxy || return $?
  if [ "$daemon_rc" -eq "$RC_DAEMON_MALFORMED_JSON" ]; then
    LAST_REPAIR_REASON="daemon-version-malformed-json"
    return "$daemon_rc"
  fi
  if contains_unmanaged_error "$DAEMON_STDERR"; then
    LAST_REPAIR_REASON="daemon-unmanaged"
    return "$RC_UNMANAGED"
  fi
  capture_login_status || return $?
  ensure_daemon_policy || return $?

  # --from-cli needs a selected installation, even when it is stopped. On the
  # first launch seed the disabled-updater policy before bootstrapping it.
  if [ "$daemon_rc" -ne 0 ] && ! has_selected_daemon; then
    start_daemon || return $?
  fi
  # --from-cli restarts even identical binaries. Do not invoke it on every
  # healthy timer tick. Legacy installations still require a one-time migration.
  if [ "$daemon_rc" -ne 0 ] || ! has_local_daemon_selection ||
    ! remote_start_versions_current; then
    update_daemon_from_cli || return $?
  fi
  remote_start || return $?
  set_last_action_if_none "remote-control-healthy"
}

collect_probe() {
  resolve_operator_cli || return 0
  capture_daemon_version || true
  # A probe never starts a daemon or changes settings.
}

collect_probe_preserving_reason() {
  local previous_reason="$LAST_REPAIR_REASON"
  collect_probe
  [ -z "$previous_reason" ] || LAST_REPAIR_REASON="$previous_reason"
}

status_json() {
  local exit_code="${1:-0}"
  jq -n \
    --arg timestamp "$(date -Is)" \
    --arg operatorCli "$OPERATOR_CLI_RESOLVED" \
    --arg desiredVersion "$DESIRED_VERSION" \
    --arg managedCodexVersion "$MANAGED_CODEX_VERSION" \
    --arg appServerVersion "$APP_SERVER_VERSION" \
    --arg authMode "$AUTH_MODE" \
    --arg loginStatus "$LOGIN_STATUS" \
    --arg daemonStatus "$DAEMON_STATUS" \
    --arg serverName "$SERVER_NAME" \
    --arg lastAction "$LAST_ACTION" \
    --arg lastRepairReason "$LAST_REPAIR_REASON" \
    --arg pidEvidence "$PID_EVIDENCE" \
    --argjson remoteControlEnabled "$REMOTE_CONTROL_ENABLED" \
    --argjson exitCode "$exit_code" \
    '{
      timestamp: $timestamp,
      operatorCli: $operatorCli,
      desiredVersion: $desiredVersion,
      managedCodexVersion: $managedCodexVersion,
      appServerVersion: $appServerVersion,
      remoteControlEnabled: $remoteControlEnabled,
      authMode: $authMode,
      loginStatus: $loginStatus,
      daemonStatus: $daemonStatus,
      serverName: $serverName,
      lastAction: $lastAction,
      lastRepairReason: $lastRepairReason,
      pidEvidence: $pidEvidence,
      exitCode: $exitCode
    }'
}

write_status() {
  local exit_code="${1:-0}"
  mkdir_state || return $?
  local tmp
  tmp="$(mktemp "$STATE_DIR/status.XXXXXX")" || return $?
  status_json "$exit_code" >"$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$STATUS_FILE"
}

load_alerting() {
  # shellcheck source=/dev/null
  [ -n "$SERVICE_LIB" ] && [ -f "$SERVICE_LIB" ] && source "$SERVICE_LIB"
  local pushover_cred="$PUSHOVER_CRED_FILE"
  if [ -z "$pushover_cred" ] && [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
    pushover_cred="$CREDENTIALS_DIRECTORY/pushover-system-monitor"
  fi
  if [ -n "$pushover_cred" ] && [ -r "$pushover_cred" ]; then
    # shellcheck source=/dev/null
    source "$pushover_cred"
  fi
}

ALERT_HOST="${ALERT_HOST:-remote-host}"
# Pushover 본문 상한(1024자) 안에서 근거 라인까지 담기 위한 예산.
ALERT_BODY_MAX_BYTES=1000
ALERT_EVIDENCE_LINE_MAX_BYTES=240

strip_ansi() {
  # BSD sed는 \x1b를 모르므로 awk (gawk/BSD awk 모두 \033 지원)
  awk '{ gsub(/\033\[[0-9;]*m/, ""); print }'
}

# 바이트 예산으로 자르되 꼬리의 잘린 UTF-8 시퀀스를 버린다. GNU cut -c는 바이트 단위라
# 한글(3바이트)이 쪼개져 잘못된 UTF-8이 Pushover로 갈 수 있다. 로케일에 의존하지 않는다.
truncate_utf8() {
  local text="$1" max="$2" s n i byte need
  s="$(printf '%s' "$text" | head -c "$max")"
  local LC_ALL=C
  n=${#s}
  if [ "$n" -lt "$max" ]; then
    printf '%s' "$s"
    return 0
  fi
  for ((i = 1; i <= 4 && i <= n; i++)); do
    byte=$(printf '%d' "'${s:n-i:1}")
    if ((byte < 0x80)); then
      printf '%s' "$s"
      return 0
    fi
    if ((byte >= 0xC0)); then
      if ((byte >= 0xF0)); then need=4; elif ((byte >= 0xE0)); then need=3; else need=2; fi
      if ((i < need)); then printf '%s' "${s:0:n-i}"; else printf '%s' "$s"; fi
      return 0
    fi
  done
  printf '%s' "$s"
}

capture_daemon_log_offset() {
  DAEMON_LOG_OFFSET=0
  [ -f "$DAEMON_LOG_PATH" ] || return 0
  DAEMON_LOG_OFFSET="$(wc -c <"$DAEMON_LOG_PATH" | tr -d '[:space:]')"
}

# app-server 로그가 원인을 말해 주는 실패만 근거 대상이다. lock·패키지 동기화·로그인
# 상태처럼 app-server를 건드리기 전에 끝난 실패에 데몬 로그를 붙이면 무관한 토큰 수리로
# 오도한다.
evidence_relevant_for_reason() {
  case "${1%%:*}" in
    remote-control-* | daemon-version-* | daemon-start-* | daemon-update-* | daemon-unmanaged) return 0 ;;
    *) return 1 ;;
  esac
}

# LAST_REPAIR_REASON 코드 → 한국어 "원인<TAB>조치". `:` 뒤 상세는 코드 표시에만 남긴다.
# 알림만 보고도 왜 실패했고 무엇을 해야 하는지 알 수 있어야 한다 (2026-09-05 token_revoke
# 장애 때 "exit=52, reason=remote-control-start-failed"만으로는 하루종일 원인을 몰랐다).
repair_reason_explain() {
  local reason="${1:-unknown}" head
  head="${reason%%:*}"
  case "$head" in
    remote-control-start-not-connected)
      printf '%s\t%s' "app-server가 백엔드에 연결되지 못한 채 timeout(connecting)" "아래 app-server 로그를 확인하고 인증 오류가 있으면 해당 호스트에서 로그인 상태 확인"
      ;;
    remote-control-start-failed | daemon-start-failed | daemon-update-from-cli-failed)
      printf '%s\t%s' "공식 Codex 데몬 명령 실패" "stderr와 app-server 로그 확인 후 해당 호스트에서 Codex 상태 확인"
      ;;
    remote-control-start-malformed-json | daemon-version-malformed-json)
      printf '%s\t%s' "codex CLI 출력이 JSON이 아님" "codex 업데이트로 출력 형식이 바뀌었는지 확인 ('codex --version')"
      ;;
    remote-control-start-version-drift | daemon-version-drift)
      printf '%s\t%s' "실행 중 app-server 버전이 선택한 CLI 버전과 다름" "실행 중 작업과 SSH 연결을 확인한 뒤 'codex app-server daemon update --from-cli --yes' 실행"
      ;;
    daemon-unmanaged | remote-control-start-unmanaged)
      printf '%s\t%s' "app-server의 관리 상태를 확인할 수 없음" "SSH 연결과 실행 중 작업을 확인한 뒤 관리형 서버로 전환. 현재 PID를 일괄 종료하지 말 것"
      ;;
    version-update-deferred-ssh-connected)
      printf '%s\t%s' "SSH 연결이 있어 Codex 데몬 변경을 보류함" "작업 완료 후 Codex 앱의 SSH 연결을 해제하면 다음 점검에서 적용. 강제 종료하지 말 것"
      ;;
    auth-not-chatgpt | auth-status-not-chatgpt)
      printf '%s\t%s' "ChatGPT 계정 로그인이 아님 (API key 모드 또는 미로그인)" "해당 호스트에서 'codex login status' 확인"
      ;;
    lock-acquire-timeout | lock-open-failed | state-dir-unavailable)
      printf '%s\t%s' "maint 상태 디렉토리 또는 lock 획득 실패" "이전 maintenance 실행과 상태 디렉토리 권한 확인"
      ;;
    process-query-failed)
      printf '%s\t%s' "SSH 연결 여부를 확인할 수 없어 데몬 변경을 중단함" "호스트의 프로세스 조회 상태를 확인한 뒤 다시 실행"
      ;;
    daemon-settings-failed)
      printf '%s\t%s' "데몬 자동 업데이트 정책 설정 실패" "데몬 settings.json 형식과 daemon.lock 점유 상태 확인. 잘못된 설정은 자동으로 덮어쓰지 않음"
      ;;
    operator-codex-not-found | operator-version-failed | operator-version-malformed)
      printf '%s\t%s' "공식 native Codex CLI 실행을 확인할 수 없음" "'codex --version'과 native 설치 경로 확인"
      ;;
    *)
      printf '%s\t%s' "분류되지 않은 실패 ($reason)" "'journalctl -u codex-remote-control-ensure'와 maintenance 상태 파일 확인"
      ;;
  esac
}

# 실패 시점 근거: start 명령 stderr 첫 줄 + app-server 데몬 로그의 마지막 ERROR 라인.
# token_revoked 같은 실제 원인은 status.json이 아니라 이 로그에만 남는다.
alert_evidence() {
  local reason="$1" out="" line label size offset
  if [ -n "$START_STDERR" ]; then
    line="$(truncate_utf8 "$(printf '%s\n' "$START_STDERR" | head -n 1)" "$ALERT_EVIDENCE_LINE_MAX_BYTES")"
    [ -z "$line" ] || out="stderr: $line"
  fi
  if evidence_relevant_for_reason "$reason" && [ -f "$DAEMON_LOG_PATH" ]; then
    size="$(wc -c <"$DAEMON_LOG_PATH" | tr -d '[:space:]')"
    offset="$DAEMON_LOG_OFFSET"
    # 데몬 재시작으로 로그가 비워졌으면 offset이 크기를 넘는다 → 처음부터 본다.
    [ "$offset" -le "$size" ] || offset=0
    line="$(tail -c +"$((offset + 1))" "$DAEMON_LOG_PATH" 2>/dev/null | grep -a 'ERROR' | tail -n 1 | strip_ansi)"
    label="app-server"
    if [ -z "$line" ]; then
      line="$(grep -a 'ERROR' "$DAEMON_LOG_PATH" 2>/dev/null | tail -n 1 | strip_ansi)"
      label="app-server(이번 실행 이전 기록)"
    fi
    if [ -n "$line" ]; then
      line="$(truncate_utf8 "$line" "$ALERT_EVIDENCE_LINE_MAX_BYTES")"
      out="${out:+$out
}${label}: $line"
    fi
  fi
  printf '%s' "$out"
}

failure_alert_body() {
  local exit_code="$1" reason="${LAST_REPAIR_REASON:-unknown}" cause fix evidence body
  IFS=$'\t' read -r cause fix <<<"$(repair_reason_explain "$reason")"
  body="${ALERT_HOST}의 Codex 원격 제어 점검이 실패했습니다 (exit=${exit_code}, 코드: ${reason}, auth=${AUTH_MODE:-unknown})
원인: ${cause}
조치: ${fix}"
  evidence="$(alert_evidence "$reason")"
  [ -z "$evidence" ] || body="${body}
근거:
${evidence}"
  truncate_utf8 "$body" "$ALERT_BODY_MAX_BYTES"
}

send_alerts() {
  local exit_code="$1"
  # An active SSH client defers inspection; it is not evidence of an outage or
  # recovery. Preserve the last observed health state and notification cooldown.
  [ "$exit_code" -ne "$RC_UPDATE_DEFERRED" ] || return 0
  command -v send_notification >/dev/null 2>&1 || return 0
  [ -n "${PUSHOVER_TOKEN:-}" ] && [ -n "${PUSHOVER_USER:-}" ] || return 0

  local now
  now="$(date +%s)"
  local state_file="$STATE_DIR/last-health-state"
  local last_failure_file="$STATE_DIR/last-failure-alert"
  local reason_file="$STATE_DIR/last-failure-reason"
  local previous="unknown"
  [ -f "$state_file" ] && previous="$(cat "$state_file" 2>/dev/null || echo unknown)"

  if [ "$exit_code" -eq 0 ]; then
    if [ "$previous" = "failed" ]; then
      send_notification "Codex 원격 제어 복구 · ${ALERT_HOST}" \
        "${ALERT_HOST}의 Codex 원격 제어가 정상으로 돌아왔습니다 (app-server ${APP_SERVER_VERSION:-unknown})." 0
    fi
    echo "healthy" >"$state_file"
    return 0
  fi

  local last=0
  [ -f "$last_failure_file" ] && last="$(cat "$last_failure_file" 2>/dev/null || echo 0)"
  local reason="${LAST_REPAIR_REASON%%:*}" last_reason="" interval="$ALERT_COOLDOWN_SECONDS"
  [ ! -f "$reason_file" ] || last_reason="$(cat "$reason_file")"
  if [ "$previous" = "failed" ] && [ "$reason" = "$last_reason" ]; then
    interval="$ALERT_REPEAT_SECONDS"
  fi
  if [ "$previous" != "failed" ] || [ $((now - last)) -ge "$interval" ]; then
    send_notification "Codex 원격 제어 실패 · ${ALERT_HOST}" "$(failure_alert_body "$exit_code")" 0
    echo "$now" >"$last_failure_file"
    printf '%s\n' "$reason" >"$reason_file"
  fi
  echo "failed" >"$state_file"
}

cmd_probe() {
  collect_probe
  status_json 0
}

cmd_health_json() {
  if [ -f "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    cmd_probe
  fi
}

cmd_ensure_running() {
  local rc=0
  capture_daemon_log_offset
  with_lock ensure_running_core || rc=$?
  if [ "$rc" -ne 0 ]; then
    collect_probe_preserving_reason
  fi
  write_status "$rc" || true
  load_alerting
  send_alerts "$rc" || true
  return "$rc"
}

usage() {
  cat >&2 <<'EOF'
Usage: codex-remote-control-maint <probe|ensure-running|health-json>
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    probe) cmd_probe ;;
    ensure-running) cmd_ensure_running ;;
    health-json) cmd_health_json ;;
    -h | --help | help) usage ;;
    *)
      usage
      return 2
      ;;
  esac
}

main "$@"
