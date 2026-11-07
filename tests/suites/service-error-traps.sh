# tests/suites/service-error-traps.sh — 서비스 ERR 전파·단일 알림·복구 회귀
# shellcheck shell=bash
# SC2154: REPO_ROOT 등은 aggregator가 정의한다.
# shellcheck disable=SC2154

# 기존 update fixture의 실제 스크립트·라이브러리·대역을 재사용한다. 실패 주입은
# jq/curl/서비스 제어 경계에서만 수행하며 실제 네트워크·컨테이너를 사용하지 않는다.
_service_error_prepare_update() {
  local sandbox="$1" consumer="$2" command
  "_${consumer}_update_prepare_sandbox" "$sandbox"
  : > "$sandbox/error-events"
  for command in curl podman systemctl; do
    mv "$sandbox/stub-bin/$command" "$sandbox/stub-bin/$command-base"
  done

  cat > "$sandbox/stub-bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${@: -1}"
if [[ "$url" == https://api.pushover.net/* ]]; then
  printf 'notify\n' >> "$SERVICE_ERROR_FIXTURE/error-events"
  "$SERVICE_ERROR_FIXTURE/stub-bin/curl-base" "$@"
  exit "$SERVICE_ERROR_NOTIFY_EXIT"
fi
"$SERVICE_ERROR_FIXTURE/stub-bin/curl-base" "$@"
if [[ "$SERVICE_ERROR_CASE" == explicit && "$url" == http://localhost:* ]]; then
  exit 22
fi
EOF

  cat > "$sandbox/stub-bin/jq" <<'EOF'
#!/usr/bin/env bash
if [[ "$SERVICE_ERROR_CASE" == function && "$*" == *'.tag_name'* ]]; then exit 5; fi
exec "$SERVICE_ERROR_REAL_JQ" "$@"
EOF

  cat > "$sandbox/stub-bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$SERVICE_ERROR_FIXTURE/stub-bin/systemctl-base" "$@"
case "$1" in
  stop)
    : > "$SERVICE_ERROR_FIXTURE/stopped"
    ;;
  start)
    printf 'start\n' >> "$SERVICE_ERROR_FIXTURE/error-events"
    case "$SERVICE_ERROR_CASE" in
      startup|recovery-fails)
        if [[ ! -e "$SERVICE_ERROR_FIXTURE/start-attempted" ]]; then
          : > "$SERVICE_ERROR_FIXTURE/start-attempted"
          exit 31
        fi
        [[ "$SERVICE_ERROR_CASE" != recovery-fails ]] || exit 43
        ;;
      reported-corrupt|reported-small) exit 31 ;;
    esac
    rm -f "$SERVICE_ERROR_FIXTURE/stopped"
    ;;
esac
EOF

  cat > "$sandbox/stub-bin/podman" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == container ]]; then
  printf 'podman %s\n' "$*" >> "$UPDATE_TEST_CALL_LOG"
  printf 'inspect-running\n' >> "$SERVICE_ERROR_FIXTURE/error-events"
  if [[ -e "$SERVICE_ERROR_FIXTURE/stopped" || "$SERVICE_ERROR_CASE" == explicit ]]; then
    printf 'false\n'
  else
    printf 'true\n'
  fi
  exit 0
fi
"$SERVICE_ERROR_FIXTURE/stub-bin/podman-base" "$@"
EOF

  cat > "$sandbox/stub-bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "$SERVICE_ERROR_CASE" == substitution && "$1" == +%Y%m%d-%H%M%S ]]; then exit 11; fi
exec "$SERVICE_ERROR_REAL_DATE" "$@"
EOF

  cat > "$sandbox/stub-bin/gzip" <<'EOF'
#!/usr/bin/env bash
if [[ "$SERVICE_ERROR_CASE" == reported-corrupt && "$1" == -t ]]; then exit 1; fi
exec "$SERVICE_ERROR_REAL_GZIP" "$@"
EOF

  # 명시적 HTTP 실패의 재시도는 횟수를 유지하되 실제 대기하지 않는다.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sandbox/stub-bin/sleep"
  chmod +x "$sandbox/stub-bin/"{curl,jq,systemctl,podman,date,gzip,sleep}
}

