# Home Manager 설정 (macOS)
{
  config,
  pkgs,
  lib,
  inputs,
  username,
  nixosConfigPath,
  hostType,
  ...
}:

{
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "backup";

  # Home Manager 모듈에 nixosConfigPath, hostType 전달
  home-manager.extraSpecialArgs = { inherit nixosConfigPath hostType; };

  home-manager.users.${username} =
    {
      config,
      pkgs,
      lib,
      ...
    }:
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
        ../shared/programs/claude # shared로 이동됨
        ../shared/programs/direnv # 디렉토리별 개발 환경 자동 활성화
        ../shared/programs/ghostty
        ../shared/programs/git
        ../shared/programs/shell # 공통 shell 설정
        ../shared/programs/shell/darwin.nix # macOS 전용 shell 추가
        ../shared/programs/tmux
        ../shared/programs/vim

        # macOS 전용
        ./programs/atuin
        ./programs/hammerspoon
        ./programs/cursor
        ./programs/folder-actions
        ./programs/keybindings
        ./programs/ssh
      ];

      # CLI 도구 패키지
      home.packages = with pkgs; [
        # 파일/검색 도구
        bat
        broot
        eza
        fd
        fzf
        ripgrep
        zoxide

        # 개발 도구
        tmux
        lazygit
        gh
        git
        shellcheck

        # 쉘 도구
        starship
        atuin

        # 미디어 처리
        ffmpeg
        imagemagick
        rar

        # 기타 유틸리티
        curl
        unzip
        jq
        htop

        # Nix 도구
        nvd # 시스템 변경사항 미리보기: nrp (preview), nrh (history)
      ];

      home.stateVersion = "25.05";
    };
}
