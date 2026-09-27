# tests/suites/homeserver-smoke-test.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
#
# 홈서버 스모크 검사(modules/nixos/programs/smoke-test/files/smoke-test.sh)의 종료 코드·알림 계약.
# 검사 실패는 요약 알림 한 번 + 0이 아닌 종료, 예상하지 못한 크래시는 크래시 알림 한 번이다.
# 알림 성공 여부는 종료 코드를 바꾸지 않는다. HTTP·systemctl·알림은 모두 대역이고 백업은 합성 파일이다.

setup_smoke_test_fixture() {
  local sandbox="$1"
  local bin="$sandbox/bin"

  # 백업 신선도 검사가 GNU find -printf / stat -c를 쓴다. BSD 도구면 합성 백업을 못 읽어
  # 엉뚱한 FAIL로 보이므로 원인을 먼저 드러낸다.
  find "$sandbox" -maxdepth 0 -printf '' >/dev/null 2>&1 \
    || fail "smoke-test fixture requires GNU find (-printf)"
  stat -c %Y "$sandbox" >/dev/null 2>&1 \
    || fail "smoke-test fixture requires GNU stat (-c)"

  mkdir -p "$bin" \
    "$sandbox/backups/immich" \
    "$sandbox/backups/karakeep/2026-09-26" \
    "$sandbox/backups/anki-host/main"
  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/pushover"
  : > "$sandbox/notifications.log"

  # 알림 대역: 제목|우선순위|본문 첫 줄을 기록한다. notify-fail 표식이 있으면 실패를 돌려준다.
  cat > "$sandbox/service-lib" <<'EOF'
send_notification() {
  printf '%s|%s|%s\n' "$1" "${3:--1}" "${2%%$'\n'*}" >> "$NOTIFICATION_LOG"
  if [ -e "$NOTIFY_FAIL_MARKER" ]; then
    return 7
  fi
}
EOF

  # 신선한 합성 백업 (mtime = 지금)
  : > "$sandbox/backups/immich/immich-db-20260926.dump"
  : > "$sandbox/backups/karakeep/2026-09-26/db.db.gz"
  : > "$sandbox/backups/anki-host/main/anki-host-main-20260926.colpkg"

  # HTTP 대역: URL별 응답 코드. 목록에 없는 URL은 연결 실패(000)로 끝난다.
  cat > "$sandbox/http-codes" <<'EOF'
https://svc-a.test/ 200
https://svc-b.test/login 302
http://127.0.0.1:8790/health 200
EOF
  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url=""
for arg in "$@"; do
  url="$arg"
done
printf '%s\n' "$url" >> "$CURL_LOG"
code=$(awk -v u="$url" '$1 == u { print $2 }' "$HTTP_CODES_FILE")
if [ -z "$code" ]; then
  printf '000'
  exit 7
fi
printf '%s' "$code"
EOF

  # systemctl 대역: ok=실패 유닛 없음, failed-unit=실패 유닛 1개, error=매니저 조회 실패
  printf 'ok\n' > "$sandbox/systemctl-mode"
  cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$(cat "$SYSTEMCTL_MODE_FILE")" in
  ok) ;;
  failed-unit) printf 'broken.service loaded failed failed Broken unit\n' ;;
  error)
    echo "Failed to connect to bus" >&2
    exit 1
    ;;
esac
EOF

  # tailscale 대역: 승인 배선 검사를 끈 fixture라 호출되면 안 된다.
  cat > "$bin/tailscale" <<'EOF'
#!/usr/bin/env bash
echo "unexpected tailscale call: $*" >&2
exit 99
EOF
  chmod +x "$bin/curl" "$bin/systemctl" "$bin/tailscale"
}

