# tests/suites/karakeep-fallback-sync.sh — Karakeep fallback sync fixture tests (sourced)
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2164

_karakeep_fallback_sync_script="$REPO_ROOT/modules/nixos/programs/docker/karakeep-fallback-sync/files/fallback-sync.sh"

_karakeep_fallback_sync_install_curl_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
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

printf '%s\n' "$args" >> "$FALLBACK_SYNC_TEST_CURL_LOG"
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

# SingleFile 확장 기본 출력처럼 저장 주석을 <html> 직후에 두고 각 줄 끝에 공백을 남긴다.
_karakeep_fallback_sync_singlefile_header() {
  printf '%s\n' \
    '<!DOCTYPE html> <html lang="en"><!--' \
    ' Page saved with SingleFile ' \
    " url: $1 " \
    ' saved date: Sun Sep 27 2026 10:00:00 GMT+0900 (Korean Standard Time) ' \
    '--><meta charset="utf-8">'
}

_karakeep_fallback_sync_uploaded_urls() {
  sed -En 's/.*--form-string url=([^ ]+).*/\1/p' "$1/curl.log"
}

_karakeep_fallback_sync_assert_relinked() {
  local sandbox="$1"
  local expected_url="$2"
  local uploaded
  uploaded=$(_karakeep_fallback_sync_uploaded_urls "$sandbox")
  [ "$uploaded" = "$expected_url" ] \
    || fail "expected exactly one upload to $expected_url, got: ${uploaded:-<none>}"
  ! grep -Fqx "$expected_url" "$sandbox/state/failed-urls.txt" \
    || fail "expected relinked queue URL to be removed: $expected_url"
  grep -Fq "$expected_url" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected processed state to record $expected_url"
}

# 보류: 업로드·큐 제거·processed 기록 없이 원인을 구분한 알림을 한 번 보낸다.
_karakeep_fallback_sync_assert_held() {
  local sandbox="$1"
  local reason="$2"
  local notification_count
  [ ! -s "$sandbox/curl.log" ] || fail "expected no upload while held: $(cat "$sandbox/curl.log")"
  cmp -s "$sandbox/queue-before" "$sandbox/state/failed-urls.txt" \
    || fail "expected held run to leave the failed URL queue unchanged"
  [ ! -s "$sandbox/state/fallback-processed.tsv" ] \
    || fail "expected held run not to record processed state"
  notification_count=$(grep -Fc "send_notification_strict" "$sandbox/notifications.log" || true)
  [ "$notification_count" = "1" ] \
    || fail "expected exactly one hold notification, got $notification_count"
  grep -Fq "원인: $reason" "$sandbox/notifications.log" \
    || fail "expected hold notification reason: $reason"
}

_karakeep_fallback_sync_write_queue() {
  local sandbox="$1"
  shift
  printf '%s\n' "$@" > "$sandbox/state/failed-urls.txt"
  cp "$sandbox/state/failed-urls.txt" "$sandbox/queue-before"
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
<link rel="canonical" href="https://example.com/articles/one?from=queue">
HTML

  _karakeep_fallback_sync_run "$sandbox" "$stdout_path" "$stderr_path" \
    || fail "expected fallback sync success case to exit 0"

  assert_file_contains "$sandbox/state/failed-urls.txt" "$remaining_url"
  ! grep -Fqx "$matched_url" "$sandbox/state/failed-urls.txt" \
    || fail "expected matched queue URL to be removed"
  grep -Fq "$matched_url" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected processed state to record matched URL"
  output=$(cat "$stdout_path")
  assert_contains "$output" "Auto relink succeeded: $matched_url <- $sandbox/fallback/archive.html (via canonical)"
}

