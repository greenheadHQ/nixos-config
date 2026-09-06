# modules/nixos/programs/anki-host/backup.nix
# 인스턴스별 .colpkg 일일 백업 (헬퍼 /export → SSD backups/ → HDD) + 복구점(restore-points/) HDD 미러
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
  stateRoot = constants.paths.ankiHostState;
  inherit (constants.paths) mediaData;
  backupDir = "${mediaData}/backups/anki-host";
  pushoverCredPath = config.age.secrets.pushover-anki.path;
  pushoverHelper = ../../../shared/scripts/lib/pushover.sh;
  backupInstances = lib.filterAttrs (_: inst: inst.enable && inst.backup.enable) cfg.instances;
  instanceList = lib.concatStringsSep " " (
    lib.mapAttrsToList (name: inst: "${name}:${toString inst.helperPort}") backupInstances
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
  config = lib.mkIf (cfg.enable && backupInstances != { }) {
    age.secrets.pushover-anki = {
      file = ../../../../secrets/pushover-anki.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.anki-host-backup = {
      description = "Daily .colpkg backup of headless Anki instances (SSD -> HDD)";
      after = lib.mapAttrsToList (name: _: "anki-host-${name}.service") backupInstances;

      # sync.nix와 같은 정책 — LoadCredential 원본 부재 시 EXIT_CREDENTIALS 실패를 조건으로 막는다
      unitConfig.ConditionPathExists = pushoverCredPath;

      environment = {
        INSTANCES = instanceList;
        STATE_ROOT = stateRoot;
        BACKUP_DIR = backupDir;
        RETENTION_DAYS = toString cfg.retentionDays;
        # SSD에는 직전 백업 1개 + 오늘 백업 1개만 남긴다 (컬렉션+미디어 ≈ 200MB/개). 장기 보존은 HDD 몫.
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
