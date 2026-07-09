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

    immichOriginalsMirror = {
      enable = lib.mkEnableOption "Immich originals daily rsync mirror to HDD";
      mirrorTime = lib.mkOption {
        type = lib.types.str;
        default = "*-*-* 04:30:00";
        description = "OnCalendar time for daily originals mirror";
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
      webhookTokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional file containing the expected Karakeep webhook bearer token";
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

    daWeeklyReport = {
      enable = lib.mkEnableOption "DA session weekly report timer";
      retryWindow = lib.mkOption {
        type = lib.types.submodule {
          options = {
            weekday = lib.mkOption {
              type = lib.types.enum [
                "Mon"
                "Tue"
                "Wed"
                "Thu"
                "Fri"
                "Sat"
                "Sun"
              ];
              default = "Mon";
              description = "Weekday for weekly DA report generation attempts";
            };
            startHour = lib.mkOption {
              type = lib.types.ints.between 0 23;
              default = 9;
              description = "First local hour included in the retry window";
            };
            deadlineHour = lib.mkOption {
              type = lib.types.ints.between 0 23;
              default = 14;
              description = "Local hour at which the retry window finalizes partial publication";
            };
            timezone = lib.mkOption {
              type = lib.types.str;
              default = "Asia/Seoul";
              description = "Timezone used by the weekly DA report retry window";
            };
          };
        };
        default = { };
        description = "Structured retry window used to derive both OnCalendar and the WINDOW_* service environment";
      };
      reminderCalendar = lib.mkOption {
        type = lib.types.str;
        default = "Sun *-*-* 22:00:00 Asia/Seoul";
        description = "OnCalendar time for the pre-report Pushover reminder";
      };
      trackingIssueNumber = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "GitHub issue number to comment on; null skips GitHub publishing";
      };
    };

    # opnix: 1Password Service Account 기반 시크릿 materialization 인프라
    # enable=true 시 services.onepassword-secrets(Go SDK root oneshot)로 op:// reference를
    # tmpfs에 materialize하고, SA token 90일 rotation 알림 timer를 활성화한다.
    opnix = {
      enable = lib.mkEnableOption "1Password Service Account secrets materialization (opnix)";
    };

    codexRemoteControl = {
      enable = lib.mkEnableOption "Codex mobile remote-control app-server regression guard";
    };

    claudeRemoteControl = {
      enable = lib.mkEnableOption "Claude Code Remote Control 선언 인스턴스(nixos-config)의 상시 유지 + 전체 인스턴스 version-drift 감시";

      # 선언 인스턴스 시작 옵션 — maint가 instances.json에 없는 선언 항목을
      # 시드하고, 죽었거나 drift된 서버를 재기동할 때 이 값을 보존한다.
      spawn = lib.mkOption {
        type = lib.types.enum [
          "worktree"
          "same-dir"
        ];
        default = "worktree";
        description = "Spawn mode for remote sessions; worktree sessions tombstone if their server restarts while active";
      };

      permissionMode = lib.mkOption {
        type = lib.types.enum [
          "acceptEdits"
          "bypassPermissions"
          "default"
          "dontAsk"
          "plan"
        ];
        default = "bypassPermissions";
        description = "Permission mode for bridge-spawned sessions";
      };

      capacity = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Max concurrent remote sessions; null omits --capacity and uses the upstream default";
      };

      idleThresholdMinutes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 30;
        description = "Transcript inactivity window before a session counts as idle (restart gate)";
      };
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
    ../programs/docker/immich-originals-mirror.nix # Immich 원본 사진/영상 HDD 일일 미러
    ../programs/docker/karakeep.nix # Karakeep 웹 아카이버/북마크 관리 (3컨테이너)
    ../programs/docker/karakeep-backup.nix # Karakeep SQLite 매일 백업
    ../programs/docker/karakeep-notify.nix # Karakeep 웹훅→Pushover 브리지
    ../programs/docker/karakeep-log-monitor.nix # Karakeep 로그 감시 (OOM/실패 알림)
    ../programs/docker/karakeep-fallback-sync.nix # Karakeep fallback HTML 자동 재연결
    ../programs/docker/karakeep-singlefile-bridge.nix # Karakeep SingleFile 대용량 분기 브리지
    ../programs/karakeep-update # Karakeep 버전 체크 + 업데이트 알림
    ../programs/caddy.nix # HTTPS 리버스 프록시
    ../programs/smoke-test.nix # 런타임 스모크 테스트 (헬스체크 + 백업 신선도)
    ../programs/da-weekly-report # DA 세션 주간 리포트 timer
    ../programs/opnix # 1Password Service Account 시크릿 materialization
    ../programs/opnix-rotate.nix # SA token 90일 rotation 알림 (opnix.enable 게이팅)
    ../programs/codex-remote-control.nix # Codex mobile remote-control app-server 회귀 방지
    ../programs/claude-remote-control.nix # Claude Code RC bridge version-drift 감시
  ];
}
