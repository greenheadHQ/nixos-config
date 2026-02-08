# NixOS 시스템 설정
{
  config,
  pkgs,
  lib,
  inputs,
  username,
  hostname,
  ...
}:

{
  # 시스템 기본
  system.stateVersion = "24.11";

  # 부트로더
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # 호스트명
  networking.hostName = hostname;
  networking.networkmanager.enable = true;

  # 시간대
  time.timeZone = "Asia/Seoul";

  # 로케일 (영어)
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix 설정
  nix = {
    settings = {
      experimental-features = [
        "nix-command"
        "flakes"
      ];
      auto-optimise-store = true;
      trusted-users = [
        "root"
        username
      ];
    };
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # 사용자
  users.users.${username} = {
    isNormalUser = true;
    description = "YOON NOKDOO";
    extraGroups = [
      "wheel"
      "networkmanager"
    ];
    shell = pkgs.zsh;
    # SSH 키는 hosts/greenhead-minipc/default.nix에서 설정
  };

  # 기본 패키지
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    htop
    nvd
  ];

  # Zsh 활성화
  programs.zsh.enable = true;

  # wheel 그룹 sudo 비밀번호 생략 (SSH 키 인증 + Tailscale 보안)
  security.sudo.wheelNeedsPassword = false;

  # 동적 링크 바이너리 지원 (Claude Code 등)
  programs.nix-ld.enable = true;

  # 프로그램 모듈 임포트
  imports = [
    ./programs/tailscale.nix
    ./programs/ssh.nix
    ./programs/mosh.nix
    ./programs/fail2ban.nix
    ./options/homeserver.nix # Docker/Podman 기반 홈서버 서비스 (mkOption)
  ];

  # 홈서버 서비스 활성화 (mkEnableOption 기본값 false)
  homeserver.immich.enable = true;
  homeserver.uptimeKuma.enable = true;
  homeserver.immichCleanup.enable = true; # Claude Code Temp 앨범 매일 전체 삭제
  homeserver.immichUpdate.enable = true; # Immich 버전 체크 + 업데이트 알림
  homeserver.uptimeKumaUpdate.enable = true; # Uptime Kuma 버전 체크 + 업데이트 알림
  homeserver.copypartyUpdate.enable = true; # Copyparty 버전 체크 + 업데이트 알림
  homeserver.ankiSync.enable = true; # Anki 자체 호스팅 동기화 서버
  homeserver.copyparty.enable = true; # 셀프호스팅 파일 서버
  homeserver.reverseProxy.enable = true; # Caddy HTTPS 리버스 프록시
}
