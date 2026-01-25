# tmux 설정
{
  config,
  pkgs,
  lib,
  ...
}:

let
  tmuxDir = ./files;
in
{
  programs.tmux = {
    enable = true;

    plugins = with pkgs.tmuxPlugins; [
      {
        plugin = resurrect;
        extraConfig = ''
          set -g @resurrect-dir '~/.local/share/tmux/resurrect'
          set -g @resurrect-capture-pane-contents 'on'

          # Pane 변수 저장/복원 hook (eval로 실행되므로 run-shell 불필요)
          set -g @resurrect-hook-post-save-all '$HOME/.tmux/scripts/save-pane-vars.sh'
          set -g @resurrect-hook-post-restore-all '$HOME/.tmux/scripts/restore-pane-vars.sh'
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
    ".tmux/scripts/pane-note.sh" = {
      source = "${tmuxDir}/scripts/pane-note.sh";
      executable = true;
    };
    ".tmux/scripts/pane-link.sh" = {
      source = "${tmuxDir}/scripts/pane-link.sh";
      executable = true;
    };
    ".tmux/scripts/pane-peek.sh" = {
      source = "${tmuxDir}/scripts/pane-peek.sh";
      executable = true;
    };
    ".tmux/scripts/prefix-help.sh" = {
      source = "${tmuxDir}/scripts/prefix-help.sh";
      executable = true;
    };
    ".tmux/scripts/pane-tag.sh" = {
      source = "${tmuxDir}/scripts/pane-tag.sh";
      executable = true;
    };
    ".tmux/scripts/pane-link-helpers.sh" = {
      source = "${tmuxDir}/scripts/pane-link-helpers.sh";
      executable = true;
    };
    ".tmux/scripts/pane-search-helpers.sh" = {
      source = "${tmuxDir}/scripts/pane-search-helpers.sh";
      executable = true;
    };
    ".tmux/scripts/pane-search.sh" = {
      source = "${tmuxDir}/scripts/pane-search.sh";
      executable = true;
    };
    ".tmux/scripts/find-unused-prefixes.sh" = {
      source = "${tmuxDir}/scripts/find-unused-prefixes.sh";
      executable = true;
    };
    ".tmux/scripts/save-pane-vars.sh" = {
      source = "${tmuxDir}/scripts/save-pane-vars.sh";
      executable = true;
    };
    ".tmux/scripts/restore-pane-vars.sh" = {
      source = "${tmuxDir}/scripts/restore-pane-vars.sh";
      executable = true;
    };
    ".tmux/scripts/smoke-test.sh" = {
      source = "${tmuxDir}/scripts/smoke-test.sh";
      executable = true;
    };
    # NOTE: ~/.tmux.conf는 더 이상 필요없음
    # programs.tmux.extraConfig에서 ~/.tmux/tmux.conf를 source하므로
    # XDG 경로(~/.config/tmux/tmux.conf)가 우선 로드됨
  };

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
