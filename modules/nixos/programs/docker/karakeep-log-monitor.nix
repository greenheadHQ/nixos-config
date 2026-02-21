# modules/nixos/programs/docker/karakeep-log-monitor.nix
# Karakeep 컨테이너 로그 감시 (OOM/실패 패턴 감지 → Pushover 알림)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.karakeepLogMonitor;
  karakeepCfg = config.homeserver.karakeep;
  failedUrlQueueFile = cfg.queueFile;
  notifyStateFile = "/var/lib/karakeep-log-monitor/notified-urls.tsv";

  pushoverCredPath = config.age.secrets.pushover-karakeep.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };
  inherit (constants.domain) base subdomains;

  logMonitorScript = pkgs.writeShellApplication {
    name = "karakeep-log-monitor";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      systemd
      gnugrep
      gawk
      util-linux
    ];
    text = builtins.readFile ./karakeep-log-monitor/files/log-monitor.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && karakeepCfg.enable) {
    # Pushover 시크릿 (karakeep-notify/backup와 동일 선언 — 모듈 시스템이 merge)
    age.secrets.pushover-karakeep = {
      file = ../../../../secrets/pushover-karakeep.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.karakeep-log-monitor = {
      description = "Karakeep log monitor (OOM/failure Pushover alerts)";
      after = [ "podman-karakeep.service" ];
      bindsTo = [ "podman-karakeep.service" ];
      wantedBy = [
        "multi-user.target"
        "podman-karakeep.service"
      ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${logMonitorScript}/bin/karakeep-log-monitor";
        Restart = "on-failure";
        RestartSec = "5s";
        StateDirectory = "karakeep-log-monitor";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        COPYPARTY_FALLBACK_URL = "https://${subdomains.copyparty}.${base}/archive-fallback/";
        FAILED_URL_QUEUE_FILE = failedUrlQueueFile;
        FAILED_URL_QUEUE_LOCK_FILE = "${failedUrlQueueFile}.lock";
        FAILED_URL_QUEUE_MAX = "200";
        NOTIFY_STATE_FILE = notifyStateFile;
      };
    };
  };
}
