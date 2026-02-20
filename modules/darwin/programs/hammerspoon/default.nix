# Hammerspoon 설정 (macOS 키보드/자동화)
{
  config,
  pkgs,
  lib,
  ...
}:

let
  hammerspoonDir = ./files;
in
{
  # ~/.hammerspoon/ 디렉토리 관리
  home.file = {
    ".hammerspoon/init.lua".source = "${hammerspoonDir}/init.lua";
    ".hammerspoon/foundation_remapping.lua".source = "${hammerspoonDir}/foundation_remapping.lua";
    ".hammerspoon/atuin_menubar.lua".source = "${hammerspoonDir}/atuin_menubar.lua";
  };
}
