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
  local sandbox source_url real_awk notification_count now
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/source"
  _karakeep_fallback_sync_write_queue "$sandbox" "$source_url"
  cat > "$sandbox/fallback/archive.html" <<HTML
<!doctype html>
<link rel="canonical" href="$source_url">
HTML
  # 식별자 태그 파서(awk 프로그램에 og:url이 들어 있는 호출)만 실패시킨다.
  real_awk=$(command -v awk)
  cat > "$sandbox/stub-bin/awk" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *og:url*) echo "awk: simulated read error" >&2; exit 2 ;;
esac
exec "$real_awk" "\$@"
STUB
  chmod +x "$sandbox/stub-bin/awk"

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
  rm -f "$sandbox/stub-bin/awk"
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

# processed 기록은 첫 필드의 파일 해시가 정확히 같을 때만 건너뛴다.
test_karakeep_fallback_sync_processed_state_matches_exact_hash() {
  local sandbox source_url other_url file other_file other_hash now
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/source"
  other_url="https://example.com/articles/other"
  _karakeep_fallback_sync_write_queue "$sandbox" "$source_url" "$other_url"
  file="$sandbox/fallback/archive.html"
  printf '<link rel="canonical" href="%s">\n' "$source_url" > "$file"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected first relink run to exit 0"
  _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"

  # 해시가 첫 필드와 정확히 같은 파일은 다시 판정하지 않는다.
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected second run to exit 0"
  [ "$(_karakeep_fallback_sync_uploaded_urls "$sandbox")" = "$source_url" ] \
    || fail "expected processed file not to be uploaded again"
  ! grep -Fq "자동 재연결 보류" "$sandbox/notifications.log" \
    || fail "expected processed file not to be judged again"

  # 해시를 부분 문자열로만 포함하는 기록은 처리 완료로 보지 않는다.
  other_file="$sandbox/fallback/other.html"
  printf '<link rel="canonical" href="%s">\n' "$other_url" > "$other_file"
  other_hash=$(sha256sum "$other_file" | cut -d ' ' -f 1)
  now=$(date +%s)
  printf 'x%s\thttps://example.com/articles/unrelated\t%s\t%s\n' "$other_hash" "$file" "$now" \
    >> "$sandbox/state/fallback-processed.tsv"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected third run to exit 0"
  grep -Fq -- "--form-string url=$other_url " "$sandbox/curl.log" \
    || fail "expected a file whose hash only appears as a substring to be relinked"
}

# 식별자 태그의 속성이 여러 줄에 걸쳐도 읽는다. 매치는 태그의 첫 `>`에서 끝나야 하므로,
# 뒤따르는 다른 태그의 rel·href와 섞여 본문 링크가 식별자로 잡히면 안 된다 (#1495 리뷰).
test_karakeep_fallback_sync_reads_identifier_tags_spanning_lines() {
  local sandbox source_url related_url body_url
  related_url="https://example.com/articles/related"
  body_url="https://example.com/articles/body-link"

  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/canonical-multiline"
  _karakeep_fallback_sync_write_queue "$sandbox" "$related_url" "$source_url" "$body_url"
  printf '%s\n' \
    '<!doctype html>' \
    '<link' \
    '  rel="canonical"' \
    "  href=\"$source_url\">" \
    '<link' \
    '  rel="stylesheet"' \
    '  href="/style.css"><a' \
    '  rel="canonical"' \
    "  href=\"$related_url\">related</a>" \
    '<a' \
    "  href=\"$body_url\"" \
    '>body</a>' > "$sandbox/fallback/archive.html"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected multi-line canonical run to exit 0"
  _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"
  assert_file_contains "$sandbox/state/failed-urls.txt" "$related_url"
  assert_file_contains "$sandbox/state/failed-urls.txt" "$body_url"

  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  source_url="https://example.com/articles/og-multiline"
  _karakeep_fallback_sync_write_queue "$sandbox" "$body_url" "$source_url"
  printf '%s\r\n' \
    '<!doctype html>' \
    '<meta' \
    '  property="og:url"' \
    "  content=\"$source_url\"" \
    '>' \
    '<a' \
    "  href=\"$body_url\"" \
    '>body</a>' > "$sandbox/fallback/archive.html"
  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected multi-line og:url run to exit 0"
  _karakeep_fallback_sync_assert_relinked "$sandbox" "$source_url"
  assert_file_contains "$sandbox/state/failed-urls.txt" "$body_url"
}

