# modules/nixos/options/homeserver.nix
# 홈서버 서비스 옵션 정의
# mkOption/mkEnableOption으로 서비스 선언적 활성화 지원
{
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

    copyparty = {
      enable = lib.mkEnableOption "Copyparty file server (Google Drive alternative)";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.copyparty;
        description = "Port for Copyparty web interface";
      };
    };

    karakeep = {
      enable = lib.mkEnableOption "Karakeep bookmark manager and web archiver";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.karakeep;
        description = "Karakeep web UI port";
      };
    };

    karakeepBackup = {
      enable = lib.mkEnableOption "Karakeep SQLite daily backup to HDD";
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

    karakeepUpdate = {
      enable = lib.mkEnableOption "Karakeep version check and update notification";
      checkTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 06:00:00";
        description = "OnCalendar time for version check";
      };
    };

    karakeepNotify = {
      enable = lib.mkEnableOption "Karakeep webhook-to-Pushover bridge";
      webhookPort = lib.mkOption {
        type = lib.types.port;
        default = 9999;
        description = "Local port for webhook receiver";
      };
    };

    karakeepLogMonitor = {
      enable = lib.mkEnableOption "Karakeep log monitor (OOM/failure Pushover alerts)";
      queueFile = lib.mkOption {
        type = lib.types.str;
        default = "/var/lib/karakeep-log-monitor/failed-urls.queue";
        description = "Shared failed URL queue file used by karakeep-log-monitor and karakeep-fallback-sync";
      };
    };

    karakeepFallbackSync = {
      enable = lib.mkEnableOption "Karakeep archive-fallback auto relink sync";
      syncInterval = lib.mkOption {
        type = lib.types.str;
        default = "1m";
        description = "OnUnitActiveSec interval for fallback sync service";
      };
    };

    karakeepSinglefileBridge = {
      enable = lib.mkEnableOption "Karakeep SingleFile size-guard bridge";
      port = lib.mkOption {
        type = lib.types.port;
        default = 3010;
        description = "Local port for Karakeep SingleFile bridge";
      };
      maxAssetSizeMb = lib.mkOption {
        type = lib.types.int;
        default = 50;
        description = "Max SingleFile asset size in MB before fallback mode";
      };
    };

    reverseProxy = {
      enable = lib.mkEnableOption "Caddy reverse proxy with HTTPS for homeserver services";
    };

    smokeTest = {
      enable = lib.mkEnableOption "Homeserver runtime smoke test (healthcheck + backup freshness)";
      timerInterval = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 06:00:00";
        description = "OnCalendar interval for smoke test (default: daily 06:00)";
      };
      backupMaxAgeHours = lib.mkOption {
        type = lib.types.int;
        default = 26;
        description = "Maximum age (hours) for backup files before alerting";
      };
    };

    # opnix: 1Password Service Account 기반 시크릿 materialization 인프라
    # enable=true 시 services.onepassword-secrets(Go SDK root oneshot)로 op:// reference를
    # tmpfs에 materialize하고, SA token 90일 rotation 알림 timer를 활성화한다.
    opnix = {
      enable = lib.mkEnableOption "1Password Service Account secrets materialization (opnix)";
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
    ../programs/docker/copyparty.nix # Copyparty 파일 서버
    ../programs/docker/immich-backup.nix # Immich PostgreSQL 매일 백업
    ../programs/docker/karakeep.nix # Karakeep 웹 아카이버/북마크 관리 (3컨테이너)
    ../programs/docker/karakeep-backup.nix # Karakeep SQLite 매일 백업
    ../programs/docker/karakeep-notify.nix # Karakeep 웹훅→Pushover 브리지
    ../programs/docker/karakeep-log-monitor.nix # Karakeep 로그 감시 (OOM/실패 알림)
    ../programs/docker/karakeep-fallback-sync.nix # Karakeep fallback HTML 자동 재연결
    ../programs/docker/karakeep-singlefile-bridge.nix # Karakeep SingleFile 대용량 분기 브리지
    ../programs/karakeep-update # Karakeep 버전 체크 + 업데이트 알림
    ../programs/caddy.nix # HTTPS 리버스 프록시
    ../programs/smoke-test.nix # 런타임 스모크 테스트 (헬스체크 + 백업 신선도)
    ../programs/opnix # 1Password Service Account 시크릿 materialization
    ../programs/opnix-rotate.nix # SA token 90일 rotation 알림 (opnix.enable 게이팅)
  ];
}
