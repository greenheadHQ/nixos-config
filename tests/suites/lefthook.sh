# tests/suites/lefthook.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
# ─── install-lefthook-hooks fixture helpers ───
# 실제 lefthook은 stub으로 대체한다. 우리 검증 대상은 install-lefthook-hooks.sh의
# cleanup_main_redundant_hooks_path / apply_worktree_local_hooks_config /
# acquire_install_lock / run_lefthook_install / inject_staged_guard 동작이고,
# lefthook 자체의 install 로직은 별도 신뢰 영역이다. stub은 install 명령 호출 시
# `call_lefthook run "pre-commit" "$@"` 라인을 포함한 minimal pre-commit 파일만 작성한다.

# Marker 리터럴을 install-lefthook-hooks.sh에서 한 번만 정의하고 테스트가
# 그 정의를 sed로 추출해 사용한다. install 스크립트에서 marker를 바꿔도
# 테스트가 그 변경을 자동으로 따라간다 (silent fail 방지).
LEFTHOOK_GUARD_BEGIN_MARKER=$(sed -n 's/^BEGIN_MARKER="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
LEFTHOOK_GUARD_END_MARKER=$(sed -n 's/^END_MARKER="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
[[ -n "$LEFTHOOK_GUARD_BEGIN_MARKER" ]] || fail "could not extract BEGIN_MARKER from install-lefthook-hooks.sh"
[[ -n "$LEFTHOOK_GUARD_END_MARKER" ]] || fail "could not extract END_MARKER from install-lefthook-hooks.sh"

install_lefthook_git_isolation() {
  # skill_noise_git의 7개 격리 옵션과 동일하게 사용자 시스템 git/global config 영향 차단:
  # HOME/XDG_CONFIG_HOME (user 설정 sandbox 외부 차단), GIT_CONFIG_GLOBAL=/dev/null
  # (~/.gitconfig 비활성), GIT_CONFIG_NOSYSTEM=1 (/etc/gitconfig 비활성),
  # 그리고 init.templateDir/commit.gpgSign/core.hooksPath default 격리.
  local home_dir="$1"
  mkdir -p "$home_dir/.config"
  echo "HOME=$home_dir"
  echo "XDG_CONFIG_HOME=$home_dir/.config"
  echo "GIT_CONFIG_GLOBAL=/dev/null"
  echo "GIT_CONFIG_NOSYSTEM=1"
}

install_lefthook_isolated_git() {
  # fixture repo 내부의 git 명령은 모두 위 격리 + init.templateDir 빈값 + gpgSign 끔.
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

create_install_lefthook_fixture() {
  # 메인 repo 모드 fixture: git init된 단일 repo (git_dir == git_common_dir).
  # is_main_repo가 true로 평가되어 cleanup_main_redundant_hooks_path 분기 검증.
  local repo_root="$1" stub_dir="$2"
  local home_dir
  home_dir="$(dirname "$repo_root")/home"
  mkdir -p "$repo_root" "$stub_dir" "$home_dir/.config"

  install_lefthook_isolated_git "$repo_root" init >/dev/null 2>&1
  install_lefthook_isolated_git "$repo_root" config user.name "Test User"
  install_lefthook_isolated_git "$repo_root" config user.email "test@example.com"
  cat > "$repo_root/lefthook.yml" <<'YML'
pre-commit:
  jobs:
    - name: noop
      run: "true"
YML
  install_lefthook_isolated_git "$repo_root" add lefthook.yml
  install_lefthook_isolated_git "$repo_root" commit -m "initial" >/dev/null 2>&1

  cat > "$stub_dir/lefthook" <<'STUB'
#!/usr/bin/env bash
# stub for install-lefthook-hooks shell tests: emulate `lefthook install` by writing
# a minimal pre-commit hook that contains the `call_lefthook run "pre-commit" "$@"`
# marker expected by inject_staged_guard. The stub also tolerates --force (worktree
# mode passes it). Silent on success to mirror the real CLI output we strip.
set -euo pipefail
case "${1:-}" in
  install)
    cd "$(git rev-parse --show-toplevel)"
    hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "$hooks_dir"
    cat > "$hooks_dir/pre-commit" <<'HOOK'
#!/bin/sh
call_lefthook run "pre-commit" "$@"
HOOK
    chmod +x "$hooks_dir/pre-commit"
    ;;
  *)
    echo "stub lefthook: unsupported command: ${1:-}" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_dir/lefthook"
}

create_install_lefthook_worktree_fixture() {
  # 워크트리 모드 fixture: 메인 repo 생성 후 git worktree add으로 worktree 분기.
  # is_main_repo가 false로 평가되어 apply_worktree_local_hooks_config 분기 검증.
  # 반환: $repo_root는 메인이 아닌 worktree 경로(스크립트는 그 안에서 실행됨).
  local main_root="$1" worktree_root="$2" stub_dir="$3"
  local home_dir
  home_dir="$(dirname "$main_root")/home"
  mkdir -p "$main_root" "$stub_dir" "$home_dir/.config"

  install_lefthook_isolated_git "$main_root" init -b main >/dev/null 2>&1
  install_lefthook_isolated_git "$main_root" config user.name "Test User"
  install_lefthook_isolated_git "$main_root" config user.email "test@example.com"
  cat > "$main_root/lefthook.yml" <<'YML'
pre-commit:
  jobs:
    - name: noop
      run: "true"
YML
  install_lefthook_isolated_git "$main_root" add lefthook.yml
  install_lefthook_isolated_git "$main_root" commit -m "initial" >/dev/null 2>&1
  install_lefthook_isolated_git "$main_root" worktree add -b feature "$worktree_root" >/dev/null 2>&1

  cat > "$stub_dir/lefthook" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  install)
    cd "$(git rev-parse --show-toplevel)"
    hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "$hooks_dir"
    cat > "$hooks_dir/pre-commit" <<'HOOK'
#!/bin/sh
call_lefthook run "pre-commit" "$@"
HOOK
    chmod +x "$hooks_dir/pre-commit"
    ;;
  *)
    echo "stub lefthook: unsupported command: ${1:-}" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_dir/lefthook"
}

