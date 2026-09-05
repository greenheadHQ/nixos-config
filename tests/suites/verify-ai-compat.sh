# tests/suites/verify-ai-compat.sh — verify-ai-compat host-state lib fixture tests
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC1091: repo-local lib source.
# SC2034: 이 suite가 세팅하는 전역(MAIN_REPO_ROOT/RETIRED_*)은 source한 lib이 소비한다.
# shellcheck disable=SC2154,SC1091,SC2034

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
  warnings=0
  pass_count=0

  pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS\t%s\n' "$1"
  }

  fail() {
    errors=$((errors + 1))
    printf 'FAIL\t%s\n' "$1"
  }

  warn() {
    warnings=$((warnings + 1))
    printf 'WARN\t%s\n' "$1"
  }

  "$@"
  printf 'ERRORS\t%s\n' "$errors"
  printf 'WARNINGS\t%s\n' "$warnings"
  printf 'PASSES\t%s\n' "$pass_count"
)

_verify_ai_compat_assert_error_count() {
  local output="$1"
  local expected="$2"
  local marker
  marker="$(printf 'ERRORS\t%s' "$expected")"
  assert_contains "$output" "$marker"
}

_verify_ai_compat_assert_warning_count() {
  local output="$1"
  local expected="$2"
  local marker
  marker="$(printf 'WARNINGS\t%s' "$expected")"
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

# ─── retired 스킬 잔존 참조 스캔 범위 ───
# fixture는 실제 retired 스킬명을 쓰지 않는다 (이 파일 자체가 스캔 범위 안이라 자기 매치를 피한다).
_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME="retired-demo-skill"

_verify_ai_compat_make_retired_ref_fixture() {
  local repo_root="$1"
  local name="$_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME"
  local shared="$repo_root/modules/shared/programs/claude/files/skills"

  mkdir -p \
    "$shared/demo/modes" \
    "$shared/demo/references" \
    "$repo_root/.claude/skills/other" \
    "$repo_root/scripts/ai" \
    "$repo_root/tests/suites"

  # 구 스캔 범위(SKILL.md·references/*.md·evals/queries.json)가 놓치던 위치들.
  printf 'audit mode still routes to %s\n' "$name" > "$shared/demo/modes/audit.md"
  printf '# helper referencing %s\n' "$name" > "$repo_root/scripts/ai/legacy-helper.sh"
  printf '# suite referencing %s\n' "$name" > "$repo_root/tests/suites/legacy.sh"
  # 의도적 이력 서술 (제외 목록 대상) — 같은 파일에 진짜 잔존 참조도 한 줄 둔다.
  {
    printf 'Owner note: %s removed in the past.\n' "$name"
    printf 'audit still routes to %s today.\n' "$name"
  } > "$shared/demo/references/history.md"
  printf 'clean doc\n' > "$repo_root/.claude/skills/other/SKILL.md"
}

_verify_ai_compat_retired_ref_check() {
  RETIRED_SHARED_SKILLS=("$_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME")
  RETIRED_REF_SCAN_ROOTS=(
    "$REPO_ROOT/.claude/skills"
    "$REPO_ROOT/modules/shared/programs/claude/files/skills"
    "$REPO_ROOT/scripts/ai"
    "$REPO_ROOT/tests"
  )
  RETIRED_REF_SCAN_EXCLUDE=()
  if [ -n "${1:-}" ]; then
    RETIRED_REF_SCAN_EXCLUDE=("$1")
  fi
  verify_retired_shared_skill_references
}

# 제외 항목 문자열(<스킬명>|<상대 경로>|<라인 부분문자열>) 조립 helper.
_verify_ai_compat_retired_ref_exclude_entry() {
  printf '%s|%s|%s' \
    "$_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME" \
    "modules/shared/programs/claude/files/skills/demo/references/history.md" \
    "$1"
}

test_verify_ai_compat_retired_ref_scan_covers_modes_scripts_and_tests() {
  local sandbox home_dir repo_root output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  _verify_ai_compat_make_retired_ref_fixture "$repo_root"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" \
    _verify_ai_compat_retired_ref_check "" 2>&1)"
  _verify_ai_compat_assert_error_count "$output" 0
  _verify_ai_compat_assert_warning_count "$output" 1
  assert_contains "$output" "retired shared 스킬 참조 잔존: $_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME (5건)"
  assert_contains "$output" "modules/shared/programs/claude/files/skills/demo/modes/audit.md:1:"
  assert_contains "$output" "scripts/ai/legacy-helper.sh:1:"
  assert_contains "$output" "tests/suites/legacy.sh:1:"
}

# 제외는 파일이 아니라 라인 단위다: 같은 파일의 이력 서술만 면제되고,
# 그 아래 진짜 잔존 참조는 그대로 잡혀야 한다.
test_verify_ai_compat_retired_ref_scan_honors_exclusions() {
  local sandbox home_dir repo_root entry output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  _verify_ai_compat_make_retired_ref_fixture "$repo_root"
  entry="$(_verify_ai_compat_retired_ref_exclude_entry "removed in the past")"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" \
    _verify_ai_compat_retired_ref_check "$entry" 2>&1)"
  _verify_ai_compat_assert_error_count "$output" 0
  assert_contains "$output" "retired shared 스킬 참조 잔존: $_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME (4건)"
  assert_not_contains "$output" "demo/references/history.md:1:"
  assert_contains "$output" "demo/references/history.md:2:"
}

# 아무 라인에도 걸리지 않는 제외 항목은 죽은 규칙이므로 fail로 드러나야 한다.
test_verify_ai_compat_retired_ref_scan_detects_stale_exclusion() {
  local sandbox home_dir repo_root entry output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  _verify_ai_compat_make_retired_ref_fixture "$repo_root"
  entry="$(_verify_ai_compat_retired_ref_exclude_entry "이미 사라진 서술")"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" \
    _verify_ai_compat_retired_ref_check "$entry" 2>&1)"
  _verify_ai_compat_assert_error_count "$output" 1
  assert_contains "$output" "제외 항목이 아무 라인에도 걸리지 않음(stale)"
  assert_contains "$output" "retired shared 스킬 참조 잔존: $_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME (5건)"
}

# 읽지 못한 파일이 있어도(grep rc>1) 같은 실행에서 찾은 매치는 계속 보고해야 한다.
test_verify_ai_compat_retired_ref_scan_reports_partial_grep_failure() {
  local sandbox home_dir repo_root unreadable output
  if [ "$(id -u)" = 0 ]; then
    echo "    (skip: root는 읽기 권한 제한을 우회한다)" >&2
    return 0
  fi
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  _verify_ai_compat_make_retired_ref_fixture "$repo_root"
  unreadable="$repo_root/scripts/ai/legacy-helper.sh"
  chmod 000 "$unreadable"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" \
    _verify_ai_compat_retired_ref_check "" 2>&1)"
  chmod 644 "$unreadable"  # sandbox cleanup이 rm -rf 할 수 있도록 권한 복구.
  _verify_ai_compat_assert_error_count "$output" 1
  assert_contains "$output" "grep 부분 실패: $_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME"
  assert_contains "$output" "retired shared 스킬 참조 잔존: $_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME (4건)"
  assert_contains "$output" "modules/shared/programs/claude/files/skills/demo/modes/audit.md:1:"
}

test_verify_ai_compat_retired_ref_scan_passes_when_clean() {
  local sandbox home_dir repo_root output
  sandbox="$(new_sandbox)"
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  mkdir -p "$repo_root/.claude/skills/other" "$repo_root/scripts/ai" "$repo_root/tests/suites"
  printf 'clean doc\n' > "$repo_root/.claude/skills/other/SKILL.md"

  output="$(_verify_ai_compat_with_stubbed_gate "$home_dir" "$repo_root" \
    _verify_ai_compat_retired_ref_check "" 2>&1)"
  _verify_ai_compat_assert_error_count "$output" 0
  _verify_ai_compat_assert_warning_count "$output" 0
  assert_contains "$output" "retired shared 스킬 참조 없음: $_VERIFY_AI_COMPAT_RETIRED_FIXTURE_NAME"
}
