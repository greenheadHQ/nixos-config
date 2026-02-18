# modules/nixos/programs/docker/archivebox-backup.nix
# ArchiveBox SQLite 매일 백업 (SSD -> HDD)
# DB만 백업 (archive/ 디렉토리는 이미 HDD에 있으므로 별도 백업 불필요)
# vaultwarden-backup.nix 패턴 기반, service-lib.sh로 Pushover 실패 알림
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.archiveBoxBackup;
  archiveBoxCfg = config.homeserver.archiveBox;
  inherit (constants.paths) dockerData mediaData;

  srcDir = "${dockerData}/archivebox/data";
  backupDir = "${mediaData}/backups/archivebox";
  pushoverCredPath = config.age.secrets.pushover-archivebox.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  backupScript = pkgs.writeShellApplication {
    name = "archivebox-backup";
    runtimeInputs = with pkgs; [
      sqlite
      coreutils
      findutils
      gzip
    ];
    text = ''
      # service-lib.sh 로드 (send_notification 사용)
      # shellcheck source=/dev/null
      source "$PUSHOVER_CRED_FILE"
      # shellcheck source=/dev/null
      source "$SERVICE_LIB"

      # 에러 핸들러: 실패 시 Pushover 알림
      cleanup_on_error() {
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
          send_notification "ArchiveBox Backup" \
            "백업 실패 (exit $exit_code). journalctl -u archivebox-backup 확인 필요." 1
        fi
      }
      trap cleanup_on_error EXIT

      echo "=== ArchiveBox backup start: $(date -Iseconds) ==="

      # 소스 DB 확인
      DB_FILE="${srcDir}/index.sqlite3"
      if [ ! -f "$DB_FILE" ]; then
        echo "ERROR: Database not found at $DB_FILE" >&2
        exit 1
      fi

      # 날짜별 백업 디렉토리
      DATED_DIR="$BACKUP_DIR/$(date +%Y-%m-%d)"
      mkdir -p "$DATED_DIR"

      # SQLite DB 안전 백업 (.backup 명령은 WAL 모드에서도 일관성 보장)
      # 원자적 쓰기: 임시 파일 -> mv (정전 시 불완전 파일 방지)
      sqlite3 "$DB_FILE" ".backup '$DATED_DIR/index.sqlite3.tmp'"
      mv "$DATED_DIR/index.sqlite3.tmp" "$DATED_DIR/index.sqlite3"
      gzip -f "$DATED_DIR/index.sqlite3"

      # 무결성 검증
      if ! gunzip -t "$DATED_DIR/index.sqlite3.gz"; then
        echo "ERROR: Backup integrity check failed" >&2
        exit 1
      fi

      echo "SQLite backup completed: $DATED_DIR/index.sqlite3.gz"

      # 보관 정리 (retentionDays 초과 백업 삭제)
      DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -print | wc -l)
      find "$BACKUP_DIR" -maxdepth 1 -type d -name "20*" -mtime +"$RETENTION_DAYS" -exec rm -rf {} +
      if [ "$DELETED" -gt 0 ]; then
        echo "Cleaned up $DELETED old backups (>''${RETENTION_DAYS} days)"
      fi

      echo "=== ArchiveBox backup completed: $(date -Iseconds) ==="
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && archiveBoxCfg.enable) {
    # Pushover 시크릿
    age.secrets.pushover-archivebox = {
      file = ../../../../secrets/pushover-archivebox.age;
      owner = "root";
      mode = "0400";
    };

    # 백업 서비스 (oneshot)
    systemd.services.archivebox-backup = {
      description = "ArchiveBox SQLite backup (SSD -> HDD)";

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/archivebox-backup";
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
        RETENTION_DAYS = toString cfg.retentionDays;
      };
    };

    # 타이머 (매일 05:00 KST)
    systemd.timers.archivebox-backup = {
      description = "Daily ArchiveBox SQLite backup";
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
