# tests/suites/wt-cli.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
test_wt_ls_from_deployed_layout_lists_worktrees() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  install_deployed_layout "$sandbox"
  create_git_fixture_repo "$repo_root"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" ls
    ' 2>&1
  )

  assert_contains "$output" "Worktrees (1)"
  assert_contains "$output" "feature_one"
}

test_wt_cd_by_name_returns_target_path() {
  local sandbox home_dir repo_root output expected_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  expected_path="$repo_root/.claude/worktrees/feature_one"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" cd feature_one
      ' 2>&1
  )

  assert_contains "$output" "$expected_path"
}

test_wt_create_conflict_noninteractive_requires_if_exists() {
  local sandbox home_dir repo_root output rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  rc=0
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" feature_one
      ' 2>&1
  ) || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit for noninteractive conflict"
  assert_contains "$output" "--if-exists"
  assert_not_contains "$output" "선택>"
}

test_wt_create_if_exists_reuse_returns_path() {
  local sandbox home_dir repo_root output expected_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  expected_path="$repo_root/.claude/worktrees/feature_one"
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" --if-exists=reuse feature_one
      ' 2>&1
  )

  assert_contains "$output" "$expected_path"
}

test_wt_ls_json_outputs_parseable_array() {
  local sandbox home_dir repo_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" ls --json
      ' 2>/dev/null
  )

  echo "$output" | jq -e 'type == "array" and any(.[]; .name == "feature_one" and (.dirty | type == "boolean") and (.unpushed | type == "boolean"))' >/dev/null \
    || fail "wt ls --json must be a JSON array containing feature_one with boolean flags: $output"
}

test_wt_cd_noninteractive_requires_name() {
  local sandbox home_dir repo_root output rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  rc=0
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      WT_NONINTERACTIVE=1 \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" cd
      ' 2>&1
  ) || rc=$?

  [[ "$rc" -ne 0 ]] || fail "expected non-zero exit for noninteractive cd without name"
  assert_contains "$output" "이름을 인자로"
}

# 비대화형 + TMUX 환경: tmux 윈도우 전환 분기는 대화형 한정이어야 한다.
# 가드 없으면 매칭 윈도우 존재 시 select-window 후 경로 출력 없이 return 0 —
# `cd "$(wt cd <name>)"`가 빈 문자열을 받고(zsh `cd ""`는 no-op 성공) 사용자
# tmux 화면이 임의 전환된다.
test_wt_cd_noninteractive_in_tmux_prints_path() {
  local sandbox home_dir repo_root output expected_path stub_dir marker
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubbin"
  marker="$sandbox/select-window-called"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  expected_path="$repo_root/.claude/worktrees/feature_one"

  # tmux stub: 대상 worktree에 매칭되는 pane이 존재하는 상황을 재현한다.
  # select-window 호출 시 marker 파일을 남겨 "호출되지 않았음"을 검증한다.
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) exit 0 ;;
  list-panes)    printf '@1 %s\n' "${TMUX_STUB_PANE_PATH:?}" ;;
  select-window) touch "${TMUX_STUB_MARKER:?}" ;;
  *)             exit 0 ;;
esac
STUB
  chmod +x "$stub_dir/tmux"

  output=$(
    TMUX="$sandbox/fake-tmux-socket,1234,0" \
    TMUX_STUB_PANE_PATH="$expected_path" \
    TMUX_STUB_MARKER="$marker" \
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" cd feature_one
    ' 2>&1
  )

  assert_contains "$output" "$expected_path"
  [[ ! -f "$marker" ]] || fail "noninteractive wt cd must not call tmux select-window"
}

# 비대화형 + TMUX 환경: create/reuse 경로(_open_worktree)도 동일 정책
# (_wt_tmux_ui_allowed)을 따라야 한다 — tmux 윈도우 생성/전환 없이 경로를
# stdout으로 출력한다.
test_wt_create_reuse_noninteractive_in_tmux_prints_path() {
  local sandbox home_dir repo_root output expected_path stub_dir marker
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubbin"
  marker="$sandbox/tmux-ui-called"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  expected_path="$repo_root/.claude/worktrees/feature_one"

  # tmux stub: select-window/new-window 호출 시 marker를 남겨 미호출을 검증한다.
  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) exit 0 ;;
  list-panes)    printf '@1 %s\n' "${TMUX_STUB_PANE_PATH:?}" ;;
  select-window|new-window) touch "${TMUX_STUB_MARKER:?}" ;;
  *)             exit 0 ;;
esac
STUB
  chmod +x "$stub_dir/tmux"

  output=$(
    TMUX="$sandbox/fake-tmux-socket,1234,0" \
    TMUX_STUB_PANE_PATH="$expected_path" \
    TMUX_STUB_MARKER="$marker" \
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" --if-exists=reuse feature_one
    ' 2>&1
  )

  assert_contains "$output" "$expected_path"
  [[ ! -f "$marker" ]] || fail "noninteractive wt create/reuse must not touch tmux windows"
}

# 비대화형 --stay: 대화형에서는 경로를 stderr 안내만 하지만(stdout에 내면 래퍼가
# cd해버림), 비대화형에서는 stdout 경로 출력 계약을 지켜야 한다.
test_wt_create_stay_noninteractive_prints_path_to_stdout() {
  local sandbox home_dir repo_root stdout_only expected_path stub_dir marker
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubbin"
  marker="$sandbox/tmux-ui-called"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  expected_path="$repo_root/.claude/worktrees/feature_one"

  mkdir -p "$stub_dir"
  cat > "$stub_dir/tmux" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  list-sessions) exit 0 ;;
  list-panes)    printf '@1 %s\n' "${TMUX_STUB_PANE_PATH:?}" ;;
  select-window|new-window) touch "${TMUX_STUB_MARKER:?}" ;;
  *)             exit 0 ;;
esac
STUB
  chmod +x "$stub_dir/tmux"

  # stdout만 캡처 (stderr 제외) — 경로가 "stdout"으로 나오는지가 검증 대상
  stdout_only=$(
    TMUX="$sandbox/fake-tmux-socket,1234,0" \
    TMUX_STUB_PANE_PATH="$expected_path" \
    TMUX_STUB_MARKER="$marker" \
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    WT_NONINTERACTIVE=1 \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/wt"'" --stay --if-exists=reuse feature_one
    ' 2>/dev/null
  )

  assert_contains "$stdout_only" "$expected_path"
  [[ ! -f "$marker" ]] || fail "noninteractive --stay must not touch tmux windows"
}
