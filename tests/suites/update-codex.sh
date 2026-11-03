# tests/suites/update-codex.sh — update-codex 릴리스 태그 조회(GraphQL)·실패 보고 fixture tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# shellcheck disable=SC2154

_uc_script="$REPO_ROOT/modules/shared/scripts/update-codex.sh"

# gh stub — `api -i graphql` 호출만 받는다(REST 경로나 -i 누락이 생기면 99로 실패해 드러낸다).
# 실제 `gh api -i`처럼 stdout에 상태 줄 + 헤더(CRLF) + 빈 줄 + 본문을 낸다.
#   정상: -f cursor=<c> 인자로 페이지를 고른다. 첫 페이지(cursor 없음)는 $UC_TEST_PAGES_DIR/first.json,
#         이후는 $UC_TEST_PAGES_DIR/<cursor>.json. UC_TEST_GH_WARN이 있으면 stderr에 경고를 남긴다.
#   실패: UC_TEST_GH_FAIL_EXIT가 있으면 UC_TEST_GH_FAIL_STATUS(예: "504 Gateway Timeout")로 상태 줄과
#         UC_TEST_GH_FAIL_BODY를 내고(STATUS가 비면 응답 없음 — stdout 없음), UC_TEST_GH_FAIL_STDERR를
#         stderr에 쓴 뒤 그 코드로 종료한다.
#   호출 상한: 10회를 넘으면 99로 실패한다 — 페이지 루프 진행 가드가 깨졌을 때 테스트가
#         무한 대기(하네스에 테스트별 시간 제한 없음) 대신 실패로 드러나게 한다.
# 호출 로그에는 query 본문을 빼고 남기고(여러 줄이라 assertion을 흐린다), 본문은 따로 저장한다.
_uc_install_gh_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cursor=""
logged=()
for arg in "$@"; do
  case "$arg" in
    query=*) logged+=("query=<omitted>"); printf '%s\n' "${arg#query=}" > "$UC_TEST_GH_QUERY" ;;
    cursor=*) cursor="${arg#cursor=}"; logged+=("$arg") ;;
    *) logged+=("$arg") ;;
  esac
done
printf '%s\n' "${logged[*]}" >> "$UC_TEST_GH_LOG"
if [ "$(wc -l < "$UC_TEST_GH_LOG")" -gt 10 ]; then
  echo "gh stub: too many calls (pagination loop not progressing?)" >&2
  exit 99
fi
if [ "${1:-}" != "api" ] || [ "${2:-}" != "-i" ] || [ "${3:-}" != "graphql" ]; then
  echo "gh stub: unexpected call: ${logged[*]}" >&2
  exit 99
fi
emit() {
  printf 'HTTP/2.0 %s\n' "$1"
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'X-Github-Request-Id: FIXTURE\r\n'
  printf '\r\n'
  printf '%s' "$2"
}
if [ -n "${UC_TEST_GH_FAIL_EXIT:-}" ]; then
  [ -z "${UC_TEST_GH_FAIL_STATUS:-}" ] || emit "$UC_TEST_GH_FAIL_STATUS" "${UC_TEST_GH_FAIL_BODY:-}"
  [ -z "${UC_TEST_GH_FAIL_STDERR:-}" ] || printf '%s\n' "$UC_TEST_GH_FAIL_STDERR" >&2
  exit "$UC_TEST_GH_FAIL_EXIT"
fi
page_file="$UC_TEST_PAGES_DIR/${cursor:-first}.json"
[ -f "$page_file" ] || { echo "gh stub: no page for cursor '$cursor'" >&2; exit 99; }
[ -z "${UC_TEST_GH_WARN:-}" ] || printf '%s\n' "$UC_TEST_GH_WARN" >&2
emit "200 OK" "$(cat "$page_file")"
STUB
  chmod +x "$path"
}

# nix stub — `nix store prefetch-file --json <url>`에 고정 해시를 돌려주고 호출을 기록한다.
_uc_install_nix_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$UC_TEST_NIX_LOG"
printf '{"hash":"sha256-STUB-%s"}\n' "$(basename "${*: -1}")"
STUB
  chmod +x "$path"
}

# _uc_write_page <file> <has_next:true|false> <end_cursor> <nodes_json_array>
_uc_write_page() {
  local file="$1" has_next="$2" end_cursor="$3" nodes="$4"
  jq -n --argjson hn "$has_next" --arg ec "$end_cursor" --argjson nodes "$nodes" \
    '{data: {repository: {releases: {pageInfo: {hasNextPage: $hn, endCursor: $ec}, nodes: $nodes}}}}' > "$file"
}

