# Hammerspoon 설정 (macOS 키보드/자동화)
{ ... }:

let
  hammerspoonDir = ./files;
  constants = import ../../../../libraries/constants.nix;
in
{
  # ~/.hammerspoon/ 디렉토리 관리
  home.file = {
    ".hammerspoon/init.lua".source = "${hammerspoonDir}/init.lua";
    ".hammerspoon/foundation_remapping.lua".source = "${hammerspoonDir}/foundation_remapping.lua";
    ".hammerspoon/anki_card_links.lua".text =
      builtins.replaceStrings
        [ "@ANKI_CONNECT_URL@" ]
        [ "http://127.0.0.1:${toString constants.ankiDesktop.ankiConnectPort}" ]
        (builtins.readFile ./files/anki_card_links.lua);
  };
}
