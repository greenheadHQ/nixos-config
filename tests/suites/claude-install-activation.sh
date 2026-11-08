# tests/suites/claude-install-activation.sh — Claude 설치 activation의 dry-run 계약
# shellcheck shell=bash
# shellcheck disable=SC2154

_prepare_claude_install_fixture() {
  local sandbox="$1"
  mkdir -p "$sandbox/home/.local/bin" "$sandbox/bin"

  # 선언의 실제 본문을 실행하되 다운로드·설치 명령만 대역으로 치환한다.
  # 설치 URL에 접속하거나 사용자 홈의 설치 파일을 읽지 않는다.
  python3 - "$REPO_ROOT/modules/shared/programs/claude/default.nix" "$sandbox/activation.sh" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
marker = '  home.activation.installClaudeCode = lib.hm.dag.entryAfter [ "writeBoundary" ] \'\'\n'
assert source.count(marker) == 1, "Claude 설치 activation 선언을 찾을 수 없음"
body = source.split(marker, 1)[1].split("\n  '';", 1)[0]
replacements = {
    "${pkgs.curl}/bin/curl": '"$CLAUDE_FIXTURE_CURL"',
    "${pkgs.bash}/bin/bash": '"$CLAUDE_FIXTURE_INSTALLER"',
}
for original, replacement in replacements.items():
    assert original in body, f"설치 명령 경계 변경: {original}"
    body = body.replace(original, replacement)
body = body.replace("''${", "${")
assert "${pkgs." not in body, "대역으로 치환되지 않은 실행 경로"
pathlib.Path(sys.argv[2]).write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
PY

  cat > "$sandbox/bin/download" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'download\n' >> "$CLAUDE_FIXTURE_LOG"
printf 'synthetic installer input\n'
exit "${CLAUDE_FIXTURE_DOWNLOAD_RC:-0}"
EOF
  cat > "$sandbox/bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'install\n' >> "$CLAUDE_FIXTURE_LOG"
cat > "$CLAUDE_FIXTURE_INPUT"
if [[ "${CLAUDE_FIXTURE_INSTALL_RC:-0}" -ne 0 ]]; then
  exit "$CLAUDE_FIXTURE_INSTALL_RC"
fi
printf 'synthetic installed binary\n' > "$HOME/.local/bin/claude"
EOF
  chmod +x "$sandbox/bin/download" "$sandbox/bin/install"
}

_run_claude_install_fixture() {
  local sandbox="$1" mode="$2" download_rc="${3:-0}" install_rc="${4:-0}"
  HOME="$sandbox/home" \
  DRY_RUN_CMD="$mode" \
  CLAUDE_FIXTURE_CURL="$sandbox/bin/download" \
  CLAUDE_FIXTURE_INSTALLER="$sandbox/bin/install" \
  CLAUDE_FIXTURE_LOG="$sandbox/calls.log" \
  CLAUDE_FIXTURE_INPUT="$sandbox/input.txt" \
  CLAUDE_FIXTURE_DOWNLOAD_RC="$download_rc" \
  CLAUDE_FIXTURE_INSTALL_RC="$install_rc" \
  bash "$sandbox/activation.sh"
}

test_claude_install_activation_respects_dry_run() {
  local sandbox installed mode output
  for installed in absent present; do
    for mode in '' echo; do
      sandbox=$(new_sandbox)
      _prepare_claude_install_fixture "$sandbox"
      if [[ "$installed" == present ]]; then
        printf 'existing binary\n' > "$sandbox/home/.local/bin/claude"
      fi

      output=$(_run_claude_install_fixture "$sandbox" "$mode")

      if [[ "$installed" == absent && -z "$mode" ]]; then
        assert_line_count "$sandbox/calls.log" download 1
        assert_line_count "$sandbox/calls.log" install 1
        assert_file_contains "$sandbox/input.txt" 'synthetic installer input'
        assert_file_contains "$sandbox/home/.local/bin/claude" 'synthetic installed binary'
      else
        [[ ! -e "$sandbox/calls.log" ]] || fail "미리보기 또는 기존 설치에서 명령이 실행됨"
        [[ ! -e "$sandbox/input.txt" ]] || fail "설치 입력 파일이 생성됨"
        if [[ "$installed" == present ]]; then
          assert_file_contains "$sandbox/home/.local/bin/claude" 'existing binary'
        else
          [[ ! -e "$sandbox/home/.local/bin/claude" ]] || fail "미리보기에서 설치 파일이 생성됨"
          assert_contains "$output" 'Would install Claude Code binary'
        fi
      fi
    done
  done
}

test_claude_install_activation_propagates_failures() {
  local sandbox source rc download_rc install_rc
  for source in download install; do
    sandbox=$(new_sandbox)
    _prepare_claude_install_fixture "$sandbox"
    download_rc=0
    install_rc=0
    if [[ "$source" == download ]]; then download_rc=31; else install_rc=47; fi
    rc=0
    _run_claude_install_fixture "$sandbox" '' "$download_rc" "$install_rc" > "$sandbox/output.log" 2>&1 || rc=$?
    [[ "$rc" -eq $((download_rc + install_rc)) ]] || fail "설치 파이프라인의 실패 코드가 전달되지 않음"
    assert_line_count "$sandbox/calls.log" download 1
    assert_line_count "$sandbox/calls.log" install 1
  done
}