# _uc_node <tag> <is_prerelease> <is_draft>
_uc_node() {
  jq -nc --arg t "$1" --argjson p "$2" --argjson d "$3" '{tagName: $t, isPrerelease: $p, isDraft: $d}'
}

# _uc_prepare_sandbox <sandbox> <pinned_version>
_uc_prepare_sandbox() {
  local sandbox="$1" version="$2" pin_dir
  pin_dir="$sandbox/flake/modules/shared/programs/codex"
  mkdir -p "$sandbox/bin" "$sandbox/pages" "$sandbox/home" "$sandbox/tmp" "$pin_dir"
  : > "$sandbox/gh.log"
  : > "$sandbox/nix.log"
  jq -n --arg v "$version" '{
    version: $v,
    tag: ("rust-v" + $v),
    platforms: {
      "aarch64-darwin": {asset: "codex-package-aarch64-apple-darwin.tar.gz", hash: "sha256-OLD-darwin"},
      "x86_64-linux": {asset: "codex-package-x86_64-unknown-linux-musl.tar.gz", hash: "sha256-OLD-linux"}
    }
  }' > "$pin_dir/codex-pin.json"
  sed "s|@flakePath@|$sandbox/flake|g" "$_uc_script" > "$sandbox/update-codex"
  _uc_install_gh_stub "$sandbox/bin/gh"
  _uc_install_nix_stub "$sandbox/bin/nix"
}

_uc_pin() {
  printf '%s\n' "$1/flake/modules/shared/programs/codex/codex-pin.json"
}

# _uc_run <sandbox> [VAR=value...] -- [update-codex args...]
# stdout/stderr는 $sandbox/out, $sandbox/err에 남기고 종료 코드를 $sandbox/rc에 쓴다.
# TMPDIR을 sandbox 안으로 돌려 gh stderr 임시 파일의 정리 여부를 검사할 수 있게 한다.
_uc_run() {
  local sandbox="$1" rc=0
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" != "--" ] || shift
  env \
    PATH="$sandbox/bin:$PATH" \
    HOME="$sandbox/home" \
    TMPDIR="$sandbox/tmp" \
    UC_TEST_GH_LOG="$sandbox/gh.log" \
    UC_TEST_GH_QUERY="$sandbox/gh.query" \
    UC_TEST_NIX_LOG="$sandbox/nix.log" \
    UC_TEST_PAGES_DIR="$sandbox/pages" \
    ${envs[@]+"${envs[@]}"} \
    bash "$sandbox/update-codex" "$@" > "$sandbox/out" 2> "$sandbox/err" || rc=$?
  printf '%s\n' "$rc" > "$sandbox/rc"
}

# 종료 코드를 확인하고, 성공·실패와 무관하게 gh stderr 임시 파일이 남지 않았는지도 확인한다.
_uc_assert_rc() {
  local sandbox="$1" expected="$2" actual leftover
  actual="$(cat "$sandbox/rc")"
  [ "$actual" = "$expected" ] ||
    fail "expected update-codex exit $expected, got $actual (stdout: $(cat "$sandbox/out"); stderr: $(cat "$sandbox/err"))"
  leftover="$(find "$sandbox/tmp" -name 'update-codex-gh.*' -print)"
  [ -z "$leftover" ] || fail "gh stderr temp file left behind: $leftover"
}

# _uc_run_gh_failure <sandbox> <status|""> <body> <stderr>
_uc_run_gh_failure() {
  _uc_run "$1" \
    UC_TEST_GH_FAIL_EXIT=1 \
    UC_TEST_GH_FAIL_STATUS="$2" \
    UC_TEST_GH_FAIL_BODY="$3" \
    UC_TEST_GH_FAIL_STDERR="$4" \
    -- --no-build
}

# stable 선택 계약: prerelease·draft·rust-v 외 시리즈를 건너뛰고 목록 순서의 첫 stable을 고르며,
# 이미 최신이면 prefetch 없이 끝난다.
test_update_codex_graphql_skips_prerelease_draft_and_other_series() {
  local sandbox nodes
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  nodes="[$(_uc_node rust-v0.102.0-alpha.1 true false),$(_uc_node rust-v0.102.0 false true),$(_uc_node codex-sdk-v9.9.9 false false),$(_uc_node rust-v0.101.0 false false),$(_uc_node rust-v0.100.0 false false)]"
  _uc_write_page "$sandbox/pages/first.json" false "" "$nodes"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 0
  assert_contains "$(cat "$sandbox/out")" "이미 최신: codex 0.101.0 (rust-v0.101.0)"
  assert_contains "$(cat "$sandbox/gh.log")" "api -i graphql -f query=<omitted> -f owner=openai -f name=codex"
  assert_not_contains "$(cat "$sandbox/gh.log")" "cursor="
  [ ! -s "$sandbox/nix.log" ] || fail "fast path must not prefetch: $(cat "$sandbox/nix.log")"
}