test_karakeep_fallback_sync_flatten_error_is_a_match_error() {
  local sandbox file real_tr
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" "https://example.com/articles/source"
  file="$sandbox/fallback/archive.html"
  printf '<link rel="canonical" href="https://example.com/articles/source">\n' > "$file"
  real_tr=$(command -v tr)
  cat > "$sandbox/stub-bin/tr" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *'\\r\\n'*) echo "tr: simulated write error" >&2; exit 1 ;;
esac
exec "$real_tr" "\$@"
STUB
  chmod +x "$sandbox/stub-bin/tr"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected flatten error run to keep script-level exit 0"

  _karakeep_fallback_sync_assert_match_error "$sandbox" "$file"
}

# URL 동일성은 경로 끝 `/`만 무시하고 쿼리는 끝 `/`까지 정확히 비교한다 (#1495 리뷰 P1).
test_karakeep_fallback_sync_trailing_slash_is_ignored_only_in_path() {
  local sandbox uploaded
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" \
    "https://example.com/p?redirect=/a/" \
    "https://example.com/p?redirect=/a" \
    "https://example.com/dir/" \
    "https://example.com/q/?x=1"
  printf '<link rel="canonical" href="%s">\n' "https://example.com/p?redirect=/a" > "$sandbox/fallback/query.html"
  printf '<link rel="canonical" href="%s">\n' "https://example.com/dir" > "$sandbox/fallback/path.html"
  printf '<link rel="canonical" href="%s">\n' "https://example.com/q?x=1" > "$sandbox/fallback/path-query.html"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected trailing slash run to exit 0"

  uploaded=$(_karakeep_fallback_sync_uploaded_urls "$sandbox" | sort)
  [ "$uploaded" = "$(printf '%s\n' "https://example.com/dir/" "https://example.com/p?redirect=/a" "https://example.com/q/?x=1" | sort)" ] \
    || fail "expected only exact-query and path-slash matches to relink, got: $uploaded"
  [ "$(cat "$sandbox/state/failed-urls.txt")" = "https://example.com/p?redirect=/a/" ] \
    || fail "expected the query URL ending in / to stay queued"
}

# 문법 표 한 행의 기대를 적는다. relink는 업로드되고 큐에서 빠지며, held는 업로드 없이 큐에 남는다.
_karakeep_fallback_sync_syntax_expect() {
  local sandbox="$1"
  local expect="$2"
  local queue_url="$3"
  printf '%s\n' "$queue_url" >> "$sandbox/state/failed-urls.txt"
  printf '%s\t%s\n' "$expect" "$queue_url" >> "$sandbox/syntax-expect"
}

_karakeep_fallback_sync_assert_syntax_expectations() {
  local sandbox="$1"
  local uploaded expect url
  uploaded=$(_karakeep_fallback_sync_uploaded_urls "$sandbox")
  while IFS=$'\t' read -r expect url; do
    if [ "$expect" = relink ]; then
      printf '%s\n' "$uploaded" | grep -Fqx -- "$url" || fail "expected syntax case to relink: $url"
      ! grep -Fqx -- "$url" "$sandbox/state/failed-urls.txt" || fail "expected relinked syntax case to leave the queue: $url"
    else
      ! printf '%s\n' "$uploaded" | grep -Fqx -- "$url" || fail "expected syntax case to be held: $url"
      grep -Fqx -- "$url" "$sandbox/state/failed-urls.txt" || fail "expected held syntax case to stay queued: $url"
    fi
  done < "$sandbox/syntax-expect"
}

# 식별자 태그(canonical link, og:url·twitter:url meta)의 HTML 속성 문법 변형 (#1495 리뷰 P2).
test_karakeep_fallback_sync_identifier_tag_attribute_syntax() {
  local sandbox b tab nl
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  : > "$sandbox/state/failed-urls.txt"
  : > "$sandbox/syntax-expect"
  b="https://example.com/syntax"
  tab=$'\t'
  nl=$'\n'

  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/eq-spaces"
  printf '<link rel = "canonical" href = "%s">\n' "$b/eq-spaces" > "$sandbox/fallback/eq-spaces.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/eq-tabs"
  printf '<link rel%s=%s"canonical"%shref%s=%s"%s">\n' "$tab" "$tab" "$tab" "$tab" "$tab" "$b/eq-tabs" > "$sandbox/fallback/eq-tabs.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/eq-newlines"
  printf '<link rel%s=%s"canonical"%shref%s=%s"%s">\n' "$nl" "$nl" "$nl" "$nl" "$nl" "$b/eq-newlines" > "$sandbox/fallback/eq-newlines.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/single-quotes"
  printf "<link rel='canonical' href='%s'>\n" "$b/single-quotes" > "$sandbox/fallback/single-quotes.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/unquoted"
  printf '<link rel=canonical href=%s>\n' "$b/unquoted" > "$sandbox/fallback/unquoted.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/unquoted-self-closing"
  printf '<link rel=canonical href=%s />\n' "$b/unquoted-self-closing" > "$sandbox/fallback/unquoted-self-closing.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/upper-names"
  printf '<LINK REL="canonical" HREF="%s">\n' "$b/upper-names" > "$sandbox/fallback/upper-names.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/rel-keyword-case"
  printf '<link rel="Canonical" href="%s">\n' "$b/rel-keyword-case" > "$sandbox/fallback/rel-keyword-case.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/rel-tokens"
  printf '<link rel="alternate  canonical" href="%s">\n' "$b/rel-tokens" > "$sandbox/fallback/rel-tokens.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/content-first"
  printf '<meta content="%s" property="og:url">\n' "$b/content-first" > "$sandbox/fallback/content-first.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/self-closing"
  printf '<meta property="og:url" content="%s"/>\n' "$b/self-closing" > "$sandbox/fallback/self-closing.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/og-property-case"
  printf '<meta property="OG:URL" content="%s">\n' "$b/og-property-case" > "$sandbox/fallback/og-property-case.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/twitter-mixed"
  printf "<meta name = 'twitter:url' content = %s >\n" "$b/twitter-mixed" > "$sandbox/fallback/twitter-mixed.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/entity?a=1&b=2"
  printf '<link rel="canonical" href="%s">\n' "$b/entity?a=1&amp;b=2" > "$sandbox/fallback/entity.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/value-whitespace"
  printf '<link rel="canonical" href=" %s ">\n' "$b/value-whitespace" > "$sandbox/fallback/value-whitespace.html"
  # 중복 속성은 HTML 파서처럼 첫 값을 쓴다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$b/duplicate-first"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/duplicate-second"
  printf '<link rel="canonical" href="%s" href="%s">\n' "$b/duplicate-first" "$b/duplicate-second" > "$sandbox/fallback/duplicate.html"

  # 따옴표 안의 `>`는 지원하지 않는다. 그 식별자는 판정에서 빠진다. 이 파일에는 다른 식별자가
  # 없어 보류되고, 잘린 값과 정확히 같은 큐 URL이 있어도 그 URL로 덮어쓰지 않는다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/quoted-gt?x=>1"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/quoted-gt?x="
  printf '<link rel="canonical" href="%s">\n' "$b/quoted-gt?x=>1" > "$sandbox/fallback/quoted-gt.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/rel-not-token"
  printf '<link rel="canonicalx" href="%s">\n' "$b/rel-not-token" > "$sandbox/fallback/rel-not-token.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/rel-other"
  printf '<link rel="alternate" href="%s">\n' "$b/rel-other" > "$sandbox/fallback/rel-other.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/og-as-name"
  printf '<meta name="og:url" content="%s">\n' "$b/og-as-name" > "$sandbox/fallback/og-as-name.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/tag-prefix"
  printf '<linker rel="canonical" href="%s">\n' "$b/tag-prefix" > "$sandbox/fallback/tag-prefix.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$b/unclosed-tag"
  printf '<link rel="canonical" href="%s"' "$b/unclosed-tag" > "$sandbox/fallback/unclosed-tag.html"
  cp "$sandbox/state/failed-urls.txt" "$sandbox/queue-before"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected attribute syntax run to exit 0"

  _karakeep_fallback_sync_assert_syntax_expectations "$sandbox"
}

# 식별자 태그는 문서 head에서만 읽는다. head 안에서도 주석과 script·style 본문의 태그 모양
# 텍스트는 태그가 아니다. body 안 iframe srcdoc 같은 임베드 문서의 canonical이 섞이면 그 URL만
# 큐에 있을 때 다른 북마크를 덮어쓴다 (#1495 재리뷰).
test_karakeep_fallback_sync_identifier_tags_read_only_in_head() {
  local sandbox h
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  : > "$sandbox/state/failed-urls.txt"
  : > "$sandbox/syntax-expect"
  h="https://example.com/context"

  # head의 canonical은 읽고, body 안 srcdoc의 따옴표 없는 canonical은 읽지 않는다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/head-source"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/srcdoc-embed"
  printf '<!doctype html><html><head><link rel="canonical" href="%s"></head><body><iframe srcdoc="<link rel=canonical href=%s>"></iframe></body></html>\n' \
    "$h/head-source" "$h/srcdoc-embed" > "$sandbox/fallback/srcdoc-with-head.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/srcdoc-only"
  printf '<!doctype html><html><head><title>t</title></head><body><iframe srcdoc="<link rel=canonical href=%s>"></iframe></body></html>\n' \
    "$h/srcdoc-only" > "$sandbox/fallback/srcdoc-only.html"
  # body 시작 태그가 생략돼도 </head>에서 멈춘다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/after-head-end"
  printf '<head><title>t</title></head><div><iframe srcdoc="<link rel=canonical href=%s>"></iframe></div>\n' \
    "$h/after-head-end" > "$sandbox/fallback/after-head-end.html"
  # </head>가 생략돼도 body 시작 태그에서 멈춘다. 이름의 대소문자는 가리지 않는다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/after-body"
  printf '<head><title>t</title><body><link rel=canonical href=%s>\n' "$h/after-body" > "$sandbox/fallback/after-body.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/after-upper-body"
  printf '<HTML><HEAD><TITLE>t</TITLE><BODY class="x"><LINK REL="canonical" HREF="%s">\n' \
    "$h/after-upper-body" > "$sandbox/fallback/after-upper-body.html"
  # 이름이 body로 시작할 뿐인 태그는 경계가 아니다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-bodyx"
  printf '<head><bodyx><link rel="canonical" href="%s">\n' "$h/after-bodyx" > "$sandbox/fallback/after-bodyx.html"
  # head와 body 태그가 없는 문서는 끝까지 읽는다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/no-head-body"
  printf '<p>본문</p>\n<link rel="canonical" href="%s">\n' "$h/no-head-body" > "$sandbox/fallback/no-head-body.html"
  # head 안 주석과 script·style 본문의 태그 모양 텍스트는 읽지 않는다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-comment"
  printf '<head><!-- <link rel="canonical" href="%s"> --></head>\n' "$h/in-comment" > "$sandbox/fallback/in-comment.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-multiline-comment"
  printf '<head><!--\n<link\n  rel="canonical"\n  href="%s">\n--></head>\n' \
    "$h/in-multiline-comment" > "$sandbox/fallback/in-multiline-comment.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-script"
  printf "<head><script>var s = '<link rel=\"canonical\" href=\"%s\">';</script></head>\n" \
    "$h/in-script" > "$sandbox/fallback/in-script.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-style"
  printf '<head><style>/* <link rel="canonical" href="%s"> */</style></head>\n' "$h/in-style" > "$sandbox/fallback/in-style.html"
  # 닫히지 않은 주석과 script는 거기서 스캔을 끝낸다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/unclosed-comment"
  printf '<head><!-- <link rel="canonical" href="%s">\n' "$h/unclosed-comment" > "$sandbox/fallback/unclosed-comment.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/unclosed-script"
  printf '<head><script><link rel="canonical" href="%s">\n' "$h/unclosed-script" > "$sandbox/fallback/unclosed-script.html"
  # 주석과 script가 끝난 뒤의 head 태그는 읽는다. `<!-->`는 곧바로 닫히는 빈 주석이다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-comment"
  printf '<head><!-- x --><link rel="canonical" href="%s"></head>\n' "$h/after-comment" > "$sandbox/fallback/after-comment.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-script"
  printf '<head><script>if (a < b) {}</script><link rel="canonical" href="%s"></head>\n' \
    "$h/after-script" > "$sandbox/fallback/after-script.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-empty-comment"
  printf '<head><!--><link rel="canonical" href="%s"></head>\n' "$h/after-empty-comment" > "$sandbox/fallback/after-empty-comment.html"
  # template 내용은 문서에 적용되지 않는 inert 조각이다. 중첩 깊이가 0이 될 때까지 건너뛰고,
  # 닫히지 않으면 끝까지 건너뛴다. template 안의 주석·script에 든 `</template>` 텍스트는 끝 태그가 아니다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-template"
  printf '<head><template><link rel="canonical" href="%s"></template></head>\n' "$h/in-template" > "$sandbox/fallback/in-template.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-nested-template"
  printf '<head><template><template></template><link rel="canonical" href="%s"></template></head>\n' \
    "$h/in-nested-template" > "$sandbox/fallback/in-nested-template.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/template-end-in-comment"
  printf '<head><template><!-- </template> --><link rel="canonical" href="%s"></template></head>\n' \
    "$h/template-end-in-comment" > "$sandbox/fallback/template-end-in-comment.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/template-end-in-script"
  printf '<head><template><script>var s = "</template>";</script><link rel="canonical" href="%s"></template></head>\n' \
    "$h/template-end-in-script" > "$sandbox/fallback/template-end-in-script.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/unclosed-template"
  printf '<head><template><link rel="canonical" href="%s">\n' "$h/unclosed-template" > "$sandbox/fallback/unclosed-template.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-template"
  printf '<head><template><p>x</p></template><link rel="canonical" href="%s"></head>\n' \
    "$h/after-template" > "$sandbox/fallback/after-template.html"
  # 스크립트가 켜진 브라우저는 head의 noscript·noframes 내용을 원시 텍스트로 읽으므로 요소가 아니다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-noscript"
  printf '<head><noscript><link rel="canonical" href="%s"></noscript></head>\n' "$h/in-noscript" > "$sandbox/fallback/in-noscript.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-noframes"
  printf '<head><noframes><link rel="canonical" href="%s"></noframes></head>\n' "$h/in-noframes" > "$sandbox/fallback/in-noframes.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-noscript-img"
  printf '<head><noscript><img src="https://example.com/pixel.gif"></noscript><link rel="canonical" href="%s"></head>\n' \
    "$h/after-noscript-img" > "$sandbox/fallback/after-noscript-img.html"
  # 이름이 template·noscript로 시작할 뿐인 태그는 건너뛰기 대상이 아니다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-templatex"
  printf '<head><templatex><link rel="canonical" href="%s"></head>\n' "$h/after-templatex" > "$sandbox/fallback/after-templatex.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-noscriptx"
  printf '<head><noscriptx><link rel="canonical" href="%s"></head>\n' "$h/after-noscriptx" > "$sandbox/fallback/after-noscriptx.html"
  # title 내용은 RCDATA 텍스트라 `</title>` 전까지 태그를 인식하지 않는다. 닫히지 않으면 끝까지 건너뛴다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/in-title"
  printf '<head><title><link rel="canonical" href="%s"></title></head>\n' "$h/in-title" > "$sandbox/fallback/in-title.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/unclosed-title"
  printf '<head><title><link rel="canonical" href="%s">\n' "$h/unclosed-title" > "$sandbox/fallback/unclosed-title.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-title"
  printf '<head><title>t</title><link rel="canonical" href="%s"></head>\n' "$h/after-title" > "$sandbox/fallback/after-title.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-titlex"
  printf '<head><titlex><link rel="canonical" href="%s"></head>\n' "$h/after-titlex" > "$sandbox/fallback/after-titlex.html"
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/after-upper-title"
  printf '<head><TITLE>t</TITLE><link rel="canonical" href="%s"></head>\n' "$h/after-upper-title" > "$sandbox/fallback/after-upper-title.html"
  # SingleFile 저장 주석은 태그 파서와 따로 원본에서 읽으므로 head 한정의 영향을 받지 않는다.
  _karakeep_fallback_sync_syntax_expect "$sandbox" relink "$h/singlefile-saved"
  _karakeep_fallback_sync_syntax_expect "$sandbox" held "$h/singlefile-srcdoc"
  {
    _karakeep_fallback_sync_singlefile_header "$h/singlefile-saved"
    printf '<title>t</title></head><body><iframe srcdoc="<link rel=canonical href=%s>"></iframe></body></html>\n' \
      "$h/singlefile-srcdoc"
  } > "$sandbox/fallback/singlefile.html"
  cp "$sandbox/state/failed-urls.txt" "$sandbox/queue-before"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected head context run to exit 0"

  _karakeep_fallback_sync_assert_syntax_expectations "$sandbox"
}

# SingleFile 저장 주석 파서가 실패해도 나머지 식별자만으로 판정하지 않는다.
test_karakeep_fallback_sync_singlefile_parser_error_is_a_match_error() {
  local sandbox file real_awk
  sandbox=$(new_sandbox)
  _karakeep_fallback_sync_prepare_sandbox "$sandbox"
  _karakeep_fallback_sync_write_queue "$sandbox" "https://example.com/articles/source"
  file="$sandbox/fallback/archive.html"
  printf '<link rel="canonical" href="https://example.com/articles/source">\n' > "$file"
  # 저장 주석 파서(awk 프로그램에 마커 문자열이 들어 있는 호출)만 실패시킨다.
  real_awk=$(command -v awk)
  cat > "$sandbox/stub-bin/awk" <<STUB
#!/usr/bin/env bash
case "\$*" in
  *"Page saved with SingleFile"*) echo "awk: simulated read error" >&2; exit 2 ;;
esac
exec "$real_awk" "\$@"
STUB
  chmod +x "$sandbox/stub-bin/awk"

  _karakeep_fallback_sync_run "$sandbox" "$sandbox/stdout" "$sandbox/stderr" \
    || fail "expected SingleFile parser error run to keep script-level exit 0"

  _karakeep_fallback_sync_assert_match_error "$sandbox" "$file"
}
