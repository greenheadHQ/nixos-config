# tests/suites/test-infra.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# set -e가 실제로 켜진 자식 셸에서 호출한다. 바깥 테스트가 실패를 캡처하는 조건 문맥이
# helper 본문의 errexit를 비활성화하지 않아야 0건 계수 회귀를 재현할 수 있다.
_test_infra_line_count_fixture() {
  local sandbox="$1"
  shift
  bash -c '
    set -euo pipefail
    TEST_TMP_FILE="$2/cleanup.list"
    . "$1/tests/lib/test-common.sh"
    assert_line_count "$3" "$4" "$5"
    echo assertion-passed
  ' _ "$REPO_ROOT" "$sandbox" "$@"
}

test_assert_line_count_preserves_exact_line_counts() {
  local sandbox file output rc=0
  sandbox="$(new_sandbox)"
  file="$sandbox/lines"
  printf '%s\n' 'match.' 'prefix match.' 'match.x' 'matchX' 'match.' > "$file"
  output="$(_test_infra_line_count_fixture "$sandbox" "$file" 'match.' 2 2>&1)"
  assert_contains "$output" assertion-passed

  output="$(_test_infra_line_count_fixture "$sandbox" "$file" 'match.' 1 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "positive count mismatch should fail: $output"
  assert_contains "$output" "FAIL: expected $file to contain 1 occurrences of: match. (actual: 2)"
  assert_not_contains "$output" assertion-passed
}

test_assert_line_count_accepts_zero_matches() {
  local sandbox file output
  sandbox="$(new_sandbox)"
  for file in empty other-lines; do
    : > "$sandbox/$file"
    [[ "$file" != other-lines ]] || printf '%s\n' 'other line' > "$sandbox/$file"
    output="$(_test_infra_line_count_fixture "$sandbox" "$sandbox/$file" match 0 2>&1)"
    assert_contains "$output" assertion-passed
    assert_not_contains "$output" "FAIL:"
  done
}

test_assert_line_count_reports_zero_match_mismatch() {
  local sandbox file output rc=0
  sandbox="$(new_sandbox)"
  file="$sandbox/lines"
  printf '%s\n' 'other line' > "$file"
  output="$(_test_infra_line_count_fixture "$sandbox" "$file" match 1 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "zero count mismatch should fail: $output"
  assert_contains "$output" "FAIL: expected $file to contain 1 occurrences of: match (actual: 0)"
  assert_not_contains "$output" assertion-passed
}

test_assert_line_count_rejects_file_errors() {
  local sandbox file output rc
  sandbox="$(new_sandbox)"
  for file in missing unreadable; do
    if [[ "$file" == unreadable ]]; then
      printf '%s\n' match > "$sandbox/$file"
      chmod 000 "$sandbox/$file"
      if [[ -r "$sandbox/$file" ]]; then
        echo "SKIP: unreadable-file assertion requires a user without permission override" >&2
        continue
      fi
    fi
    rc=0
    output="$(_test_infra_line_count_fixture "$sandbox" "$sandbox/$file" match 0 2>&1)" || rc=$?
    [[ "$rc" -ne 0 ]] || fail "$file must not pass as a zero count: $output"
    assert_contains "$output" "FAIL: could not count exact lines in $sandbox/$file (grep exit: 2)"
    assert_not_contains "$output" assertion-passed
  done
}

test_assert_line_count_rejects_grep_error_with_zero_output() {
  local sandbox output rc=0
  sandbox="$(new_sandbox)"
  output="$(bash -c '
    set -euo pipefail
    TEST_TMP_FILE="$2/cleanup.list"
    . "$1/tests/lib/test-common.sh"
    grep() { echo 0; echo "synthetic grep error" >&2; return 23; }
    assert_line_count "$2/lines" match 0
    echo assertion-passed
  ' _ "$REPO_ROOT" "$sandbox" 2>&1)" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "grep error with zero output must fail: $output"
  assert_contains "$output" "FAIL: could not count exact lines in $sandbox/lines (grep exit: 23)"
  assert_not_contains "$output" assertion-passed
}

