# tests/suites/immich-cleanup-v3-guard.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT 등)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

setup_immich_cleanup_fixture() {
  local sandbox="$1"
  local scenario="$2"
  local bin="$sandbox/bin"

  mkdir -p "$bin"
  printf 'IMMICH_API_KEY=test-key\n' > "$sandbox/api-key"
  printf 'PUSHOVER_TOKEN=x\nPUSHOVER_USER=x\n' > "$sandbox/pushover"
  # 알림 대역: notify-fail 표식이 있으면 실패를 돌려준다 (알림 실패가 정리 결과를 바꾸는지 검사용).
  cat > "$sandbox/service-lib" <<'EOF'
send_notification() {
  printf '%s\n' "$2" >> "$NOTIFICATION_LOG"
  if [ -e "$NOTIFY_FAIL_MARKER" ]; then
    return 7
  fi
}
EOF
  printf '%s\n' "$scenario" > "$sandbox/scenario"

  cat > "$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

body=""
method="GET"
url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X)
      method="$2"
      shift 2
      ;;
    -d)
      body="$2"
      shift 2
      ;;
    -sf|-fsS|-s|-f)
      shift
      ;;
    -H|--proto|--connect-timeout|--max-time|--form-string)
      shift
      if [ "$#" -gt 0 ] && [[ "$1" != -* ]] && [[ "$1" != http* ]]; then
        shift
      fi
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  */api/albums)
    printf '[{"albumName":"Claude Code Temp","id":"album-1"}]\n'
    ;;
  */api/search/metadata)
    page=$(jq -r '.page' <<<"$body")
    printf 'page=%s\n' "$page" >> "$REQUEST_LOG"
    case "$(cat "$SCENARIO_FILE"):$page" in
      paginated:1)
        printf '{"assets":{"items":[{"id":"11111111-1111-1111-8111-111111111111"},{"id":"22222222-2222-2222-8222-222222222222"}],"nextPage":"2","count":2,"total":3,"facets":[]}}'
        ;;
      paginated:2)
        printf '{"assets":{"items":[{"id":"33333333-3333-3333-8333-333333333333"}],"nextPage":null,"count":1,"total":3,"facets":[]}}'
        ;;
      empty:1)
        printf '{"assets":{"items":[],"nextPage":null,"count":0,"total":0,"facets":[]}}'
        ;;
      invalid-id:1)
        printf '{"assets":{"items":[{"id":"not-a-uuid"}],"nextPage":null,"count":1,"total":1,"facets":[]}}'
        ;;
      invalid-next-page:1)
        printf '{"assets":{"items":[{"id":"44444444-4444-4444-8444-444444444444"}],"nextPage":"","count":1,"total":1,"facets":[]}}'
        ;;
      *)
        printf 'unexpected scenario/page: %s/%s\n' "$(cat "$SCENARIO_FILE")" "$page" >&2
        exit 1
        ;;
    esac
    ;;
  */api/assets)
    [ "$method" = "DELETE" ] || exit 1
    jq -r '.ids[]' <<<"$body" >> "$DELETE_LOG"
    jq -c . <<<"$body" >> "$DELETE_BODY_LOG"
    # delete-fail-ids에 적힌 자산은 HTTP 오류로 응답한다 (curl -f의 22)
    if [ -f "$DELETE_FAIL_FILE" ] && grep -Fqx "$(jq -r '.ids[0]' <<<"$body")" "$DELETE_FAIL_FILE"; then
      exit 22
    fi
    ;;
  *)
    printf 'unexpected curl url: %s\n' "$url" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "$bin/curl"
}

run_immich_cleanup_fixture() {
  local sandbox="$1"
  local script="$REPO_ROOT/modules/nixos/programs/immich-cleanup/files/cleanup-script.sh"

  PATH="$sandbox/bin:$PATH" \
    IMMICH_URL="http://immich.test" \
    API_KEY_FILE="$sandbox/api-key" \
    ALBUM_NAME="Claude Code Temp" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$sandbox/service-lib" \
    NOTIFICATION_LOG="$sandbox/notifications.log" \
    REQUEST_LOG="$sandbox/requests.log" \
    DELETE_LOG="$sandbox/deletes.log" \
    DELETE_BODY_LOG="$sandbox/delete-bodies.log" \
    DELETE_FAIL_FILE="$sandbox/delete-fail-ids" \
    NOTIFY_FAIL_MARKER="$sandbox/notify-fail" \
    SCENARIO_FILE="$sandbox/scenario" \
    bash "$script"
}