_service_error_run_update() (
  local sandbox="$1" consumer="$2" scenario="$3" notify_exit="$4"
  export SERVICE_ERROR_FIXTURE="$sandbox" SERVICE_ERROR_CASE="$scenario" SERVICE_ERROR_NOTIFY_EXIT="$notify_exit"
  export SERVICE_ERROR_REAL_JQ SERVICE_ERROR_REAL_DATE SERVICE_ERROR_REAL_GZIP
  SERVICE_ERROR_REAL_JQ=$(command -v jq)
  SERVICE_ERROR_REAL_DATE=$(command -v date)
  SERVICE_ERROR_REAL_GZIP=$(command -v gzip)
  if [[ "$consumer" == karakeep ]]; then
    _karakeep_update_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" --ack-bridge-risk
  else
    "_${consumer}_update_run" "$sandbox" "$sandbox/stdout" "$sandbox/stderr"
  fi
)

test_update_function_failures_notify_once_without_restart() {
  local consumer notify_exit sandbox rc
  for consumer in immich karakeep uptime_kuma copyparty; do
    for notify_exit in 0 7; do
      sandbox=$(new_sandbox)
      _service_error_prepare_update "$sandbox" "$consumer"
      rc=0
      _service_error_run_update "$sandbox" "$consumer" function "$notify_exit" || rc=$?
      [[ "$rc" == 5 ]] || fail "$consumer function failure must keep exit 5 (got $rc)"
      assert_line_count "$sandbox/error-events" notify 1
      assert_line_count "$sandbox/error-events" start 0
      assert_contains "$(cat "$sandbox/calls.log")" "업데이트 실패: 스크립트 오류 발생"
      assert_not_contains "$(cat "$sandbox/stdout")" "업데이트 실패: 스크립트 오류 발생"
      assert_not_contains "$(cat "$sandbox/stdout")" "Update completed successfully"
      if [[ "$consumer" != immich ]]; then
        assert_line_count "$sandbox/error-events" inspect-running 1
      fi
    done
  done
}

test_update_substitution_failures_keep_status_and_recover_once() {
  local consumer notify_exit sandbox rc
  # 두 백업 스크립트의 TIMESTAMP=$(date ...)는 실제 최상위 명령 치환 경계다.
  for consumer in immich uptime_kuma; do
    for notify_exit in 0 7; do
      sandbox=$(new_sandbox)
      _service_error_prepare_update "$sandbox" "$consumer"
      rc=0
      _service_error_run_update "$sandbox" "$consumer" substitution "$notify_exit" || rc=$?
      [[ "$rc" == 11 ]] || fail "$consumer substitution failure must keep exit 11 (got $rc)"
      assert_line_count "$sandbox/error-events" notify 1
      if [[ "$consumer" == uptime_kuma ]]; then
        # Uptime Kuma는 백업 전에 중지하며, 실패 뒤 기존 cleanup이 한 번 복구한다.
        assert_line_count "$sandbox/error-events" inspect-running 1
        assert_line_count "$sandbox/error-events" start 1
        [[ ! -e "$sandbox/stopped" ]] || fail "stopped fixture container was not recovered"
      else
        assert_line_count "$sandbox/error-events" start 0
      fi
    done
  done
}

test_update_startup_failure_preserves_recovery_and_single_notification() {
  local consumer scenario notify_exit sandbox rc
  for consumer in immich karakeep uptime_kuma copyparty; do
    for scenario in startup recovery-fails; do
      for notify_exit in 0 7; do
        sandbox=$(new_sandbox)
        _service_error_prepare_update "$sandbox" "$consumer"
        rc=0
        _service_error_run_update "$sandbox" "$consumer" "$scenario" "$notify_exit" || rc=$?
        [[ "$rc" == 31 ]] || fail "$consumer/$scenario must keep original start exit 31 (got $rc)"
        assert_line_count "$sandbox/error-events" notify 1
        assert_line_count "$sandbox/error-events" inspect-running 1
        if [[ "$consumer" == immich ]]; then
          # Immich의 기존 오류 처리에는 자동 재시작이 없다. 새 복구 정책을 추가하지 않는다.
          assert_line_count "$sandbox/error-events" start 1
          [[ -e "$sandbox/stopped" ]] || fail "Immich failure unexpectedly recovered containers"
          continue
        fi
        # 최초 start의 실패 뒤 cleanup의 복구 시도는 딱 한 번이다.
        assert_line_count "$sandbox/error-events" start 2
        assert_not_contains "$(cat "$sandbox/stdout")" "Restarting container after failure"
        if [[ "$scenario" == startup ]]; then
          [[ ! -e "$sandbox/stopped" ]] || fail "recovery did not start fixture container"
          assert_contains "$(cat "$sandbox/calls.log")" "컨테이너 자동 복구 완료"
        else
          [[ -e "$sandbox/stopped" ]] || fail "failed recovery was treated as running"
          assert_contains "$(cat "$sandbox/calls.log")" "컨테이너 자동 복구 실패"
        fi
      done
    done
  done
}