test_assert_line_count_harness_diagnostics() {
  local jobs kind expected sandbox file output rc jobs_modes="1 2"
  if ! bash -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 3 ]; }'; then
    echo "SKIP: line-count parallel diagnostics require nested bash 4.3+ (sequential still checked)" >&2
    jobs_modes=1
  fi
  for jobs in $jobs_modes; do
    for kind in zero-pass zero-mismatch positive-mismatch file-error; do
      sandbox="$(new_sandbox)"
      file="$sandbox/lines"
      : > "$file"
      expected=1
      case "$kind" in
        zero-pass) expected=0 ;;
        positive-mismatch) printf '%s\n' match > "$file"; expected=2 ;;
        file-error) rm "$file"; expected=0 ;;
      esac
      rc=0
      output="$(TEST_JOBS="$jobs" bash -c '
        set -euo pipefail
        TEST_TMP_FILE="$2/cleanup.list"
        . "$1/tests/lib/test-common.sh"
        . "$1/tests/lib/parallel-harness.sh"
        line_count_fixture() {
          assert_line_count "$3" match "$4"
          : > "$2/assertion-after"
        }
        later_fixture() { : > "$2/later-after"; }
        run_test "line count fixture" line_count_fixture "$@"
        run_test "later fixture" later_fixture "$@"
        parallel_barrier
      ' _ "$REPO_ROOT" "$sandbox" "$file" "$expected" 2>&1)" || rc=$?
      if [[ "$kind" == zero-pass ]]; then
        [[ "$rc" -eq 0 && -f "$sandbox/assertion-after" && -f "$sandbox/later-after" ]] ||
          fail "TEST_JOBS=$jobs zero count should pass and run both tests: $output"
        assert_not_contains "$output" "[FAIL]"
        continue
      fi
      [[ "$rc" -ne 0 && ! -e "$sandbox/assertion-after" ]] ||
        fail "TEST_JOBS=$jobs $kind should stop the failed assertion: $output"
      case "$kind" in
        zero-mismatch) assert_contains "$output" "match (actual: 0)" ;;
        positive-mismatch) assert_contains "$output" "match (actual: 1)" ;;
        file-error) assert_contains "$output" "FAIL: could not count exact lines in $file (grep exit: 2)" ;;
      esac
      if [[ "$jobs" == 1 ]]; then
        [[ ! -e "$sandbox/later-after" ]] || fail "sequential runner should stop on first failure"
        assert_not_contains "$output" "==> later fixture"
      else
        [[ -f "$sandbox/later-after" ]] || fail "parallel runner should still run the later fixture"
        assert_contains "$output" "==> line count fixture  [FAIL]"
        assert_contains "$output" "통과 1 · 실패 1"
      fi
    done
  done
}

test_fixture_git_is_hermetic_against_global_hooks() {
  local sandbox repo_root hook_dir global_config hook_marker
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  hook_dir="$sandbox/global-hooks"
  global_config="$sandbox/global-gitconfig"
  hook_marker="$sandbox/HOOK_RAN"

  mkdir -p "$hook_dir"
  cat > "$hook_dir/pre-commit" <<EOF
#!/usr/bin/env bash
echo hook-ran > "$hook_marker"
exit 1
EOF
  chmod +x "$hook_dir/pre-commit"
  cat > "$global_config" <<EOF
[core]
	hooksPath = $hook_dir
EOF

  GIT_CONFIG_GLOBAL="$global_config" create_git_fixture_repo "$repo_root"

  [[ -d "$repo_root/.git" ]] || fail "expected fixture repo to be created"
  [[ ! -e "$hook_marker" ]] || fail "expected fixture git setup to ignore host global hooks"
}

# tests/suites/*.sh 는 '정의 전용'이고, 실제 실행 등록은 tests/shell-script-tests.sh 의 수기
# run_test 나열이 유일한 경로다(aggregator 의 find 디스커버리는 파일을 source 할 뿐 함수를
# 실행하지 않는다). 두 목록이 어긋날 때 역방향(등록됐는데 미정의)은 command-not-found 로
# 시끄럽게 죽지만, 정방향(정의됐는데 미등록)은 완전히 무증상이다 — PR #1179 의 3-suite 분리에서
# claude-rc 테스트 52개가 그렇게 조용히 죽어 있었다. 그 계약을 여기서 강제한다.
#
# 정의 원천을 'suites 파일 텍스트'로 한정하는 이유: 런타임 `declare -F` 열거를 쓰면
# scripts/ai/test-runtime-profile.sh 가 production 함수를 test_runtime_profile_* 로 명명하고 있어
# (tests/suites/test-runtime-profile.sh 가 이를 source) 오탐이 난다.
test_suite_function_registration_parity() {
  local defined registered unregistered undefined

  # `name() (` 서브셸 정의형(tests/suites/test-runtime-profile.sh)도 함께 매치된다.
  defined="$(grep -hoE '^[[:space:]]*test_[A-Za-z0-9_]+\(\)' "$REPO_ROOT"/tests/suites/*.sh |
    sed -E 's/^[[:space:]]*//; s/\(\)$//' | sort -u)"
  # 앵커는 '행 선두 + 선택적 공백'까지만 둔다. 조건부 블록 안의 들여쓴 run_test 는 포함하되,
  # 주석으로 비활성화된 등록(`# run_test "x" test_x`)은 제외해야 한다 — 그걸 등록으로 세면
  # 실행되지 않는 테스트가 parity 를 통과해 이 가드가 막으려던 무증상 누락이 그대로 남는다.
  registered="$(grep -oE '^[[:space:]]*run_test "[^"]*" [A-Za-z0-9_]+' "$REPO_ROOT/tests/shell-script-tests.sh" |
    awk '{ print $NF }' | sort -u)"

  [[ -n "$defined" ]] || fail "expected suite definitions to be discovered"
  [[ -n "$registered" ]] || fail "expected aggregator registrations to be discovered"

  unregistered="$(comm -23 <(printf '%s\n' "$defined") <(printf '%s\n' "$registered"))"
  [[ -z "$unregistered" ]] ||
    fail "suite 정의 함수가 tests/shell-script-tests.sh 에 등록되지 않았다(실행되지 않음): $(echo "$unregistered" | tr '\n' ' ')"

  undefined="$(comm -13 <(printf '%s\n' "$defined") <(printf '%s\n' "$registered"))"
  [[ -z "$undefined" ]] ||
    fail "tests/shell-script-tests.sh 가 등록한 이름이 tests/suites/*.sh 에 정의되어 있지 않다: $(echo "$undefined" | tr '\n' ' ')"
}
