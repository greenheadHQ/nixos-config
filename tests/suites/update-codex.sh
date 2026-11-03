# tests/suites/update-codex.sh — update-codex 릴리스 태그 조회(GraphQL)·실패 보고 fixture tests (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# shellcheck disable=SC2154

_uc_script="$REPO_ROOT/modules/shared/scripts/update-codex.sh"

# gh stub — `api graphql` 호출만 받는다(REST 경로가 되살아나면 99로 실패해 드러낸다).
#   정상: -f cursor=<c> 인자로 페이지를 고른다. 첫 페이지(cursor 없음)는 $UC_TEST_PAGES_DIR/first.json,
#         이후는 $UC_TEST_PAGES_DIR/<cursor>.json. UC_TEST_GH_WARN이 있으면 stderr에 경고를 남긴다.
#   실패: UC_TEST_GH_FAIL_EXIT가 있으면 UC_TEST_GH_FAIL_STDOUT/STDERR를 내고 그 코드로 종료한다
#         (실제 gh는 HTTP 오류 시 응답 본문을 stdout, "gh: <msg> (HTTP nnn)"을 stderr에 쓴다).
# 호출 로그에는 query 본문을 빼고 남긴다(여러 줄이라 assertion을 흐린다).
_uc_install_gh_stub() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
cursor=""
logged=()
for arg in "$@"; do
  case "$arg" in
    query=*) logged+=("query=<omitted>") ;;
    cursor=*) cursor="${arg#cursor=}"; logged+=("$arg") ;;
    *) logged+=("$arg") ;;
  esac
done
printf '%s\n' "${logged[*]}" >> "$UC_TEST_GH_LOG"
if [ "${1:-}" != "api" ] || [ "${2:-}" != "graphql" ]; then
  echo "gh stub: unexpected call: ${logged[*]}" >&2
  exit 99
fi
if [ -n "${UC_TEST_GH_FAIL_EXIT:-}" ]; then
  printf '%s' "${UC_TEST_GH_FAIL_STDOUT:-}"
  [ -z "${UC_TEST_GH_FAIL_STDERR:-}" ] || printf '%s\n' "$UC_TEST_GH_FAIL_STDERR" >&2
  exit "$UC_TEST_GH_FAIL_EXIT"
fi
page_file="$UC_TEST_PAGES_DIR/${cursor:-first}.json"
[ -f "$page_file" ] || { echo "gh stub: no page for cursor '$cursor'" >&2; exit 99; }
[ -z "${UC_TEST_GH_WARN:-}" ] || printf '%s\n' "$UC_TEST_GH_WARN" >&2
cat "$page_file"
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
  mkdir -p "$sandbox/bin" "$sandbox/pages" "$sandbox/home" "$pin_dir"
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
    UC_TEST_GH_LOG="$sandbox/gh.log" \
    UC_TEST_NIX_LOG="$sandbox/nix.log" \
    UC_TEST_PAGES_DIR="$sandbox/pages" \
    ${envs[@]+"${envs[@]}"} \
    bash "$sandbox/update-codex" "$@" > "$sandbox/out" 2> "$sandbox/err" || rc=$?
  printf '%s\n' "$rc" > "$sandbox/rc"
}

_uc_assert_rc() {
  local sandbox="$1" expected="$2" actual
  actual="$(cat "$sandbox/rc")"
  [ "$actual" = "$expected" ] ||
    fail "expected update-codex exit $expected, got $actual (stdout: $(cat "$sandbox/out"); stderr: $(cat "$sandbox/err"))"
}

test_update_codex_graphql_skips_prerelease_draft_and_other_series() {
  local sandbox nodes
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.101.0"
  nodes="[$(_uc_node rust-v0.102.0-alpha.1 true false),$(_uc_node rust-v0.102.0 false true),$(_uc_node codex-sdk-v9.9.9 false false),$(_uc_node rust-v0.101.0 false false),$(_uc_node rust-v0.100.0 false false)]"
  _uc_write_page "$sandbox/pages/first.json" false "" "$nodes"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 0
  assert_contains "$(cat "$sandbox/out")" "이미 최신: codex 0.101.0 (rust-v0.101.0)"
  assert_contains "$(cat "$sandbox/gh.log")" "api graphql -f query=<omitted> -f owner=openai -f name=codex"
  assert_not_contains "$(cat "$sandbox/gh.log")" "cursor="
  [ ! -s "$sandbox/nix.log" ] || fail "fast path must not prefetch: $(cat "$sandbox/nix.log")"
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
  assert_line_count "$sandbox/gh.log" "api graphql -f query=<omitted> -f owner=openai -f name=codex" 1
  assert_line_count "$sandbox/gh.log" "api graphql -f query=<omitted> -f owner=openai -f name=codex -f cursor=CURSOR1" 1
}

