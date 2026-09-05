# tests/suites/interaction-limits-renewal.sh — interaction limits 갱신 스크립트 fixture tests (sourced)
# shellcheck shell=bash
# shellcheck disable=SC2154

_ilr_script="$REPO_ROOT/modules/nixos/programs/interaction-limits-renewal/files/interaction-limits-renewal.sh"

# 단일 gh stub:
#   GET  — ILR_TEST_GET_EXIT가 0이면 ILR_TEST_GET_JSON(기본 '{}')을 반환, 아니면 해당 코드로 실패.
#          PUT 이후(marker 존재)에는 ILR_TEST_GET_JSON_AFTER_PUT이 있으면 그 값을 반환.
#   PUT  — 모든 `api -X` 호출을 PUT으로 간주해 marker 파일을 남기고 ILR_TEST_PUT_EXIT로 종료
#          (의도적 단순화: 검증 대상 스크립트의 유일한 -X 호출이 PUT이다).
_ilr_install_gh_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$ILR_TEST_GH_LOG"
if [ "${1:-}" = "api" ] && [ "${2:-}" = "-X" ]; then
  touch "$ILR_TEST_PUT_DONE_MARKER"
  exit "${ILR_TEST_PUT_EXIT:-0}"
fi
if [ "${ILR_TEST_GET_EXIT:-0}" -ne 0 ]; then
  exit "${ILR_TEST_GET_EXIT}"
fi
json="${ILR_TEST_GET_JSON-}"
[ -n "$json" ] || json='{}'
if [ -f "${ILR_TEST_PUT_DONE_MARKER:-/nonexistent}" ] && [ -n "${ILR_TEST_GET_JSON_AFTER_PUT:-}" ]; then
  json="$ILR_TEST_GET_JSON_AFTER_PUT"
fi
if [ "${1:-}" = "api" ] && [ "${3:-}" = "--jq" ]; then
  printf '%s\n' "$json" | jq -r "${4:-.}"
  exit 0
fi
printf '%s\n' "$json"
exit 0
STUB
  chmod +x "$path"
}

# PUSHOVER_LIB stub: 실제 전송 없이 제목/본문을 캡처한다.
_ilr_install_pushover_lib_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
send_pushover_fail_soft() {
  printf '%s\t%s\t%s\n' "$3" "$4" "$5" >> "$ILR_TEST_NOTIFY_LOG"
  return 0
}
STUB
}

_ilr_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/bin"
  : > "$sandbox/gh.log"
  : > "$sandbox/notify.log"
  printf 'fixture-pat\n' > "$sandbox/github-pat"
  printf 'cred\n' > "$sandbox/pushover-cred"
  printf 'helper\n' > "$sandbox/pushover-helper"
  _ilr_install_pushover_lib_stub "$sandbox/pushover-lib.sh"
  _ilr_install_gh_stub "$sandbox/bin/gh"
}

_ilr_run() {
  local sandbox="$1"
  shift
  env \
    PATH="$sandbox/bin:$PATH" \
    REPO="example-owner/example-repo" \
    LIMIT_VALUE="collaborators_only" \
    EXPIRY="six_months" \
    RENEW_THRESHOLD_DAYS="14" \
    GH_PAT_PATH="$sandbox/github-pat" \
    PUSHOVER_HELPER="$sandbox/pushover-helper" \
    PUSHOVER_SHARE_CRED="$sandbox/pushover-cred" \
    PUSHOVER_LIB="$sandbox/pushover-lib.sh" \
    ILR_TEST_GH_LOG="$sandbox/gh.log" \
    ILR_TEST_NOTIFY_LOG="$sandbox/notify.log" \
    ILR_TEST_PUT_DONE_MARKER="$sandbox/put-done" \
    "$@" \
    bash "$_ilr_script"
}

_ilr_future_date() {
  # GNU date 전제 (NixOS/prePushRuntime coreutils).
  date -u -d "+$1 days" +%Y-%m-%dT%H:%M:%SZ
}

test_ilr_no_renewal_when_far_from_expiry() {
  local sandbox expires
  sandbox=$(new_sandbox)
  _ilr_prepare_sandbox "$sandbox"
  expires=$(_ilr_future_date 100)

  local out
  out=$(_ilr_run "$sandbox" ILR_TEST_GET_JSON="{\"limit\":\"collaborators_only\",\"expires_at\":\"$expires\"}")

  assert_contains "$out" "no renewal needed"
  if grep -q "PUT" "$sandbox/gh.log"; then
    fail "PUT must not run when far from expiry"
  fi
  if [ -s "$sandbox/notify.log" ]; then
    fail "no notification expected on quiet path"
  fi
}

