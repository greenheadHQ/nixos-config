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
  cat > "$sandbox/service-lib" <<'EOF'
send_notification() {
  printf '%s\n' "$2" >> "$NOTIFICATION_LOG"
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
