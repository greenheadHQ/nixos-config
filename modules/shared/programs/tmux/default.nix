# tmux 설정
{ ... }:

let
  tmuxDir = ./files;
in
{
  programs.tmux = {
    enable = true;
    terminal = "tmux-256color";
    mouse = true;
    historyLimit = 50000;
    escapeTime = 10;
    baseIndex = 1;
    keyMode = "vi";
    focusEvents = true;

    # Home Manager가 생성하는 ~/.config/tmux/tmux.conf가 먼저 로드되므로,
    # 사용자 설정을 여기서 source해야 함
    extraConfig = ''
      source-file ~/.tmux/tmux.conf
    '';
  };

  home.file.".tmux/tmux.conf".source = "${tmuxDir}/tmux.conf";
}
