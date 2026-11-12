# tests/suites/codex-remote-control.sh — Native daemon maintenance fixtures
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_codex_rc_script() {
  printf '%s\n' "$REPO_ROOT/modules/nixos/programs/codex-remote-control/files/codex-remote-control-maint.sh"
}

_codex_rc_settings_helper() {
  printf '%s\n' "$REPO_ROOT/modules/nixos/programs/codex-remote-control/files/codex-daemon-settings.py"
}

_codex_rc_make_fake_codex() {
  local bin_dir="$1"
  mkdir -p "$bin_dir"
  cat >"$bin_dir/codex" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_CODEX_LOG"
case "$*" in
  "--version")
    printf 'codex-cli %s\n' "${FAKE_CODEX_VERSION:-0.142.4}"
    exit "${FAKE_VERSION_RC:-0}"
    ;;
  "login status")
    if [ -n "${FAKE_ATTACH_SSH_ON_LOGIN:-}" ]; then
      printf '4000500 fixture codex app-server proxy\n' > "$FAKE_ATTACH_SSH_ON_LOGIN"
    fi
    echo "${FAKE_LOGIN_STATUS:-Logged in using ChatGPT}"
    exit "${FAKE_LOGIN_RC:-0}"
    ;;
  "app-server daemon version")
    if [ "${FAKE_DAEMON_MALFORMED:-0}" = "1" ]; then
      echo "{bad json"
      exit 0
    fi
    if [ "${FAKE_DAEMON_RC:-0}" != "0" ]; then
      echo "${FAKE_DAEMON_ERR:-daemon not running}" >&2
      exit "$FAKE_DAEMON_RC"
    fi
    if [ -n "${FAKE_DAEMON_JSON:-}" ]; then
      printf '%s\n' "$FAKE_DAEMON_JSON"
    else
      printf '{"status":"running","managedCodexVersion":"0.142.4","appServerVersion":"0.142.4"}\n'
    fi
    exit 0
    ;;
  "app-server daemon start" | "app-server daemon update --from-cli --yes" | "remote-control start --json")
    # Every mutating lifecycle command must observe the policy, and must be able
    # to reacquire the native lock (the merge helper must already have exited).
    python3 - "$CODEX_HOME" <<'PYCHECK'
import fcntl, json, pathlib, sys
state = pathlib.Path(sys.argv[1]) / 'app-server-daemon'
assert json.loads((state / 'settings.json').read_text())['updater']['autoUpdateEnabled'] is False
with (state / 'daemon.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
PYCHECK
    ;;
  *) echo "unexpected fake CLI invocation" >&2; exit 99 ;;
esac
case "$*" in
  "app-server daemon start")
    [ "${FAKE_BOOTSTRAP_RC:-0}" = 0 ] || exit "$FAKE_BOOTSTRAP_RC"
    mkdir -p "$CODEX_HOME/packages/app-server-daemon/releases/local-fixture"
    ln -sfn releases/local-fixture "$CODEX_HOME/packages/app-server-daemon/current"
    ;;
  "app-server daemon update --from-cli --yes")
    [ "${FAKE_UPDATE_RC:-0}" = 0 ] || { echo "native update failed" >&2; exit "$FAKE_UPDATE_RC"; }
    mkdir -p "$CODEX_HOME/packages/app-server-daemon/releases/local-fixture"
    ln -sfn releases/local-fixture "$CODEX_HOME/packages/app-server-daemon/current"
    if [ -n "${FAKE_ATTACH_SSH_ON_UPDATE:-}" ]; then
      printf '4000500 fixture codex app-server proxy\n' > "$FAKE_ATTACH_SSH_ON_UPDATE"
    fi
    ;;
  "remote-control start --json")
    if [ "${FAKE_START_RC:-0}" != 0 ]; then
      echo "${FAKE_START_ERR:-start failed}" >&2
      exit "$FAKE_START_RC"
    fi
    if [ -n "${FAKE_START_DAEMON_FD_FILE:-}" ]; then
      (
        printf 'ready\n' > "$FAKE_START_DAEMON_FD_FILE"
        sleep 5
      ) >/dev/null 2>&1 &
      disown
    fi
    if [ -n "${FAKE_START_JSON:-}" ]; then
      printf '%s\n' "$FAKE_START_JSON"
    else
      printf '{"mode":"daemon","status":"connected","serverName":"remote-host","daemon":{"status":"alreadyRunning","managedCodexVersion":"%s","appServerVersion":"%s"}}\n' "${FAKE_CODEX_VERSION:-0.142.4}" "${FAKE_CODEX_VERSION:-0.142.4}"
    fi
    ;;
esac
EOS
  chmod +x "$bin_dir/codex"
}

