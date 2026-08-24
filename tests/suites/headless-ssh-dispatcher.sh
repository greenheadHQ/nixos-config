# tests/suites/headless-ssh-dispatcher.sh — hermetic headless SSH dispatcher groups
# shellcheck shell=bash

_run_headless_ssh_dispatcher_group() {
  local group="$1"
  python3 "$REPO_ROOT/tests/headless-ssh-dispatcher-tests.py" "$group"
}

test_headless_ssh_dispatcher_group_coverage() {
  python3 - "$REPO_ROOT/tests/headless-ssh-dispatcher-tests.py" <<'PY'
import ast
import pathlib
import sys

tree = ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
actual = sorted(
    node.name
    for node in tree.body
    if isinstance(node, ast.ClassDef)
    and any(isinstance(base, ast.Name) and base.id == "DispatcherFixture" for base in node.bases)
)
expected = sorted("CoreContractTests ScopeTests LifecycleTests DependencyTests".split())
if actual != expected:
    raise SystemExit(f"dispatcher suite class coverage drift: actual={actual} expected={expected}")
PY
}

test_headless_ssh_dispatcher_core_contract() {
  _run_headless_ssh_dispatcher_group CoreContractTests
}

test_headless_ssh_dispatcher_scope_parser() {
  _run_headless_ssh_dispatcher_group ScopeTests
}

test_headless_ssh_dispatcher_supervisor() {
  _run_headless_ssh_dispatcher_group LifecycleTests
}

test_headless_ssh_dispatcher_identity_compat() {
  _run_headless_ssh_dispatcher_group DependencyTests
}

test_claude_owner_shell_finalizes_dispatcher_path() {
  local sandbox personal_env personal_init work_env finalizer
  local stable_bin fixture_env fixture_finalizer zsh_bin
  local raw_bin dispatcher_bin competitor_bin tools_bin initial_path owner_shell_path actual
  sandbox="$(new_sandbox)"
  raw_bin="$sandbox/raw/bin"
  dispatcher_bin="$sandbox/dispatcher/bin"
  competitor_bin="$sandbox/competitor/bin"
  tools_bin="$sandbox/tools/bin"
  zsh_bin="$(command -v zsh)"
  mkdir -p "$raw_bin" "$dispatcher_bin" "$competitor_bin" "$tools_bin" "$sandbox/home"

  # snapshot 생성기 셸이 CLAUDECODE=1 login shell로 rc를 명시 source한다 (Claude
  # tool 셸 자신은 비대화형이라 rc 미평가 — 2026-08-24 실측). Home Manager 산출물
  # 두 벌을 평가해 production 순서 그대로 production 셸 파서에서 재생한다.
  # 주의(2026-08-24 실측): vendor snapshot의 `export PATH=`는 zsh 평가 결과가 아니라
  # claude process.env.PATH의 리터럴 기록이다. 여기서 검증하는 rc 평가 PATH가
  # snapshot에 캡처된다고 가정하지 않는다 — snapshot 계층의 PATH 방어는
  # test_claude_stale_snapshot_path_recovery(멱등 append)가 검증한다.
  personal_env="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"greenhead-MacBookPro\".config.home-manager.users.greenhead.programs.zsh.envExtra"
  )"
  personal_init="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"greenhead-MacBookPro\".config.home-manager.users.greenhead.programs.zsh.initContent"
  )"
  work_env="$(
    nix eval --raw \
      "$REPO_ROOT#darwinConfigurations.\"work-MacBookPro\".config.home-manager.users.glen.programs.zsh.envExtra"
  )"
  finalizer="$(
    awk '
      /BEGIN nixos-config headless SSH snapshot PATH finalizer/ { emit = 1 }
      emit { print }
      /END nixos-config headless SSH snapshot PATH finalizer/ { exit }
    ' <<<"$personal_init"
  )"
  stable_bin="$(
    sed -n 's@.*path=("\([^"]*/headless-ssh/bin\)".*@\1@p' <<<"$personal_env" | head -1
  )"
  [[ -n "$stable_bin" ]] || fail "personal envExtra did not expose the stable headless SSH path"
  [[ -n "$finalizer" ]] || fail "personal initContent did not expose the snapshot PATH finalizer"
  [[ "$work_env" != *"$stable_bin"* ]] || fail "work host unexpectedly exposed the headless SSH path"

  # Replace only the evaluated deployment path. Predicates, zsh path-array
  # behavior, and finalizer control flow remain exactly as rendered.
  fixture_env="${personal_env//"$stable_bin"/"$dispatcher_bin"}"
  fixture_finalizer="${finalizer//"$stable_bin"/"$dispatcher_bin"}"
  initial_path="$raw_bin:$tools_bin:/usr/bin:/bin"
  printf '#!/bin/sh\nprintf "raw\\n"\n' > "$raw_bin/ssh"
  printf '#!/bin/sh\nprintf "headless\\n"\n' > "$dispatcher_bin/ssh"
  printf '#!/bin/sh\nprintf "competitor\\n"\n' > "$competitor_bin/ssh"
  # Keep timeout explicit so the fixture varies only the child ssh lookup.
  printf '#!/bin/sh\nexec "$@"\n' > "$tools_bin/timeout"
  chmod +x \
    "$raw_bin/ssh" "$dispatcher_bin/ssh" "$competitor_bin/ssh" \
    "$tools_bin/timeout"

  mkdir -p "$sandbox/owner-zdot" "$sandbox/tool-zdot" "$sandbox/work-zdot"
  printf 'export PATH="%s"\n%s\n' "$initial_path" "$fixture_env" > "$sandbox/owner-zdot/.zshenv"
  printf 'export PATH="%s:$PATH"\n%s\n' \
    "$competitor_bin" "$fixture_finalizer" > "$sandbox/owner-zdot/.zshrc"
  printf 'export PATH="%s"\n%s\n' "$initial_path" "$fixture_env" > "$sandbox/tool-zdot/.zshenv"
  printf 'export PATH="%s"\n%s\n' "$initial_path" "$work_env" > "$sandbox/work-zdot/.zshenv"

  owner_shell_path="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/owner-zdot" \
      PATH="$initial_path" CLAUDECODE=1 \
      "$zsh_bin" -d -c -l 'source "$ZDOTDIR/.zshrc" < /dev/null; print -r -- "$PATH"'
  )"
  [[ "$owner_shell_path" == "$dispatcher_bin:"* ]] \
    || fail "owner shell rc did not finalize dispatcher PATH: $owner_shell_path"
  [[ "$owner_shell_path" == *":$competitor_bin:"* ]] \
    || fail "owner shell fixture did not retain the competing PATH entry"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/tool-zdot" PATH="$initial_path" \
      NIXOS_CONFIG_HEADLESS_SSH=1 TIMEOUT_BIN="$tools_bin/timeout" \
      "$zsh_bin" -d -c '"$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "headless" ]] || fail "launcher marker did not resolve dispatcher SSH: $actual"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/tool-zdot" PATH="$initial_path" \
      TIMEOUT_BIN="$tools_bin/timeout" "$zsh_bin" -d -c '"$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "raw" ]] || fail "ordinary shell no longer resolves raw SSH: $actual"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/work-zdot" PATH="$initial_path" \
      CLAUDECODE=1 TIMEOUT_BIN="$tools_bin/timeout" "$zsh_bin" -d -c '"$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "raw" ]] || fail "work-host Claude shell no longer resolves raw SSH: $actual"
}

