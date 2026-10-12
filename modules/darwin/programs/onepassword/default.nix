# 개인/업무 Mac 공통. 앱 설치 정책(personal-only Homebrew)은 바꾸지 않는다.
# 1Password는 단축키의 settings.json 직접 수정을 허용한다:
# https://support.1password.com/settings-security/
# 전체 파일을 Nix store/symlink로 관리하면 앱의 mutable 설정과 보안 서명을 잃는다.
{
  config,
  lib,
  pkgs,
  constants,
  ...
}:
let
  settingsPath = "${config.home.homeDirectory}/${constants.onePassword.settingsMacRelPath}";
  shortcuts = constants.onePassword.shortcuts;
  applyShortcuts = pkgs.writeShellScriptBin "onepassword-shortcuts" ''
    ${builtins.readFile ./shortcuts-wrapper.sh}
    # deadline과 timeout 안내는 shortcuts-wrapper.sh가 소유한다 (tests/suites/onepassword-shortcuts.sh).
    onepassword_shortcuts_run ${pkgs.coreutils}/bin/timeout \
      ${pkgs.python3}/bin/python3 ${./apply-shortcuts.py} \
      ${lib.escapeShellArgs [
        settingsPath
        shortcuts.quickAccess
        shortcuts.autoFill
      ]}
  '';
in
{
  home.packages = [ applyShortcuts ];
  home.activation.applyOnePasswordShortcuts = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    if ! run ${lib.getExe applyShortcuts}; then
      echo "Warning: 1Password shortcuts were not applied; the helper message above names the cause and the next step." >&2
    fi
  '';
}