_codex_rc_setup() {
  local sandbox="$1"
  COD_RC_HOME="$sandbox/home"
  COD_RC_STATE="$sandbox/state"
  COD_RC_FAKE_BIN="$sandbox/fake-bin"
  COD_RC_LOG="$sandbox/codex.log"
  COD_RC_PS="$sandbox/ps.txt"
  mkdir -p "$COD_RC_HOME/.codex/packages/app-server-daemon/releases/local-fixture" "$COD_RC_STATE"
  ln -s releases/local-fixture "$COD_RC_HOME/.codex/packages/app-server-daemon/current"
  : >"$COD_RC_PS"
  _codex_rc_make_fake_codex "$COD_RC_FAKE_BIN"
}

_codex_rc_env() {
  env \
    HOME="$COD_RC_HOME" \
    CODEX_HOME="$COD_RC_HOME/.codex" \
    STATE_DIR="${STATE_DIR:-$COD_RC_STATE}" \
    CODEX_BIN="${CODEX_BIN:-$COD_RC_FAKE_BIN/codex}" \
    CODEX_SETTINGS_HELPER="$(_codex_rc_settings_helper)" \
    CODEX_REMOTE_CONTROL_PS_FILE="${CODEX_REMOTE_CONTROL_PS_FILE-$COD_RC_PS}" \
    FAKE_CODEX_LOG="$COD_RC_LOG" \
    ALERT_HOST=remote-host \
    "$@"
}

_codex_rc_make_alerting() {
  local sandbox="$1"
  COD_RC_ALERT_LOG="$sandbox/alerts.log"
  COD_RC_SERVICE_LIB="$sandbox/service-lib.sh"
  COD_RC_PUSHOVER_CRED="$sandbox/pushover.env"

  cat >"$COD_RC_SERVICE_LIB" <<'EOS'
send_notification() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$ALERT_LOG"
}
EOS
  printf '%s\n' 'PUSHOVER_TOKEN=test-token' 'PUSHOVER_USER=test-user' >"$COD_RC_PUSHOVER_CRED"
}

_codex_rc_assert_alert_count() {
  local needle="$1"
  local expected="$2"
  local actual

  actual="$(
    if [ -f "$COD_RC_ALERT_LOG" ]; then
      awk -v needle="$needle" 'index($0, needle) { count++ } END { print count + 0 }' "$COD_RC_ALERT_LOG"
    else
      printf '0\n'
    fi
  )"
  [ "$actual" = "$expected" ] ||
    fail "expected $expected alert(s) containing '$needle' in $COD_RC_ALERT_LOG, got $actual"
}

test_codex_remote_control_probe_parses_daemon_json() {
  local sandbox out
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  out="$(_codex_rc_env bash "$(_codex_rc_script)" probe)"
  jq -e '.daemonStatus == "running" and .managedCodexVersion == "0.142.4" and .appServerVersion == "0.142.4"' <<<"$out" >/dev/null ||
    fail "probe did not parse daemon version JSON: $out"
}

test_codex_remote_control_probe_marks_malformed_daemon_json() {
  local sandbox out
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  out="$(FAKE_DAEMON_MALFORMED=1 _codex_rc_env bash "$(_codex_rc_script)" probe)"
  jq -e '.daemonStatus == "malformed-json"' <<<"$out" >/dev/null ||
    fail "probe did not mark malformed daemon JSON: $out"
}

test_codex_remote_control_ensure_running_rejects_malformed_daemon_json() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if FAKE_DAEMON_MALFORMED=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail on malformed daemon JSON"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.daemonStatus == "malformed-json" and .lastRepairReason == "daemon-version-malformed-json" and .exitCode == 40' <<<"$status" >/dev/null ||
    fail "malformed daemon JSON was not recorded as unhealthy: $status"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start --json'
}

test_codex_remote_control_ensure_running_starts_when_absent() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  FAKE_DAEMON_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.remoteControlEnabled == true and .serverName == "remote-host" and .exitCode == 0' <<<"$status" >/dev/null ||
    fail "ensure-running did not record successful remote-control start: $status"
  grep -Fqx 'remote-control start --json' "$COD_RC_LOG" ||
    fail "ensure-running did not invoke remote-control start"
}

test_codex_remote_control_rejects_stale_start_versions() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if FAKE_DAEMON_RC=1 \
    FAKE_START_JSON='{"mode":"daemon","status":"connected","serverName":"remote-host","daemon":{"status":"started","managedCodexVersion":"0.133.0","appServerVersion":"0.133.0"}}' \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should reject connected start output with stale versions"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.remoteControlEnabled == false and (.lastRepairReason | startswith("remote-control-start-version-drift:0.133.0/0.133.0")) and .exitCode != 0' <<<"$status" >/dev/null ||
    fail "stale start versions were not recorded as unhealthy: $status"
}

test_codex_remote_control_auth_failure_is_non_destructive() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if FAKE_LOGIN_STATUS='Logged in using API key' _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail for API-key auth"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.authMode == "api-key" and .exitCode != 0' <<<"$status" >/dev/null ||
    fail "auth failure status not recorded: $status"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start --json'
}