# vendor snapshot은 zsh 평가 PATH가 아니라 claude process.env.PATH를 리터럴 기록하므로
# 터미널 기원 snapshot은 생성 시점에 dispatcher가 없다 — "stale"만이 아니라 신규
# 생성분도 같다 (claude-rc 계열 기원만 launcher env 상속으로 예외). 이 멱등 append
# recovery가 그 층 PATH 방어의 실효 경로이며, activation(nrs 시점)과 launchd
# WatchPaths agent(상시) 두 곳에 배선된다 (darwin.nix).
# 함수명의 "stale"은 이력 연속성을 위해 유지한다 — 개명한 형제 테스트와 달리
# 이름이 거짓(검증하지 않는 동작 서술)이 아니라 과소포괄일 뿐이다.
test_claude_stale_snapshot_path_recovery() {
  local sandbox snapshot_dir stale_snapshot dispatcher_bin raw_bin tools_bin initial_path zsh_bin actual
  local recovery="$REPO_ROOT/modules/shared/programs/shell/files/refresh-claude-snapshot-paths.sh"
  sandbox="$(new_sandbox)"
  snapshot_dir="$sandbox/shell-snapshots"
  stale_snapshot="$snapshot_dir/snapshot-zsh-stale.sh"
  dispatcher_bin="$sandbox/dispatcher/bin"
  raw_bin="$sandbox/raw/bin"
  tools_bin="$sandbox/tools/bin"
  initial_path="$raw_bin:$tools_bin:/usr/bin:/bin"
  zsh_bin="$(command -v zsh)"
  mkdir -p "$snapshot_dir" "$dispatcher_bin" "$raw_bin" "$tools_bin" "$sandbox/home" "$sandbox/zdot"

  printf '#!/bin/sh\nprintf "raw\\n"\n' > "$raw_bin/ssh"
  printf '#!/bin/sh\nprintf "headless\\n"\n' > "$dispatcher_bin/ssh"
  printf '#!/bin/sh\nexec "$@"\n' > "$tools_bin/timeout"
  chmod +x "$raw_bin/ssh" "$dispatcher_bin/ssh" "$tools_bin/timeout"
  printf 'export PATH="%s"\n' "$initial_path" > "$stale_snapshot"
  printf 'sentinel\n' > "$sandbox/symlink-target"
  ln -s "$sandbox/symlink-target" "$snapshot_dir/snapshot-zsh-symlink.sh"

  bash "$recovery" "$snapshot_dir" "$dispatcher_bin"
  bash "$recovery" "$snapshot_dir" "$dispatcher_bin"

  [[ "$(grep -Fc '# nixos-config headless SSH PATH recovery v1' "$stale_snapshot")" == "1" ]] \
    || fail "stale snapshot recovery was not idempotent"
  [[ "$(cat "$sandbox/symlink-target")" == "sentinel" ]] \
    || fail "snapshot recovery followed a symlink"

  actual="$(
    env -i HOME="$sandbox/home" ZDOTDIR="$sandbox/zdot" PATH="$initial_path" \
      CLAUDE_CODE_SESSION_KIND=bg SNAPSHOT_FILE="$stale_snapshot" \
      TIMEOUT_BIN="$tools_bin/timeout" \
      "$zsh_bin" -d -c 'source "$SNAPSHOT_FILE"; "$TIMEOUT_BIN" ssh'
  )"
  [[ "$actual" == "headless" ]] \
    || fail "unrepaired snapshot still resolved raw SSH: $actual"
}