# 쿼리만 다른 URL은 다른 글일 수 있어 자동으로 연결하지 않는다 (#1388 결정 보정).
test_karakeep_fallback_sync_query_only_difference_is_held() {
  local sandbox
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" \
    "https://example.com/articles/one?from=queue" \
    "https://example.com/articles/two"
  cat > "$sandbox/fallback/archive.html" <<'HTML'
<!doctype html>
<link rel="canonical" href="https://example.com/articles/one?from=singlefile">
HTML

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"

  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 일치 없음"
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

test_karakeep_fallback_sync_canonical_beats_body_link_in_either_queue_order() {
  local sandbox source_url related_url queue_order
  source_url="https://example.com/articles/current"
  related_url="https://example.com/articles/related"

  for queue_order in source-first related-first; do
    sandbox=$(new_sandbox)
    _karakeep_fallback_sync_prepare_sandbox "$sandbox"
    if [ "$queue_order" = "source-first" ]; then
      _karakeep_fallback_sync_write_queue "$sandbox" "$source_url" "$related_url"
    else
      _karakeep_fallback_sync_write_queue "$sandbox" "$related_url" "$source_url"
    fi
    cat > "$sandbox/fallback/archive.html" <<HTML
<!doctype html>
<link rel="canonical" href="$source_url">
<p>관련 글: <a href="$related_url">related</a></p>
HTML

    _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
      || fail "expected $queue_order run to exit 0"

    _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"
    assert_file_contains "$sandbox/state/failed-urls.txt" "$related_url"
  done
}

test_karakeep_fallback_sync_body_link_without_identifier_is_held() {
  local sandbox body_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  body_url="https://example.com/articles/linked"
  _karakeep_fallback_sync_write_queue "$sandbox" "$body_url"
  cat > "$sandbox/fallback/archive.html" <<HTML
<!doctype html>
<p>참고: <a href="$body_url">$body_url</a></p>
HTML

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"
  _karakeep_fallback_sync_assert_held "$sandbox" "원문 식별자 없음"
  assert_contains "$(cat "$sandbox/stdout")" "Auto relink held (no-identifier): $sandbox/fallback/archive.html"

  # 같은 파일의 보류 알림은 파일 해시당 한 번이다.
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected second held run to exit 0"
  _karakeep_fallback_sync_assert_held "$sandbox" "원문 식별자 없음"
  assert_contains "$(cat "$sandbox/stdout")" "Unmatched fallback already notified once (no-identifier): $sandbox/fallback/archive.html"
}

test_karakeep_fallback_sync_conflicting_queued_identifiers_are_held() {
  local sandbox singlefile_url og_url output
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  singlefile_url="https://example.com/articles/saved"
  og_url="https://example.com/articles/og"
  _karakeep_fallback_sync_write_queue "$sandbox" "$singlefile_url" "$og_url"
  {
    _karakeep_fallback_sync_singlefile_header "$singlefile_url"
    printf '<meta property="og:url" content="%s">\n' "$og_url"
  } > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"

  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 후보 여럿"
  output=$(cat "$sandbox/stdout")
  assert_contains "$output" "Auto relink held (ambiguous): $sandbox/fallback/archive.html"
  assert_contains "$output" "identifier singlefile: $singlefile_url"
  assert_contains "$output" "identifier og:url: $og_url"
  assert_contains "$output" "candidate: $singlefile_url (singlefile)"
  assert_contains "$output" "candidate: $og_url (og:url)"
}

test_karakeep_fallback_sync_selects_the_only_queued_identifier() {
  local sandbox singlefile_url og_url unrelated_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  singlefile_url="https://example.com/articles/saved"
  og_url="https://example.com/articles/og"
  unrelated_url="https://example.com/articles/unrelated"
  _karakeep_fallback_sync_write_queue "$sandbox" "$unrelated_url" "$og_url"
  {
    _karakeep_fallback_sync_singlefile_header "$singlefile_url"
    printf '<meta property="og:url" content="%s">\n' "$og_url"
  } > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected relink run to exit 0"

  _karakeep_fallback_sync_assert_relinked "$sandbox" "$og_url"
  assert_file_contains "$sandbox/state/failed-urls.txt" "$unrelated_url"
}

test_karakeep_fallback_sync_duplicate_identifier_sources_count_once() {
  local sandbox source_url unrelated_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/same"
  unrelated_url="https://example.com/articles/unrelated"
  _karakeep_fallback_sync_write_queue "$sandbox" "$unrelated_url" "$source_url"
  {
    _karakeep_fallback_sync_singlefile_header "$source_url"
    printf '<link rel="canonical" href="%s/">\n' "$source_url"
    printf '<meta property="og:url" content="%s">\n' "$source_url"
    printf '<meta name="twitter:url" content="%s">\n' "$source_url"
  } > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected relink run to exit 0"

  _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"
  assert_contains "$(cat "$sandbox/stdout")" "Auto relink succeeded: $source_url <- $sandbox/fallback/archive.html (via canonical,og:url,singlefile,twitter:url)"
  assert_file_contains "$sandbox/state/failed-urls.txt" "$unrelated_url"
}

test_karakeep_fallback_sync_selects_exact_query_among_variants() {
  local sandbox exact_url sibling_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  exact_url="https://example.com/articles/query?x=1"
  sibling_url="https://example.com/articles/query?x=2"
  _karakeep_fallback_sync_write_queue "$sandbox" "$sibling_url" "$exact_url"
  cat > "$sandbox/fallback/archive.html" <<HTML
<!doctype html>
<link rel="canonical" href="$exact_url">
HTML

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected relink run to exit 0"

  _karakeep_fallback_sync_assert_relinked "$sandbox" "$exact_url"
  assert_file_contains "$sandbox/state/failed-urls.txt" "$sibling_url"
}

test_karakeep_fallback_sync_query_variants_without_exact_match_are_held() {
  local sandbox
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" \
    "https://example.com/articles/query?x=1" \
    "https://example.com/articles/query?x=2"
  cat > "$sandbox/fallback/archive.html" <<'HTML'
<!doctype html>
<link rel="canonical" href="https://example.com/articles/query?x=3">
HTML

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"

  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 일치 없음"
}

test_karakeep_fallback_sync_ignores_url_text_outside_singlefile_comment() {
  local sandbox singlefile_url body_text_url other_comment_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  singlefile_url="https://example.com/articles/saved"
  body_text_url="https://example.com/articles/body-text"
  other_comment_url="https://example.com/articles/other-comment"
  _karakeep_fallback_sync_write_queue "$sandbox" "$body_text_url" "$other_comment_url"
  {
    # 마커 없는 주석이 저장 주석보다 앞에 있어도 그 url: 줄은 읽지 않는다.
    printf '%s\n' '<!--' " url: $other_comment_url " '-->'
    _karakeep_fallback_sync_singlefile_header "$singlefile_url"
    printf '%s\n' '<pre>' "url: $body_text_url" '</pre>'
  } > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"

  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 일치 없음"
  assert_contains "$(cat "$sandbox/stdout")" "identifier singlefile: $singlefile_url"
}

# 쿼리 값으로 글을 구분하는 사이트에서 쿼리를 무시하면 다른 북마크를 덮어쓴다 (#1388 리뷰 재현).
test_karakeep_fallback_sync_video_id_query_is_not_matched_loosely() {
  local sandbox
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" \
    "https://youtu.be/AAA" \
    "https://www.youtube.com/watch?v=BBB"
  _karakeep_fallback_sync_singlefile_header "https://www.youtube.com/watch?v=AAA" > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"

  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 일치 없음"
}

test_karakeep_fallback_sync_ignores_saved_comment_after_the_first() {
  local sandbox source_url victim_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/real"
  victim_url="https://example.com/articles/victim"
  _karakeep_fallback_sync_write_queue "$sandbox" "$victim_url"
  {
    _karakeep_fallback_sync_singlefile_header "$source_url"
    printf '%s\n' '<body><p>text</p><!--' ' Page saved with SingleFile ' " url: $victim_url " '--></body>'
  } > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected held run to exit 0"

  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 일치 없음"
  assert_not_contains "$(cat "$sandbox/stdout")" "identifier singlefile: $victim_url"
}

test_karakeep_fallback_sync_duplicate_queue_lines_count_once() {
  local sandbox source_url other_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/repeated"
  other_url="https://example.com/articles/other"
  _karakeep_fallback_sync_write_queue "$sandbox" "$source_url" "$other_url" "$source_url"
  cat > "$sandbox/fallback/archive.html" <<HTML
<!doctype html>
<link rel="canonical" href="$source_url">
HTML

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected relink run to exit 0"

  [ "$(_karakeep_fallback_sync_uploaded_urls "$sandbox")" = "$source_url" ] \
    || fail "expected duplicate queue lines to be treated as one candidate"
  grep -Fq "$source_url" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected processed state to record $source_url"
}

# 식별자 추출 단계 하나라도 실패하면 일부 식별자만으로 판정하지 않는다. 보류 알림 기록을
# 남기지 않아 다음 실행에서 다시 판정하고, 알림은 시간 창으로만 억제한다.
test_karakeep_fallback_sync_identifier_extraction_error_is_retried() {
  local sandbox source_url real_grep notification_count now
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/source"
  _karakeep_fallback_sync_write_queue "$sandbox" "$source_url"
  cat > "$sandbox/fallback/archive.html" <<HTML
<!doctype html>
<link rel="canonical" href="$source_url">
HTML
  real_grep=$(command -v grep)
  cat > "$sandbox/stub-bin/grep" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *canonical*) echo "grep: simulated read error" >&2; exit 2 ;;
esac
exec "$real_grep" "\$@"
STUB
  chmod +x "$sandbox/stub-bin/grep"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected match error run to keep script-level exit 0"
  [ ! -s "$sandbox/curl.log" ] || fail "expected no upload after match error"
  cmp -s "$sandbox/queue-before" "$sandbox/state/failed-urls.txt" \
    || fail "expected match error to leave the failed URL queue unchanged"
  [ ! -s "$sandbox/state/fallback-processed.tsv" ] || fail "expected no processed state after match error"
  [ ! -s "$sandbox/state/fallback-unmatched-notified.tsv" ] \
    || fail "expected match error not to be recorded as a notified hold"
  grep -Fq "원인: 판정 실패" "$sandbox/notifications.log" \
    || fail "expected match error notification reason"
  assert_contains "$(cat "$sandbox/stdout")" "Auto relink match error: $sandbox/fallback/archive.html"
  assert_contains "$(cat "$sandbox/stdout")" "Fallback sync failure count: 1/3"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected second match error run to exit 0"
  notification_count=$(grep -Fc "원인: 판정 실패" "$sandbox/notifications.log")
  [ "$notification_count" = "1" ] \
    || fail "expected match error notification to be throttled, got $notification_count"
  assert_contains "$(cat "$sandbox/stdout")" "Auto relink match error: $sandbox/fallback/archive.html"

  # 억제 시간 창이 지나면 다시 알린다.
  now=$(date +%s)
  awk -F '\t' -v ts="$((now - 3600))" 'BEGIN { OFS = "\t" } { $2 = ts; print }' \
    "$sandbox/state/fallback-notify-state.tsv" > "$sandbox/notify-state.aged"
  mv "$sandbox/notify-state.aged" "$sandbox/state/fallback-notify-state.tsv"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected third match error run to exit 0"
  notification_count=$(grep -Fc "원인: 판정 실패" "$sandbox/notifications.log")
  [ "$notification_count" = "2" ] \
    || fail "expected match error notification after the throttle window, got $notification_count"

  # 추출이 회복되면 같은 파일을 정상 판정해 재연결한다.
  rm -f "$sandbox/stub-bin/grep"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected recovered run to exit 0"
  _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"
}

