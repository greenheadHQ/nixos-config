# tests/suites/verify-ai-compat.sh — verify-ai-compat host-state lib fixture tests
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC1091: repo-local lib source.
# shellcheck disable=SC2154,SC1091

source "$REPO_ROOT/scripts/ai/lib/host-state-checks.sh"

_verify_ai_compat_write_script() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' '#!/usr/bin/env bash' ':' > "$path"
}

_verify_ai_compat_make_oracle_fixture() {
  local repo_root="$1"
  local source_state="$2"
  local lib_path="$repo_root/modules/shared/programs/claude/files/lib/demo-lib.sh"
  local hook_path="$repo_root/modules/shared/programs/claude/files/hooks/demo-hook.sh"

  mkdir -p "$(dirname "$lib_path")" "$(dirname "$hook_path")" "$repo_root/scripts"
  cat > "$lib_path" <<'EOF'
#!/usr/bin/env bash
# demo lib
# USED-BY:
# claude/files/hooks/demo-hook.sh   # via $DEMO_LIB
#
demo_lib_function() { :; }
EOF

  if [[ "$source_state" == "present" ]]; then
    cat > "$hook_path" <<'EOF'
#!/usr/bin/env bash
DEMO_LIB="${DEMO_LIB:-demo-lib.sh}"
. "$DEMO_LIB"
EOF
  else
    cat > "$hook_path" <<'EOF'
#!/usr/bin/env bash
DEMO_LIB="${DEMO_LIB:-demo-lib.sh}"
:
EOF
  fi
}

_verify_ai_compat_make_positive_fixture() {
  local sandbox="$1"
  local home_dir="$sandbox/home"
  local repo_root="$sandbox/repo"
  local codex_hook="$repo_root/modules/shared/programs/codex/files/hooks/pinning-guard.sh"
  local claude_hook="$repo_root/modules/shared/programs/claude/files/hooks/pinning-guard.sh"

  _verify_ai_compat_write_script "$codex_hook"
  _verify_ai_compat_write_script "$claude_hook"
  chmod +x "$codex_hook" "$claude_hook"
  mkdir -p "$home_dir/.codex/hooks" "$home_dir/.claude/hooks"
  ln -s "$codex_hook" "$home_dir/.codex/hooks/pinning-guard.sh"
  ln -s "$claude_hook" "$home_dir/.claude/hooks/pinning-guard.sh"
  _verify_ai_compat_make_oracle_fixture "$repo_root" present
}

_verify_ai_compat_with_stubbed_gate() (
  set -euo pipefail
  local home_dir="$1"
  local repo_root="$2"
  shift 2

  mkdir -p "$home_dir" "$repo_root"
  HOME="$home_dir"
  REPO_ROOT="$repo_root"
  REPO_ROOT_REAL="$(cd "$repo_root" && pwd -P)"
  MAIN_REPO_ROOT="$REPO_ROOT_REAL"
  errors=0
  pass_count=0

  pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS\t%s\n' "$1"
  }

  fail() {
    errors=$((errors + 1))
    printf 'FAIL\t%s\n' "$1"
  }

  "$@"
  printf 'ERRORS\t%s\n' "$errors"
  printf 'PASSES\t%s\n' "$pass_count"
)

_verify_ai_compat_assert_error_count() {
  local output="$1"
  local expected="$2"
  local marker
  marker="$(printf 'ERRORS\t%s' "$expected")"
  assert_contains "$output" "$marker"
}

_verify_ai_compat_positive_checks() {
  local expected_suffix="modules/shared/programs/claude/files/hooks/pinning-guard.sh"
  local expected="$REPO_ROOT_REAL/$expected_suffix"

  _check_hook_executable ".codex/hooks/pinning-guard.sh"
  _check_executable_symlink_suffix ".claude/hooks/pinning-guard.sh" "$expected_suffix"
  if resolved_target_matches_repo_suffix "$expected" "$expected" "$expected_suffix"; then
    pass "resolved target accepts expected repo suffix"
  else
    fail "resolved target rejected expected repo suffix"
  fi
  verify_used_by_oracle "$REPO_ROOT/modules/shared/programs/claude/files/lib/demo-lib.sh" "demo-lib.sh"
}

