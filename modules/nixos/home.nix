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

let
  packages = import ../../libraries/packages.nix { inherit pkgs; };
in
{
  home = {
    inherit username;
    homeDirectory = "/home/${username}";
    stateVersion = "24.11"; # 최초 설치 시점 기준, 특별한 마이그레이션 없으면 변경 금지
  };

  imports = [
    # Secrets 관리 (agenix)
    inputs.agenix.homeManagerModules.default
    ../shared/programs/secrets

    # 공유 프로그램 (공통)
    ../shared/programs/broot
    ../shared/programs/agent-browser
    ../shared/programs/claude # Claude Code 설정
    ../shared/programs/codex # Codex CLI 호환 레이어
    ../shared/programs/direnv # 디렉토리별 개발 환경 자동 활성화
    ../shared/programs/git
    ../shared/programs/lazygit
    ../shared/programs/shell # 공통 shell 설정
    ../shared/programs/shell/nixos.nix # Linux 전용 추가
    ../shared/programs/tmux
    ../shared/programs/neovim

    # NixOS 전용
    ./programs/ssh-client # macOS SSH 접속 설정
  ];

  # 패키지 (libraries/packages.nix에서 공통 관리)
  home.packages = packages.shared ++ packages.nixosOnly;

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
