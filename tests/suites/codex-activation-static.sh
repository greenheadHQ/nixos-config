# tests/suites/codex-activation-static.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
test_codex_activation_agents_symlink_guard_static() {
  local content
  content="$(cat "$REPO_ROOT/modules/shared/programs/codex/default.nix")"
  assert_contains "$content" 'Refusing to project Codex skills through .agents symlink'
  assert_contains "$content" 'Refusing to project Codex skills because .agents is not a directory'
  assert_contains "$content" 'Refusing to project Codex skills through .agents/skills symlink'
  assert_contains "$content" 'Refusing to project Codex skills because .agents/skills is not a directory'
  assert_contains "$content" 'mkdir -p "$TARGET_SKILLS"'
}