run_smoke_test_fixture() {
  local sandbox="$1"
  local script="$REPO_ROOT/modules/nixos/programs/smoke-test/files/smoke-test.sh"

  # writeShellApplication이 붙이는 헤더(set -o errexit/nounset/pipefail)를 그대로 재현한다.
  PATH="$sandbox/bin:$PATH" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$sandbox/service-lib" \
    NOTIFICATION_LOG="$sandbox/notifications.log" \
    NOTIFY_FAIL_MARKER="$sandbox/notify-fail" \
    CURL_LOG="$sandbox/curl.log" \
    HTTP_CODES_FILE="$sandbox/http-codes" \
    SYSTEMCTL_MODE_FILE="$sandbox/systemctl-mode" \
    TAILSCALE_IP="100.64.0.1" \
    BACKUP_MAX_AGE="26" \
    ENDPOINT_LIST="svc-a.test:200:/ svc-b.test:302:/login" \
    LOOPBACK_ENDPOINT_LIST="200|http://127.0.0.1:8790/health" \
    PUBLIC_ENDPOINT_LIST="" \
    APPROVAL_FQDN="" \
    LEGACY_FUNNEL_PORT="8443" \
    APPROVAL_PORT="9443" \
    APPROVAL_TARGET="" \
    IMMICH_BACKUP_DIR="${SMOKE_IMMICH_BACKUP_DIR-$sandbox/backups/immich}" \
    KARAKEEP_BACKUP_DIR="${SMOKE_KARAKEEP_BACKUP_DIR-$sandbox/backups/karakeep}" \
    ANKI_BACKUP_ROOT="$sandbox/backups/anki-host" \
    ANKI_BACKUP_INSTANCES="${SMOKE_ANKI_BACKUP_INSTANCES-main}" \
    bash -o errexit -o nounset -o pipefail "$script"
}

# 알림 로그에서 종류별 호출 수를 센다. 요약=우선순위 0의 "N/M passed", 크래시=우선순위 1의 "스크립트 크래시".
smoke_summary_notifications() {
  grep -c '^Smoke Test|0|[0-9]*/[0-9]* passed$' "$1/notifications.log" || true
}

smoke_crash_notifications() {
  grep -c '^Smoke Test|1|스크립트 크래시 ' "$1/notifications.log" || true
}

assert_smoke_result() {
  local sandbox="$1" label="$2" actual_rc="$3" expected_rc="$4" expected_summary="$5" expected_crash="$6"
  local summary crash
  summary="$(smoke_summary_notifications "$sandbox")"
  crash="$(smoke_crash_notifications "$sandbox")"
  [[ "$actual_rc" == "$expected_rc" ]] \
    || fail "$label: expected exit $expected_rc, got $actual_rc"
  [[ "$summary" == "$expected_summary" ]] \
    || fail "$label: expected $expected_summary summary notification(s), got $summary"
  [[ "$crash" == "$expected_crash" ]] \
    || fail "$label: expected $expected_crash crash notification(s), got $crash"
}