# 쿼리 계약: 태그 이름·prerelease·draft만 받고(asset 미요청 — 504 원인), orderBy를 두지 않는다
# (기본 순서가 REST 목록 순서와 같고 CREATED_AT 정렬은 --pre 첫 매치를 바꾼다).
test_update_codex_graphql_query_requests_minimal_fields_in_default_order() {
  local sandbox query
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  _uc_write_page "$sandbox/pages/first.json" false "" "[$(_uc_node rust-v0.101.0 false false)]"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 0
  query="$(cat "$sandbox/gh.query")"
  assert_contains "$query" "nodes { tagName isPrerelease isDraft }"
  assert_contains "$query" "pageInfo { hasNextPage endCursor }"
  assert_contains "$query" "releases(first: 100, after: \$cursor)"
  assert_not_contains "$query" "orderBy"
  assert_not_contains "$query" "releaseAssets"
}

test_update_codex_graphql_follows_cursor_until_match() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  _uc_write_page "$sandbox/pages/first.json" true "CURSOR1" \
    "[$(_uc_node rust-v0.102.0-alpha.2 true false),$(_uc_node rust-v0.102.0-alpha.1 true false)]"
  _uc_write_page "$sandbox/pages/CURSOR1.json" false "" \
    "[$(_uc_node rust-v0.101.0 false false)]"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 0
  assert_contains "$(cat "$sandbox/out")" "이미 최신: codex 0.101.0 (rust-v0.101.0)"
  assert_line_count "$sandbox/gh.log" "api -i graphql -f query=<omitted> -f owner=openai -f name=codex" 1
  assert_line_count "$sandbox/gh.log" "api -i graphql -f query=<omitted> -f owner=openai -f name=codex -f cursor=CURSOR1" 1
}

test_update_codex_graphql_rejects_stalled_cursor() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  _uc_write_page "$sandbox/pages/first.json" true "CURSOR1" "[$(_uc_node rust-v0.102.0-alpha.1 true false)]"
  _uc_write_page "$sandbox/pages/CURSOR1.json" true "CURSOR1" "[$(_uc_node rust-v0.102.0-alpha.0 true false)]"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (응답 형식 이상) — hasNextPage=true인데 이미 받은 endCursor가 다시 나왔다"
  assert_line_count "$sandbox/gh.log" "api -i graphql -f query=<omitted> -f owner=openai -f name=codex -f cursor=CURSOR1" 1
}

# 직전 값만 비교하면 A→B→A 순환 cursor를 놓쳐 요청을 끝없이 보낸다 — 받은 cursor 이력 전체와 비교한다.
test_update_codex_graphql_rejects_cyclic_cursor() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  _uc_write_page "$sandbox/pages/first.json" true "CURSOR1" "[$(_uc_node rust-v0.102.0-alpha.3 true false)]"
  _uc_write_page "$sandbox/pages/CURSOR1.json" true "CURSOR2" "[$(_uc_node rust-v0.102.0-alpha.2 true false)]"
  _uc_write_page "$sandbox/pages/CURSOR2.json" true "CURSOR1" "[$(_uc_node rust-v0.102.0-alpha.1 true false)]"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (응답 형식 이상) — hasNextPage=true인데 이미 받은 endCursor가 다시 나왔다"
  [ "$(wc -l < "$sandbox/gh.log" | tr -d ' ')" = 3 ] || fail "expected exactly 3 gh calls, got: $(cat "$sandbox/gh.log")"
}

# 2페이지 이후 빈 endCursor를 그대로 쓰면 cursor가 비어 첫 페이지부터 다시 받는 무한 루프가 된다.
test_update_codex_graphql_rejects_empty_cursor_after_first_page() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  _uc_write_page "$sandbox/pages/first.json" true "CURSOR1" "[$(_uc_node rust-v0.102.0-alpha.2 true false)]"
  _uc_write_page "$sandbox/pages/CURSOR1.json" true "" "[$(_uc_node rust-v0.102.0-alpha.1 true false)]"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (응답 형식 이상) — hasNextPage=true인데 endCursor가 비었다"
  [ "$(wc -l < "$sandbox/gh.log" | tr -d ' ')" = 2 ] || fail "expected exactly 2 gh calls, got: $(cat "$sandbox/gh.log")"
}

