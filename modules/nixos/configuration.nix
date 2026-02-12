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
      trusted-users = [
        "root"
        username
      ];
    };
    # 스토어 최적화 (하드링크로 중복 파일 제거)
    optimise.automatic = true;
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
  };

  # agenix 시스템 레벨 복호화 키 (서비스 모듈 enable 여부와 무관하게 유지)
  age.identityPaths = [ "/home/${username}/.ssh/id_ed25519" ];

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

  # 로그 용량 제한 (컨테이너 포함 전체 시스템 로그)
  services.journald.extraConfig = ''
    SystemMaxUse=2G
    MaxRetentionSec=30day
  '';

  # wheel 그룹 sudo 비밀번호 생략 (SSH 키 인증 + Tailscale 보안)
  security.sudo.wheelNeedsPassword = false;

  # 동적 링크 바이너리 지원 (Claude Code 등)
  programs.nix-ld.enable = true;
  # Playwright Chromium 런타임 의존성 (agent-browser)
  # install.rs의 apt 패키지 목록에서 매핑
  programs.nix-ld.libraries = with pkgs; [
    # 핵심 라이브러리
    nss
    nspr
    atk
    cups
    dbus
    libdrm
    libgbm
    mesa
    pango
    cairo
    expat
    at-spi2-core
    alsa-lib
    glib
    gtk3
    gdk-pixbuf
    freetype
    fontconfig
    # X11 라이브러리
    libx11
    libxcomposite
    libxdamage
    libxext
    libxfixes
    libxrandr
    libxcursor
    libxi
    libxrender
    libxcb
    libxshmfence
    # 기타
    libxkbcommon
  ];

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
  homeserver.vaultwarden.enable = true; # Vaultwarden 비밀번호 관리자
  homeserver.reverseProxy.enable = true; # Caddy HTTPS 리버스 프록시
}