test_smoke_test_all_pass_exits_zero_without_notification() {
  local mode sandbox output rc
  for mode in notify-ok notify-fail; do
    sandbox="$(new_sandbox)"
    setup_smoke_test_fixture "$sandbox"
    [[ "$mode" == notify-ok ]] || : > "$sandbox/notify-fail"

    if output=$(run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

    assert_smoke_result "$sandbox" "all pass ($mode)" "$rc" 0 0 0
    [[ ! -s "$sandbox/notifications.log" ]] || fail "all pass ($mode): no notification expected"
    # 기존 검사 범위와 순서: HTTP → loopback → immich → karakeep → anki 인스턴스 → systemd
    [[ "$(grep -E '^(OK|FAIL): ' <<<"$output")" == "$(cat <<'EOF'
OK: HTTP svc-a.test/ = 200 (got 200)
OK: HTTP svc-b.test/login = 302 (got 302)
OK: HTTP http://127.0.0.1:8790/health = 200 (got 200)
OK: Immich backup freshness (0h <= 26h)
OK: Karakeep backup freshness (0h <= 26h)
OK: Anki main backup freshness (0h <= 26h)
OK: No failed systemd units (none)
EOF
)" ]] || fail "all pass ($mode): unexpected check list: $output"
    assert_contains "$output" "=== Smoke test: 7/7 passed ==="
  done
}

test_smoke_test_disabled_backups_are_not_checked() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_smoke_test_fixture "$sandbox"
  # 비활성 백업은 Nix가 빈 값으로 주입한다 — 디렉터리가 비어 있어도 검사 대상이 아니다.
  rm -rf "$sandbox/backups"

  if output=$(SMOKE_IMMICH_BACKUP_DIR="" SMOKE_KARAKEEP_BACKUP_DIR="" SMOKE_ANKI_BACKUP_INSTANCES="" \
    run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  assert_smoke_result "$sandbox" "disabled backups" "$rc" 0 0 0
  assert_not_contains "$output" "backup"
  assert_contains "$output" "=== Smoke test: 4/4 passed ==="
}

test_smoke_test_http_failure_exits_nonzero_with_single_summary() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_smoke_test_fixture "$sandbox"
  sed -i.bak 's|^https://svc-b.test/login 302$|https://svc-b.test/login 500|' "$sandbox/http-codes"

  if output=$(run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  assert_smoke_result "$sandbox" "http failure" "$rc" 1 1 0
  assert_contains "$output" "FAIL: HTTP svc-b.test/login = 302 (got 500)"
  assert_file_contains "$sandbox/notifications.log" "Smoke Test|0|6/7 passed"
}

test_smoke_test_stale_backup_exits_nonzero_with_single_summary() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_smoke_test_fixture "$sandbox"
  touch -t 200001010000 "$sandbox/backups/immich/immich-db-20260926.dump"

  if output=$(run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  assert_smoke_result "$sandbox" "stale backup" "$rc" 1 1 0
  assert_contains "$output" "FAIL: Immich backup freshness ("
  assert_file_contains "$sandbox/notifications.log" "Smoke Test|0|6/7 passed"
}

test_smoke_test_systemd_failures_exit_nonzero_with_single_summary() {
  local mode sandbox output rc expected
  for mode in error failed-unit; do
    sandbox="$(new_sandbox)"
    setup_smoke_test_fixture "$sandbox"
    printf '%s\n' "$mode" > "$sandbox/systemctl-mode"

    if output=$(run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

    assert_smoke_result "$sandbox" "systemctl $mode" "$rc" 1 1 0
    case "$mode" in
      error) expected="FAIL: systemd failed-unit query (systemctl rc=1)" ;;
      failed-unit) expected="FAIL: No failed systemd units (broken.service )" ;;
    esac
    assert_contains "$output" "$expected"
  done
}

test_smoke_test_notification_failure_keeps_check_failure() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_smoke_test_fixture "$sandbox"
  sed -i.bak 's|^https://svc-b.test/login 302$|https://svc-b.test/login 500|' "$sandbox/http-codes"
  : > "$sandbox/notify-fail"

  if output=$(run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  # 요약 알림이 실패해도 검사 실패 종료(1)가 유지되고, 같은 실패를 크래시로 다시 알리지 않는다.
  assert_smoke_result "$sandbox" "http failure + notify failure" "$rc" 1 1 0
  assert_contains "$output" "=== Smoke test: 6/7 passed ==="
}

test_smoke_test_crash_sends_single_crash_notification() {
  local mode sandbox output rc
  for mode in notify-ok notify-fail; do
    sandbox="$(new_sandbox)"
    setup_smoke_test_fixture "$sandbox"
    [[ "$mode" == notify-ok ]] || : > "$sandbox/notify-fail"
    # 예상하지 못한 명령 실패: 백업 mtime 조회가 값을 낸 뒤 rc 3으로 끝난다(set -e 크래시).
    cat > "$sandbox/bin/stat" <<'EOF'
#!/usr/bin/env bash
date +%s
exit 3
EOF
    chmod +x "$sandbox/bin/stat"

    if output=$(run_smoke_test_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

    # 크래시 종료 코드는 알림 성공 여부와 무관하게 원래 값(3)을 유지한다.
    assert_smoke_result "$sandbox" "crash ($mode)" "$rc" 3 0 1
    assert_file_contains "$sandbox/notifications.log" \
      "Smoke Test|1|스크립트 크래시 (exit 3). journalctl -u homeserver-smoke-test 확인 필요."
    assert_not_contains "$output" "=== Smoke test:"
  done
}
