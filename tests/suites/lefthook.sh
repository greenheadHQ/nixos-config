# tests/suites/lefthook.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
# ─── install-lefthook-hooks fixture helpers ───
# 대부분의 테스트에서 실제 lefthook은 stub으로 대체한다. 우리 검증 대상은 install-lefthook-hooks.sh의
# cleanup_main_redundant_hooks_path / apply_worktree_local_hooks_config /
# acquire_install_lock / require_canonical_lefthook_config / refuse_symlinked_hooks /
# run_lefthook_install / inject_staged_guard / disable_lefthook_auto_install 동작이고,
# lefthook 자체의 install 로직은 별도 신뢰 영역이다.
# stub은 install 명령 호출 시 설정된 hook(pre-commit/commit-msg/pre-push)을 모두 생성하며,
# 각 파일은 `call_lefthook()` preamble과 `call_lefthook run "<hook>" "$@"` 호출부를 함께 포함한다
# (installer가 그 둘을 함께 요구한다 — #1073).
# 예외: test_lefthook_auto_sync_cannot_drop_guard_end_to_end는 auto-sync 동작 자체를 확인해야
# 하므로 stub 없이 실제 lefthook 바이너리를 사용한다.

# Marker 리터럴을 install-lefthook-hooks.sh에서 한 번만 정의하고 테스트가
# 그 정의를 sed로 추출해 사용한다. install 스크립트에서 marker를 바꿔도
# 테스트가 그 변경을 자동으로 따라간다 (silent fail 방지).
LEFTHOOK_GUARD_BEGIN_MARKER=$(sed -n 's/^BEGIN_MARKER="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
LEFTHOOK_GUARD_END_MARKER=$(sed -n 's/^END_MARKER="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
LEFTHOOK_NO_AUTO_INSTALL_FLAG=$(sed -n 's/^NO_AUTO_INSTALL_FLAG="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
LEFTHOOK_GIT_HOOK_NAMES=$(sed -n 's/^GIT_HOOK_NAMES="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
LEFTHOOK_GIT_HOOK_NAMES_IGNORING_EXIT_STATUS=$(sed -n 's/^GIT_HOOK_NAMES_IGNORING_EXIT_STATUS="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh")
[[ -n "$LEFTHOOK_GUARD_BEGIN_MARKER" ]] || fail "could not extract BEGIN_MARKER from install-lefthook-hooks.sh"
[[ -n "$LEFTHOOK_GUARD_END_MARKER" ]] || fail "could not extract END_MARKER from install-lefthook-hooks.sh"
[[ -n "$LEFTHOOK_NO_AUTO_INSTALL_FLAG" ]] || fail "could not extract NO_AUTO_INSTALL_FLAG from install-lefthook-hooks.sh"
[[ -n "$LEFTHOOK_GIT_HOOK_NAMES" ]] || fail "could not extract GIT_HOOK_NAMES from install-lefthook-hooks.sh"
[[ -n "$LEFTHOOK_GIT_HOOK_NAMES_IGNORING_EXIT_STATUS" ]] \
  || fail "could not extract GIT_HOOK_NAMES_IGNORING_EXIT_STATUS from install-lefthook-hooks.sh"

# fixture가 만드는 hook 형태의 유일한 소유점 (printf 포맷).
#
# installer는 `call_lefthook()` 정의와 `call_lefthook run` 호출부를 함께 요구하므로
# (hook_defines_call_lefthook, #1073), preamble이 빠진 fixture는 "깨진 hook"으로 거부된다.
# 정상 hook을 만드는 곳이 stub 둘 + 파일 밖 fixture 하나로 셋인데, 각자 형태를 들고 있으면
# 한쪽만 고쳤을 때 조용히 갈라진다. 아래 조각에서만 정의하고 나머지는 전부 파생시킨다.
#
# 실제 lefthook 산출물의 골격(shebang → 빈 줄 → ... → `call_lefthook()` 정의 → 호출부)을 따르되,
# 검사에 무관한 LEFTHOOK_VERBOSE/LEFTHOOK=0 블록은 재현하지 않는다.
#
# **불변식: 이 포맷들에는 `%s`(hook 이름) 외의 `%`를 넣지 마라.** 같은 문자열이 두 가지 방식으로
# 소비되기 때문이다 — `lefthook_hook_preamble`은 `printf '%b'`의 피연산자로(포맷 해석 없음),
# `write_lefthook_*`와 두 stub은 `printf "$FORMAT"`의 포맷으로(해석 있음) 쓴다. `%`를 하나라도
# 넣으면 `%b` 경로만 원문을 보존하고 나머지는 조용히 문자를 먹으며, 뒤따르는 `%s`가 인자를 잃어
# hook 이름까지 빈 문자열이 된다 (실측). 종료코드는 0이라 아무도 알아채지 못한다.
LEFTHOOK_STUB_HOOK_SHEBANG_FORMAT='#!/bin/sh\n'
LEFTHOOK_STUB_HOOK_PREAMBLE_FORMAT="$LEFTHOOK_STUB_HOOK_SHEBANG_FORMAT"'\ncall_lefthook()\n{\n  lefthook "$@"\n}\n\n'
# `%s`는 hook 이름.
LEFTHOOK_STUB_HOOK_CALL_FORMAT='call_lefthook run "%s" "$@"\n'
# 정상 hook = preamble + 호출부. 깨진 hook = shebang + 호출부 (preamble의 부재가 핵심).
LEFTHOOK_STUB_HOOK_FORMAT="$LEFTHOOK_STUB_HOOK_PREAMBLE_FORMAT$LEFTHOOK_STUB_HOOK_CALL_FORMAT"
LEFTHOOK_STUB_HOOK_BROKEN_FORMAT="$LEFTHOOK_STUB_HOOK_SHEBANG_FORMAT$LEFTHOOK_STUB_HOOK_CALL_FORMAT"

lefthook_config_hook_names() {
  # installer의 configured_hooks와 같은 방식으로 lefthook.yml에서 hook 이름만 뽑는다
  # (전역 옵션 키 제외). GIT_HOOK_NAMES는 installer에서 추출해 재사용한다.
  awk -v known=" $LEFTHOOK_GIT_HOOK_NAMES " '
    /^[A-Za-z0-9_.-]+:/ {
      name = $1
      sub(/:$/, "", name)
      if (index(known, " " name " ") > 0) { printf "%s%s", sep, name; sep = " " }
    }
  ' "$1"
}

extract_self_check_run_body() {
  # lefthook.yml의 <top-level hook>.commands.lefthook-guard-self-check 의 `run: |` 본문만 뽑는다.
  local top="$1"
  awk -v want="${top}:" '
    $0 == want { in_top = 1; next }
    in_top && /^[^[:space:]#]/ { exit }
    in_top && /^    lefthook-guard-self-check:$/ { in_cmd = 1; next }
    in_cmd && /^    [^[:space:]]/ { exit }
    in_cmd && /^      run: \|$/ { in_run = 1; next }
    in_run && /^      [^[:space:]]/ { exit }
    in_run { print }
  ' "$REPO_ROOT/lefthook.yml"
}

assert_hook_call_line() {
  # 설치된 hook의 lefthook 호출부가 정확히 기대 형태인지 확인한다. 완전 일치로 비교하므로
  # 플래그 누락뿐 아니라 중복 주입(비-idempotent 회귀)도 함께 잡힌다.
  local hook_path="$1" hook_name="$2" expected actual
  expected="call_lefthook run \"${hook_name}\" ${LEFTHOOK_NO_AUTO_INSTALL_FLAG} \"\$@\""
  actual=$(grep -F 'call_lefthook run ' "$hook_path" || true)
  [[ "$actual" == "$expected" ]] || fail "hook $hook_path: expected call line [$expected], got [$actual]"
}

lefthook_hook_preamble() {
  # LEFTHOOK_STUB_HOOK_PREAMBLE_FORMAT을 그대로 풀어 stdout으로 낸다. 호출부의 *형태*를 시험하는
  # fixture는 그 뒤에 자기 body를 이어 붙인다 — preamble이 없으면 "깨진 hook" 판정이 먼저 발동해
  # 엉뚱한 이유로 실패하기 때문이다 (#1073).
  # preamble 단독은 치환할 인자가 없으므로 `%b`로 백슬래시 이스케이프만 푼다 (SC2059 회피).
  # 전체 포맷 쪽은 hook 이름 `%s` 치환이 필요해 `%b`를 쓸 수 없다 — 두 경로가 갈리는 지점이며,
  # 그래서 상수에 `%`를 넣으면 안 된다 (상수 정의부의 불변식 참조).
  printf '%b' "$LEFTHOOK_STUB_HOOK_PREAMBLE_FORMAT"
}

write_lefthook_generated_hook() {
  # lefthook이 남긴 그대로의 hook: preamble + 호출부, 플래그 없음.
  # 플래그를 일부러 넣지 않는다 — 주입 대상이 되는 것이 이 헬퍼를 쓰는 테스트의 관심사다.
  # 호출처가 하나뿐이지만 write_lefthook_hook_missing_preamble과 대칭을 이뤄 "정상/깨짐" 두 형태를
  # 나란히 소유한다. 둘 중 하나만 헬퍼로 두면 다음 사람이 짝을 놓친다.
  local hook_path="$1" hook_name="$2"
  # shellcheck disable=SC2059  # 포맷은 신뢰된 상수, hook 이름이 유일한 인자다.
  printf "$LEFTHOOK_STUB_HOOK_FORMAT" "$hook_name" > "$hook_path"
  chmod +x "$hook_path"
}

write_lefthook_hook_missing_preamble() {
  # 호출부만 있고 `call_lefthook()` 정의가 없는 hook. preamble의 부재가 이 fixture의 존재 이유다
  # — installer의 사후 검증이 거부해야 하는 대상이자, `bash -n`이 문법 오류로 보지 않는다는 전제의
  # 표본이다. 호출부 형태는 위 정상 형태와 같은 상수에서 파생된다.
  # 실제 lefthook의 `.old` 백업은 rename 산물이라 실행 권한을 유지하므로 여기서도 chmod +x 한다.
  local hook_path="$1" hook_name="$2"
  # shellcheck disable=SC2059  # 포맷은 신뢰된 상수, hook 이름이 유일한 인자다.
  printf "$LEFTHOOK_STUB_HOOK_BROKEN_FORMAT" "$hook_name" > "$hook_path"
  chmod +x "$hook_path"
}

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

write_install_lefthook_fixture_config() {
  # installer는 lefthook.yml의 top-level 키에서 기대 hook 목록을 도출한다. 실제 저장소와 같은
  # 세 hook을 정의해, "설정된 hook이 전부 설치됐는가" 검증이 fixture에서도 성립하게 한다.
  cat > "$1/lefthook.yml" <<'YML'
pre-commit:
  jobs:
    - name: noop
      run: "true"
commit-msg:
  jobs:
    - name: noop
      run: "true"
pre-push:
  jobs:
    - name: noop
      run: "true"
YML
}

write_install_lefthook_stub() {
  # 두 fixture 생성기가 공유하는 lefthook stub. install 동작을 한 곳에서만 정의해
  # 호출 형태나 hook 집합을 바꿀 때 한쪽만 고치는 사고를 막는다.
  # 실제 CLI처럼 lefthook.yml에서 hook 이름을 읽되, 전역 옵션 키(`colors` 등)는 건너뛴다.
  # 생성하는 hook의 형태는 LEFTHOOK_STUB_HOOK_FORMAT이 단독으로 정한다 (preamble + 호출부).
  cat > "$1/lefthook" <<STUB
#!/usr/bin/env bash
# stub for install-lefthook-hooks shell tests: emulate \`lefthook install\` by writing every
# hook configured in lefthook.yml, each containing the \`call_lefthook()\` preamble and the
# \`call_lefthook run "<hook>" "\$@"\` marker expected by inject_staged_guard and
# disable_lefthook_auto_install. Hook names come from the config (like the real CLI) and global
# option keys are skipped, so fixtures and assertions cannot drift apart. The stub also
# tolerates --force (worktree mode passes it).
# Silent on success to mirror the real CLI output we strip.
set -euo pipefail
known=" $LEFTHOOK_GIT_HOOK_NAMES "
case "\${1:-}" in
  install)
    cd "\$(git rev-parse --show-toplevel)"
    hooks_dir="\$(git rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "\$hooks_dir"
    for hook in \$(awk -v known="\$known" '/^[A-Za-z0-9_.-]+:/ { name = \$1; sub(/:\$/, "", name); if (index(known, " " name " ") > 0) print name }' lefthook.yml); do
      printf '$LEFTHOOK_STUB_HOOK_FORMAT' "\$hook" > "\$hooks_dir/\$hook"
      chmod +x "\$hooks_dir/\$hook"
    done
    ;;
  *)
    echo "stub lefthook: unsupported command: \${1:-}" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$1/lefthook"
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
  write_install_lefthook_fixture_config "$repo_root"
  install_lefthook_isolated_git "$repo_root" add lefthook.yml
  install_lefthook_isolated_git "$repo_root" commit -m "initial" >/dev/null 2>&1

  write_install_lefthook_stub "$stub_dir"
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
  write_install_lefthook_fixture_config "$main_root"
  install_lefthook_isolated_git "$main_root" add lefthook.yml
  install_lefthook_isolated_git "$main_root" commit -m "initial" >/dev/null 2>&1
  install_lefthook_isolated_git "$main_root" worktree add -b feature "$worktree_root" >/dev/null 2>&1

  write_install_lefthook_stub "$stub_dir"
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

test_install_lefthook_injects_no_auto_install_into_every_hook() {
  # `lefthook run`의 암묵 auto-sync는 hook 하나에서 발동해도 설치된 hook을 모두 재생성하며
  # staged-config guard를 지운다. 따라서 guard가 없는 commit-msg/pre-push도 차단해야 한다.
  local sandbox repo_root stub_dir hooks_dir hook_name
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "install failed: $INSTALL_LEFTHOOK_OUTPUT"

  hooks_dir="$repo_root/.git/hooks"
  for hook_name in pre-commit commit-msg pre-push; do
    assert_hook_call_line "$hooks_dir/$hook_name" "$hook_name"
  done

  # guard 블록 자체는 pre-commit 전용 — 다른 hook으로 새지 않아야 한다.
  grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hooks_dir/pre-commit" || fail "guard marker missing from pre-commit"
  for hook_name in commit-msg pre-push; do
    ! grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hooks_dir/$hook_name" \
      || fail "guard marker unexpectedly injected into $hook_name"
  done
}

test_install_lefthook_no_auto_install_injection_is_idempotent() {
  # 매 direnv 진입마다 재실행되므로 플래그가 누적되면 안 된다. assert_hook_call_line은
  # 완전 일치 비교라 중복 주입(`--no-auto-install --no-auto-install`)을 잡는다.
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "first install failed: $INSTALL_LEFTHOOK_OUTPUT"
  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "second install failed: $INSTALL_LEFTHOOK_OUTPUT"

  assert_hook_call_line "$repo_root/.git/hooks/pre-commit" "pre-commit"
}

test_install_lefthook_patches_stale_unconfigured_hook() {
  # `lefthook install`은 설정에서 빠진 hook 파일을 지우지 않는다. 그렇게 남은 hook의
  # `call_lefthook run` 호출부에 플래그가 없으면, git이 그 hook을 실행할 때(예: pre-commit
  # 다음의 prepare-commit-msg) auto-install이 발동해 guard와 플래그를 통째로 지운다.
  # 설정에 없더라도 lefthook이 만든 hook이면 패치 대상이어야 한다.
  local sandbox repo_root stub_dir hooks_dir stale
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  # 과거 설정에 있다가 빠진 hook을 흉내낸다 (lefthook이 남긴 그대로, 플래그 없음).
  hooks_dir="$repo_root/.git/hooks"
  mkdir -p "$hooks_dir"
  stale="$hooks_dir/prepare-commit-msg"
  write_lefthook_generated_hook "$stale" "prepare-commit-msg"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "install must not fail on a stale unconfigured hook; output: $INSTALL_LEFTHOOK_OUTPUT"

  # 설정에 없어도 lefthook이 만든 hook이면 플래그가 주입되어 auto-install 우회로가 닫힌다.
  assert_hook_call_line "$stale" "prepare-commit-msg"
  assert_hook_call_line "$hooks_dir/pre-commit" "pre-commit"
}

test_install_lefthook_rejects_hook_without_call_lefthook_definition() {
  # 호출부만 있고 preamble(`call_lefthook()` 정의)이 없는 hook은 실행 즉시 exit 127로 죽어
  # 그 이벤트의 모든 커밋을 막는다. 그런데 `bash -n`은 문법만 보므로 이런 파일도 통과시킨다.
  # installer가 정의의 부재를 직접 확인하지 않으면, 깨진 hook에 플래그를 주입한 뒤 성공을
  # 보고하고 커밋 전면 차단 상태를 그대로 남긴다 (#1073에서 실제로 발생).
  #
  # 이 테스트는 동시에, installer가 실패하더라도 이미 설치된 hook의 `--no-auto-install`이
  # 살아 있음을 확인한다. 정의 검사는 python 패치 **이후**에 돈다 — 앞으로 옮기면
  # run_lefthook_install이 세 hook을 순정 템플릿으로 다시 써서 플래그를 지운 직후에 죽고,
  # commit-time self-check가 그 상태를 커밋 차단으로 판정한다.
  local sandbox repo_root stub_dir hooks_dir broken
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  # 1회차: 정상 설치로 세 hook에 플래그를 심는다.
  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "first install failed: $INSTALL_LEFTHOOK_OUTPUT"

  # `prepare-commit-msg`는 git이 exit status를 존중하는 hook이라 깨지면 커밋을 막는다.
  # 그래서 installer는 경고가 아니라 실패로 알려야 한다.
  hooks_dir="$repo_root/.git/hooks"
  broken="$hooks_dir/prepare-commit-msg"
  write_lefthook_hook_missing_preamble "$broken" "prepare-commit-msg"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" != "0" ]] \
    || fail "install must fail on a hook that calls call_lefthook without defining it; output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "no call_lefthook() definition"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "$broken"

  # 실패했어도 configured hook의 플래그는 손상되지 않아야 한다.
  local hook_name checked=0
  for hook_name in $(lefthook_config_hook_names "$repo_root/lefthook.yml"); do
    assert_hook_call_line "$hooks_dir/$hook_name" "$hook_name"
    checked=$((checked + 1))
  done
  # 3 = write_install_lefthook_fixture_config가 정의하는 hook 수 (pre-commit/commit-msg/pre-push).
  # 개수를 단언해 위 루프가 조용히 0회 도는 것을 막는다.
  [[ "$checked" -eq 3 ]] || fail "expected to check 3 configured hooks, checked $checked"
}

test_install_lefthook_warns_but_survives_a_broken_post_hook() {
  # git은 `post-*` 계열 hook의 exit status를 무시한다. 그런 hook이 깨져 exit 127로 죽어도 커밋과
  # push는 그대로 진행되므로, installer는 실패가 아니라 경고를 낸다 — 커밋을 한 건도 막지 못하는
  # 파일 하나 때문에 direnv 진입까지 막을 이유가 없다 (main도 이 경우 rc=0이었다).
  local sandbox repo_root stub_dir broken
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "first install failed: $INSTALL_LEFTHOOK_OUTPUT"

  broken="$repo_root/.git/hooks/post-commit"
  write_lefthook_hook_missing_preamble "$broken" "post-commit"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] \
    || fail "install must not fail on a broken hook whose exit status git ignores; output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "warning:"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "$broken"
}

test_install_lefthook_exit_status_ignoring_hooks_are_known_git_hooks() {
  # 경고 경로는 hook 이름을 GIT_HOOK_NAMES_IGNORING_EXIT_STATUS와 대조해 고른다. 그 목록에 git이
  # 모르는 이름이 들어가면 그 항목은 영원히 매치되지 않아 조용히 죽은 원소가 되고, 반대로 오타가
  # 나면 fail이 걸려야 할 hook이 경고로 새어 나간다. 부분집합 관계를 단언해 둘 다 막는다.
  local ignored known
  for ignored in $LEFTHOOK_GIT_HOOK_NAMES_IGNORING_EXIT_STATUS; do
    local found=0
    for known in $LEFTHOOK_GIT_HOOK_NAMES; do
      [[ "$ignored" == "$known" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] \
      || fail "GIT_HOOK_NAMES_IGNORING_EXIT_STATUS contains '$ignored', which is not a git hook name in GIT_HOOK_NAMES"
  done

  # `post-checkout`은 이름만 보면 이 집합에 속할 것 같지만, git 문서는 그 hook의 exit status가
  # `git checkout`/`git switch`의 exit status가 된다고 명시한다. 실수로 다시 들어가는 것을 막는다.
  for ignored in $LEFTHOOK_GIT_HOOK_NAMES_IGNORING_EXIT_STATUS; do
    [[ "$ignored" != "post-checkout" ]] \
      || fail "post-checkout must not be treated as exit-status-ignoring: its exit status becomes git checkout's"
  done
}

test_install_lefthook_premise_bash_n_accepts_undefined_function_call() {
  # 위 테스트들이 방어하는 전제를 못박는다: `bash -n`은 정의되지 않은 함수 호출을 문법 오류로
  # 보지 않는다. 이 전제가 성립하기 때문에 installer가 정의 존재를 따로 확인해야 한다.
  # bash가 언젠가 이것을 잡기 시작하면 이 테스트가 실패하고, 그때 별도 검사의 필요성을 재검토한다.
  # hook 이름 인자는 `bash -n` 결과에 영향이 없으므로 임의 값이어도 무방하다.
  local sandbox probe
  sandbox=$(new_sandbox)
  probe="$sandbox/probe.sh"
  write_lefthook_hook_missing_preamble "$probe" "prepare-commit-msg"

  bash -n "$probe" \
    || fail "bash -n now rejects an undefined function call; revisit hook_defines_call_lefthook"
}

test_install_lefthook_leaves_old_backup_hooks_untouched() {
  # lefthook은 밀려난 기존 hook을 `<name>.old`로 남긴다. 실행되지 않는 파일이므로
  # 패치 대상에서 제외한다 (되살렸을 때 원본 그대로여야 한다).
  # 이 fixture는 preamble이 없어도 된다 — `.old`는 패치 대상 선정에서 확장자로 걸러지므로 정의 검사에
  # 닿지 않는다. 여기서는 "손대지 않는다"만이 관심사다.
  # 헬퍼가 실행 권한을 붙이는 것도 의도다. 실제 lefthook의 `.old`는 rename 산물이라 원본 hook의
  # mode를 그대로 물려받는다.
  local sandbox repo_root stub_dir backup before after
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  mkdir -p "$repo_root/.git/hooks"
  backup="$repo_root/.git/hooks/pre-commit.old"
  write_lefthook_hook_missing_preamble "$backup" "pre-commit"
  before=$(cat "$backup")

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] || fail "install failed: $INSTALL_LEFTHOOK_OUTPUT"

  after=$(cat "$backup")
  [[ "$before" == "$after" ]] || fail "expected $backup to stay untouched; got: $after"
}

write_drifting_lefthook_stub() {
  # 정상 stub과 같은 hook 집합을 만들되, pre-commit만 body_file 내용으로 덮어써 호출부를
  # 흐트러뜨린다. 나머지 hook은 정상이라 검증이 pre-commit에서만 걸린다 — 그러려면 나머지 hook도
  # LEFTHOOK_STUB_HOOK_FORMAT의 preamble을 갖춰야 한다. 갖추지 않으면 "깨진 hook" 판정이
  # 다른 hook에서 먼저 발동해 이 fixture가 겨냥한 검증 지점에 닿지 못한다 (#1073).
  # body를 stub 소스에 리터럴로 심으면 stub 실행 시 `"$@"`/`${VAR}`가 확장돼 버리므로,
  # 파일 경로만 넘기고 그대로 복사한다.
  local stub_dir="$1" body_file="$2"
  cat > "$stub_dir/lefthook" <<STUB
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  install)
    cd "\$(git rev-parse --show-toplevel)"
    hooks_dir="\$(git rev-parse --path-format=absolute --git-path hooks)"
    mkdir -p "\$hooks_dir"
    for hook in \$(awk '/^[A-Za-z0-9_.-]+:/ { sub(/:\$/, "", \$1); print \$1 }' lefthook.yml); do
      printf '$LEFTHOOK_STUB_HOOK_FORMAT' "\$hook" > "\$hooks_dir/\$hook"
      chmod +x "\$hooks_dir/\$hook"
    done
    cp "$body_file" "\$hooks_dir/pre-commit"
    chmod +x "\$hooks_dir/pre-commit"
    ;;
  *)
    echo "stub lefthook: unsupported command: \${1:-}" >&2
    exit 1
    ;;
esac
STUB
  chmod +x "$stub_dir/lefthook"
}

test_install_lefthook_fails_when_lefthook_call_shape_changes() {
  # 상류 lefthook이 hook 템플릿의 호출부 형태를 바꾸면 플래그 주입이 조용한 no-op가 되고,
  # 다음 auto-sync가 guard를 다시 지운다. 그 실패를 install 시점으로 당겼는지 검증한다.
  #
  # 이 fixture의 hook에는 플래그와 `call_lefthook run `을 한 줄에 모두 담은 decoy 주석이 있다.
  # "파일 어딘가에 플래그가 있는가" 식의 느슨한 검사는 이 주석만으로 통과해버리므로, 검증이
  # 실행 라인 자체를 정확히 대조하는지까지 함께 못박는다.
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  # 호출부는 하나지만 `"$@"`로 끝나지 않아 주입이 no-op가 된다. decoy 주석에는 플래그만 있어
  # "파일 어딘가에 플래그가 있는가" 식의 느슨한 검사라면 통과해버린다.
  # preamble을 갖춰야 "깨진 hook" 판정이 아니라 호출부 형태 검증까지 도달한다 (#1073).
  {
    lefthook_hook_preamble
    cat <<'BODY'
# decoy: --no-auto-install appears here, but not on the call line
call_lefthook run "pre-commit" "$@" # upstream template drift
BODY
  } > "$sandbox/drift-body"
  write_drifting_lefthook_stub "$stub_dir" "$sandbox/drift-body"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" != "0" ]] || fail "expected install to fail when the lefthook call shape changes; output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "expected exact call line"
}

test_install_lefthook_fails_on_unpatched_second_call() {
  # 기대 라인 하나의 존재만 확인하면, 같은 hook에 패치되지 않은 두 번째 호출이 남아 있어도
  # 통과해 그 경로에서 auto-install이 계속 살아 있다. 호출부가 정확히 하나인지도 세는지 본다.
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  # 첫 호출은 column 0이라 패치되지만, 들여쓴 둘째 호출은 주입 대상이 아니라 그대로 남는다.
  # preamble을 갖춰야 "깨진 hook" 판정이 아니라 호출부 개수 검증까지 도달한다 (#1073).
  {
    lefthook_hook_preamble
    cat <<'BODY'
call_lefthook run "pre-commit" "$@"
if [ -n "${EXTRA:-}" ]; then
  call_lefthook run "pre-commit" "$@"
fi
BODY
  } > "$sandbox/second-call-body"
  write_drifting_lefthook_stub "$stub_dir" "$sandbox/second-call-body"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" != "0" ]] || fail "expected install to fail when a second, unpatched lefthook call remains; output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "expected exactly one 'call_lefthook run' line"
}

test_install_lefthook_rejects_foreign_lefthook_config() {
  # `lefthook install`은 LEFTHOOK_CONFIG가 가리키는 설정을 쓰는데 preflight는 저장소의
  # lefthook.yml만 읽는다. 두 경로가 갈라진 채 상태를 바꾸지 않는지 확인한다.
  local sandbox repo_root stub_dir home_dir rc out
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  home_dir="$sandbox/home"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"
  printf 'post-commit:\n  jobs:\n    - name: noop\n      run: "true"\n' > "$sandbox/other-lefthook.yml"

  rc=0
  out=$(
    cd "$repo_root"
    export HOME="$home_dir"
    export XDG_CONFIG_HOME="$home_dir/.config"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export PATH="$stub_dir:$PATH"
    export LEFTHOOK_CONFIG="$sandbox/other-lefthook.yml"
    bash "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh" 2>&1
  ) || rc=$?

  [[ "$rc" != "0" ]] || fail "expected install to fail with a foreign LEFTHOOK_CONFIG; output: $out"
  assert_contains "$out" "LEFTHOOK_CONFIG must point to"
  [[ ! -f "$repo_root/.git/hooks/pre-commit" ]] || fail "no hook should be written when LEFTHOOK_CONFIG is rejected"
}

assert_symlinked_hook_refused_before_install() {
  # symlink hook은 `lefthook install`이 링크를 따라가 외부 target을 덮어쓰기 전에 거부되어야
  # 한다. target에는 stub이 쓸 내용과 다른 sentinel을 넣어, 선행 write가 있었다면 반드시
  # 드러나게 한다 (내용이 우연히 같으면 이 검증은 아무것도 잡지 못한다).
  local sandbox="$1" repo_root="$2" stub_dir="$3" hook_name="$4"
  local hooks_dir target sentinel
  hooks_dir="$repo_root/.git/hooks"
  target="$sandbox/external-$hook_name"
  sentinel="SENTINEL_${hook_name}_must_survive"
  printf '#!/bin/sh\n# %s\nexit 0\n' "$sentinel" > "$target"
  chmod +x "$target"
  mkdir -p "$hooks_dir"
  rm -f "$hooks_dir/$hook_name"
  ln -s "$target" "$hooks_dir/$hook_name"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" != "0" ]] || fail "expected install to fail on a symlinked $hook_name; output: $INSTALL_LEFTHOOK_OUTPUT"
  assert_contains "$INSTALL_LEFTHOOK_OUTPUT" "refusing to install over a symlinked hook"
  [[ -L "$hooks_dir/$hook_name" ]] || fail "symlinked $hook_name must be left in place, not replaced"
  grep -Fq "$sentinel" "$target" || fail "external symlink target was written through before the refusal: $target"
}

test_install_lefthook_refuses_symlinked_hook() {
  # `lefthook install`은 configured hook을 제자리에 쓰므로 symlink를 만나면 링크를 따라
  # 외부 target을 덮어쓴다. install 전 preflight가 이를 막는지 확인한다.
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  assert_symlinked_hook_refused_before_install "$sandbox" "$repo_root" "$stub_dir" "pre-push"
}

test_install_lefthook_refuses_symlinked_pre_commit() {
  # pre-commit은 inject_staged_guard가 in-place로 다시 쓰는 경로이기도 하다. preflight가
  # install 전에 세우므로 guard 주입도 외부 target에 닿지 않아야 한다.
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  assert_symlinked_hook_refused_before_install "$sandbox" "$repo_root" "$stub_dir" "pre-commit"
  if grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$sandbox/external-pre-commit"; then
    fail "staged-config guard must not be injected into the external symlink target"
  fi
}

test_lefthook_self_check_hook_list_matches_config() {
  # self-check가 순회하는 hook 목록은 lefthook.yml이 정의한 hook 집합과 같아야 한다.
  # auto-install을 껐으므로 목록이 어긋나면 설치되지 않은 hook의 게이트가 조용히 사라진다.
  local from_config from_self_check
  from_config=$(lefthook_config_hook_names "$REPO_ROOT/lefthook.yml")
  from_self_check=$(extract_self_check_run_body "pre-commit" | sed -n 's/^ *for hook_name in \(.*\); do$/\1/p')

  [[ -n "$from_self_check" ]] || fail "could not extract the hook list from lefthook.yml self-check"
  [[ "$from_config" == "$from_self_check" ]] \
    || fail "hook list drift: lefthook.yml self-check iterates [$from_self_check], but lefthook.yml defines [$from_config]"
}

test_install_lefthook_ignores_global_config_keys() {
  # lefthook.yml의 top-level에는 hook 외에 전역 옵션(`colors`, `skip_output` 등)도 올 수 있다.
  # 그것을 hook 이름으로 오인하면 `.git/hooks/colors`를 찾다가 install이 막힌다.
  local sandbox repo_root stub_dir
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"

  # 기존 fixture config 앞에 전역 옵션 키를 얹는다.
  {
    printf 'colors: false\nmin_version: 2.0.0\nskip_output:\n  - meta\n'
    cat "$repo_root/lefthook.yml"
  } > "$repo_root/lefthook.yml.new"
  mv "$repo_root/lefthook.yml.new" "$repo_root/lefthook.yml"

  run_install_lefthook_capture "$repo_root" "$stub_dir"
  [[ "$INSTALL_LEFTHOOK_RC" == "0" ]] \
    || fail "global lefthook.yml keys must not be treated as hooks; output: $INSTALL_LEFTHOOK_OUTPUT"
  [[ ! -e "$repo_root/.git/hooks/colors" ]] || fail "a global config key was installed as a hook file"
  assert_hook_call_line "$repo_root/.git/hooks/pre-commit" "pre-commit"
}

test_lefthook_self_check_bodies_stay_in_sync() {
  # commit-msg의 self-check는 pre-commit 본문의 수동 복제다 (staged files가 0인 --allow-empty
  # 경로를 막기 위해 존재). 두 본문이 의도치 않게 갈라지면 한쪽 게이트만 강화되는 사고가 나므로,
  # 유일하게 허용된 차이(에러 prefix의 " (commit-msg)")만 정규화한 뒤 완전 일치를 요구한다.
  local pre_body msg_body
  pre_body=$(extract_self_check_run_body "pre-commit")
  msg_body=$(extract_self_check_run_body "commit-msg" | sed 's/lefthook-guard-self-check (commit-msg):/lefthook-guard-self-check:/')

  [[ -n "$pre_body" ]] || fail "could not extract pre-commit lefthook-guard-self-check run body"
  [[ -n "$msg_body" ]] || fail "could not extract commit-msg lefthook-guard-self-check run body"
  if [[ "$pre_body" != "$msg_body" ]]; then
    fail "lefthook.yml self-check bodies diverged (only the ' (commit-msg)' error prefix may differ):
$(diff <(printf '%s\n' "$pre_body") <(printf '%s\n' "$msg_body") || true)"
  fi
}

lefthook_make_checksum_stale() {
  # 실측(lefthook 2.1.5): auto-sync는 저장된 해시가 현재 config와 다르고 **동시에** config
  # mtime이 저장된 timestamp보다 새로울 때만 발동한다. 둘 중 하나만으로는 재설치되지 않는다.
  local repo_root="$1" checksum
  checksum="$repo_root/.git/info/lefthook.checksum"
  [[ -f "$checksum" ]] || fail "expected lefthook.checksum to exist after install: $checksum"
  printf 'deadbeefdeadbeefdeadbeefdeadbeef 1\n' > "$checksum"
  touch "$repo_root/lefthook.yml"
}

lefthook_exec_hook() {
  # 실제 hook 파일을 git이 실행하듯 돌린다. `lefthook run`을 직접 부르면 우리가 hook에 주입한
  # --no-auto-install을 우회하게 되어 검증이 성립하지 않는다.
  local repo_root="$1" hook_path="$2" home_dir
  home_dir="$(dirname "$repo_root")/home"
  (
    cd "$repo_root"
    export HOME="$home_dir"
    export XDG_CONFIG_HOME="$home_dir/.config"
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    sh "$hook_path"
  ) >/dev/null 2>&1
}

test_lefthook_auto_sync_cannot_drop_guard_end_to_end() {
  # stub이 아닌 실제 lefthook으로, checksum이 stale한 상태에서 hook을 실행해도 guard가
  # 살아남는지 확인한다. 대조군(플래그를 뗀 hook)이 실제로 guard를 잃는 것도 함께 보여,
  # 이 테스트가 "lefthook이 원래 sync를 안 해서" 통과하는 착시가 아님을 보장한다.
  # 수동 재현: `git commit` 직후 `.git/hooks/pre-commit`에서 guard 마커가 사라지는지 확인.
  local sandbox repo_root stub_dir hook_path tmp_hook
  if ! command -v lefthook >/dev/null 2>&1; then
    fail "real lefthook binary not found on PATH; this suite runs inside the nix devShell"
  fi
  sandbox=$(new_sandbox)
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stubs"
  create_install_lefthook_fixture "$repo_root" "$stub_dir"  # stub_dir는 PATH에 넣지 않는다

  lefthook_install_real() {
    (
      cd "$repo_root"
      export HOME="$sandbox/home"
      export XDG_CONFIG_HOME="$sandbox/home/.config"
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      bash "$REPO_ROOT/scripts/ai/install-lefthook-hooks.sh"
    ) >/dev/null 2>&1 || fail "real-lefthook install failed"
  }

  hook_path="$repo_root/.git/hooks/pre-commit"

  # ── 대조군: 플래그를 제거하면 auto-sync가 guard를 지운다 ──
  lefthook_install_real
  grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hook_path" || fail "guard missing right after install"
  tmp_hook="$sandbox/hook.stripped"
  sed "s| ${LEFTHOOK_NO_AUTO_INSTALL_FLAG} | |" "$hook_path" > "$tmp_hook"
  cat "$tmp_hook" > "$hook_path"
  chmod +x "$hook_path"
  lefthook_make_checksum_stale "$repo_root"
  lefthook_exec_hook "$repo_root" "$hook_path"
  if grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hook_path"; then
    fail "control group: lefthook no longer auto-syncs on a stale checksum — the --no-auto-install injection may now be unnecessary; re-verify with 'lefthook run --help'"
  fi

  # ── 실험군: 플래그가 붙은 정상 hook은 같은 조건에서 guard를 지키다 ──
  lefthook_install_real
  assert_hook_call_line "$hook_path" "pre-commit"
  lefthook_make_checksum_stale "$repo_root"
  lefthook_exec_hook "$repo_root" "$hook_path"
  grep -Fq "$LEFTHOOK_GUARD_BEGIN_MARKER" "$hook_path" \
    || fail "auto-sync dropped the staged-config guard despite $LEFTHOOK_NO_AUTO_INSTALL_FLAG"
  assert_hook_call_line "$hook_path" "pre-commit"
}