test_immich_cleanup_v3_paginates_next_page_string() {
  local sandbox output
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" paginated

  output=$(run_immich_cleanup_fixture "$sandbox")

  assert_contains "$output" "Found 3 assets to delete"
  assert_contains "$output" "Cleanup completed. Success: 3, Failed: 0"
  assert_file_contains "$sandbox/deletes.log" "11111111-1111-1111-8111-111111111111"
  assert_file_contains "$sandbox/deletes.log" "22222222-2222-2222-8222-222222222222"
  assert_file_contains "$sandbox/deletes.log" "33333333-3333-3333-8333-333333333333"
  assert_line_count "$sandbox/requests.log" "page=1" 1
  assert_line_count "$sandbox/requests.log" "page=2" 1
}

test_immich_cleanup_v3_empty_album_preserves_notification() {
  local sandbox output
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" empty

  output=$(run_immich_cleanup_fixture "$sandbox")

  assert_contains "$output" "No assets in album. Nothing to cleanup."
  assert_file_contains "$sandbox/notifications.log" "삭제할 이미지가 없습니다"
  [[ ! -e "$sandbox/deletes.log" ]] || fail "empty album must not call asset delete"
}

test_immich_cleanup_v3_rejects_invalid_asset_id() {
  local sandbox output
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" invalid-id

  if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then
    fail "invalid asset id must fail cleanup before delete"
  fi

  assert_contains "$output" "Unexpected search response: asset id is not a UUID string"
  assert_file_contains "$sandbox/notifications.log" "앨범 asset ID 응답 형식 오류"
  [[ ! -e "$sandbox/deletes.log" ]] || fail "invalid asset id must not call asset delete"
}

test_immich_cleanup_v3_rejects_invalid_next_page() {
  local sandbox output
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" invalid-next-page

  if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then
    fail "invalid nextPage must fail cleanup before delete"
  fi

  assert_contains "$output" "Unexpected search response: .assets.nextPage is not a positive integer string"
  assert_file_contains "$sandbox/notifications.log" "앨범 asset 페이지 응답 형식 오류"
  [[ ! -e "$sandbox/deletes.log" ]] || fail "invalid nextPage must not call asset delete"
}

# ─── 종료 코드 계약 (#1387): 전부 성공·빈 앨범은 0, 삭제 실패가 하나라도 있으면 1 ───
# 요약 알림은 결과마다 한 번이고, 알림 실패가 정리 결과(종료 코드)를 바꾸지 않는다.

# paginated 시나리오의 요청 계약: 페이지마다 조회 1회, 자산마다 DELETE 1회(force=true, 실패 자산 재시도 없음)
assert_immich_cleanup_paginated_requests() {
  local sandbox="$1" id forced
  assert_line_count "$sandbox/requests.log" "page=1" 1
  assert_line_count "$sandbox/requests.log" "page=2" 1
  [[ "$(wc -l < "$sandbox/requests.log")" -eq 2 ]] || fail "expected exactly 2 page requests"
  for id in 11111111-1111-1111-8111-111111111111 \
    22222222-2222-2222-8222-222222222222 \
    33333333-3333-3333-8333-333333333333; do
    assert_line_count "$sandbox/deletes.log" "$id" 1
    forced="$(grep -Fxc "{\"ids\":[\"$id\"],\"force\":true}" "$sandbox/delete-bodies.log" || true)"
    [[ "$forced" == 1 ]] || fail "expected one DELETE with force=true for $id (actual: $forced)"
  done
  [[ "$(wc -l < "$sandbox/deletes.log")" -eq 3 ]] || fail "expected exactly 3 delete requests"
}

# 알림 로그가 기대한 메시지 한 줄뿐인지 본다 — ERR trap의 "오류 발생" 알림이 끼면 실패한다.
assert_immich_cleanup_only_notification() {
  local sandbox="$1" label="$2" expected="$3" actual
  actual="$(cat "$sandbox/notifications.log" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] \
    || fail "$label: expected only notification '$expected', got: $actual"
}

test_immich_cleanup_all_success_exits_zero_with_single_summary() {
  local mode sandbox output rc
  for mode in notify-ok notify-fail; do
    sandbox="$(new_sandbox)"
    setup_immich_cleanup_fixture "$sandbox" paginated
    [[ "$mode" == notify-ok ]] || : > "$sandbox/notify-fail"

    if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

    [[ "$rc" == 0 ]] || fail "all success ($mode): expected exit 0, got $rc"
    assert_contains "$output" "Cleanup completed. Success: 3, Failed: 0"
    assert_immich_cleanup_only_notification "$sandbox" "all success ($mode)" "3개 이미지 삭제됨"
    assert_immich_cleanup_paginated_requests "$sandbox"
  done
}