test_ilr_renews_and_notifies_when_near_expiry() {
  local sandbox expires new_expires
  sandbox=$(new_sandbox)
  _ilr_prepare_sandbox "$sandbox"
  expires=$(_ilr_future_date 5)
  new_expires=$(_ilr_future_date 182)

  _ilr_run "$sandbox" \
    ILR_TEST_GET_JSON="{\"limit\":\"collaborators_only\",\"expires_at\":\"$expires\"}" \
    ILR_TEST_GET_JSON_AFTER_PUT="{\"limit\":\"collaborators_only\",\"expires_at\":\"$new_expires\"}" \
    > "$sandbox/stdout"

  assert_contains "$(cat "$sandbox/gh.log")" "api -X PUT repos/example-owner/example-repo/interaction-limits"
  assert_contains "$(cat "$sandbox/notify.log")" "갱신 필요"
  assert_contains "$(cat "$sandbox/notify.log")" "갱신 완료"
  assert_contains "$(cat "$sandbox/stdout")" "RENEWED: reason=expiring"
  assert_contains "$(cat "$sandbox/stdout")" "$new_expires"
}

test_ilr_renews_when_limits_absent() {
  local sandbox
  sandbox=$(new_sandbox)
  _ilr_prepare_sandbox "$sandbox"

  _ilr_run "$sandbox" ILR_TEST_GET_JSON="{}" > "$sandbox/stdout"

  assert_contains "$(cat "$sandbox/gh.log")" "api -X PUT repos/example-owner/example-repo/interaction-limits"
  assert_contains "$(cat "$sandbox/notify.log")" "limits 미설정"
  assert_contains "$(cat "$sandbox/notify.log")" "갱신 완료"
  assert_contains "$(cat "$sandbox/stdout")" "RENEWED: reason=absent"
}

test_ilr_get_failure_notifies_and_exits_nonzero() {
  local sandbox
  sandbox=$(new_sandbox)
  _ilr_prepare_sandbox "$sandbox"

  if _ilr_run "$sandbox" ILR_TEST_GET_EXIT=1 > "$sandbox/stdout" 2> "$sandbox/stderr"; then
    fail "script must exit nonzero when GET fails"
  fi
  assert_contains "$(cat "$sandbox/notify.log")" "조회(GET) 실패"
  assert_contains "$(cat "$sandbox/stderr")" "GET failed"
  if grep -q "PUT" "$sandbox/gh.log"; then
    fail "PUT must not run when GET fails (미설정 오진 방지)"
  fi
}

test_ilr_put_failure_notifies_and_exits_nonzero() {
  local sandbox expires
  sandbox=$(new_sandbox)
  _ilr_prepare_sandbox "$sandbox"
  expires=$(_ilr_future_date 3)

  if _ilr_run "$sandbox" \
    ILR_TEST_GET_JSON="{\"limit\":\"collaborators_only\",\"expires_at\":\"$expires\"}" \
    ILR_TEST_PUT_EXIT=1 > "$sandbox/stdout" 2> "$sandbox/stderr"; then
    fail "script must exit nonzero when PUT fails"
  fi
  assert_contains "$(cat "$sandbox/notify.log")" "갱신 실패"
  assert_contains "$(cat "$sandbox/stderr")" "PUT failed"
}

test_ilr_missing_pat_notifies_and_exits_nonzero() {
  local sandbox
  sandbox=$(new_sandbox)
  _ilr_prepare_sandbox "$sandbox"
  rm -f "$sandbox/github-pat"

  if _ilr_run "$sandbox" > "$sandbox/stdout" 2> "$sandbox/stderr"; then
    fail "script must exit nonzero when github-pat is unreadable"
  fi
  assert_contains "$(cat "$sandbox/notify.log")" "갱신 실패"
  assert_contains "$(cat "$sandbox/stderr")" "GH_PAT_PATH not readable"
  if grep -q "api" "$sandbox/gh.log"; then
    fail "gh must not be called without a readable PAT"
  fi
}
