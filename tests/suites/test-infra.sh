# tests/suites/test-infra.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
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
  # 조건부 블록 안의 들여쓴 run_test 도 포함해야 하므로 행 선두 앵커를 쓰지 않는다.
  registered="$(grep -oE 'run_test "[^"]*" [A-Za-z0-9_]+' "$REPO_ROOT/tests/shell-script-tests.sh" |
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
