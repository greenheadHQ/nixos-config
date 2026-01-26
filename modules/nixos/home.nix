# Home Manager 설정 (NixOS)
{
  config,
  pkgs,
  lib,
  inputs,
  username,
  hostType,
  nixosConfigPath,
  ...
}:

{
  home = {
    inherit username;
    homeDirectory = "/home/${username}";
    stateVersion = "24.11";
  };

  imports = [
    # Secrets 관리 (agenix)
    inputs.agenix.homeManagerModules.default
    ../shared/programs/secrets

    # 공유 프로그램 (공통)
    ../shared/programs/broot
    ../shared/programs/claude # Claude Code 설정
    ../shared/programs/direnv # 디렉토리별 개발 환경 자동 활성화
    ../shared/programs/git
    ../shared/programs/shell # 공통 shell 설정
    ../shared/programs/shell/nixos.nix # Linux 전용 추가
    ../shared/programs/tmux
    ../shared/programs/vim

    # NixOS 전용
    ./programs/ssh-client # macOS SSH 접속 설정
  ];

  # 패키지 (모바일 개발 최적화)
  home.packages = with pkgs; [
    # Terminfo (Ghostty SSH 접속 지원)
    ghostty

    # CLI 도구
    bat
    curl
    eza
    fd
    fzf
    ripgrep
    zoxide
    jq
    htop
    nvd

    # 개발 도구
    tmux
    lazygit
    gh
    git
    shellcheck

    # 쉘 도구
    starship
    atuin

    # 런타임 관리
    mise

    # mosh (불안정한 네트워크 대비)
    mosh
  ];

  # Claude 세션 관리 스크립트
  home.file.".local/bin/claude-session" = {
    executable = true;
    text = ''
      #!/bin/bash
      SESSION_NAME="claude"

      # 기존 세션이 있으면 연결, 없으면 생성
      tmux has-session -t $SESSION_NAME 2>/dev/null
      if [ $? != 0 ]; then
          tmux new-session -d -s $SESSION_NAME -c ~/projects
          tmux send-keys -t $SESSION_NAME "claude" Enter
      fi
      tmux attach-session -t $SESSION_NAME
    '';
  };

  programs.home-manager.enable = true;

  # SSH 에이전트 자동 시작 (GitHub SSH 작업용)
  services.ssh-agent.enable = true;

  # SSH 키 자동 로드 (로그인 시 keychain이 ssh-agent에 키 추가)
  programs.keychain = {
    enable = true;
    keys = [ "id_ed25519" ];
    enableZshIntegration = true;
  };
}
