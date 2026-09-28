# tests/suites/codex-review-status.sh — codex-review-status 판정·CLI 계약 (sourced)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의.
# shellcheck disable=SC2154
test_codex_review_status_contract() {
  python3 "$REPO_ROOT/tests/codex-review-status-tests.py"
}

test_codex_review_status_help_from_deployed_layout() {
  local sandbox output
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"

  output=$(
    HOME="$sandbox/home" COLUMNS=200 FORCE_COLOR=1 \
      "$sandbox/home/.local/bin/codex-review-status" --help 2>&1
  )

  assert_contains "$output" "usage: codex-review-status"
  assert_contains "$output" "--wait SECONDS"
  assert_contains "$output" "상태: draft, pending, reviewed, lgtm, limited, failed, timeout, absent."
  # 에이전트가 읽는 출력이라 FORCE_COLOR 환경에서도 색 제어 문자가 없어야 한다.
  assert_not_contains "$output" $'\033['
}
