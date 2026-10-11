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
    # AppData TCC prompt가 activation을 무기한 붙잡지 않도록 실제 파일 접근을 제한한다.
    exec ${pkgs.coreutils}/bin/timeout --kill-after=2s 10s \
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
      echo "Warning: 1Password shortcuts were not applied. Resolve app-data access, quit 1Password, and run onepassword-shortcuts again." >&2
    fi
  '';
}
