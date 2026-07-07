# NixOS 시스템 설정
{
  config,
  pkgs,
  lib,
  inputs,
  constants,
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

  # 커널 패닉 시 자동 재부팅 (10초 후)
  boot.kernel.sysctl."kernel.panic" = 10;

  # systemd watchdog — 시스템 hang 감지 시 자동 재부팅
  # RuntimeWatchdogSec: systemd가 이 간격 내에 하드웨어 watchdog을 ping해야 함 (못하면 hang 판정)
  # RebootWatchdogSec: hang 판정 후 강제 재부팅까지 대기 시간
  systemd.settings.Manager = {
    RuntimeWatchdogSec = "30s";
    RebootWatchdogSec = "10min";
  };

  # 호스트명
  networking.hostName = hostname;
  networking.networkmanager.enable = true;

  # 시간대
  time.timeZone = "Asia/Seoul";

  # 로케일 (영어)
  i18n.defaultLocale = "en_US.UTF-8";

  # Nix 설정
  nix = {
    # 공통 설정(experimental-features, warn-dirty, optimise, gc options)은
    # modules/shared/configuration.nix에서 주입
    settings.trusted-users = [
      "root"
      username
    ];
    gc.dates = "weekly";
  };

  # agenix 시스템 레벨 복호화 키 (서비스 모듈 enable 여부와 무관하게 유지)
  # dual-identity: user 로그인 키(대부분의 .age) + host key(SA token 등 부팅 의존 시크릿).
  # agenix가 각 .age의 recipient에 맞는 키로 복호화한다 (host key 분리).
  age.identityPaths = [
    "/home/${username}/.ssh/id_ed25519" # user key — 대부분의 .age
    constants.paths.agenixHostIdentityKey # host key — SA token (minipcHostOnly)
  ];

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
    nvd
    bubblewrap # Codex CLI Linux sandbox (read-only/workspace-write)
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

  # 프로그램 모듈 임포트
  imports = [
    ./programs/tailscale.nix
    ./programs/ssh.nix
    ./programs/mosh.nix
    ./programs/smartd.nix # S.M.A.R.T. 디스크 건강 모니터링 (Pushover 알림)
    ./programs/temp-monitor # lm-sensors 온도 모니터링 (5분마다, Pushover 알림)
    ./programs/pushover-purge-reminder.nix # Backup archive 6개월 보관 만료 reminder (2026-12-01 1회성)
    ./options/homeserver.nix # Docker/Podman 기반 홈서버 서비스 (mkOption)
  ];

  # 홈서버 서비스 활성화 (mkEnableOption 기본값 false)
  homeserver.immich.enable = true;
  homeserver.uptimeKuma.enable = true;
  homeserver.immichCleanup.enable = true; # Claude Code Temp 앨범 매일 전체 삭제
  homeserver.immichUpdate.enable = true; # Immich 버전 체크 + 업데이트 알림
  homeserver.uptimeKumaUpdate.enable = true; # Uptime Kuma 버전 체크 + 업데이트 알림
  homeserver.copypartyUpdate.enable = true; # Copyparty 버전 체크 + 업데이트 알림
  homeserver.copyparty.enable = true; # 셀프호스팅 파일 서버
  homeserver.karakeep.enable = true; # Karakeep 웹 아카이버/북마크 관리 (3컨테이너)
  homeserver.karakeepBackup.enable = true; # Karakeep SQLite 매일 백업 (HDD)
  homeserver.karakeepNotify.enable = true; # Karakeep 웹훅→Pushover 브리지
  homeserver.karakeepLogMonitor.enable = true; # Karakeep 로그 모니터 (OOM/실패 알림)
  homeserver.karakeepFallbackSync.enable = true; # fallback HTML 자동 재연결 (API)
  homeserver.karakeepSinglefileBridge.enable = true; # SingleFile 대용량 자동 분기 (링크+보관 fullPageArchive)
  homeserver.karakeepUpdate.enable = true; # Karakeep 버전 체크 + 업데이트 알림
  homeserver.immichBackup.enable = true; # Immich PostgreSQL 매일 백업 (HDD)
  homeserver.immichOriginalsMirror.enable = true; # Immich 원본 사진/영상 HDD 일일 미러
  homeserver.reverseProxy.enable = true; # Caddy HTTPS 리버스 프록시
  homeserver.smokeTest.enable = true; # 런타임 스모크 테스트 (헬스체크 + 백업 신선도)
  homeserver.opnix.enable = true; # 1Password SA token materialization + gh 인증
  homeserver.codexRemoteControl.enable = true; # Codex mobile remote-control app-server 회귀 방지
  homeserver.claudeRemoteControl = {
    enable = true; # Claude Code RC bridge version-drift 감시 (30분 timer)
    capacity = 10; # 현행 운영값 — 자동 재시작 시 이 값으로 유지된다
    name = "miniPC";
  };
}
