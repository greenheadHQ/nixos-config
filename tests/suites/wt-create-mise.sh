# tests/suites/wt-create-mise.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# 격리된 환경(fixture HOME, 전역 git config 차단)에서 fixture repo의 Git 명령을 실행한다.
_mise_fixture_git() {
  local repo_root="$1" home_dir="$2"
  shift 2
  HOME="$home_dir" \
    XDG_CONFIG_HOME="$home_dir/.config" \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo_root" \
    -c core.hooksPath=/dev/null \
    -c commit.gpgSign=false \
    "$@"
}

# stub mise: trust 호출(인자 없는 디렉토리 trust — cwd 기록)을 marker에 남기고
# MISE_STUB_EXIT로 종료. settings get paranoid는 MISE_STUB_PARANOID를 반환.
_install_mise_stub() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mise" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  trust)
    printf 'trust:%s\n' "$PWD" >> "${MISE_TRUST_MARKER:?}"
    exit "${MISE_STUB_EXIT:-0}"
    ;;
  settings)
    echo "${MISE_STUB_PARANOID:-false}"
    ;;
esac
exit 0
EOF
  chmod +x "$stub_dir/mise"
}

# 공통 준비: sandbox + fixture repo(+mise.toml 커밋) + stub 설치 후 wt create 실행.
# 인자: <branch> [extra env KEY=VALUE ...]. 전역 출력 변수:
#   _MISE_WT_OUTPUT(실행 출력), _MISE_WT_PATH(생성 worktree 경로), _MISE_WT_MARKER(marker 파일).
_run_wt_create_with_mise_stub() {
  local branch="$1"
  shift
  local sandbox home_dir repo_root stub_dir
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  _MISE_WT_MARKER="$sandbox/mise-trust-marker"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  _install_mise_stub "$stub_dir"

  printf '[tools]\nnode = "22"\n' > "$repo_root/mise.toml"
  _mise_fixture_git "$repo_root" "$home_dir" add mise.toml
  _mise_fixture_git "$repo_root" "$home_dir" commit -m "add mise.toml" > /dev/null 2>&1

  _MISE_WT_OUTPUT=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
      MISE_TRUST_MARKER="$_MISE_WT_MARKER" \
      WT_NONINTERACTIVE=1 \
      "$@" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" "'"$branch"'"
      ' 2>&1
  )
  _MISE_WT_PATH="$repo_root/.claude/worktrees/$branch"
}

test_wt_create_trusts_mise_configs() {
  local _MISE_WT_OUTPUT _MISE_WT_PATH _MISE_WT_MARKER
  _run_wt_create_with_mise_stub feature-mise-trust

  [[ -d "$_MISE_WT_PATH" ]] || fail "expected worktree directory to exist: $_MISE_WT_PATH"
  assert_contains "$_MISE_WT_OUTPUT" "$_MISE_WT_PATH"
  [[ -f "$_MISE_WT_MARKER" ]] || fail "expected directory-level mise trust to run in the worktree"
  assert_contains "$(cat "$_MISE_WT_MARKER")" "trust:$_MISE_WT_PATH"
}

test_wt_create_mise_trust_failure_is_nonfatal() {
  local _MISE_WT_OUTPUT _MISE_WT_PATH _MISE_WT_MARKER
  _run_wt_create_with_mise_stub feature-mise-fail MISE_STUB_EXIT=1

  [[ -d "$_MISE_WT_PATH" ]] || fail "worktree creation must survive mise trust failure: $_MISE_WT_PATH"
  assert_contains "$_MISE_WT_OUTPUT" "$_MISE_WT_PATH"
  assert_contains "$_MISE_WT_OUTPUT" "mise trust 실패"
}

test_wt_create_mise_paranoid_skips_auto_trust() {
  local _MISE_WT_OUTPUT _MISE_WT_PATH _MISE_WT_MARKER
  _run_wt_create_with_mise_stub feature-mise-paranoid MISE_PARANOID=1

  [[ -d "$_MISE_WT_PATH" ]] || fail "worktree creation must succeed in paranoid mode: $_MISE_WT_PATH"
  assert_contains "$_MISE_WT_OUTPUT" "paranoid"
  [[ ! -f "$_MISE_WT_MARKER" ]] || fail "paranoid mode must not auto-trust: $(cat "$_MISE_WT_MARKER")"
}

test_wt_create_mise_paranoid_setting_skips_auto_trust() {
  local _MISE_WT_OUTPUT _MISE_WT_PATH _MISE_WT_MARKER
  _run_wt_create_with_mise_stub feature-mise-paranoid-set MISE_STUB_PARANOID=true

  [[ -d "$_MISE_WT_PATH" ]] || fail "worktree creation must succeed with paranoid=true: $_MISE_WT_PATH"
  assert_contains "$_MISE_WT_OUTPUT" "paranoid"
  [[ ! -f "$_MISE_WT_MARKER" ]] || fail "paranoid setting must not auto-trust: $(cat "$_MISE_WT_MARKER")"
}

test_wt_create_mise_symlink_config_skips_auto_trust() {
  local _MISE_WT_OUTPUT _MISE_WT_PATH _MISE_WT_MARKER
  local sandbox home_dir repo_root stub_dir outside
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  outside="$sandbox/outside.toml"
  _MISE_WT_MARKER="$sandbox/mise-trust-marker"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  _install_mise_stub "$stub_dir"

  printf '[env]\nEVIL = "1"\n' > "$outside"
  ln -s "$outside" "$repo_root/mise.toml"
  _mise_fixture_git "$repo_root" "$home_dir" add mise.toml
  _mise_fixture_git "$repo_root" "$home_dir" commit -m "add symlinked mise.toml" > /dev/null 2>&1

  _MISE_WT_OUTPUT=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
      MISE_TRUST_MARKER="$_MISE_WT_MARKER" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-mise-symlink
      ' 2>&1
  )
  _MISE_WT_PATH="$repo_root/.claude/worktrees/feature-mise-symlink"

  [[ -d "$_MISE_WT_PATH" ]] || fail "worktree creation must succeed with symlinked config: $_MISE_WT_PATH"
  assert_contains "$_MISE_WT_OUTPUT" "symlink"
  [[ ! -f "$_MISE_WT_MARKER" ]] || fail "symlinked config must not be auto-trusted: $(cat "$_MISE_WT_MARKER")"
}