test_immich_cleanup_empty_album_exits_zero() {
  local mode sandbox output rc
  for mode in notify-ok notify-fail; do
    sandbox="$(new_sandbox)"
    setup_immich_cleanup_fixture "$sandbox" empty
    [[ "$mode" == notify-ok ]] || : > "$sandbox/notify-fail"

    if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

    [[ "$rc" == 0 ]] || fail "empty album ($mode): expected exit 0, got $rc"
    assert_immich_cleanup_only_notification "$sandbox" "empty album ($mode)" "삭제할 이미지가 없습니다"
    assert_line_count "$sandbox/requests.log" "page=1" 1
    [[ ! -e "$sandbox/deletes.log" ]] || fail "empty album ($mode) must not call asset delete"
  done
}

test_immich_cleanup_partial_delete_failure_exits_nonzero() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" paginated
  printf '%s\n' 22222222-2222-2222-8222-222222222222 > "$sandbox/delete-fail-ids"

  if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  [[ "$rc" == 1 ]] || fail "partial failure: expected exit 1, got $rc"
  assert_contains "$output" "Failed to delete asset: 22222222-2222-2222-8222-222222222222"
  assert_contains "$output" "Cleanup completed. Success: 2, Failed: 1"
  assert_immich_cleanup_only_notification "$sandbox" "partial failure" "2개 삭제, 1개 실패"
  assert_immich_cleanup_paginated_requests "$sandbox"
}

test_immich_cleanup_all_delete_failure_exits_nonzero() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" paginated
  printf '%s\n' 11111111-1111-1111-8111-111111111111 \
    22222222-2222-2222-8222-222222222222 \
    33333333-3333-3333-8333-333333333333 > "$sandbox/delete-fail-ids"

  if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  [[ "$rc" == 1 ]] || fail "all failure: expected exit 1, got $rc"
  assert_contains "$output" "Cleanup completed. Success: 0, Failed: 3"
  assert_immich_cleanup_only_notification "$sandbox" "all failure" "0개 삭제, 3개 실패"
  assert_immich_cleanup_paginated_requests "$sandbox"
}

test_immich_cleanup_notification_failure_keeps_delete_failure() {
  local sandbox output rc
  sandbox="$(new_sandbox)"
  setup_immich_cleanup_fixture "$sandbox" paginated
  printf '%s\n' 22222222-2222-2222-8222-222222222222 > "$sandbox/delete-fail-ids"
  : > "$sandbox/notify-fail"

  if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

  # 알림 실패 코드(7)가 삭제 실패 종료(1)를 덮지 않고, ERR trap 알림으로 중복되지 않는다.
  [[ "$rc" == 1 ]] || fail "partial failure + notify failure: expected exit 1, got $rc"
  assert_contains "$output" "Cleanup completed. Success: 2, Failed: 1"
  assert_immich_cleanup_only_notification "$sandbox" "partial failure + notify failure" "2개 삭제, 1개 실패"
  assert_immich_cleanup_paginated_requests "$sandbox"
}

test_immich_cleanup_unexpected_failure_sends_single_error_notification() {
  local mode sandbox output rc real_jq
  real_jq="$(command -v jq)"
  for mode in notify-ok notify-fail; do
    sandbox="$(new_sandbox)"
    setup_immich_cleanup_fixture "$sandbox" paginated
    [[ "$mode" == notify-ok ]] || : > "$sandbox/notify-fail"
    # 예상하지 못한 명령 실패: 스크립트 본문의 DELETE body 생성(force 포함 jq -n)만 rc 5로 실패하고,
    # 나머지 jq 호출(대역 curl 포함)은 실제 jq에 맡긴다.
    cat > "$sandbox/bin/jq" <<EOS
#!/usr/bin/env bash
case "\$*" in
  *"force: true"*) exit 5 ;;
esac
exec "$real_jq" "\$@"
EOS
    chmod +x "$sandbox/bin/jq"

    if output=$(run_immich_cleanup_fixture "$sandbox" 2>&1); then rc=0; else rc=$?; fi

    # 원래 실패 코드(5)로 끝나고, 요약 알림 없이 ERR trap 알림만 한 번 나간다.
    # 알림이 실패(7)해도 종료 코드는 5다.
    [[ "$rc" == 5 ]] || fail "unexpected failure ($mode): expected exit 5, got $rc"
    assert_not_contains "$output" "Cleanup completed."
    assert_immich_cleanup_only_notification "$sandbox" "unexpected failure ($mode)" "오류 발생: 스크립트 실패"
    assert_line_count "$sandbox/requests.log" "page=1" 1
    assert_line_count "$sandbox/requests.log" "page=2" 1
    [[ ! -e "$sandbox/deletes.log" ]] || fail "unexpected failure ($mode) must stop before asset delete"
  done
}