# --pre는 draft만 빼고 목록 순서의 첫 매치를 고른다. 조건에 맞는 prerelease를 둘 두어
# "마지막 매치"를 고르는 회귀(alpha.0 선택)도 드러나게 한다.
test_update_codex_graphql_pre_includes_prerelease_but_not_draft() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.102.0-alpha.1"
  _uc_write_page "$sandbox/pages/first.json" false "" \
    "[$(_uc_node rust-v0.102.0-alpha.2 true true),$(_uc_node rust-v0.102.0-alpha.1 true false),$(_uc_node rust-v0.102.0-alpha.0 true false),$(_uc_node rust-v0.101.0 false false)]"

  _uc_run "$sandbox" -- --pre --no-build

  _uc_assert_rc "$sandbox" 0
  assert_contains "$(cat "$sandbox/out")" "이미 최신: codex 0.102.0-alpha.1 (rust-v0.102.0-alpha.1)"
}

# 새 버전이면 핀의 모든 플랫폼 asset을 prefetch해 version·tag·hash를 갱신한다.
test_update_codex_graphql_new_version_updates_pin() {
  local sandbox pin
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"
  pin="$(_uc_pin "$sandbox")"
  _uc_write_page "$sandbox/pages/first.json" false "" \
    "[$(_uc_node rust-v0.101.0 false false),$(_uc_node rust-v0.100.0 false false)]"

  _uc_run "$sandbox" UC_TEST_GH_WARN="gh-warning: fixture notice" -- --no-build

  _uc_assert_rc "$sandbox" 0
  assert_contains "$(cat "$sandbox/out")" "codex 0.100.0 → 0.101.0 (rust-v0.101.0) 갱신 중..."
  # 성공 경로에서도 gh stderr(경고)를 버리지 않는다.
  assert_contains "$(cat "$sandbox/err")" "gh-warning: fixture notice"
  assert_contains "$(cat "$sandbox/nix.log")" "https://github.com/openai/codex/releases/download/rust-v0.101.0/codex-package-aarch64-apple-darwin.tar.gz"
  [ "$(jq -r '[.version, .tag, .platforms["aarch64-darwin"].hash] | join(" ")' "$pin")" = \
    "0.101.0 rust-v0.101.0 sha256-STUB-codex-package-aarch64-apple-darwin.tar.gz" ] ||
    fail "pin not updated as expected: $(cat "$pin")"
  [ "$(jq -r '.platforms["x86_64-linux"].hash' "$pin")" = \
    "sha256-STUB-codex-package-x86_64-unknown-linux-musl.tar.gz" ] ||
    fail "linux pin hash not updated: $(cat "$pin")"
}

# 원래 버그(REST 504가 "gh auth/network 확인"으로 가려짐)의 회귀 테스트.
test_update_codex_reports_http_status_on_gateway_timeout() {
  local sandbox pin before
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"
  pin="$(_uc_pin "$sandbox")"
  before="$(cat "$pin")"

  _uc_run_gh_failure "$sandbox" "504 Gateway Timeout" \
    '{"message": "We couldn'"'"'t respond to your request in time."}' \
    "gh: We couldn't respond to your request in time. (HTTP 504)"

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "update-codex: 최신 릴리스 태그 조회 실패 (HTTP 504 Gateway Timeout) — GitHub 서버 측 오류·시간 초과, 잠시 후 재시도"
  assert_contains "$(cat "$sandbox/err")" "  gh: We couldn't respond to your request in time. (HTTP 504)"
  assert_not_contains "$(cat "$sandbox/err")" "gh auth/network 확인"
  [ "$(cat "$pin")" = "$before" ] || fail "pin must be untouched on lookup failure"
}

# gh는 errors만 있는 본문이면 5xx여도 stderr에 HTTP 상태를 쓰지 않는다 — 상태 줄에서 읽어야 한다.
test_update_codex_reports_http_status_when_gh_stderr_omits_it() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "502 Bad Gateway" \
    '{"data":null,"errors":[{"message":"Something went wrong while executing your query. This may be the result of a timeout."}]}' \
    "gh: Something went wrong while executing your query. This may be the result of a timeout."

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 502 Bad Gateway, GraphQL 오류) — GitHub 서버 측 오류·시간 초과, 잠시 후 재시도"
  assert_contains "$(cat "$sandbox/err")" "  gh: Something went wrong while executing your query."
}