# root는 파일 권한을 무시해 읽기 실패를 재현할 수 없다.
_karakeep_fallback_sync_skip_if_root() {
  if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: $1 needs a non-root user to make a file unreadable" >&2
    return 0
  fi
  return 1
}

# 판정 실패: 업로드·큐 변경·보류 기록 없이 "판정 실패"를 한 번 알리고 실패로 센다.
_karakeep_fallback_sync_assert_match_error() {
  local sandbox="$1"
  local file="$2"
  local output
  [ ! -s "$sandbox/curl.log" ] || fail "expected no upload after match error"
  cmp -s "$sandbox/queue-before" "$sandbox/state/failed-urls.txt" \
    || fail "expected match error to leave the failed URL queue unchanged"
  [ ! -s "$sandbox/state/fallback-unmatched-notified.tsv" ] \
    || fail "expected match error not to be recorded as a notified hold"
  [ "$(grep -Fc "원인: 판정 실패" "$sandbox/notifications.log" || true)" = "1" ] \
    || fail "expected exactly one match error notification"
  output=$(cat "$sandbox/stdout")
  assert_contains "$output" "Auto relink match error: $file"
  assert_contains "$output" "Fallback sync failure count: 1/3"
}

# 해시를 못 구하면 빈 해시가 processed 기록의 아무 줄과 일치해 조용히 건너뛰던 경로를 막는다.
test_karakeep_fallback_sync_unreadable_file_is_a_match_error() {
  local sandbox file now
  _karakeep_fallback_sync_skip_if_root "unreadable fallback file" && return 0
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" "https://example.com/articles/source"
  now=$(date +%s)
  : > "$sandbox/kept.html"
  printf 'old-hash\thttps://example.com/articles/old\t%s\t%s\n' "$sandbox/kept.html" "$now" \
    > "$sandbox/state/fallback-processed.tsv"
  cp "$sandbox/state/fallback-processed.tsv" "$sandbox/processed-before"
  file="$sandbox/fallback/unreadable.html"
  printf '<link rel="canonical" href="https://example.com/articles/source">\n' > "$file"
  chmod 000 "$file"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || { chmod 600 "$file"; fail "expected unreadable file run to keep script-level exit 0"; }
  chmod 600 "$file"

  _karakeep_fallback_sync_assert_match_error "$sandbox" "$file"
  cmp -s "$sandbox/processed-before" "$sandbox/state/fallback-processed.tsv" \
    || fail "expected unreadable file not to change processed state"
  grep -Fq "match-error:path:" "$sandbox/state/fallback-notify-state.tsv" \
    || fail "expected unreadable file notification to be throttled by a path-based key"
}