test_update_codex_graphql_pre_includes_prerelease_but_not_draft() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.102.0-alpha.1"
  _uc_write_page "$sandbox/pages/first.json" false "" \
    "[$(_uc_node rust-v0.102.0-alpha.2 true true),$(_uc_node rust-v0.102.0-alpha.1 true false),$(_uc_node rust-v0.101.0 false false)]"

  _uc_run "$sandbox" -- --pre --no-build

  _uc_assert_rc "$sandbox" 0
  assert_contains "$(cat "$sandbox/out")" "이미 최신: codex 0.102.0-alpha.1 (rust-v0.102.0-alpha.1)"
}

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
}

test_update_codex_reports_http_status_from_gh_stderr() {
  local sandbox pin before
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"
  pin="$(_uc_pin "$sandbox")"
  before="$(cat "$pin")"

  _uc_run "$sandbox" \
    UC_TEST_GH_FAIL_EXIT=1 \
    UC_TEST_GH_FAIL_STDOUT='{"message": "We couldn'"'"'t respond to your request in time."}' \
    UC_TEST_GH_FAIL_STDERR="gh: We couldn't respond to your request in time. (HTTP 504)" \
    -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "update-codex: 최신 릴리스 태그 조회 실패 (HTTP 504) — GitHub 서버 측 오류·시간 초과"
  assert_contains "$(cat "$sandbox/err")" "  gh: We couldn't respond to your request in time. (HTTP 504)"
  assert_not_contains "$(cat "$sandbox/err")" "gh auth/network 확인"
  [ "$(cat "$pin")" = "$before" ] || fail "pin must be untouched on lookup failure"
}

test_update_codex_reports_auth_failure_status() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run "$sandbox" \
    UC_TEST_GH_FAIL_EXIT=1 \
    UC_TEST_GH_FAIL_STDOUT='{"message": "Bad credentials", "status": "401"}' \
    UC_TEST_GH_FAIL_STDERR="gh: Bad credentials (HTTP 401)" \
    -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 401) — 인증 실패, gh auth status로 확인"
  assert_contains "$(cat "$sandbox/err")" "  gh: Bad credentials (HTTP 401)"
}

test_update_codex_reports_graphql_error_without_http_status() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run "$sandbox" \
    UC_TEST_GH_FAIL_EXIT=1 \
    UC_TEST_GH_FAIL_STDOUT='{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}' \
    UC_TEST_GH_FAIL_STDERR="gh: Could not resolve to a Repository" \
    -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (GraphQL 오류)"
  assert_contains "$(cat "$sandbox/err")" "  gh: Could not resolve to a Repository"
}

test_update_codex_reports_missing_http_response() {
  local sandbox
  sandbox=$(new_sandbox)
  _uc_prepare_sandbox "$sandbox" "0.100.0"

  _uc_run "$sandbox" \
    UC_TEST_GH_FAIL_EXIT=1 \
    UC_TEST_GH_FAIL_STDERR='Post "https://api.github.com/graphql": dial tcp: connect: connection refused' \
    -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (HTTP 응답 없음) — 네트워크·프록시·gh 설정 확인"
  assert_contains "$(cat "$sandbox/err")" "  Post \"https://api.github.com/graphql\": dial tcp: connect: connection refused"
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
  printf '%s\n' '{"data":{"repository":null}}' > "$sandbox/pages/first.json"

  _uc_run "$sandbox" -- --no-build

  _uc_assert_rc "$sandbox" 1
  assert_contains "$(cat "$sandbox/err")" "최신 릴리스 태그 조회 실패 (응답 형식 이상)"
}
