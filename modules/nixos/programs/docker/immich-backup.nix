# modules/nixos/programs/docker/immich-backup.nix
# Immich PostgreSQL 매일 백업 (컨테이너 내부 pg_dump → HDD)
# vaultwarden-backup.nix 패턴 기반, service-lib.sh로 Pushover 알림
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
    ];
    text = ''
      # service-lib.sh 로드 (send_notification 사용)
      # shellcheck source=/dev/null
      source "$PUSHOVER_CRED_FILE"
      # shellcheck source=/dev/null
      source "$SERVICE_LIB"

      # BACKUP_DIR, RETENTION_DAYS는 systemd environment에서 주입됨
      TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
      BACKUP_FILE="$BACKUP_DIR/immich-db-$TIMESTAMP.dump"
      TMP_FILE="$BACKUP_FILE.tmp"

      # 에러 핸들러: 실패 시 Pushover 알림 + 임시 파일 정리
      cleanup_on_error() {
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
          rm -f "$TMP_FILE"
          send_notification "Immich DB Backup" \
            "백업 실패 (exit $exit_code). journalctl -u immich-db-backup 확인 필요." 1
        fi
      }
      trap cleanup_on_error EXIT

      echo "=== Immich PostgreSQL backup start: $(date -Iseconds) ==="

      # 1. 디스크 공간 검사 (5GB 미만이면 중단)
      AVAIL_KB=$(df --output=avail "$BACKUP_DIR" | tail -1)
      AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
      if [ "$AVAIL_GB" -lt 5 ]; then
        echo "ERROR: Disk space low (''${AVAIL_GB}GB available, need 5GB)" >&2
        send_notification "Immich DB Backup" \
          "디스크 공간 부족 (''${AVAIL_GB}GB). 백업 중단." 1
        exit 1
      fi
      echo "Disk space OK: ''${AVAIL_GB}GB available"

      # 2. PostgreSQL 컨테이너 실행 확인
      PG_STATE=$(podman inspect --format '{{.State.Status}}' immich-postgres 2>/dev/null || echo "not_found")
      if [ "$PG_STATE" != "running" ]; then
        echo "ERROR: immich-postgres container not running (state: $PG_STATE)" >&2
        exit 1
      fi
      echo "PostgreSQL container running"

      # 3. pg_dump -Fc (커스텀 포맷, 내장 압축)
      echo "Running pg_dump..."
      podman exec immich-postgres pg_dump -Fc -U immich immich > "$TMP_FILE"
      echo "pg_dump completed: $(stat -c%s "$TMP_FILE") bytes"

      # 4. 무결성 검증 (pg_restore --list: TOC 파싱만, 데이터 복원 없음)
      echo "Verifying backup integrity..."
      podman exec -i immich-postgres pg_restore --list < "$TMP_FILE" > /dev/null
      echo "Integrity check passed"

      # 5. 최소 크기 검증 (10KB 이상)
      FILE_SIZE=$(stat -c%s "$TMP_FILE")
      if [ "$FILE_SIZE" -lt 10240 ]; then
        echo "ERROR: Backup too small (''${FILE_SIZE} bytes, minimum 10KB)" >&2
        exit 1
      fi

      # 6. 원자적 이동 (정전 시 불완전 파일 방지)
      mv "$TMP_FILE" "$BACKUP_FILE"
      echo "Backup saved: $BACKUP_FILE ($(numfmt --to=iec "$FILE_SIZE"))"

      # 7. 보관 정리 (retentionDays 초과 백업 삭제)
      DELETED=$(find "$BACKUP_DIR" -maxdepth 1 -name "immich-db-*.dump" -mtime +"$RETENTION_DAYS" -print -delete | wc -l)
      if [ "$DELETED" -gt 0 ]; then
        echo "Cleaned up $DELETED old backups (>''${RETENTION_DAYS} days)"
      fi

      # 성공 시 trap에서 exit 0이므로 알림 안 감
      echo "=== Immich PostgreSQL backup completed: $(date -Iseconds) ==="
    '';
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
        # /run/podman/ 등 다수의 시스템 경로에 접근 필요. vaultwarden-backup은 sqlite3만
        # 사용하므로 strict 가능하지만, podman exec는 컨테이너 런타임 전체 접근 필요.
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

    # 타이머 (매일 05:30 KST -- vaultwarden backup 04:30과 1시간 간격)
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
