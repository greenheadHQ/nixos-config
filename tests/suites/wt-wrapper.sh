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
  # 활성 작업 가드와 그 --yes 우회 범위는 help가 알린다 (--auto --yes는 우회하지 않음).
  assert_contains "$output" "활성 작업 가드"
  assert_contains "$output" "wt cleanup --auto --yes는 우회하지 않고"
  # 대화형 선택도 --yes 우회 범위에 든다(코드가 같은 경로를 탄다). 남는 제약 중 실측된 것도 알린다.
  assert_contains "$output" "이름을 지정하거나 대화형으로 고른 정리"
  assert_contains "$output" "샌드박스가 다른 프로세스 정보만 가린 환경"
  # 퇴역한 presentation 플래그는 help에 남으면 안 된다 — 문서에만 남은 플래그는
  # 실행하면 unknown option으로 죽는다.
  local flag
  for flag in --stay --claude --tmux; do
    assert_not_contains "$output" "$flag"
  done
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
