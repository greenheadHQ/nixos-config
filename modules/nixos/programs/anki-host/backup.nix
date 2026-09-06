# modules/nixos/programs/anki-host/backup.nix
# 인스턴스별 .colpkg 일일 백업 (헬퍼 /export → SSD 상태 디렉터리 → HDD)
# 관례: oneshot + daily timer, ProtectSystem=strict + ReadWrite/ReadOnly 분리, 04:30/05:00/05:30과 겹치지 않는 시각
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiHost;
  stateRoot = "/var/lib/anki-host";
  inherit (constants.paths) mediaData;
  backupDir = "${mediaData}/backups/anki-host";
  pushoverCredPath = config.age.secrets.pushover-anki.path;
  pushoverHelper = ../../../shared/scripts/lib/pushover.sh;
  enabledInstances = lib.filterAttrs (_: inst: inst.enable) cfg.instances;
  instanceList = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: inst: "${name}:${toString inst.helperPort}") enabledInstances
  );

  backupScript = pkgs.writeShellApplication {
    name = "anki-host-backup";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      findutils
      gawk
      python3
    ];
    text = builtins.readFile ./files/anki-host-backup.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && enabledInstances != { }) {
    age.secrets.pushover-anki = {
      file = ../../../../secrets/pushover-anki.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.anki-host-backup = {
      description = "Daily .colpkg backup of headless Anki instances (SSD -> HDD)";
      after = lib.mapAttrsToList (name: _: "anki-host-${name}.service") enabledInstances;

      environment = {
        INSTANCES = instanceList;
        STATE_ROOT = stateRoot;
        BACKUP_DIR = backupDir;
        RETENTION_DAYS = toString cfg.retentionDays;
        LOCAL_KEEP = "2";
        PUSHOVER_HELPER = "${pushoverHelper}";
      };

      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [ "pushover:${pushoverCredPath}" ];
        ExecStart = "${backupScript}/bin/anki-host-backup";
        TimeoutStartSec = "1h";
        ProtectSystem = "strict";
        ReadWritePaths = [
          backupDir
          stateRoot
        ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    systemd.timers.anki-host-backup = {
      description = "Daily headless Anki .colpkg backup";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.backupTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    systemd.tmpfiles.rules = [ "d ${backupDir} 0700 root root -" ];
  };
}
