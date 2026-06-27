# tests/suites/wt-wrapper.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
test_wt_help_from_deployed_layout() {
  local sandbox output
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"

  output=$(
    HOME="$sandbox/home" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$sandbox/home/.local/bin/wt" --help 2>&1
  )

  assert_contains "$output" "사용법: wt"
  assert_contains "$output" "wt cleanup [--auto]"
}

test_wt_wrapper_ignores_runtime_home_for_real_script() {
  local sandbox poison_home output
  sandbox=$(new_sandbox)
  poison_home="$sandbox/poison-home"
  install_deployed_layout "$sandbox"
  mkdir -p "$poison_home/.local/bin"
  cat > "$poison_home/.local/bin/.wt-real" <<'EOF'
#!/usr/bin/env bash
echo MALICIOUS_WT_REAL
EOF
  chmod +x "$poison_home/.local/bin/.wt-real"

  output=$(
    HOME="$poison_home" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash "$sandbox/home/.local/bin/wt" --help 2>&1
  )

  assert_contains "$output" "사용법: wt"
  assert_not_contains "$output" "MALICIOUS_WT_REAL"
}