test_update_codex_reports_auth_failure_status() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "401 Unauthorized" \
    '{"message": "Bad credentials", "status": "401"}' \
    "gh: Bad credentials (HTTP 401)"

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 401 Unauthorized) — 인증 실패, gh auth status로 확인"
  assert_contains "$(cat "$sandbox/err")" "  gh: Bad credentials (HTTP 401)"
}

test_update_codex_reports_forbidden_as_rate_limit_or_permission() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "403 Forbidden" \
    '{"message": "API rate limit exceeded"}' \
    "gh: API rate limit exceeded (HTTP 403)"

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 403 Forbidden) — 권한 부족 또는 rate limit, gh api rate_limit로 확인"
}

# GraphQL primary rate limit은 HTTP 200 + errors[].type=RATE_LIMITED로 온다.
test_update_codex_reports_graphql_rate_limit_on_http_200() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "200 OK" \
    '{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}' \
    "gh: API rate limit exceeded for user ID 1."

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 200 OK, GraphQL 오류: RATE_LIMITED) — 권한 부족 또는 rate limit"
}

test_update_codex_reports_graphql_error_with_http_200() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "200 OK" \
    '{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}' \
    "gh: Could not resolve to a Repository"

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 200 OK, GraphQL 오류: NOT_FOUND) — 조회 대상 저장소·권한 확인"
  assert_contains "$(cat "$sandbox/err")" "  gh: Could not resolve to a Repository"
}

test_update_codex_reports_missing_http_response() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "" "" \
    'Post "https://api.github.com/graphql": dial tcp: connect: connection refused'

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 응답 없음) — 네트워크·프록시·gh 설정 확인"
  assert_contains "$(cat "$sandbox/err")" "  Post \"https://api.github.com/graphql\": dial tcp: connect: connection refused"
}

# 헤더(200)를 받은 뒤 본문 수신 중 스트림이 끊기면 본문이 비고, $(...)가 끝 줄바꿈을 지워
# 빈 줄 구분자가 "\r\n\r"로 남는다 — 상태 줄은 그래도 읽는다.
test_update_codex_reports_status_when_body_stream_breaks() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "200 OK" "" \
    "stream error: stream ID 1; CANCEL; received from peer"

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 200 OK) — 응답 본문 수신 실패, 잠시 후 재시도"
  assert_contains "$(cat "$sandbox/err")" "  stream error: stream ID 1; CANCEL; received from peer"
}

# 쿼리 시간 초과처럼 type 없는 errors가 200으로 오면 저장소·권한 안내로 단정하지 않는다.
test_update_codex_reports_untyped_graphql_error_on_http_200() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run_gh_failure "$sandbox" "200 OK" \
    '{"data":null,"errors":[{"message":"Something went wrong while executing your query."}]}' \
    "gh: Something went wrong while executing your query."

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 200 OK, GraphQL 오류) — 아래 gh 오류 확인"
  assert_not_contains "$(cat "$sandbox/err")" "조회 대상 저장소·권한 확인"
}

# gh가 성공(rc 0)했는데 본문이 비면 "매치 없음"이 아니라 형식 이상이다.
test_update_codex_rejects_empty_success_body() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"
  : > "$sandbox/pages/first.json"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (응답 형식 이상)"
  assert_contains "$(cat "$sandbox/err")" "  <빈 본문>"
  assert_not_contains "$(cat "$sandbox/err")" "매치 없음"
}

test_update_codex_reports_no_matching_tag() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"
  _uc_write_page "$sandbox/pages/first.json" false "" \
    "[$(_uc_node rust-v0.102.0-alpha.1 true false),$(_uc_node codex-sdk-v1.0.0 false false)]"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (매치 없음) — openai/codex 릴리스 전체에"
}

test_update_codex_rejects_malformed_graphql_response() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"
  printf '%s\n' '{"data":{"repository":{"releases":{"nodes":[]}}}}' > "$sandbox/pages/first.json"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (응답 형식 이상) — data.repository.releases의 nodes·pageInfo가 없다"
  # 진단용으로 받은 본문 앞부분을 함께 보여 준다.
  assert_contains "$(cat "$sandbox/err")" '  {"data":{"repository":{"releases":{"nodes":[]}}}}'
}
