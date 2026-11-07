{
  inputs,
  pkgs,
  lib,
  hostType,
  constants,
  ...
}:
let
  # 앱에 포함된 CLI를 사용해 앱 업데이트 후 별도 CLI가 뒤처지지 않게 한다.
  # terminfo와 SSH guard는 공식 패키지에서 가져와 upstream HM 모듈이 관리한다.
  rexPackage = inputs.rex.packages.${pkgs.stdenv.hostPlatform.system}.rex;
  appCli = "${constants.rex.macAppPath}/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex";
  appPackage =
    (pkgs.writeShellScriptBin "rex" ''
      if [ ! -x ${lib.escapeShellArg appCli} ]; then
        echo "Rex Beta 앱을 ${constants.rex.macAppPath}에 먼저 설치하세요." >&2
        exit 127
      fi
      exec ${lib.escapeShellArg appCli} "$@"
    '').overrideAttrs
      (old: {
        buildCommand = old.buildCommand + ''
          ln -s ${rexPackage}/share "$out/share"
        '';
      });
in
{
  imports = [ inputs.rex.homeManagerModules.default ];

  programs.rex = lib.mkIf (hostType == "personal") {
    enable = true;
    package = appPackage;
    config = ''
      -- Ghostty의 익숙한 분할 키를 Rex에서도 사용한다.
      rex.bind("cmd+d", "pane.split", { direction = "right" })
      rex.bind("cmd+shift+d", "pane.split", { direction = "down" })

      rex.host {
        label = "MiniPC",
        endpoint = "https://${constants.rex.minipcTailnetFqdn}",
      }
    '';
  };
}
