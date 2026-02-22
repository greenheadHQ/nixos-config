# modules/nixos/options/homeserver.nix
# 홈서버 서비스 옵션 정의
# mkOption/mkEnableOption으로 서비스 선언적 활성화 지원
{
  config,
  lib,
  constants,
  username,
  ...
}:

let
  # Prefix normalization/trim is enforced in the AnkiConnect patch at runtime.
  # This type only guarantees at least one non-space character exists.
  nonBlankString = lib.types.strMatching ".*[^[:space:]].*";
  nonEmptyPrefixList = lib.types.addCheck (lib.types.listOf nonBlankString) (
    prefixes: builtins.length prefixes > 0
  );
in
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

    ankiConnect = {
      enable = lib.mkEnableOption "Headless Anki with AnkiConnect API";
      port = lib.mkOption {
        type = lib.types.port;
        default = constants.network.ports.ankiConnect;
        description = "Port for AnkiConnect HTTP API";
      };
      profile = lib.mkOption {
        type = lib.types.str;
        default = "server";
        description = "Anki profile name";
      };
      configApi = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Enable AnkiConnect custom config actions (`getConfig`, `setConfig`).
            Defaults to true because awesome-anki integration depends on this API.
            Access is constrained by Tailscale network isolation and allowedKeyPrefixes.
          '';
        };
        allowedKeyPrefixes = lib.mkOption {
          type = nonEmptyPrefixList;
          default = [ "awesomeAnki." ];
          description = "Allowed key prefixes for config API writes/reads.";
        };
        maxValueBytes = lib.mkOption {
          type = lib.types.ints.positive;
          default = 65536;
          description = "Maximum serialized UTF-8 JSON payload size per config value.";
        };
      };
      sync = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable AnkiConnect <-> Sync Server auto sync.";
        };
        url = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Custom sync endpoint URL. null이면 로컬 Anki Sync Server URL을 사용.";
        };
        username = lib.mkOption {
          type = lib.types.str;
          default = username;
          description = "Sync username used by headless Anki.";
        };
        onStart = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Trigger sync once after anki-connect service starts.";
        };
        interval = lib.mkOption {
          type = lib.types.str;
          default = "5m";
          description = "OnUnitActiveSec interval for periodic sync.";
        };
        maxRetries = lib.mkOption {
          type = lib.types.ints.positive;
          default = 3;
          description = "Maximum retry attempts per sync run.";
        };
        backoffBaseSec = lib.mkOption {
          type = lib.types.ints.positive;
          default = 5;
          description = "Base seconds for exponential backoff (5, 10, 20...).";
        };
        stateFile = lib.mkOption {
          type = lib.types.str;
          default = "/var/lib/anki/sync-status.json";
          description = "Path to sync status JSON used by operational checks/UI.";
        };
        bootstrapFromSyncServer = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Bootstrap AnkiConnect profile from Sync Server collection on first run.";
        };
        bootstrapMedia = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Copy media directory during one-time bootstrap.";
        };
        bootstrapMinCollectionBytes = lib.mkOption {
          type = lib.types.ints.unsigned;
          default = 262144;
          description = "Treat local collection as empty when smaller than this threshold.";
        };
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

    vaultwardenUpdate = {
      enable = lib.mkEnableOption "Vaultwarden version check and update notifications";
      checkTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 06:30:00";
        description = "OnCalendar time for version check";
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
    ../programs/anki-connect # Headless Anki + AnkiConnect API
    ../programs/docker/copyparty.nix # Copyparty 파일 서버
    ../programs/docker/vaultwarden.nix # Vaultwarden 비밀번호 관리자
    ../programs/docker/vaultwarden-backup.nix # Vaultwarden 백업 (SQLite 안전 백업)
    ../programs/vaultwarden-update # Vaultwarden 버전 체크 + 업데이트 알림
    ../programs/docker/immich-backup.nix # Immich PostgreSQL 매일 백업
    ../programs/docker/karakeep.nix # Karakeep 웹 아카이버/북마크 관리 (3컨테이너)
    ../programs/docker/karakeep-backup.nix # Karakeep SQLite 매일 백업
    ../programs/docker/karakeep-notify.nix # Karakeep 웹훅→Pushover 브리지
    ../programs/docker/karakeep-log-monitor.nix # Karakeep 로그 감시 (OOM/실패 알림)
    ../programs/docker/karakeep-fallback-sync.nix # Karakeep fallback HTML 자동 재연결
    ../programs/docker/karakeep-singlefile-bridge.nix # Karakeep SingleFile 대용량 분기 브리지
    ../programs/karakeep-update # Karakeep 버전 체크 + 업데이트 알림
    ../programs/caddy.nix # HTTPS 리버스 프록시
    ../programs/dev-proxy # Dev server reverse proxy (dev.greenhead.dev)
  ];
}
