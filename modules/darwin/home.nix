# Home Manager 설정 (macOS)
{
  config,
  pkgs,
  lib,
  inputs,
  username,
  nixosConfigPath,
  hostType,
  constants,
  ...
}:

{
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";

  # Home Manager 모듈에 nixosConfigPath, hostType, constants 전달
  home-manager.extraSpecialArgs = { inherit nixosConfigPath hostType constants; };

  home-manager.users.${username} =
    {
      config,
      pkgs,
      lib,
      ...
    }:
    let
      packages = import ../../libraries/packages.nix { inherit pkgs; };
    in
    {
      home.username = username;
      # mkForce: nix-darwin에서 users.users.${name}.home이 null이므로 강제 설정 필요
      home.homeDirectory = lib.mkForce "/Users/${username}";

      # 프로그램별 모듈 임포트
      imports = [
        # Secrets 관리 (agenix)
        inputs.agenix.homeManagerModules.default
        ../shared/programs/secrets

        # 공유 프로그램
        ../shared/programs/broot
        ../shared/programs/agent-browser
        ../shared/programs/claude # shared로 이동됨
        ../shared/programs/codex # Codex CLI 호환 레이어
        ../shared/programs/direnv # 디렉토리별 개발 환경 자동 활성화
        ../shared/programs/git
        ../shared/programs/lazygit
        ../shared/programs/shell # 공통 shell 설정
        ../shared/programs/shell/darwin.nix # macOS 전용 shell 추가
        ../shared/programs/tmux
        ../shared/programs/neovim

        # macOS 전용
        ./programs/atuin
        ./programs/hammerspoon
        ./programs/cursor
        ./programs/folder-actions
        ./programs/ghostty
        ./programs/shottr
        ./programs/keybindings
        ./programs/ssh
      ];

      # CLI 도구 패키지 (libraries/packages.nix에서 공통 관리)
      home.packages = packages.shared ++ packages.darwinOnly;

      home.stateVersion = "25.05";
    };
}