test_codex_remote_control_login_status_is_sanitized() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  FAKE_LOGIN_STATUS='Logged in using ChatGPT as private@example.com' _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.authMode == "chatgpt" and .loginStatus == "chatgpt"' <<<"$status" >/dev/null ||
    fail "loginStatus should contain only sanitized auth mode: $status"
  assert_not_contains "$status" 'private@example.com'
}

test_codex_remote_control_missing_operator_reason_is_preserved() {
  local sandbox status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"

  if CODEX_BIN="$sandbox/missing-codex" _codex_rc_env bash "$(_codex_rc_script)" ensure-running; then
    fail "ensure-running should fail when operator codex is missing"
  fi
  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "operator-codex-not-found" and .exitCode == 25' <<<"$status" >/dev/null ||
    fail "missing operator reason was not preserved: $status"
}

test_codex_remote_control_lock_failure_does_not_run_core_action() {
  local sandbox bad_state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  bad_state="$sandbox/not-a-directory"
  : >"$bad_state"

  if STATE_DIR="$bad_state" _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail when state dir cannot be created"
  fi
  assert_not_contains "$(cat "$COD_RC_LOG" 2>/dev/null || true)" 'remote-control start --json'
}

test_codex_remote_control_lock_acquire_timeout_is_recorded() {
  local sandbox ready lock_holder status
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ready="$sandbox/lock-ready"

  # shellcheck disable=SC2016
  flock "$COD_RC_STATE/maintenance.lock" bash -c 'touch "$1"; sleep 5' _ "$ready" &
  lock_holder=$!
  for _ in {1..50}; do
    [ ! -e "$ready" ] || break
    kill -0 "$lock_holder" 2>/dev/null || fail "lock holder exited before acquiring lock"
    sleep 0.1
  done
  [ -e "$ready" ] || fail "lock holder did not acquire lock"

  if MAINT_LOCK_TIMEOUT_SECONDS=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    kill "$lock_holder" 2>/dev/null || true
    wait "$lock_holder" 2>/dev/null || true
    fail "ensure-running should fail when maintenance lock acquisition times out"
  fi
  kill "$lock_holder" 2>/dev/null || true
  wait "$lock_holder" 2>/dev/null || true

  status="$(cat "$COD_RC_STATE/status.json")"
  jq -e '.lastRepairReason == "lock-acquire-timeout" and .exitCode != 0' <<<"$status" >/dev/null ||
    fail "lock timeout was not recorded as unhealthy: $status"
  assert_not_contains "$(cat "$COD_RC_LOG" 2>/dev/null || true)" 'remote-control start --json'
}

test_codex_remote_control_spawned_daemon_does_not_inherit_lock_fd() {
  local sandbox fd_file
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  fd_file="$sandbox/daemon-fds.txt"

  FAKE_START_DAEMON_FD_FILE="$fd_file" _codex_rc_env bash "$(_codex_rc_script)" ensure-running >/dev/null 2>&1 ||
    fail "ensure-running should succeed on the healthy fixture path"

  local _i
  for _i in {1..50}; do
    [ ! -s "$fd_file" ] || break
    sleep 0.1
  done
  [ -s "$fd_file" ] || fail "fake daemon did not record its fd table"

  # 데몬이 lock fd를 상속하면 maint 스크립트 종료 후에도 flock이 유지되어
  # 이후 모든 타이머 실행이 lock-acquire-timeout으로 실패한다 (2026-07 실장애).
  flock --timeout 1 --exclusive "$COD_RC_STATE/maintenance.lock" -c true ||
    fail "maintenance lock still held after ensure-running exited (fd leaked to spawned daemon)"
}

test_codex_remote_control_alert_recovery_after_failure() {
  local sandbox state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'failed\n' >"$COD_RC_STATE/last-health-state"

  ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "healthy" ] || fail "recovery should update health state to healthy, got: $state"
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 1
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
}

test_codex_remote_control_alert_success_without_failure_is_quiet() {
  local sandbox state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"

  ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "healthy" ] || fail "healthy run should write healthy state, got: $state"
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
}

test_codex_remote_control_alert_failure_sets_failed_and_cools_down() {
  local sandbox first_last second_last state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' >"$COD_RC_STATE/last-health-state"

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail for malformed daemon JSON"
  fi

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "failed" ] || fail "failed run should write failed state, got: $state"
  [ -s "$COD_RC_STATE/last-failure-alert" ] || fail "failed run should record last failure alert timestamp"
  first_last="$(cat "$COD_RC_STATE/last-failure-alert")"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 1

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should keep failing for malformed daemon JSON"
  fi

  state="$(cat "$COD_RC_STATE/last-health-state")"
  second_last="$(cat "$COD_RC_STATE/last-failure-alert")"
  [ "$state" = "failed" ] || fail "repeated failure should keep failed state, got: $state"
  [ "$second_last" = "$first_last" ] || fail "cooldown should not rewrite last failure alert timestamp"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 1
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
}

