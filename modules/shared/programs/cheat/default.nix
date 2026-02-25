# cheat CLI 설정 — 터미널 cheatsheet 즉시 조회
# 사용법: cheat nvim/surround, cheat -l -t neovim, cheat -s ciw
{
  config,
  pkgs,
  nixosConfigPath,
  ...
}:

let
  cheatsheetsPath = "${nixosConfigPath}/modules/shared/programs/cheat/cheatsheets";
in
{
  home.packages = [ pkgs.cheat ];

  # cheat-browse: cheat + fzf 브라우저 (tmux/nvim/터미널 공용)
  home.file.".local/bin/cheat-browse" = {
    source = ./files/scripts/cheat-browse.sh;
    executable = true;
  };

  xdg.configFile."cheat/conf.yml".text = ''
    editor: nvim
    colorize: true
    style: monokai
    formatter: terminal256
    pager: less -FRX
    cheatpaths:
      - name: personal
        path: ${cheatsheetsPath}
        tags: [ personal ]
        readonly: false
  '';
}
