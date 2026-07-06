# tests/suites/karakeep-fallback-sync.sh - Karakeep fallback sync fixture tests (sourced)
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_karakeep_fallback_sync_script="$REPO_ROOT/modules/nixos/programs/docker/karakeep-fallback-sync/files/fallback-sync.sh"

_karakeep_fallback_sync_install_curl_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

output_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o)
      output_path="${2:-}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "$*" >> "$FALLBACK_SYNC_TEST_CURL_LOG"
if [ -n "$output_path" ]; then
  printf '%s\n' "${FALLBACK_SYNC_TEST_CURL_BODY:-{\"ok\":true}}" > "$output_path"
fi
printf '%s' "${FALLBACK_SYNC_TEST_HTTP_CODE:-200}"
exit "${FALLBACK_SYNC_TEST_CURL_EXIT:-0}"
STUB
  chmod +x "$path"
}

_karakeep_fallback_sync_prepare_sandbox() {
  local sandbox="$1"
  mkdir -p "$sandbox/fallback" "$sandbox/state" "$sandbox/stub-bin"
  printf 'KARAKEEP_API_KEY=fixture-api-key\n' > "$sandbox/pushover"
  : > "$sandbox/notifications.log"
  : > "$sandbox/curl.log"
  cat > "$sandbox/service-lib" <<'STUB'
send_notification() {
  printf 'send_notification\t%s\n' "$*" >> "$FALLBACK_SYNC_TEST_NOTIFICATIONS"
}

send_notification_strict() {
  printf 'send_notification_strict\t%s\n' "$*" >> "$FALLBACK_SYNC_TEST_NOTIFICATIONS"
}
STUB
  _karakeep_fallback_sync_install_curl_stub "$sandbox/stub-bin/curl"
}

_karakeep_fallback_sync_run() {
  local sandbox="$1"
  local stdout_path="$2"
  local stderr_path="$3"

  env \
    PATH="$sandbox/stub-bin:$PATH" \
    PUSHOVER_CRED_FILE="$sandbox/pushover" \
    SERVICE_LIB="$sandbox/service-lib" \
    FALLBACK_DIR="$sandbox/fallback" \
    FAILED_URL_QUEUE_FILE="$sandbox/state/failed-urls.txt" \
    KARAKEEP_BASE_URL="http://karakeep.local" \
    FALLBACK_SYNC_TEST_CURL_LOG="$sandbox/curl.log" \
    FALLBACK_SYNC_TEST_NOTIFICATIONS="$sandbox/notifications.log" \
    FALLBACK_SYNC_TEST_HTTP_CODE="${FALLBACK_SYNC_TEST_HTTP_CODE:-200}" \
    FALLBACK_SYNC_TEST_CURL_EXIT="${FALLBACK_SYNC_TEST_CURL_EXIT:-0}" \
    bash -eu -o pipefail "$_karakeep_fallback_sync_script" > "$stdout_path" 2> "$stderr_path"
}

test_karakeep_fallback_sync_success_removes_only_matched_queue_url() {
  local sandbox stdout_path stderr_path matched_url remaining_url output
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  matched_url="https://example.com/articles/one?from=queue"
  remaining_url="https://example.com/articles/two"
  printf '%s\n%s\n' "$matched_url" "$remaining_url" > "$sandbox/state/failed-urls.txt"
  cat > "$sandbox/fallback/archive.html" <<'HTML'
<!doctype html>
<link rel="canonical" href="https://example.com/articles/one?from=singlefile">
HTML

  _karakeep_fallback_sync_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected fallback sync success case to exit 0"

  assert_file_contains "$sandbox/state/failed-urls.txt" "$remaining_url"
  ! grep -Fqx "$matched_url" "$sandbox/state/failed-urls.txt" \
    || fail "expected matched queue URL to be removed"
  grep -Fq "$matched_url" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected processed state to record matched URL"
  output=$(cat "$stdout_path")
  assert_contains "$output" "Auto relink succeeded: $matched_url <- $sandbox/fallback/archive.html"
}