test_codex_remote_control_alert_without_pushover_token_does_not_mutate_state() {
  local sandbox state
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' >"$COD_RC_STATE/last-health-state"

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$sandbox/missing-pushover.env" \
    CREDENTIALS_DIRECTORY='' \
    PUSHOVER_TOKEN='' \
    PUSHOVER_USER='' \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail for malformed daemon JSON"
  fi

  state="$(cat "$COD_RC_STATE/last-health-state")"
  [ "$state" = "healthy" ] || fail "missing Pushover token should leave health state unchanged, got: $state"
  [ ! -e "$COD_RC_STATE/last-failure-alert" ] || fail "missing Pushover token should not write failure alert timestamp"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
}

test_codex_remote_control_alert_body_explains_cause_and_evidence() {
  local sandbox body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' >"$COD_RC_STATE/last-health-state"
  mkdir -p "$COD_RC_HOME/.codex/app-server-daemon"
  printf '%s\n' \
    'INFO app-server started' \
    $'\e[2m2026-09-04T04:00:50Z\e[0m \e[31mERROR\e[0m codex_login::auth::manager: Failed to refresh token: 401 Unauthorized: refresh_token_invalidated' \
    >"$COD_RC_HOME/.codex/app-server-daemon/daemon.stderr.log"

  if FAKE_DAEMON_MALFORMED=1 \
    ALERT_LOG="$COD_RC_ALERT_LOG" \
    SERVICE_LIB="$COD_RC_SERVICE_LIB" \
    PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null; then
    fail "ensure-running should fail for malformed daemon JSON"
  fi

  _codex_rc_assert_alert_count "Codex 원격 제어 실패 · remote-host" 1
  body="$(cat "$COD_RC_ALERT_LOG")"
  for needle in \
    "remote-host의 Codex 원격 제어 점검이 실패했습니다 (exit=40, 코드: daemon-version-malformed-json" \
    "원인: codex CLI 출력이 JSON이 아님" \
    "조치: codex 업데이트로 출력 형식이 바뀌었는지 확인" \
    "근거:" \
    "app-server(이번 실행 이전 기록): 2026-09-04T04:00:50Z ERROR codex_login::auth::manager: Failed to refresh token: 401 Unauthorized: refresh_token_invalidated"; do
    grep -Fq -- "$needle" "$COD_RC_ALERT_LOG" || fail "alert body missing '$needle': $body"
  done
  if grep -q $'\e\[' "$COD_RC_ALERT_LOG"; then
    fail "alert body must not carry ANSI escapes: $body"
  fi
  grep -Fq -- "stderr:" "$COD_RC_ALERT_LOG" && fail "no start stderr captured, so no stderr line expected: $body"
  return 0
}

# maint 함수 격리 호출: 마지막 줄의 main "$@"를 떼고 source한다. T_REASON/T_STDERR/T_OFFSET은
# source 뒤에 대입한다 — 스크립트 상단이 이 변수들을 빈값으로 초기화하므로 env로는 못 넘긴다.

_codex_rc_call_fn() {
  CODEX_HOME="$COD_RC_HOME/.codex" STATE_DIR="$COD_RC_STATE" \
    bash -c 'set -uo pipefail; source <(sed "\$d" "$1"); shift; LAST_REPAIR_REASON="${T_REASON:-}"; START_STDERR="${T_STDERR:-}"; DAEMON_LOG_OFFSET="${T_OFFSET:-0}"; "$@"' _ "$(_codex_rc_script)" "$@"
}

test_codex_remote_control_restart_preserves_codex_lock_inodes() {
  local sandbox ps_file control daemon name
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ps_file="$sandbox/ps.txt"
  : >"$ps_file"
  control="$COD_RC_HOME/.codex/app-server-control"
  daemon="$COD_RC_HOME/.codex/app-server-daemon"
  mkdir -p "$control" "$daemon"
  for name in "$control/app-server-control.sock" "$control/app-server-startup.lock" "$daemon/daemon.lock" "$daemon/app-server.pid.lock" "$daemon/app-server-updater.pid.lock"; do
    printf 'owned by Codex\n' >"$name"
    ln "$name" "$name.witness"
  done
  FAKE_DAEMON_JSON='{"status":"running","managedCodexVersion":"0.133.0","appServerVersion":"0.133.0"}' \
    CODEX_REMOTE_CONTROL_PS_FILE="$ps_file" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  for name in "$control/app-server-control.sock" "$control/app-server-startup.lock" "$daemon/daemon.lock" "$daemon/app-server.pid.lock" "$daemon/app-server-updater.pid.lock"; do
    [ "$name" -ef "$name.witness" ] || fail "maintenance unlinked a Codex-owned socket/lock inode: $name"
  done
}