test_karakeep_fallback_sync_unreadable_queue_is_a_match_error() {
  local sandbox file
  _karakeep_fallback_sync_skip_if_root "unreadable failed URL queue" && return 0
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" "https://example.com/articles/source"
  file="$sandbox/fallback/archive.html"
  printf '<link rel="canonical" href="https://example.com/articles/source">\n' > "$file"
  chmod 000 "$sandbox/state/failed-urls.txt"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || { chmod 600 "$sandbox/state/failed-urls.txt"; fail "expected unreadable queue run to keep script-level exit 0"; }
  chmod 600 "$sandbox/state/failed-urls.txt"

  _karakeep_fallback_sync_assert_match_error "$sandbox" "$file"
}

# 저장 주석 안의 `<!--`는 본문이다. 그 뒤의 `url:`을 줄 머리로 읽지 않고, `<!-->`의 `-->`는 주석을 닫는다.
test_karakeep_fallback_sync_comment_open_inside_saved_comment_is_text() {
  local sandbox source_url injected_url after_close_url
  source_url="https://example.com/articles/real"
  injected_url="https://example.com/articles/injected"
  after_close_url="https://example.com/articles/after-close"

  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" "$injected_url"
  printf '%s\n' \
    '<!DOCTYPE html> <html lang="en"><!--' \
    ' Page saved with SingleFile ' \
    " url: $source_url " \
    "<!-- url: $injected_url" \
    '--><meta charset="utf-8">' > "$sandbox/fallback/archive.html"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected injected url run to exit 0"
  _karakeep_fallback_sync_assert_held "$sandbox" "실패 URL 일치 없음"

  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" "$after_close_url"
  printf '%s\n' \
    '<!DOCTYPE html> <html lang="en"><!--' \
    ' Page saved with SingleFile <!-->' \
    " url: $after_close_url " \
    '--><meta charset="utf-8">' > "$sandbox/fallback/archive.html"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected early close run to exit 0"
  _karakeep_fallback_sync_assert_held "$sandbox" "원문 식별자 없음"
}

