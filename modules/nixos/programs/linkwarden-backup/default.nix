# modules/nixos/programs/linkwarden-backup/default.nix
# Linkwarden PostgreSQL 매일 백업 (NixOS native pg_dump → HDD)
# vaultwarden-backup.nix 패턴 기반, 단 Podman 대신 NixOS PostgreSQL 직접 사용
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.linkwardenBackup;
  linkwardenCfg = config.homeserver.linkwarden;
  inherit (constants.paths) mediaData;

  backupDir = "${mediaData}/backups/linkwarden";
  pushoverCredPath = config.age.secrets.pushover-linkwarden.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  backupScript = pkgs.writeShellApplication {
    name = "linkwarden-db-backup";
    runtimeInputs = with pkgs; [
      postgresql
      coreutils
      findutils
      curl # send_notification (service-lib) 용
    ];
    text = ''
      # shellcheck source=/dev/null
      source "$PUSHOVER_CRED_FILE"
      # shellcheck source=/dev/null
      source "$SERVICE_LIB"

      TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
      BACKUP_FILE="$BACKUP_DIR/linkwarden-db-$TIMESTAMP.dump"
      TMP_FILE="$BACKUP_FILE.tmp"

      cleanup_on_error() {
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
          rm -f "$TMP_FILE"
          send_notification "Linkwarden DB Backup" \
            "백업 실패 (exit $exit_code). journalctl -u linkwarden-db-backup 확인 필요." 1
        fi
      }
      trap cleanup_on_error EXIT

      echo "=== Linkwarden PostgreSQL backup start: $(date -Iseconds) ==="

      # 1. 디스크 공간 검사 (1GB 미만이면 중단)
      AVAIL_KB=$(df --output=avail "$BACKUP_DIR" | tail -1)
      AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
      if [ "$AVAIL_GB" -lt 1 ]; then
        echo "ERROR: Disk space low (''${AVAIL_GB}GB available, need 1GB)" >&2
        send_notification "Linkwarden DB Backup" \
          "디스크 공간 부족 (''${AVAIL_GB}GB). 백업 중단." 1
        exit 1
      fi
      echo "Disk space OK: ''${AVAIL_GB}GB available"

      # 2. PostgreSQL 서비스 확인
      if ! systemctl is-active --quiet postgresql.service; then
        echo "ERROR: PostgreSQL service not running" >&2
        exit 1
      fi
      echo "PostgreSQL service running"

      # 3. pg_dump -Fc (NixOS native PostgreSQL, peer auth)
      echo "Running pg_dump..."
      sudo -u postgres pg_dump -Fc linkwarden > "$TMP_FILE"
      echo "pg_dump completed: $(stat -c%s "$TMP_FILE") bytes"

      # 4. 무결성 검증
      echo "Verifying backup integrity..."
      pg_restore --list "$TMP_FILE" > /dev/null
      echo "Integrity check passed"

      # 5. 최소 크기 검증 (5KB 이상)
      FILE_SIZE=$(stat -c%s "$TMP_FILE")
      if [ "$FILE_SIZE" -lt 5120 ]; then
        echo "ERROR: Backup too small (''${FILE_SIZE} bytes, minimum 5KB)" >&2
        exit 1
      fi

      # 6. 원자적 이동
      mv "$TMP_FILE" "$BACKUP_FILE"
      echo "Backup saved: $BACKUP_FILE ($(numfmt --to=iec "$FILE_SIZE"))"

      # 7. 보관 정리
      DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name "linkwarden-db-*.dump" -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
      if [ "$DELETED" -gt 0 ]; then
        echo "Cleaned up $DELETED old backups (>''${RETENTION_DAYS} days)"
      fi

      echo "=== Linkwarden PostgreSQL backup completed: $(date -Iseconds) ==="
    '';
  };
in
{
  config = lib.mkIf (cfg.enable && linkwardenCfg.enable) {
    # agenix 시크릿 (linkwarden-update와 동일 선언, NixOS 모듈 시스템이 merge)
    age.secrets.pushover-linkwarden = {
      file = ../../../../secrets/pushover-linkwarden.age;
      owner = "root";
      mode = "0400";
    };

    # 백업 서비스 (oneshot)
    systemd.services.linkwarden-db-backup = {
      description = "Linkwarden PostgreSQL backup (pg_dump -Fc → HDD)";
      after = [ "postgresql.service" ];
      wants = [ "postgresql.service" ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${backupScript}/bin/linkwarden-db-backup";
        TimeoutSec = "30m";
        # ProtectSystem=strict 불가 — sudo -u postgres pg_dump가
        # /run/postgresql/, /var/lib/postgresql/ 등 시스템 경로 접근 필요
        ReadWritePaths = [ backupDir ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        BACKUP_DIR = backupDir;
        RETENTION_DAYS = toString cfg.retentionDays;
      };
    };

    # 타이머 (매일 05:00)
    systemd.timers.linkwarden-db-backup = {
      description = "Daily Linkwarden PostgreSQL backup";
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
