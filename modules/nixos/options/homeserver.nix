# modules/nixos/options/homeserver.nix
# 홈서버 서비스 옵션 정의
# mkOption/mkEnableOption으로 서비스 선언적 활성화 지원
{
  config,
  lib,
  constants,
  ...
}:

{
  options.homeserver = {
    immich = {
      enable = lib.mkEnableOption "Immich photo backup service";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.immich;
        description = "Port for Immich web interface";
      };
    };

    immichBackup = {
      enable = lib.mkEnableOption "Immich PostgreSQL daily backup to HDD";
      backupTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 05:30:00";
        description = "OnCalendar time for daily backup";
      };
      retentionDays = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Number of days to retain backups";
      };
    };

    uptimeKuma = {
      enable = lib.mkEnableOption "Uptime Kuma monitoring service";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.uptimeKuma;
        description = "Port for Uptime Kuma web interface";
      };
    };

    immichCleanup = {
      enable = lib.mkEnableOption "Immich temp album cleanup (Claude Code Temp)";
      albumName = lib.mkOption {
        type = lib.types.str;
        default = "Claude Code Temp";
        description = "Name of the album to cleanup";
      };
    };

    immichUpdate = {
      enable = lib.mkEnableOption "Immich version check and update notifications";
      checkTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 03:00:00";
        description = "OnCalendar time for version check";
      };
    };

    uptimeKumaUpdate = {
      enable = lib.mkEnableOption "Uptime Kuma version check and update notifications";
      checkTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 03:30:00";
        description = "OnCalendar time for version check";
      };
    };

    copypartyUpdate = {
      enable = lib.mkEnableOption "Copyparty version check and update notifications";
      checkTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 04:00:00";
        description = "OnCalendar time for version check";
      };
    };

    ankiSync = {
      enable = lib.mkEnableOption "Anki self-hosted sync server";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.ankiSync;
        description = "Port for Anki sync server";
      };
    };

    copyparty = {
      enable = lib.mkEnableOption "Copyparty file server (Google Drive alternative)";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.copyparty;
        description = "Port for Copyparty web interface";
      };
    };

    vaultwarden = {
      enable = lib.mkEnableOption "Vaultwarden password manager (Bitwarden-compatible)";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.vaultwarden;
        description = "Port for Vaultwarden web interface";
      };
    };

    linkwarden = {
      enable = lib.mkEnableOption "Linkwarden bookmark manager and web archiver";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.linkwarden;
        description = "Port for Linkwarden web interface";
      };
    };

    linkwardenBackup = {
      enable = lib.mkEnableOption "Linkwarden PostgreSQL daily backup to HDD";
      backupTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 05:00:00";
        description = "OnCalendar time for daily backup";
      };
      retentionDays = lib.mkOption {
        type = lib.types.int;
        default = 30;
        description = "Number of days to retain backups";
      };
    };

    linkwardenUpdate = {
      enable = lib.mkEnableOption "Linkwarden version check and update notifications";
      checkTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 06:00:00";
        description = "OnCalendar time for version check";
      };
    };

    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy with HTTPS for homeserver services";
    };

    devProxy = {
      enable = lib.mkEnableOption "Dev server reverse proxy (dev.greenhead.dev)";
    };
  };

  # 모든 서비스 모듈을 정적으로 import (Nix 모듈 시스템은 조건부 import 불가)
  # 각 서비스 모듈 내부에서 mkIf cfg.enable 처리
  imports = [
    ../programs/docker/runtime.nix # Podman 런타임 공통 설정
    ../programs/docker/immich.nix
    ../programs/docker/uptime-kuma.nix
    ../programs/immich-cleanup # Immich 임시 앨범 자동 삭제
    ../programs/immich-update # Immich 버전 체크 및 업데이트
    ../programs/uptime-kuma-update # Uptime Kuma 버전 체크 및 업데이트
    ../programs/copyparty-update # Copyparty 버전 체크 및 업데이트
    ../programs/anki-sync-server # Anki 자체 호스팅 동기화 서버
    ../programs/docker/copyparty.nix # Copyparty 파일 서버
    ../programs/docker/vaultwarden.nix # Vaultwarden 비밀번호 관리자
    ../programs/docker/vaultwarden-backup.nix # Vaultwarden 백업 (SQLite 안전 백업)
    ../programs/docker/immich-backup.nix # Immich PostgreSQL 매일 백업
    ../programs/linkwarden # Linkwarden 북마크 매니저 + 웹 아카이버
    ../programs/linkwarden-backup # Linkwarden PostgreSQL 매일 백업
    ../programs/linkwarden-update # Linkwarden 버전 체크 + 업데이트 알림
    ../programs/caddy.nix # HTTPS 리버스 프록시
    ../programs/dev-proxy # Dev server reverse proxy (dev.greenhead.dev)
  ];
}
