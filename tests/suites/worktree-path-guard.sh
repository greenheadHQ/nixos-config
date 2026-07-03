# tests/suites/worktree-path-guard.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# worktree-path-guard.sh PreToolUse 가드에 JSON stdin을 흘려, main repo 보호와 sibling worktree
# 오탐 제거(이슈 #935)를 함께 박제한다. 가드는 Edit/Write tool_input.file_path만 검사하며,
# main repo 세션(git-dir == git-common-dir)에서는 조기 종료로 항상 통과한다.
# 임시 bare-minimum git repo + `git worktree add` 2개(a, b)로 fixture를 구성해
# 실제 $HOME이나 이 저장소의 worktree는 건드리지 않는다.

_wpg_isolated_git() {
  # fixture repo 전용 git 실행기. HOME/XDG를 격리해 실제 사용자 git 설정과 무관하게 동작시킨다.
  local repo_root="$1"
  shift
  local home_dir
  home_dir="$(dirname "$repo_root")/home"
  mkdir -p "$home_dir/.config"
  HOME="$home_dir" \
    XDG_CONFIG_HOME="$home_dir/.config" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" \
    -c commit.gpgSign=false \
    -c init.templateDir= \
    "$@"
}

_wpg_setup_fixture() {
  # $1 = sandbox 디렉토리(new_sandbox로 이미 생성됨). main repo + worktree a/b를 만들고
  # main repo 절대경로를 stdout으로 반환한다.
  local sandbox="$1"
  local main_root="$sandbox/main"
  mkdir -p "$main_root"
  _wpg_isolated_git "$main_root" init -b main >/dev/null 2>&1
  _wpg_isolated_git "$main_root" config user.name "Test User"
  _wpg_isolated_git "$main_root" config user.email "test@example.com"
  echo "main" > "$main_root/flake.nix"
  mkdir -p "$main_root/.claude/plans"
  _wpg_isolated_git "$main_root" add flake.nix
  _wpg_isolated_git "$main_root" commit -m "initial" >/dev/null 2>&1
  _wpg_isolated_git "$main_root" worktree add ".claude/worktrees/a" -b wt-a >/dev/null 2>&1
  _wpg_isolated_git "$main_root" worktree add ".claude/worktrees/b" -b wt-b >/dev/null 2>&1
  printf '%s\n' "$main_root"
}

_wpg_decision() {
  # $1 = 훅을 실행할 cwd, $2 = tool_input.file_path, $3 = tool_name(기본 Edit).
  local cwd="$1" file_path="$2" tool_name="${3:-Edit}"
  (
    cd "$cwd" && \
    printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "$tool_name" "$file_path" | \
      bash "$REPO_ROOT/modules/shared/programs/claude/files/hooks/worktree-path-guard.sh" 2>&1
  )
}

test_worktree_path_guard_main_repo_session_always_allows() {
  local sandbox main_root out
  sandbox=$(new_sandbox)
  main_root=$(_wpg_setup_fixture "$sandbox")
  # main repo 세션(git-dir == git-common-dir)은 조기 종료 — repo 밖 임의 경로도 통과해야 한다.
  out=$(_wpg_decision "$main_root" "/etc/hosts")
  [[ -z "$out" ]] || fail "expected main repo session to allow unconditionally, got: $out"
}

test_worktree_path_guard_denies_main_repo_file_from_worktree() {
  local sandbox main_root out
  sandbox=$(new_sandbox)
  main_root=$(_wpg_setup_fixture "$sandbox")
  out=$(_wpg_decision "$main_root/.claude/worktrees/a" "$main_root/flake.nix")
  assert_contains "$out" '"permissionDecision": "deny"'
}

test_worktree_path_guard_allows_own_worktree_file() {
  local sandbox main_root out
  sandbox=$(new_sandbox)
  main_root=$(_wpg_setup_fixture "$sandbox")
  out=$(_wpg_decision "$main_root/.claude/worktrees/a" "$main_root/.claude/worktrees/a/flake.nix")
  [[ -z "$out" ]] || fail "expected own worktree file to be allowed, got: $out"
}

test_worktree_path_guard_allows_sibling_worktree_file() {
  # 이슈 #935 회귀 테스트: worktree A에서 sibling worktree B 파일 편집은 main repo 파일이
  # 아니므로 허용되어야 한다. 이번 plan의 존재 이유.
  local sandbox main_root out
  sandbox=$(new_sandbox)
  main_root=$(_wpg_setup_fixture "$sandbox")
  out=$(_wpg_decision "$main_root/.claude/worktrees/a" "$main_root/.claude/worktrees/b/flake.nix")
  [[ -z "$out" ]] || fail "expected sibling worktree file to be allowed, got: $out"
}

test_worktree_path_guard_allows_main_repo_plan_path_exception() {
  # 기존 예외(29-43행 상당, 이번 plan 범위 밖) 회귀 확인: main repo .claude/plans/*.md는
  # worktree 세션에서도 계속 허용되어야 한다.
  local sandbox main_root out
  sandbox=$(new_sandbox)
  main_root=$(_wpg_setup_fixture "$sandbox")
  out=$(_wpg_decision "$main_root/.claude/worktrees/a" "$main_root/.claude/plans/x.md")
  [[ -z "$out" ]] || fail "expected main repo plan path exception to allow, got: $out"
}