test_codex_remote_control_unmanaged_alert_does_not_blame_manual_launch() {
  local sandbox body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  body="$(T_REASON=daemon-unmanaged _codex_rc_call_fn failure_alert_body 61)"
  assert_not_contains "$body" '수동 실행'
  assert_contains "$body" 'SSH'
  assert_contains "$body" '작업'
}

_assert_valid_utf8() {
  printf '%s' "$1" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null ||
    fail "$2: not valid UTF-8"
}

# 근거는 app-server를 실제로 건드린 실패에만, 그리고 이번 실행 중 새로 쓰인 ERROR를
# 우선한다. lock·패키지·로그인 실패에 오래된 데몬 ERROR가 붙으면 무관한 토큰 수리로 오도한다.

test_codex_remote_control_alert_evidence_scoped_to_current_failure() {
  local sandbox log body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  log="$COD_RC_HOME/.codex/app-server-daemon/daemon.stderr.log"
  mkdir -p "$(dirname "$log")"
  printf '%s\n' 'ERROR old: 401 token_revoked' >"$log"

  # (1) app-server와 무관한 실패: 데몬 로그를 근거로 붙이지 않는다
  body="$(T_REASON=lock-acquire-timeout _codex_rc_call_fn failure_alert_body 1)"
  assert_contains "$body" "원인: maint 상태 디렉토리 또는 lock 획득 실패"
  assert_not_contains "$body" "근거:"
  assert_not_contains "$body" "token_revoked"

  # (2) 관련 실패 + 이번 실행 중 새 ERROR 없음: 이전 기록임을 라벨로 명시
  body="$(T_REASON=remote-control-start-not-connected T_OFFSET="$(wc -c <"$log" | tr -d ' ')" _codex_rc_call_fn failure_alert_body 50)"
  assert_contains "$body" "app-server(이번 실행 이전 기록): ERROR old: 401 token_revoked"

  # (3) 관련 실패 + offset 이후 새 ERROR: 그 라인을 라벨 없이 싣고, stderr 첫 줄도 함께
  local offset
  offset="$(wc -c <"$log" | tr -d ' ')"
  printf '%s\n' 'INFO noise' 'ERROR new: refresh_token_invalidated' >>"$log"
  body="$(T_REASON=remote-control-start-failed T_STDERR=$'first stderr line\nsecond' T_OFFSET="$offset" _codex_rc_call_fn failure_alert_body 52)"
  assert_contains "$body" "stderr: first stderr line"
  assert_not_contains "$body" "second"
  assert_contains "$body" $'\napp-server: ERROR new: refresh_token_invalidated'
  assert_not_contains "$body" "이전 기록"
  assert_not_contains "$body" "ERROR old"

  # (4) 데몬 재시작으로 로그가 비워져 offset > size: 처음부터 본다
  printf '%s\n' 'ERROR after-restart' >"$log"
  body="$(T_REASON=daemon-version-drift:0.1/0.2 T_OFFSET=999999 _codex_rc_call_fn failure_alert_body 54)"
  assert_contains "$body" "app-server: ERROR after-restart"
}

# 한글 본문/근거를 바이트 예산으로 자를 때 3바이트 문자가 쪼개지면 안 된다.

test_codex_remote_control_alert_truncation_keeps_valid_utf8() {
  local sandbox out ga log body
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  ga="$(printf '가%.0s' $(seq 1 100))" # 300 bytes

  out="$(_codex_rc_call_fn truncate_utf8 "$ga" 100)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 99 ] || fail "lead byte at boundary must be dropped: $(printf '%s' "$out" | wc -c)"
  _assert_valid_utf8 "$out" "max=100"
  out="$(_codex_rc_call_fn truncate_utf8 "$ga" 101)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 99 ] || fail "lead+1 continuation must be dropped"
  out="$(_codex_rc_call_fn truncate_utf8 "$ga" 102)"
  [ "$(printf '%s' "$out" | wc -c | tr -d ' ')" = 102 ] || fail "complete 34 chars must be kept"
  out="$(_codex_rc_call_fn truncate_utf8 "abc" 100)"
  [ "$out" = "abc" ] || fail "short text must pass through: $out"
  out="$(_codex_rc_call_fn truncate_utf8 "$(printf 'x%.0s' $(seq 1 150))" 100)"
  [ "${#out}" = 100 ] || fail "ascii must cut at exactly max bytes"

  # 실제 근거 라인 경계: "ERROR: " 7바이트 + 가×100 → 240바이트 컷이 78번째 가를 쪼갠다
  log="$COD_RC_HOME/.codex/app-server-daemon/daemon.stderr.log"
  mkdir -p "$(dirname "$log")"
  printf 'ERROR: %s\n' "$ga" >"$log"
  body="$(T_REASON=remote-control-start-failed _codex_rc_call_fn failure_alert_body 52)"
  _assert_valid_utf8 "$body" "evidence line"
  [ "$(printf '%s' "$body" | grep -a '^app-server' | wc -c | tr -d ' ')" = $((12 + 7 + 231 + 1)) ] ||
    fail "evidence line must be 238 bytes of payload: $(printf '%s' "$body" | grep -a '^app-server' | wc -c)"
}

