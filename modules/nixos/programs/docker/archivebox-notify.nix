# modules/nixos/programs/docker/archivebox-notify.nix
# ArchiveBox 런타임 이벤트 알림 (Pushover)
# - server error: podman-archivebox 실패 감지
# - archive success/failure: hook 큐 + SQLite polling fallback
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.archiveBoxNotify;
  archiveBoxCfg = config.homeserver.archiveBox;
  inherit (constants.paths) dockerData;
  inherit (constants.domain) base subdomains;

  pushoverCredPath = config.age.secrets.pushover-archivebox.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  stateDir = "/var/lib/archivebox-notify";
  dataDir = "${dockerData}/archivebox/data";
  dbFile = "${dataDir}/index.sqlite3";
  queueFile = "${dataDir}/notify/events.jsonl";

  pluginDir = "${dataDir}/plugins/pushover-notify";
  hookDst = "${pluginDir}/on_Snapshot__95_pushover_notify.py";
  hookSrc = "${./archivebox-notify/files/notify-hook.py}";

  installHookScript = pkgs.writeShellApplication {
    name = "archivebox-install-notify-hook";
    runtimeInputs = with pkgs; [ coreutils ];
    text = builtins.readFile ./archivebox-notify/files/install-hook.sh;
  };

  serverErrorNotifyScript = pkgs.writeShellApplication {
    name = "archivebox-server-error-notify";
    runtimeInputs = with pkgs; [
      coreutils
      gnused
      gnugrep
      gawk
      systemd
    ];
    text = builtins.readFile ./archivebox-notify/files/server-error-notify.sh;
  };

  eventPollerScript = pkgs.writeShellApplication {
    name = "archivebox-event-poller";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      curl
      sqlite
      gnused
      gnugrep
      ripgrep
      gawk
      util-linux
    ];
    text = builtins.readFile ./archivebox-notify/files/event-poller.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && archiveBoxCfg.enable) {
    # Pushover 시크릿 (archivebox-backup와 동일 선언 — 모듈 시스템이 merge)
    age.secrets.pushover-archivebox = {
      file = ../../../../secrets/pushover-archivebox.age;
      owner = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
      "d ${stateDir}/state 0700 root root -"
      "d ${stateDir}/metrics 0700 root root -"
      "d ${dataDir}/notify 0755 root root -"
      "d ${dataDir}/plugins 0755 root root -"
      "d ${pluginDir} 0755 root root -"
    ];

    # ArchiveBox user plugin 배치 (컨테이너 시작 전)
    systemd.services.archivebox-notify-plugin = {
      description = "Install ArchiveBox notify hook plugin";
      wantedBy = [ "podman-archivebox.service" ];
      before = [ "podman-archivebox.service" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${installHookScript}/bin/archivebox-install-notify-hook";
        RemainAfterExit = true;
        UMask = "0077";
      };

      environment = {
        HOOK_SRC = hookSrc;
        HOOK_DST = hookDst;
        QUEUE_FILE = queueFile;
      };
    };

    # podman-archivebox 실패 알림
    systemd.services.archivebox-server-error-notify = {
      description = "ArchiveBox server failure notification";

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${serverErrorNotifyScript}/bin/archivebox-server-error-notify";
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        STATE_DIR = stateDir;
        TARGET_UNIT = "podman-archivebox.service";
        DEDUPE_WINDOW_SEC = "300";
      };
    };

    # ArchiveBox 이벤트 poller (hook 큐 + SQLite 판정)
    systemd.services.archivebox-event-poller = {
      description = "ArchiveBox event notifier poller";
      after = [ "podman-archivebox.service" ];
      wants = [ "podman-archivebox.service" ];

      unitConfig = {
        ConditionPathExists = [
          pushoverCredPath
          dbFile
        ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${eventPollerScript}/bin/archivebox-event-poller";
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        ReadOnlyPaths = [ dataDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        DB_FILE = dbFile;
        QUEUE_FILE = queueFile;
        STATE_DIR = stateDir;
        ARCHIVEBOX_BASE_URL = "https://${subdomains.archiveBox}.${base}";

        SUCCESS_ENABLED = lib.boolToString cfg.successEnabled;
        INCLUDE_FULL_URL = lib.boolToString cfg.includeFullUrl;
        SILENCE_SUCCESS_NIGHT = lib.boolToString cfg.silenceSuccessNight;
        NIGHT_HOURS = cfg.nightHours;

        MAX_LOOKUPS_PER_CYCLE = "30";
        PENDING_CAP = "1000";
        PENDING_RECOVER_THRESHOLD = "800";
        PENDING_TIMEOUT_SEC = "1800";
        DEGRADE_INTERVAL_SEC = "300";
        POLL_P95_BUDGET_MS = "2000";
      };
    };

    systemd.timers.archivebox-event-poller = {
      description = "Periodic ArchiveBox event poller";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "${toString cfg.pollIntervalSec}s";
        Unit = "archivebox-event-poller.service";
        Persistent = true;
        RandomizedDelaySec = "10s";
      };
    };

    # podman-archivebox 연동
    systemd.services.podman-archivebox = {
      after = [ "archivebox-notify-plugin.service" ];
      wants = [ "archivebox-notify-plugin.service" ];

      unitConfig = {
        OnFailure = [ "archivebox-server-error-notify.service" ];
      };
    };

    # 컨테이너 내부 hook에서 읽는 queue 파일 경로
    virtualisation.oci-containers.containers.archivebox.environment = {
      PUSHOVER_NOTIFY_QUEUE_FILE = "/data/notify/events.jsonl";
    };
  };
}
