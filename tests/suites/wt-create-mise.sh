# tests/suites/wt-create-mise.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# fixture repo에 파일을 추가 커밋한다 (create_git_fixture_repo와 동일한 격리 가드).
_mise_fixture_commit() {
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

# stub mise를 설치한다: trust 호출을 marker에 기록하고 MISE_STUB_EXIT로 종료.
_install_mise_stub() {
  local stub_dir="$1"
  mkdir -p "$stub_dir"
  cat > "$stub_dir/mise" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "trust" ]]; then
  printf 'trust:%s\n' "${2:-}" >> "${MISE_TRUST_MARKER:?}"
fi
exit "${MISE_STUB_EXIT:-0}"
EOF
  chmod +x "$stub_dir/mise"
}

test_wt_create_trusts_mise_configs() {
  local sandbox home_dir repo_root stub_dir marker_file output new_worktree
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  marker_file="$sandbox/mise-trust-marker"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  _install_mise_stub "$stub_dir"

  printf '[tools]\nnode = "22"\n' > "$repo_root/mise.toml"
  _mise_fixture_commit "$repo_root" "$home_dir" add mise.toml
  _mise_fixture_commit "$repo_root" "$home_dir" commit -m "add mise.toml" > /dev/null 2>&1

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
      MISE_TRUST_MARKER="$marker_file" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-mise-trust
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/feature-mise-trust"
  [[ -d "$new_worktree" ]] || fail "expected worktree directory to exist: $new_worktree"
  assert_contains "$output" "$new_worktree"
  [[ -f "$marker_file" ]] || fail "expected mise trust to be called for worktree mise.toml"
  assert_contains "$(cat "$marker_file")" "trust:$new_worktree/mise.toml"
}

test_wt_create_mise_trust_failure_is_nonfatal() {
  local sandbox home_dir repo_root stub_dir marker_file output new_worktree
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  marker_file="$sandbox/mise-trust-marker"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  _install_mise_stub "$stub_dir"

  printf '[tools]\nnode = "22"\n' > "$repo_root/mise.toml"
  _mise_fixture_commit "$repo_root" "$home_dir" add mise.toml
  _mise_fixture_commit "$repo_root" "$home_dir" commit -m "add mise.toml" > /dev/null 2>&1

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
      MISE_TRUST_MARKER="$marker_file" \
      MISE_STUB_EXIT=1 \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature-mise-fail
      ' 2>&1
  )

  new_worktree="$repo_root/.claude/worktrees/feature-mise-fail"
  [[ -d "$new_worktree" ]] || fail "worktree creation must survive mise trust failure: $new_worktree"
  assert_contains "$output" "$new_worktree"
  assert_contains "$output" "mise trust 실패"
}