test_karakeep_fallback_sync_upload_failure_preserves_queue_and_records_notify_state() {
  local sandbox stdout_path stderr_path failed_url output notify_state
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  failed_url="https://example.com/articles/fail"
  printf '%s\n' "$failed_url" > "$sandbox/state/failed-urls.txt"
  cat > "$sandbox/fallback/archive.html" <<'HTML'
<!doctype html>
<meta property="og:url" content="https://example.com/articles/fail/">
HTML

  FALLBACK_SYNC_TEST_CURL_EXIT=7 FALLBACK_SYNC_TEST_HTTP_CODE=000 \
    _karakeep_fallback_sync_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected upload failure case to preserve current script-level exit 0"

  assert_file_contains "$sandbox/state/failed-urls.txt" "$failed_url"
  [ ! -s "$sandbox/state/fallback-processed.tsv" ] \
    || fail "expected upload failure not to record processed state"
  notify_state=$(cat "$sandbox/state/fallback-notify-state.tsv")
  assert_contains "$notify_state" "upload-failed:example.com/articles/fail"
  output=$(cat "$stdout_path")
  assert_contains "$output" "Fallback sync failure count: 1/3"
}

test_karakeep_fallback_sync_gc_removes_only_expired_state_entries() {
  local sandbox stdout_path stderr_path now
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  stdout_path="$sandbox/stdout"
  stderr_path="$sandbox/stderr"
  now=$(date +%s)
  : > "$sandbox/state/failed-urls.txt"
  printf 'old\n' > "$sandbox/fallback/old.html"
  printf 'new\n' > "$sandbox/fallback/new.html"
  cat > "$sandbox/state/fallback-processed.tsv" <<EOF
old-hash	https://example.com/old	$sandbox/fallback/old.html	946684800
new-hash	https://example.com/new	$sandbox/fallback/new.html	$now
EOF
  cat > "$sandbox/state/fallback-unmatched-notified.tsv" <<EOF
old-unmatched	946684800	$sandbox/fallback/old.html
new-unmatched	$now	$sandbox/fallback/new.html
EOF
  cat > "$sandbox/state/fallback-notify-state.tsv" <<EOF
old-notify	946684800
new-notify	$now
EOF

  _karakeep_fallback_sync_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected GC-only case with empty queue to exit 0"

  ! grep -Fq "old-hash" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected expired processed state to be removed"
  grep -Fq "new-hash" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected fresh processed state to remain"
  ! grep -Fq "old-unmatched" "$sandbox/state/fallback-unmatched-notified.tsv" \
    || fail "expected expired unmatched state to be removed"
  grep -Fq "new-unmatched" "$sandbox/state/fallback-unmatched-notified.tsv" \
    || fail "expected fresh unmatched state to remain"
  ! grep -Fq "old-notify" "$sandbox/state/fallback-notify-state.tsv" \
    || fail "expected expired notify state to be removed"
  grep -Fq "new-notify" "$sandbox/state/fallback-notify-state.tsv" \
    || fail "expected fresh notify state to remain"
}

test_karakeep_fallback_sync_unmatched_notification_is_deduplicated() {
  local sandbox stdout_one stderr_one stdout_two stderr_two notification_count
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  stdout_one="$sandbox/stdout-one"
  stderr_one="$sandbox/stderr-one"
  stdout_two="$sandbox/stdout-two"
  stderr_two="$sandbox/stderr-two"
  printf '%s\n' "https://example.com/queued-only" > "$sandbox/state/failed-urls.txt"
  cat > "$sandbox/fallback/unmatched.html" <<'HTML'
<!doctype html>
<title>No source URL in this SingleFile document</title>
HTML

  _karakeep_fallback_sync_run "$sandbox" "$stdout_one" "$stderr_one" \
    || fail "expected first unmatched run to exit 0"
  _karakeep_fallback_sync_run "$sandbox" "$stdout_two" "$stderr_two" \
    || fail "expected second unmatched run to exit 0"

  notification_count=$(grep -Fc "send_notification_strict" "$sandbox/notifications.log")
  [ "$notification_count" = "1" ] \
    || fail "expected exactly one unmatched notification, got $notification_count"
  grep -Fq "Unmatched fallback already notified once" "$stdout_two" \
    || fail "expected second run to hit unmatched notification dedup path"
}