test_update_explicit_failures_do_not_send_duplicate_notifications() {
  local consumer notify_exit sandbox rc
  for consumer in immich karakeep uptime_kuma copyparty; do
    for notify_exit in 0 7; do
      sandbox=$(new_sandbox)
      _service_error_prepare_update "$sandbox" "$consumer"
      rc=0
      _service_error_run_update "$sandbox" "$consumer" explicit "$notify_exit" || rc=$?
      [[ "$rc" == 1 ]] || fail "$consumer explicit failure must keep exit 1 (got $rc)"
      assert_line_count "$sandbox/error-events" notify 1
      assert_not_contains "$(cat "$sandbox/calls.log")" "업데이트 실패: 스크립트 오류 발생"
      if [[ "$consumer" == immich ]]; then
        assert_line_count "$sandbox/error-events" start 0
      else
        assert_line_count "$sandbox/error-events" start 1
        assert_line_count "$sandbox/error-events" inspect-running 0
      fi
    done
  done
}

test_uptime_reported_backup_failure_does_not_retry_failed_recovery() {
  local scenario notify_exit sandbox rc
  for scenario in reported-corrupt reported-small; do
    for notify_exit in 0 7; do
      sandbox=$(new_sandbox)
      _service_error_prepare_update "$sandbox" uptime_kuma
      [[ "$scenario" != reported-small ]] || printf 'small fixture\n' > "$sandbox/data/kuma.db"
      rc=0
      _service_error_run_update "$sandbox" uptime_kuma "$scenario" "$notify_exit" || rc=$?
      [[ "$rc" == 1 ]] || fail "$scenario must keep reported backup failure exit 1 (got $rc)"
      assert_line_count "$sandbox/error-events" notify 1
      assert_line_count "$sandbox/error-events" start 1
      assert_line_count "$sandbox/error-events" inspect-running 0
      assert_contains "$(cat "$sandbox/stderr")" "container recovery failed"
      assert_not_contains "$(cat "$sandbox/calls.log")" "업데이트 실패: 스크립트 오류 발생"
    done
  done
}

test_update_success_preserves_single_notification() {
  local consumer notify_exit sandbox
  for consumer in immich karakeep uptime_kuma copyparty; do
    for notify_exit in 0 7; do
      sandbox=$(new_sandbox)
      _service_error_prepare_update "$sandbox" "$consumer"
      _service_error_run_update "$sandbox" "$consumer" normal "$notify_exit" ||
        fail "$consumer normal update failed"
      assert_line_count "$sandbox/error-events" notify 1
      assert_contains "$(cat "$sandbox/stdout")" "Update completed successfully"
      assert_not_contains "$(cat "$sandbox/calls.log")" "업데이트 실패: 스크립트 오류 발생"
    done
  done
}

test_service_error_handler_preserves_nested_status_and_callback_failure() {
  local scenario sandbox rc expected_rc expected_calls
  for scenario in function substitution nested-substitution subshell pipeline condition explicit normal; do
    sandbox=$(new_sandbox)
    : > "$sandbox/events"
    rc=0
    SERVICE_ERROR_LIB="$REPO_ROOT/modules/nixos/lib/service-lib.sh" SERVICE_ERROR_EVENTS="$sandbox/events" \
      bash -s -- "$scenario" > "$sandbox/stdout" 2> "$sandbox/stderr" <<'EOF' || rc=$?
set -euo pipefail
source "$SERVICE_ERROR_LIB"
report() {
  printf 'report\n' >> "$SERVICE_ERROR_EVENTS"
  printf 'callback output\n'
  return 77
}
service_install_error_trap report
fail_inside_function() { bash -c 'exit 5'; }
case "$1" in
  function) fail_inside_function ;;
  substitution) value=$(fail_inside_function) ;;
  nested-substitution) value=$(inner=$(fail_inside_function)) ;;
  subshell) (fail_inside_function) ;;
  pipeline) fail_inside_function | cat ;;
  condition) if fail_inside_function; then exit 91; fi ;;
  explicit) printf 'reported\n' >> "$SERVICE_ERROR_EVENTS"; exit 5 ;;
  normal) : ;;
esac
EOF
    expected_rc=5
    expected_calls=1
    case "$scenario" in
      condition|normal) expected_rc=0; expected_calls=0 ;;
      explicit) expected_calls=0 ;;
    esac
    [[ "$rc" == "$expected_rc" ]] || fail "$scenario must keep exit $expected_rc (got $rc)"
    assert_line_count "$sandbox/events" report "$expected_calls"
    [[ ! -s "$sandbox/stdout" ]] || fail "$scenario error callback polluted stdout"
  done
}
