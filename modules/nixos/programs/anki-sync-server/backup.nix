# modules/nixos/programs/anki-sync-server/backup.nix
# Anki sync 서버 데이터 매일 백업 (SSD -> HDD)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiSync;
  inherit (constants.paths) mediaData;

  srcDir = "/var/lib/anki-sync-server";
  backupDir = "${mediaData}/backups/anki";

  backupScript = pkgs.writeShellApplication {
    name = "anki-sync-backup";
    runtimeInputs = with pkgs; [
      rsync
      coreutils
      findutils
    ];
    text = ''
      # 소스 디렉토리가 비어있으면 백업 중단 (데이터 유실 방지)
      if [ -z "$(ls -A "${srcDir}" 2>/dev/null)" ]; then
        echo "ERROR: Source directory empty, skipping backup" >&2
        exit 1
      fi

      # 날짜별 백업 (7일 보존)
      DATED_DIR="${backupDir}/$(date +%Y-%m-%d)"
      rsync -a "${srcDir}/" "$DATED_DIR/"

      # 7일 이전 백업 삭제
      find "${backupDir}" -maxdepth 1 -type d -name "20*" -mtime +7 -exec rm -rf {} +

      echo "Anki sync backup completed: $(date -Iseconds)"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # 백업 서비스 (oneshot)
    systemd.services.anki-sync-backup = {
      description = "Anki sync server backup (SSD -> HDD)";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/anki-sync-backup";
        ProtectSystem = "strict";
        ReadWritePaths = [ backupDir ];
        ReadOnlyPaths = [ srcDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # 타이머 (매일 04:00 KST)
    systemd.timers.anki-sync-backup = {
      description = "Daily Anki sync server backup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "*-*-* 04:00:00";
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # 백업 디렉토리 생성
    systemd.tmpfiles.rules = [
      "d ${backupDir} 0755 root root -"
    ];
  };
}
