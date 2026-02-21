# modules/nixos/programs/docker/karakeep-fallback-sync.nix
# archive-fallback HTML 자동 재연결 (실패 URL 기반)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.karakeepFallbackSync;
  karakeepCfg = config.homeserver.karakeep;
  bridgeCfg = config.homeserver.karakeepSinglefileBridge;
  monitorCfg = config.homeserver.karakeepLogMonitor;
  failedUrlQueueFile = monitorCfg.queueFile;
  inherit (constants.paths) mediaData;

  pushoverCredPath = config.age.secrets.pushover-karakeep.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  fallbackSyncScript = pkgs.writeShellApplication {
    name = "karakeep-fallback-sync";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      gnused
      gawk
      findutils
      util-linux
    ];
    text = builtins.readFile ./karakeep-fallback-sync/files/fallback-sync.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && karakeepCfg.enable && monitorCfg.enable) {
    # Pushover 시크릿 재사용 (모듈 시스템이 merge)
    age.secrets.pushover-karakeep = {
      file = ../../../../secrets/pushover-karakeep.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.karakeep-fallback-sync = {
      description = "Karakeep archive-fallback auto relink sync";
      after = [ "podman-karakeep.service" ];
      wants = [ "podman-karakeep.service" ];

      unitConfig = {
        ConditionPathExists = [
          pushoverCredPath
          "${mediaData}/archive-fallback"
        ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${fallbackSyncScript}/bin/karakeep-fallback-sync";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        FALLBACK_DIR = "${mediaData}/archive-fallback";
        FAILED_URL_QUEUE_FILE = failedUrlQueueFile;
        FAILED_URL_QUEUE_LOCK_FILE = "${failedUrlQueueFile}.lock";
        KARAKEEP_BASE_URL =
          if bridgeCfg.enable then
            "http://127.0.0.1:${toString bridgeCfg.port}"
          else
            "http://127.0.0.1:${toString karakeepCfg.port}";
      };
    };

    systemd.timers.karakeep-fallback-sync = {
      description = "Karakeep archive-fallback auto relink sync timer";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = cfg.syncInterval;
        Persistent = true;
        RandomizedDelaySec = "20s";
      };
    };
  };
}
