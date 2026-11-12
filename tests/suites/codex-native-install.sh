# shellcheck shell=bash
# shellcheck disable=SC2154

_prepare_codex_native_fixture() {
  local sandbox="$1" command
  mkdir -p "$sandbox/user-root/.local/bin" "$sandbox/runtime" "$sandbox/stubs"
  ln -s "$BASH" "$sandbox/runtime/bash"
  for command in cat chmod rm; do
    ln -s "$(command -v "$command")" "$sandbox/runtime/$command"
  done
  : > "$sandbox/calls"

  # 실제 선언을 추출하되 설치 명령과 홈 디렉터리는 fixture 경계로 옮긴다.
  python3 - "$REPO_ROOT/modules/shared/programs/codex/default.nix" "$sandbox" <<'PY'
import graphlib
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1]).read_text()
sandbox = pathlib.Path(sys.argv[2])
declaration = re.search(
    r'  home\.activation\.installCodexCli =\s*lib\.hm\.dag\.entryAfter\s*\[([^]]*)\]\s*\'\'\n',
    source,
)
assert declaration is not None, "native CLI declaration boundary changed"
after = re.findall(r'"([^"\n]+)"', declaration.group(1))
body = re.split(r"\n[ \t]*'';", source[declaration.end():], maxsplit=1)[0]
# Exercise a permitted order that runs installation as early as its declared
# dependencies allow. An absent linkGeneration edge must expose the old failure.
dag = graphlib.TopologicalSorter({
    "installCodexCli": after,
    "cleanupManualNodeCodex": ["writeBoundary"],
    "linkGeneration": ["writeBoundary"],
    "writeBoundary": [],
})
dag.prepare()
ready = set(dag.get_ready())
order = []
while ready:
    node = min(ready)
    ready.remove(node)
    order.append(node)
    dag.done(node)
    ready.update(dag.get_ready())
(sandbox / "activation-order").write_text("\n".join(order) + "\n")
replacements = {
    "${pkgs.curl}/bin/curl": '"$CODEX_NATIVE_FIXTURE_DOWNLOAD"',
    "${pkgs.bash}/bin/sh": '"$CODEX_NATIVE_FIXTURE_INSTALLER"',
    "${nativeRuntimePath}": "$CODEX_NATIVE_FIXTURE_RUNTIME",
    "$HOME": "$CODEX_NATIVE_FIXTURE_HOME",
}
for original, replacement in replacements.items():
    assert original in body, "native CLI command boundary changed"
    body = body.replace(original, replacement)
body = body.replace("''${", "${")
assert "${pkgs." not in body and "${lib." not in body, "unmapped command boundary"
(sandbox / "activation.sh").write_text("#!/usr/bin/env bash\nset -eu\n" + body + "\n")
PY

  cat > "$sandbox/stubs/download" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 && "$1" == -fsSL && "$2" == https://chatgpt.com/codex/install.sh ]] || exit 97
printf 'download <-fsSL> <https://chatgpt.com/codex/install.sh>\n' >> "$CODEX_NATIVE_FIXTURE_LOG"
printf 'synthetic installer input\n'
printf 'synthetic download diagnostic\n' >&2
exit "$CODEX_NATIVE_FIXTURE_DOWNLOAD_RC"
STUB
  cat > "$sandbox/stubs/install" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 0 ]] || exit 97
[[ "$CODEX_HOME" == "$CODEX_NATIVE_FIXTURE_HOME/.codex" ]] || exit 97
[[ "$CODEX_INSTALL_DIR" == "$CODEX_NATIVE_FIXTURE_HOME/.local/bin" ]] || exit 97
[[ "$CODEX_NON_INTERACTIVE" == 1 ]] || exit 97
[[ "$PATH" == "$CODEX_INSTALL_DIR:$CODEX_NATIVE_FIXTURE_RUNTIME" ]] || exit 97
printf 'install environment validated\n' >> "$CODEX_NATIVE_FIXTURE_LOG"
cat > "$CODEX_NATIVE_FIXTURE_INPUT"
printf 'synthetic installer diagnostic\n' >&2
(( CODEX_NATIVE_FIXTURE_INSTALL_RC == 0 )) || exit "$CODEX_NATIVE_FIXTURE_INSTALL_RC"
[[ "$CODEX_NATIVE_FIXTURE_INSTALL_MODE" != no_binary ]] || exit 0
rm -f "$CODEX_INSTALL_DIR/codex"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CODEX_INSTALL_DIR/codex"
[[ "$CODEX_NATIVE_FIXTURE_INSTALL_MODE" != nonexecutable ]] || exit 0
chmod +x "$CODEX_INSTALL_DIR/codex"
STUB
  chmod +x "$sandbox/stubs/"*
}

_run_codex_native_fixture() {
  local sandbox="$1" dry_run="${2:-}"
  # 로그인 환경을 상속하지 않는다. 설치 대상과 실행 가능한 도구는 모두 격리한다.
  env -i PATH="$sandbox/runtime" DRY_RUN_CMD="$dry_run" \
    CODEX_NATIVE_FIXTURE_HOME="$sandbox/user-root" \
    CODEX_NATIVE_FIXTURE_RUNTIME="$sandbox/runtime" \
    CODEX_NATIVE_FIXTURE_DOWNLOAD="$sandbox/stubs/download" \
    CODEX_NATIVE_FIXTURE_INSTALLER="$sandbox/stubs/install" \
    CODEX_NATIVE_FIXTURE_LOG="$sandbox/calls" \
    CODEX_NATIVE_FIXTURE_INPUT="$sandbox/input" \
    CODEX_NATIVE_FIXTURE_DOWNLOAD_RC="${native_download_rc:-0}" \
    CODEX_NATIVE_FIXTURE_INSTALL_RC="${native_install_rc:-0}" \
    CODEX_NATIVE_FIXTURE_INSTALL_MODE="${native_install_mode:-executable}" \
    "$BASH" "$sandbox/activation.sh"
}