run_install_lefthook_capture() {
  # Args: repo_root stub_dir.
  # Captures combined stdout/stderr into INSTALL_LEFTHOOK_OUTPUT and exit code into
  # INSTALL_LEFTHOOK_RC so callers can assert without tripping set -e in the runner.
  local repo_root="$1" stub_dir="$2"
  local home_dir
  home_dir="$(dirname "$repo_root")/home"
  [[ -d "$home_dir" ]] || home_dir="$(dirname "$(dirname "$repo_root")")/home"
  INSTALL_LEFTHOOK_RC=0
  INSTALL_LEFTHOOK_OUTPUT=$(
    cd "$repo_root"
    export HOME="$home_dir"
    export XDG_CONFIG_HOME="$home_dir/.config"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export PATH="$stub_dir:$PATH"
    bash "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh" 2>&1
  ) || INSTALL_LEFTHOOK_RC=$?
}

test_install_lefthook_cleanup_local_redundant() {
  local sandbox repo_root stub_dir default_hooks
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  default_hooks=$(install_lefthook_isolated_git "$repo_root" rev-parse --path-format=absolute --git-common-dir)/hooks
  install_lefthook_isolated_git "$repo_root" config --local core.hooksPath "$default_hooks"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "expected exit 0, got $INSTALL_LEFTHOOK_RC; output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "removed redundant core.hooksPath (local)"

  local after
  after=$(install_lefthook_isolated_git "$repo_root" config --local --get core.hooksPath 2>/dev/null || echo "")
  [[ -z "$after" ]] || fail "expected local core.hooksPath to be unset, got: $after"
}

test_install_lefthook_preserves_custom_local() {
  local sandbox repo_root stub_dir custom_path after
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  custom_path="$sandbox/custom-hooks"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"
  mkdir -p "$custom_path"
  install_lefthook_isolated_git "$repo_root" config --local core.hooksPath "$custom_path"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "stub install must succeed; got rc=$INSTALL_LEFTHOOK_RC, output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "non-default core.hooksPath (local) detected: $custom_path"

  after=$(install_lefthook_isolated_git "$repo_root" config --local --get core.hooksPath)
  [[ "$after" == "$custom_path" ]] || fail "expected custom local core.hooksPath preserved, got: $after"
}

test_install_lefthook_silent_on_clean_state() {
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  # Warm-up run: ensures hook + guard are in place. May emit cleanup messages if
  # the fixture happens to start with a stale core.hooksPath; here it doesn't.
  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "warm-up failed: $INSTALL_LEFTHOOK_OUTPUT"

  # Subsequent run: nothing to clean up, lefthook stub is silent, guard re-inject is silent.
  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "silent run failed: $INSTALL_LEFTHOOK_OUTPUT"
  [[ -z "$INSTALL_LEFTHOOK_OUTPUT" ]] || fail "expected silent rerun, got: [$INSTALL_LEFTHOOK_OUTPUT]"
}