test_codex_remote_control_repeated_alerts_wait_six_hours() {
  local sandbox
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  _codex_rc_make_alerting "$sandbox"
  # 이전 실행에서 보낸 같은 장애는 다음 30분 점검에서 다시 알리지 않는다.
  printf 'failed\n' >"$COD_RC_STATE/last-health-state"
  printf 'daemon-version-malformed-json\n' >"$COD_RC_STATE/last-failure-reason"
  printf '%s\n' "$(($(date +%s) - 1801))" >"$COD_RC_STATE/last-failure-alert"
  local rc=0
  FAKE_DAEMON_MALFORMED=1 ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  [ "$rc" -eq 40 ] || fail "expected malformed JSON failure"
  _codex_rc_assert_alert_count 'Codex 원격 제어 실패' 0
  # 다른 원인은 기존 30분 쿨다운을 적용한다.
  printf 'remote-control-start-failed\n' >"$COD_RC_STATE/last-failure-reason"
  FAKE_DAEMON_MALFORMED=1 ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  _codex_rc_assert_alert_count 'Codex 원격 제어 실패' 1
  # 같은 장애도 6시간 뒤에는 다시 알린다.
  printf '%s\n' "$(($(date +%s) - 21601))" >"$COD_RC_STATE/last-failure-alert"
  FAKE_DAEMON_MALFORMED=1 ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  _codex_rc_assert_alert_count 'Codex 원격 제어 실패' 2
  # 복구 후 재발은 새 장애이므로 이전 시각 때문에 숨기지 않는다.
  ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  _codex_rc_assert_alert_count 'Codex 원격 제어 복구' 1
  FAKE_DAEMON_MALFORMED=1 ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  _codex_rc_assert_alert_count 'Codex 원격 제어 실패' 3
}

test_codex_remote_control_uses_native_cli_version_without_reinstalling() {
  local sandbox native_link
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  mkdir -p "$COD_RC_HOME/.local/bin"
  native_link="$COD_RC_HOME/.local/bin/codex"
  ln -s "$COD_RC_FAKE_BIN/codex" "$native_link"
  CODEX_BIN="$native_link" _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  [ -L "$native_link" ] || fail "native CLI link must remain installed"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon update'
  assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon start'
  FAKE_CODEX_VERSION=0.143.0 CODEX_BIN="$native_link" _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  assert_file_contains "$COD_RC_LOG" 'app-server daemon update --from-cli --yes'
  jq -e '.desiredVersion == "0.143.0" and .appServerVersion == "0.143.0" and .lastAction == "updated-daemon-from-cli"' "$COD_RC_STATE/status.json" >/dev/null
}

test_codex_remote_control_first_launch_seeds_policy_before_bootstrap() {
  local sandbox actions
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  unlink "$COD_RC_HOME/.codex/packages/app-server-daemon/current"
  # A frontend standalone install alone must not be mistaken for daemon state.
  mkdir -p "$COD_RC_HOME/.codex/packages/standalone/current"
  FAKE_DAEMON_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  actions="$(grep -E '^app-server daemon (start|update)|^remote-control start' "$COD_RC_LOG")"
  [ "$actions" = $'app-server daemon start\napp-server daemon update --from-cli --yes\nremote-control start --json' ] ||
    fail "first daemon lifecycle order was incorrect"
}

test_codex_remote_control_migrates_same_version_legacy_selection_once() {
  local sandbox
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  unlink "$COD_RC_HOME/.codex/packages/app-server-daemon/current"
  mkdir -p "$COD_RC_HOME/.codex/packages/standalone/current" "$COD_RC_HOME/.codex/app-server-daemon"
  : >"$COD_RC_HOME/.codex/app-server-daemon/app-server.stderr.log"
  _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  assert_file_contains "$COD_RC_LOG" 'app-server daemon update --from-cli --yes'
  assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon start'
  : >"$COD_RC_LOG"
  _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon update'
}

test_codex_remote_control_stopped_selection_updates_before_starting() {
  local sandbox layout actions
  for layout in dedicated legacy; do
    sandbox="$(new_sandbox)"
    _codex_rc_setup "$sandbox"
    if [ "$layout" = legacy ]; then
      unlink "$COD_RC_HOME/.codex/packages/app-server-daemon/current"
      mkdir -p "$COD_RC_HOME/.codex/packages/standalone/current" "$COD_RC_HOME/.codex/app-server-daemon"
      : >"$COD_RC_HOME/.codex/app-server-daemon/app-server.stderr.log"
    fi
    FAKE_DAEMON_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running
    actions="$(grep -E '^app-server daemon (start|update)|^remote-control start' "$COD_RC_LOG")"
    [ "$actions" = $'app-server daemon update --from-cli --yes\nremote-control start --json' ] ||
      fail "selected stopped daemon must update before starting"
  done
}

