# modules/nixos/programs/docker/immich-backup.nix
# Immich PostgreSQL 매일 백업 (컨테이너 내부 pg_dump → HDD)
# service-lib.sh로 Pushover 알림 (oneshot systemd service + daily timer)
# pg_dump -Fc 커스텀 포맷: 내장 압축, 선택적 복원, pg_restore --list 검증
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.immichBackup;
  immichCfg = config.homeserver.immich;
  inherit (constants.paths) mediaData;

  backupDir = "${mediaData}/backups/immich";
  pushoverCredPath = config.age.secrets.pushover-immich.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  backupScript = pkgs.writeShellApplication {
    name = "immich-db-backup";
    runtimeInputs = with pkgs; [
      podman
      coreutils
      findutils
      curl # service-lib.sh의 send_notification에서 사용
    ];
    text = builtins.readFile ./immich-backup/files/immich-db-backup.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && immichCfg.enable) {
    # 백업 서비스 (oneshot)
    systemd.services.immich-db-backup = {
      description = "Immich PostgreSQL backup (pg_dump -Fc → HDD)";
      after = [ "podman-immich-postgres.service" ];
      wants = [ "podman-immich-postgres.service" ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/immich-db-backup";
        TimeoutSec = "1h";
        # ProtectSystem=strict 불가 — podman exec가 /run/containers/, /var/lib/containers/,
        # /run/podman/ 등 다수의 시스템 경로에 접근 필요. podman exec는 컨테이너 런타임 전체 접근 필요.
        ReadWritePaths = [ backupDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        BACKUP_DIR = backupDir;
        RETENTION_DAYS = toString cfg.retentionDays;
      };
    };

    # 타이머 (기본 매일 05:30 KST, cfg.backupTime으로 설정)
    systemd.timers.immich-db-backup = {
      description = "Daily Immich PostgreSQL backup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.backupTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # 백업 디렉토리 생성 (DB 덤프이므로 0700)
    systemd.tmpfiles.rules = [
      "d ${backupDir} 0700 root root -"
    ];
  };
}