test_verify_ai_compat_host_state_positive_fixture() {
  local sandbox home_dir repo_root output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  _verify_ai_compat_make_positive_fixture "$sandbox"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" _verify_ai_compat_positive_checks)"
  _verify_ai_compat_assert_error_count "$output" 0
  assert_contains "$output" "hook 사본 OK: .codex/hooks/pinning-guard.sh"
  assert_contains "$output" "프로비저닝 실행 파일 OK: .claude/hooks/pinning-guard.sh"
  assert_contains "$output" "USED-BY oracle 통과: demo-lib.sh"
}

_verify_ai_compat_non_executable_hook_check() {
  _check_hook_executable ".codex/hooks/pinning-guard.sh"
}

test_verify_ai_compat_host_state_detects_non_executable_hook() {
  local sandbox home_dir repo_root hook_path output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  hook_path="$repo_root/modules/shared/programs/codex/files/hooks/pinning-guard.sh"
  _verify_ai_compat_write_script "$hook_path"
  chmod 0644 "$hook_path"
  mkdir -p "$home_dir/.codex/hooks"
  ln -s "$hook_path" "$home_dir/.codex/hooks/pinning-guard.sh"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" _verify_ai_compat_non_executable_hook_check)"
  _verify_ai_compat_assert_error_count "$output" 1
  assert_contains "$output" "hook 실행 권한 없음"
}

_verify_ai_compat_bad_symlink_checks() {
  local expected_suffix="modules/shared/programs/claude/files/hooks/pinning-guard.sh"
  local expected="$REPO_ROOT_REAL/$expected_suffix"
  local foreign="$REPO_ROOT_REAL/../foreign/$expected_suffix"

  _check_executable_symlink_suffix ".claude/hooks/pinning-guard.sh" "$expected_suffix"
  _check_executable_symlink_suffix ".claude/hooks/broken.sh" "$expected_suffix"

  if resolved_target_matches_repo_suffix "$foreign" "$expected" "$expected_suffix"; then
    fail "resolved target accepted foreign prefix"
  else
    pass "resolved target rejects foreign prefix"
  fi
}

test_verify_ai_compat_host_state_detects_bad_symlink_targets() {
  local sandbox home_dir repo_root wrong_target output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  wrong_target="$sandbox/foreign/pinning-guard.sh"
  _verify_ai_compat_write_script "$wrong_target"
  chmod +x "$wrong_target"
  mkdir -p "$home_dir/.claude/hooks"
  ln -s "$wrong_target" "$home_dir/.claude/hooks/pinning-guard.sh"
  ln -s "$sandbox/missing/pinning-guard.sh" "$home_dir/.claude/hooks/broken.sh"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" _verify_ai_compat_bad_symlink_checks)"
  _verify_ai_compat_assert_error_count "$output" 2
  assert_contains "$output" "프로비저닝 실행 파일 target suffix 불일치"
  assert_contains "$output" "프로비저닝 실행 파일 없음"
  assert_contains "$output" "resolved target rejects foreign prefix"
}

_verify_ai_compat_removed_oracle_reference_check() {
  verify_used_by_oracle "$REPO_ROOT/modules/shared/programs/claude/files/lib/demo-lib.sh" "demo-lib.sh"
}

test_verify_ai_compat_host_state_detects_removed_oracle_reference() {
  local sandbox home_dir repo_root output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  mkdir -p "$home_dir"
  _verify_ai_compat_make_oracle_fixture "$repo_root" removed

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" _verify_ai_compat_removed_oracle_reference_check)"
  _verify_ai_compat_assert_error_count "$output" 1
  assert_contains "$output" "USED-BY oracle: demo-lib.sh"
  assert_contains "$output" "실제 source 패턴 미발견"
}
