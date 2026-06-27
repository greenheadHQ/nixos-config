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