test_install_lefthook_concurrent_install_serializes() {
  # Four concurrent install invocations. The host picks flock or lockf automatically
  # (단일 host에서 한 branch만 검증된다 — 다른 branch는 cross-OS CI matrix가 맡는다).
  # 둘 다 inject_staged_guard를 직렬화해 guard markers가 interleave되지 않아야
  # 다음 호출의 `SystemExit("nested guard marker")`가 발생하지 않는다.
  #
  # marker count alone은 lock 회귀에 약한 신호다 (inject_staged_guard가 매 호출마다
  # strip+re-inject하므로 lock이 없어도 hook의 어떤 single writer가 마지막에 쓰면
  # marker는 1쌍). 강화: 4개 child의 rc를 모두 캡처해서 silent fail이 하나라도
  # 있으면 fail로 본다 — lock을 끄면 race로 한두 개 child가 nested-marker SystemExit
  # 또는 다른 path로 fail한다.
  local sandbox repo_root stub_dir hook_path begin_count end_count home_dir rc_file fail_count total
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  home_dir="$sandbox/home"
  rc_file="$sandbox/rc"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  (
    cd "$repo_root"
    export HOME="$home_dir"
    export XDG_CONFIG_HOME="$home_dir/.config"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export PATH="$stub_dir:$PATH"
    # subshell `( ... ) &`로 전체 명령 pipeline을 background 한다. `bash ...; printf ... &`
    # 형식은 `&`가 마지막 명령(`printf`)에만 적용되어 4개 bash 호출이 sequential 실행 →
    # lock contention test가 실제로 race를 trigger하지 못한다.
    for _ in 1 2 3 4; do
      (
        rc=0
        bash "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh" >/dev/null 2>&1 || rc=$?
        printf '%s\n' "$rc" >> "$rc_file"
      ) &
    done
    wait
  )

  total=$(wc -l < "$rc_file" | tr -d ' ')
  [[ "$total" == "4" ]] || fail "expected 4 child exit codes captured, got $total"
  fail_count=$(grep -cv '^0$' "$rc_file" || true)
  [[ "$fail_count" == "0" ]] || fail "expected all 4 concurrent installs to succeed; $fail_count failed (rcs: $(tr '\n' ',' < "$rc_file"))"

  hook_path="$repo_root/.git/hooks/pre-commit"
  [[ -f "$hook_path" ]] || fail "expected pre-commit hook to exist after concurrent install"
  begin_count=$(grep -Fxc "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hook_path" || true)
  end_count=$(grep -Fxc "$LEFTHOOK_GUARD_END_MARKER" "$hook_path" || true)
  [[ "$begin_count" == "1" ]] || fail "expected exactly 1 begin marker after serialized install, got $begin_count"
  [[ "$end_count" == "1" ]] || fail "expected exactly 1 end marker after serialized install, got $end_count"

  # Sanity rerun: nested-marker error would surface here if a prior race left duplicates.
  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "post-race rerun failed: $INSTALL_LEFTHOOK_OUTPUT"
}

test_install_lefthook_worktree_mode_pins_local_hooks_path() {
  # 워크트리 모드: install-lefthook-hooks.sh가 apply_worktree_local_hooks_config로
  # extensions.worktreeConfig + --worktree core.hooksPath를 설정해 PR #750 worktree-local
  # 격리를 유지한다. 다른 worktree의 lefthook install이 메인 .git/hooks를 덮어써도
  # 본 worktree는 영향 없음을 cross-check.
  local sandbox main_root worktree_root stub_dir hook_path worktree_hooks main_hooks sentinel
  sandbox=$(new_sandbox)
  main_root="$sandbox/main"
  worktree_root="$sandbox/wt"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_worktree_fixture "$main_root" "$worktree_root" "$stub_dir"

  # 메인 hooks 격리 sentinel: 미리 식별 가능한 content를 메인 .git/hooks/pre-commit에
  # 박아둔다. worktree install 후에도 sentinel content가 그대로면 메인이 영향받지
  # 않았음을 content level에서 보장한다 (fixture 우연으로 통과하는 약한 검증 회피).
  main_hooks="$main_root/.git/hooks"
  mkdir -p "$main_hooks"
  sentinel="MAIN_SENTINEL_$(date +%s)_$$"
  printf '#!/bin/sh\n# %s\nexit 0\n' "$sentinel" > "$main_hooks/pre-commit"
  chmod +x "$main_hooks/pre-commit"

  run_install_lefthook_capture "$worktree_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "worktree install failed: $INSTALL_LEFTHOOK_OUTPUT"

  # extensions.worktreeConfig + --worktree core.hooksPath이 워크트리 분기로 설정됨
  local wtc hooks_path
  wtc=$(install_lefthook_isolated_git "$worktree_root" config --get extensions.worktreeConfig)
  [[ "$wtc" == "true" ]] || fail "expected extensions.worktreeConfig=true, got: $wtc"
  hooks_path=$(install_lefthook_isolated_git "$worktree_root" config --worktree --get core.hooksPath)
  worktree_hooks=$(install_lefthook_isolated_git "$worktree_root" rev-parse --path-format=absolute --git-dir)/hooks
  [[ "$hooks_path" == "$worktree_hooks" ]] || fail "expected worktree-local core.hooksPath=$worktree_hooks, got: $hooks_path"

  # 워크트리에서 install이 worktree-local hook을 작성
  hook_path="$worktree_hooks/pre-commit"
  [[ -f "$hook_path" ]] || fail "expected worktree-local pre-commit hook at $hook_path"
  grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hook_path" || fail "expected guard begin marker in worktree-local hook"

  # 격리 검증 (content level): 메인 pre-commit의 sentinel이 그대로 보존되어야 함
  grep -Fq "$sentinel" "$main_hooks/pre-commit" || fail "main repo hooks should be isolated from worktree install; sentinel '$sentinel' missing from $main_hooks/pre-commit"
}