test_codex_remote_control_native_failures_stop_followup_actions() {
  local sandbox mode rc
  for mode in bootstrap update unmanaged; do
    sandbox="$(new_sandbox)"
    _codex_rc_setup "$sandbox"
    rc=0
    case "$mode" in
      bootstrap)
        unlink "$COD_RC_HOME/.codex/packages/app-server-daemon/current"
        FAKE_DAEMON_RC=1 FAKE_BOOTSTRAP_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
        [ "$rc" = 55 ] || fail "bootstrap failure not propagated"
        assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon update'
        ;;
      update)
        FAKE_CODEX_VERSION=0.143.0 FAKE_UPDATE_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
        [ "$rc" = 56 ] || fail "native update failure not propagated"
        ;;
      unmanaged)
        FAKE_DAEMON_RC=1 FAKE_DAEMON_ERR='app server is not managed by codex app-server daemon' \
          _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
        [ "$rc" = 75 ] || fail "unmanaged daemon must be reported without repair"
        assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon update'
        ;;
    esac
    assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start'
    jq -e '.remoteControlEnabled != true and .exitCode != 0' "$COD_RC_STATE/status.json" >/dev/null
  done
}

test_codex_remote_control_ssh_defers_every_daemon_state() {
  local sandbox state rc
  for state in healthy drift missing unmanaged malformed; do
    sandbox="$(new_sandbox)"
    _codex_rc_setup "$sandbox"
    printf '4000500 fixture codex app-server proxy --config example=true\n' >"$COD_RC_PS"
    rc=0
    case "$state" in
      healthy) _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$? ;;
      drift) FAKE_CODEX_VERSION=0.143.0 _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$? ;;
      missing) FAKE_DAEMON_RC=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$? ;;
      unmanaged) FAKE_DAEMON_RC=1 FAKE_DAEMON_ERR='not managed by codex app-server daemon' _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$? ;;
      malformed) FAKE_DAEMON_MALFORMED=1 _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$? ;;
    esac
    [ "$rc" = 62 ] || fail "SSH must defer all daemon changes"
    [ ! -e "$COD_RC_HOME/.codex/app-server-daemon/settings.json" ] || fail "SSH deferral must not write daemon policy"
    assert_not_contains "$(cat "$COD_RC_LOG")" 'login status'
    assert_not_contains "$(cat "$COD_RC_LOG")" 'daemon start'
    assert_not_contains "$(cat "$COD_RC_LOG")" 'daemon update'
    assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start'
    jq -e '.exitCode == 62 and .remoteControlEnabled == null and .lastAction == "deferred-ssh-connected"' "$COD_RC_STATE/status.json" >/dev/null
  done

  # Deferral is neither failure nor recovery, even when alerting is enabled.
  _codex_rc_make_alerting "$sandbox"
  printf 'healthy\n' >"$COD_RC_STATE/last-health-state"
  rc=0
  ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  [ "$rc" = 62 ] || fail "active SSH client must defer"
  [ "$(cat "$COD_RC_STATE/last-health-state")" = healthy ] || fail "deferral changed last observed health"
  _codex_rc_assert_alert_count "Codex 원격 제어 실패" 0
  [ ! -e "$COD_RC_STATE/last-failure-alert" ] || fail "deferral changed alert cooldown"
  : >"$COD_RC_PS"
  ALERT_LOG="$COD_RC_ALERT_LOG" SERVICE_LIB="$COD_RC_SERVICE_LIB" PUSHOVER_CRED_FILE="$COD_RC_PUSHOVER_CRED" \
    _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  _codex_rc_assert_alert_count "Codex 원격 제어 복구" 0
}

test_codex_remote_control_rechecks_ssh_before_policy_and_start() {
  local sandbox rc
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  rc=0
  FAKE_ATTACH_SSH_ON_LOGIN="$COD_RC_PS" _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  [ "$rc" = 62 ] || fail "new SSH connection must defer policy mutation"
  [ ! -e "$COD_RC_HOME/.codex/app-server-daemon/settings.json" ] || fail "policy changed after SSH connected"
  : >"$COD_RC_PS"
  : >"$COD_RC_LOG"
  rc=0
  FAKE_CODEX_VERSION=0.143.0 FAKE_ATTACH_SSH_ON_UPDATE="$COD_RC_PS" _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  [ "$rc" = 62 ] || fail "new SSH connection must defer remote-control start"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start'
}