test_codex_native_install_respects_dry_run() {
  local sandbox state output
  for state in absent present; do
    sandbox=$(new_sandbox)
    _prepare_codex_native_fixture "$sandbox"
    if [[ "$state" == present ]]; then
      printf 'existing executable\n' > "$sandbox/user-root/.local/bin/codex"
      chmod +x "$sandbox/user-root/.local/bin/codex"
    fi
    output=$(_run_codex_native_fixture "$sandbox" echo)
    [[ ! -s "$sandbox/calls" && ! -e "$sandbox/input" ]] || fail 'dry-run started native installation'
    if [[ "$state" == present ]]; then
      assert_file_contains "$sandbox/user-root/.local/bin/codex" 'existing executable'
    else
      assert_contains "$output" 'Would install Codex CLI (dry-run).'
      [[ ! -e "$sandbox/user-root/.local/bin/codex" ]] || fail 'dry-run created a native binary'
    fi
  done
}

test_codex_native_install_uses_official_installer_once() {
  local sandbox output
  sandbox=$(new_sandbox)
  _prepare_codex_native_fixture "$sandbox"
  output=$(_run_codex_native_fixture "$sandbox")
  assert_contains "$output" 'Installing Codex CLI...'
  assert_not_contains "$output" synthetic
  assert_file_contains "$sandbox/input" 'synthetic installer input'
  [[ -x "$sandbox/user-root/.local/bin/codex" ]] || fail 'native installation did not complete'
  output=$(_run_codex_native_fixture "$sandbox")
  [[ -z "$output" ]] || fail 'existing installation was not skipped'
  assert_line_count "$sandbox/calls" 'download <-fsSL> <https://chatgpt.com/codex/install.sh>' 1
  assert_line_count "$sandbox/calls" 'install environment validated' 1
}

test_codex_native_install_checks_executable_completion() {
  local sandbox native_install_mode output rc
  for native_install_mode in no_binary nonexecutable; do
    sandbox=$(new_sandbox)
    _prepare_codex_native_fixture "$sandbox"
    rc=0
    output=$(_run_codex_native_fixture "$sandbox" 2>&1) || rc=$?
    [[ "$rc" == 1 ]] || fail 'incomplete native installation reported success'
    assert_contains "$output" 'Codex CLI was not installed.'
    assert_not_contains "$output" synthetic
  done
}

test_codex_native_install_propagates_failures() {
  local sandbox stage native_download_rc native_install_rc output rc
  for stage in download install; do
    sandbox=$(new_sandbox)
    _prepare_codex_native_fixture "$sandbox"
    native_download_rc=0
    native_install_rc=0
    if [[ "$stage" == download ]]; then native_download_rc=31; else native_install_rc=47; fi
    rc=0
    output=$(_run_codex_native_fixture "$sandbox" 2>&1) || rc=$?
    [[ "$rc" == 1 ]] || fail 'native installation failure was lost'
    assert_contains "$output" 'Codex CLI installation failed.'
    assert_not_contains "$output" synthetic
    assert_line_count "$sandbox/calls" 'download <-fsSL> <https://chatgpt.com/codex/install.sh>' 1
    assert_line_count "$sandbox/calls" 'install environment validated' 1
  done
}

test_codex_native_install_replaces_dangling_link() {
  local sandbox
  sandbox=$(new_sandbox)
  _prepare_codex_native_fixture "$sandbox"
  ln -s missing-native-cli "$sandbox/user-root/.local/bin/codex"
  _run_codex_native_fixture "$sandbox" >/dev/null
  [[ -x "$sandbox/user-root/.local/bin/codex" && ! -L "$sandbox/user-root/.local/bin/codex" ]] || fail 'dangling native link was not reinstalled'
  assert_line_count "$sandbox/calls" 'install environment validated' 1
}

test_codex_native_install_survives_managed_link_retirement() {
  local sandbox old_wrapper step pass
  sandbox=$(new_sandbox)
  _prepare_codex_native_fixture "$sandbox"
  old_wrapper="$sandbox/old-generation/home-manager-files/.local/bin/codex"
  mkdir -p "$(dirname "$old_wrapper")"
  printf '#!/bin/sh\nexec /nonexistent/old-cli\n' > "$old_wrapper"
  chmod +x "$old_wrapper"
  ln -s "$old_wrapper" "$sandbox/user-root/.local/bin/codex"
  [[ -x "$sandbox/user-root/.local/bin/codex" ]] || fail 'retired wrapper must initially be executable'

  for pass in first repeated; do
    while IFS= read -r step; do
      case "$step" in
        linkGeneration)
          # Model only retirement of the old managed link. A native result must
          # survive subsequent activation, just as an unmanaged file does.
          if [[ -L "$sandbox/user-root/.local/bin/codex" ]] && \
            [[ "$(readlink "$sandbox/user-root/.local/bin/codex")" == "$old_wrapper" ]]; then
            rm "$sandbox/user-root/.local/bin/codex"
          fi
          ;;
        installCodexCli) _run_codex_native_fixture "$sandbox" >/dev/null ;;
      esac
    done < "$sandbox/activation-order"
    [[ -x "$sandbox/user-root/.local/bin/codex" && ! -L "$sandbox/user-root/.local/bin/codex" ]] || \
      fail "native CLI missing after $pass managed-link retirement"
    assert_line_count "$sandbox/calls" 'install environment validated' 1
  done
}
