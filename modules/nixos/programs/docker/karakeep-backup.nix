# modules/nixos/programs/docker/karakeep-backup.nix
# Karakeep SQLite 매일 백업 (HDD → HDD)
# db.db + queue.db 백업 (assets/는 같은 HDD에 있으므로 별도 백업 불필요)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.karakeepBackup;
  karakeepCfg = config.homeserver.karakeep;
  inherit (constants.paths) mediaData;

  srcDir = "${mediaData}/karakeep";
  backupDir = "${mediaData}/backups/karakeep";
  pushoverCredPath = config.age.secrets.pushover-karakeep.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  backupScript = pkgs.writeShellApplication {
    name = "karakeep-backup";
    runtimeInputs = with pkgs; [
      sqlite
      coreutils
      findutils
      gzip
      curl # service-lib.sh의 send_notification에서 사용
    ];
    text = builtins.readFile ./karakeep-backup/files/karakeep-backup.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && karakeepCfg.enable) {
    # Pushover 시크릿 (karakeep-notify와 동일 선언 — 모듈 시스템이 merge)
    age.secrets.pushover-karakeep = {
      file = ../../../../secrets/pushover-karakeep.age;
      owner = "root";
      mode = "0400";
    };

    # 백업 서비스 (oneshot)
    systemd.services.karakeep-backup = {
      description = "Karakeep SQLite backup (HDD)";

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/karakeep-backup";
        ProtectSystem = "strict";
        ReadWritePaths = [ backupDir ];
        ReadOnlyPaths = [ srcDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        BACKUP_DIR = backupDir;
        SRC_DIR = srcDir;
        RETENTION_DAYS = toString cfg.retentionDays;
      };
    };

    # 타이머 (매일 05:00 KST)
    systemd.timers.karakeep-backup = {
      description = "Daily Karakeep SQLite backup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.backupTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # 백업 디렉토리 생성
    systemd.tmpfiles.rules = [
      "d ${backupDir} 0700 root root -"
    ];
  };
}
