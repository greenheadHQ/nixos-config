# tmux 설정
{
  config,
  pkgs,
  lib,
  ...
}:

let
  tmuxDir = ./files;

  # home.file DRY 리팩토링: 스크립트 목록에서 자동 생성
  scriptNames = [
    "pane-note"
    "pane-link"
    "pane-helpers"
    "pane-restore"
    "prefix-help"
    "pane-tag"
    "find-unused-prefixes"
    "save-pane-vars"
    "restore-pane-vars"
    "smoke-test"
  ];
  mkScript = name: {
    name = ".tmux/scripts/${name}.sh";
    value = {
      source = "${tmuxDir}/scripts/${name}.sh";
      executable = true;
    };
  };
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

    plugins = with pkgs.tmuxPlugins; [
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-dir '~/.local/share/tmux/resurrect'
          set -g @resurrect-capture-pane-contents 'on'
          set -g @resurrect-hook-post-save-all '$HOME/.tmux/scripts/save-pane-vars.sh'
          set -g @resurrect-hook-post-restore-all '$HOME/.tmux/scripts/restore-pane-vars.sh'
        '';
      }
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-save-interval '15'
          set -g @continuum-restore 'on'
        '';
      }
      yank
      {
        plugin = tmux-thumbs;
        extraConfig = ''
          set -g @thumbs-key F
          set -g @thumbs-command 'echo -n {} | tmux load-buffer - && tmux display-message "Copied: {}"'
          set -g @thumbs-upcase-command 'echo -n {} | tmux load-buffer - && tmux display-message "Copied (upper): {}"'
        '';
      }
    ];

    # Home Manager가 생성하는 ~/.config/tmux/tmux.conf가 먼저 로드되므로,
    # 사용자 설정을 여기서 source해야 함
    extraConfig = ''
      source-file ~/.tmux/tmux.conf
    '';
  };

  # ~/.tmux/ 디렉토리 전체를 심볼릭 링크로 관리
  home.file = {
    ".tmux/tmux.conf".source = "${tmuxDir}/tmux.conf";
  }
  // builtins.listToAttrs (map mkScript scriptNames);

  # yq 의존성 (YAML frontmatter 파싱용)
  home.packages = with pkgs; [
    yq-go # mikefarah/yq
  ];

  # pane-notes 및 resurrect 디렉토리 생성
  home.activation.createTmuxDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    mkdir -p $HOME/.tmux/pane-notes
    mkdir -p $HOME/.tmux/pane-notes/_archive
    mkdir -p $HOME/.tmux/pane-notes/_trash
    mkdir -p $HOME/.local/share/tmux/resurrect
  '';
}