test_codex_remote_control_settings_merge_preserves_unknown_and_rejects_malformed() {
  local sandbox
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  python3 - "$(_codex_rc_settings_helper)" "$COD_RC_HOME/.codex" <<'PY'
import json, os, pathlib, subprocess, sys
helper, home = sys.argv[1:]
state = pathlib.Path(home) / 'app-server-daemon'
state.mkdir()
target = state / 'settings.json'
original = {'remoteControlEnabled': True, 'future': {'value': ['keep']}, 'updater': {'autoUpdateEnabled': True, 'futurePolicy': 7}}
target.write_text(json.dumps(original))
subprocess.run([sys.executable, helper, home, '1'], check=True)
actual = json.loads(target.read_text())
original['updater']['autoUpdateEnabled'] = False
assert actual == original
assert target.stat().st_mode & 0o777 == 0o600
before = target.stat().st_ino
subprocess.run([sys.executable, helper, home, '1'], check=True)
assert target.stat().st_ino == before, 'already-disabled policy should not rewrite settings'
for invalid in ['{bad', '[]', 'null', '{"updater":null}', '{"updater":[]}', '{"updater":{"autoUpdateEnabled":false},"value":NaN}', '{"value":Infinity}']:
    target.write_text(invalid)
    result = subprocess.run([sys.executable, helper, home, '1'], capture_output=True)
    assert result.returncode != 0
    assert target.read_text() == invalid
assert not list(state.glob('.settings-*'))
PY
}

test_codex_remote_control_settings_lock_serializes_and_preserves_inode() {
  local sandbox
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  python3 - "$(_codex_rc_settings_helper)" "$COD_RC_HOME/.codex" <<'PY'
import fcntl, json, pathlib, subprocess, sys, time
helper, home = sys.argv[1:]
state = pathlib.Path(home) / 'app-server-daemon'
state.mkdir()
target = state / 'settings.json'
target.write_text('{"before":true}')
with (state / 'daemon.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    inode = (state / 'daemon.lock').stat().st_ino
    result = subprocess.run([sys.executable, helper, home, '0.05'], capture_output=True)
    assert result.returncode != 0 and target.read_text() == '{"before":true}'
    child = subprocess.Popen([sys.executable, helper, home, '2'])
    time.sleep(0.15)
    assert child.poll() is None, 'helper bypassed native lock'
    target.write_text('{"concurrent":"preserved","updater":{"future":8}}')
    fcntl.flock(lock, fcntl.LOCK_UN)
    assert child.wait(timeout=3) == 0
assert json.loads(target.read_text()) == {'concurrent': 'preserved', 'updater': {'future': 8, 'autoUpdateEnabled': False}}
assert (state / 'daemon.lock').stat().st_ino == inode
PY
}

test_codex_remote_control_settings_failure_prevents_native_commands() {
  local sandbox rc settings
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  mkdir -p "$COD_RC_HOME/.codex/app-server-daemon"
  settings="$COD_RC_HOME/.codex/app-server-daemon/settings.json"
  printf '{bad\n' >"$settings"
  rc=0
  _codex_rc_env bash "$(_codex_rc_script)" ensure-running 2>/dev/null || rc=$?
  [ "$rc" = 27 ] || fail "invalid settings must fail closed"
  [ "$(cat "$settings")" = '{bad' ] || fail "invalid settings were overwritten"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'daemon update'
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start'
}

test_codex_remote_control_pins_same_version_latest_selection_once() {
  local sandbox root
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  root="$COD_RC_HOME/.codex/packages/app-server-daemon"
  mkdir -p "$root/releases/0.142.4-fixture"
  ln -sfn releases/0.142.4-fixture "$root/current"
  printf '0.142.4-fixture' >"$root/auto-update-version"
  _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  assert_file_contains "$COD_RC_LOG" 'app-server daemon update --from-cli --yes'
  # The fake native update publishes its local release. Model its marker removal.
  unlink "$root/auto-update-version"
  : >"$COD_RC_LOG"
  _codex_rc_env bash "$(_codex_rc_script)" ensure-running
  assert_not_contains "$(cat "$COD_RC_LOG")" 'app-server daemon update'
}

test_codex_remote_control_process_query_failure_is_non_destructive() {
  local sandbox rc
  sandbox="$(new_sandbox)"
  _codex_rc_setup "$sandbox"
  rc=0
  CODEX_REMOTE_CONTROL_PS_FILE="$sandbox/missing-process-file" _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  [ "$rc" = 63 ] || fail "unreadable process evidence must fail closed"
  cat >"$COD_RC_FAKE_BIN/pgrep" <<'EOS'
#!/usr/bin/env bash
exit 2
EOS
  chmod +x "$COD_RC_FAKE_BIN/pgrep"
  : >"$COD_RC_LOG"
  rc=0
  CODEX_REMOTE_CONTROL_PS_FILE='' PATH="$COD_RC_FAKE_BIN:$PATH" _codex_rc_env bash "$(_codex_rc_script)" ensure-running || rc=$?
  [ "$rc" = 63 ] || fail "process lookup error must fail closed"
  [ ! -e "$COD_RC_HOME/.codex/app-server-daemon/settings.json" ] || fail "process lookup failure mutated settings"
  assert_not_contains "$(cat "$COD_RC_LOG")" 'daemon update'
  assert_not_contains "$(cat "$COD_RC_LOG")" 'remote-control start'
}