# url 줄이 없는 저장 주석에서 멈추면 뒤의 실제 저장 주석을 놓친다.
test_karakeep_fallback_sync_skips_saved_comment_without_url() {
  local sandbox source_url
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/real"
  _karakeep_fallback_sync_write_queue "$sandbox" "$source_url"
  {
    printf '%s\n' '<!-- Page saved with SingleFile -->'
    _karakeep_fallback_sync_singlefile_header "$source_url"
  } > "$sandbox/fallback/archive.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected relink run to exit 0"

  _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"
}

# 쿼리만 다른 두 URL은 다른 북마크라 업로드 실패 알림도 따로 억제한다.
test_karakeep_fallback_sync_upload_failure_notify_key_keeps_query() {
  local sandbox first_url second_url notification_count notify_state
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  first_url="https://example.com/articles/query?x=1"
  second_url="https://example.com/articles/query?x=2"
  _karakeep_fallback_sync_write_queue "$sandbox" "$first_url" "$second_url"
  printf '<link rel="canonical" href="%s">\n' "$first_url" > "$sandbox/fallback/first.html"
  printf '<link rel="canonical" href="%s">\n' "$second_url" > "$sandbox/fallback/second.html"

  FALLBACK_SYNC_TEST_CURL_EXIT=7 FALLBACK_SYNC_TEST_HTTP_CODE=000 \
    _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected upload failure run to keep script-level exit 0"

  notification_count=$(grep -Fc "자동 재연결 실패" "$sandbox/notifications.log" || true)
  [ "$notification_count" = "2" ] \
    || fail "expected one upload failure notification per query URL, got $notification_count"
  notify_state=$(cat "$sandbox/state/fallback-notify-state.tsv")
  assert_contains "$notify_state" "upload-failed:example.com/articles/query?x=1"
  assert_contains "$notify_state" "upload-failed:example.com/articles/query?x=2"
}
