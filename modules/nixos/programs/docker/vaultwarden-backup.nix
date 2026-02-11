# modules/nixos/programs/docker/vaultwarden-backup.nix
# Vaultwarden 데이터 매일 백업 (SSD -> HDD)
# SQLite DB는 sqlite3 .backup으로 안전하게 복사 (파일 복사 시 WAL 모드에서 corruption 위험)
# 비밀번호 관리자이므로 30일 보존 (다른 서비스 7일보다 길게)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.vaultwarden;
  inherit (constants.paths) dockerData mediaData;

  srcDir = "${dockerData}/vaultwarden/data";
  backupDir = "${mediaData}/backups/vaultwarden";

  backupScript = pkgs.writeShellApplication {
    name = "vaultwarden-backup";
    runtimeInputs = with pkgs; [
      sqlite
      rsync
      coreutils
      findutils
      gzip
    ];
    text = ''
      # 소스 디렉토리가 비어있으면 백업 중단 (데이터 유실 방지)
      if [ -z "$(ls -A "${srcDir}" 2>/dev/null)" ]; then
        echo "ERROR: Source directory empty, skipping backup" >&2
        exit 1
      fi

      # 날짜별 백업 디렉토리
      DATED_DIR="${backupDir}/$(date +%Y-%m-%d)"
      mkdir -p "$DATED_DIR"

      # SQLite DB 안전 백업 (.backup 명령은 WAL 모드에서도 일관성 보장)
      # 원자적 쓰기: 임시 파일 -> mv (정전 시 불완전 파일 방지)
      DB_FILE="${srcDir}/db.sqlite3"
      if [ -f "$DB_FILE" ]; then
        sqlite3 "$DB_FILE" ".backup '$DATED_DIR/db.sqlite3.tmp'"
        mv "$DATED_DIR/db.sqlite3.tmp" "$DATED_DIR/db.sqlite3"
        gzip -f "$DATED_DIR/db.sqlite3"

        # 무결성 검증
        if ! gunzip -t "$DATED_DIR/db.sqlite3.gz"; then
          echo "ERROR: Backup integrity check failed" >&2
          exit 1
        fi

        echo "SQLite backup completed: $DATED_DIR/db.sqlite3.gz"
      else
        echo "WARNING: Database file not found at $DB_FILE" >&2
      fi

      # 첨부파일, 아이콘, RSA 키 등 나머지 데이터 rsync
      # db.sqlite3* 제외 (이미 sqlite3 .backup으로 처리)
      rsync -a \
        --exclude='db.sqlite3' \
        --exclude='db.sqlite3-wal' \
        --exclude='db.sqlite3-shm' \
        "${srcDir}/" "$DATED_DIR/"

      # 30일 이전 백업 삭제
      find "${backupDir}" -maxdepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} +

      echo "Vaultwarden backup completed: $(date -Iseconds)"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # 백업 서비스 (oneshot)
    systemd.services.vaultwarden-backup = {
      description = "Vaultwarden backup (SSD -> HDD, SQLite-safe)";

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/vaultwarden-backup";
        ProtectSystem = "strict";
        ReadWritePaths = [ backupDir ];
        ReadOnlyPaths = [ srcDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };

    # 타이머 (매일 04:30 KST -- anki backup 04:00과 30분 간격)
    systemd.timers.vaultwarden-backup = {
      description = "Daily Vaultwarden backup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "*-*-* 04:30:00";
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # 백업 디렉토리 생성 (비밀번호 저장소이므로 0700)
    systemd.tmpfiles.rules = [
      "d ${backupDir} 0700 root root -"
    ];
  };
}
