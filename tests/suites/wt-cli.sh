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
    CODEX_HOME="$home_dir/.codex" \
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

# 수집 기준 회귀: 디렉토리 스캔(mindepth/maxdepth 1)만 보던 과거 구현은 두 부류를 통째로
# 놓쳤다 — (a) 등록만 남고 디렉토리가 사라진 worktree, (b) depth 2 이상 경로. 둘 다 wt의
# 시야 밖이면 `git worktree list`에는 있는데 `wt ls`에는 없는 유령이 되어 진단이 막힌다.
test_wt_ls_lists_registered_missing_and_nested_worktrees() {
  local sandbox home_dir repo_root output json gone_path nested_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  gone_path="$repo_root/.claude/worktrees/zz_gone"
  nested_path="$repo_root/.claude/worktrees/feat/nested"
  add_fixture_worktree "$repo_root" "$gone_path" "zz-gone"
  add_fixture_worktree "$repo_root" "$nested_path" "feat-nested"
  rm -rf "$gone_path"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" ls
      ' 2>&1
  )

  assert_contains "$output" "Worktrees (3)"
  assert_contains "$output" "nested"
  assert_contains "$output" "feat-nested"
  assert_contains "$output" "zz_gone"
  # 등록만 남은 항목은 worktree에서 읽을 값이 없다 — 상태를 BROKEN으로 세우고,
  # 이 상황에서 실제로 듣는 명령(prune)을 안내해야 한다.
  assert_contains "$output" "⚠️ BROKEN"
  assert_contains "$output" "손상된 worktree: zz_gone (디렉토리 없음 — 수동 정리: git worktree prune)"

  # --json의 broken 계약: worktree에서 읽을 수 없는 항목이라는 사실과, 그때 branch가
  # 등록에서 읽은 값(자리표시자 아님)이라는 것까지 고정한다. 이 플래그가 없으면 JSON
  # 소비자가 committedAt=0·dirty=false를 실제 상태로 오해한다.
  json=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" ls --json
      ' 2>/dev/null
  )
  echo "$json" | jq -e 'any(.[]; .name == "zz_gone" and .broken == true and .branch == "zz-gone" and .committedAt == 0 and .dirty == false and .pr == "NONE")' >/dev/null \
    || fail "wt ls --json must report zz_gone as broken with its registered branch: $json"
  # depth 2 이상 항목의 name은 wt_base 상대 경로여야 한다 — basename이면 depth 1 항목과
  # 구분되지 않고, cleanup에 넘길 이름으로도 쓸 수 없다.
  echo "$json" | jq -e 'any(.[]; .name == "feat/nested" and .broken == false)' >/dev/null \
    || fail "wt ls --json must name nested worktrees by relative path: $json"
}

# 잠긴(locked) worktree는 cleanup 후보에서 빠지므로, 목록에서 그 사실이 바로 보여야 한다.
test_wt_ls_marks_locked_worktree() {
  local sandbox home_dir repo_root output json locked_path
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  locked_path="$repo_root/.claude/worktrees/zz_locked"
  add_fixture_worktree "$repo_root" "$locked_path" "zz-locked"
  lock_fixture_worktree "$repo_root" "$locked_path" "bridge holds it"

  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" ls
      ' 2>&1
  )
  assert_contains "$output" "zz_locked 🔒"

  json=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" ls --json
      ' 2>/dev/null
  )
  echo "$json" | jq -e 'any(.[]; .name == "zz_locked" and .locked == true and .broken == false)' >/dev/null \
    || fail "wt ls --json must mark zz_locked as locked: $json"
  echo "$json" | jq -e 'any(.[]; .name == "feature_one" and .locked == false)' >/dev/null \
    || fail "wt ls --json must keep unlocked worktrees locked:false: $json"
}

# 등록만 남고 디렉토리가 사라진 항목도 목록에 들어오므로 `wt cd`의 매칭 후보가 된다.
# 존재하지 않는 경로를 그대로 출력하면 `cd "$(wt cd <name>)"`가 이유 없이 실패하고,
# 같은 항목을 ⚠️ BROKEN으로 표시하는 `wt ls`와 진단이 갈라진다.
test_wt_cd_refuses_broken_worktree() {
  local sandbox home_dir repo_root gone_path output rc
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"

  gone_path="$repo_root/.claude/worktrees/zz_gone"
  add_fixture_worktree "$repo_root" "$gone_path" "zz-gone"
  rm -rf "$gone_path"

  rc=0
  output=$(
    env -u TMUX \
      HOME="$home_dir" \
      CODEX_HOME="$home_dir/.codex" \
      PATH="$FIXTURE_DIR/bin:$PATH" \
      bash -c '
        set -euo pipefail
        cd "'"$repo_root"'"
        "'"$home_dir/.local/bin/wt"'" cd zz_gone
      ' 2>&1
  ) || rc=$?

  [[ "$rc" != "0" ]] || fail "손상된 worktree로는 이동할 수 없어야 함: $output"
  assert_contains "$output" "손상된 worktree라 이동할 수 없습니다: zz_gone"
  assert_contains "$output" "git worktree prune"
  assert_not_contains "$output" "$gone_path
"
}

# 수집은 등록(porcelain, 물리 경로)과 디렉토리 스캔(논리 경로)의 합집합이라, 두 표기가
# 다르면 같은 worktree가 두 줄이 된다 — `.claude`가 심링크인 배치에서 목록·정리 루프가
# 같은 항목을 두 번 도는 회귀다.
test_wt_collect_worktrees_dedupes_symlinked_base_unit() {
  local sandbox repo real_base
  sandbox=$(new_sandbox)
  repo="$sandbox/repo"
  mkdir -p "$repo"
  repo="$(cd "$repo" && pwd -P)"
  real_base="$sandbox/realclaude"

  (
    set -euo pipefail
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$repo" init -q
    git -C "$repo" config user.email t@example.invalid
    git -C "$repo" config user.name t
    git -C "$repo" commit -q --allow-empty -m first
    mkdir -p "$real_base/worktrees"
    ln -s "$real_base" "$repo/.claude"
    git -C "$repo" worktree add -q "$repo/.claude/worktrees/x" -b feature

    # WORKTREE_DIR은 평소 wt.sh가 정의한다 — 여기서는 헬퍼만 source하므로 직접 세운다.
    # shellcheck disable=SC2034
    WORKTREE_DIR=".claude/worktrees"
    # shellcheck source=/dev/null
    source "$REPO_ROOT/modules/shared/scripts/lib/wt/git-state.sh"

    local collected count
    collected=$(_collect_worktrees "$repo")
    count=$(printf '%s\n' "$collected" | grep -c 'worktrees/x$' || true)
    [[ "$count" == "1" ]] || exit 41
    # 이름도 한 번만, 상대 경로로 나와야 한다 (표시·선택 키가 이 값이다).
    [[ "$(_wt_display_name "$repo" "$collected")" == "x" ]] || exit 42
  ) || fail "_collect_worktrees가 심링크 base에서 중복 없이 수집하는지 확인 실패 (exit $?)"
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
      CODEX_HOME="$home_dir/.codex" \
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
      CODEX_HOME="$home_dir/.codex" \
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
      CODEX_HOME="$home_dir/.codex" \
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
      CODEX_HOME="$home_dir/.codex" \
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
      CODEX_HOME="$home_dir/.codex" \
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
    CODEX_HOME="$home_dir/.codex" \
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
    CODEX_HOME="$home_dir/.codex" \
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
    CODEX_HOME="$home_dir/.codex" \
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
