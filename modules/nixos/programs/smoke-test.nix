# modules/nixos/programs/smoke-test.nix
# 홈서버 런타임 스모크 테스트 (curl 헬스체크 + 백업 신선도)
# systemd timer로 주기적 실행, 실패 시 Pushover 알림
#
# 패턴 참조: immich-backup.nix, vaultwarden-backup.nix (service-lib.sh + Pushover)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.smokeTest;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.domain) base subdomains;
  inherit (constants.paths) mediaData;

  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../lib/service-lib.nix { inherit pkgs; };

  # 활성 서비스만 헬스체크 (비활성 서비스 false positive 방지)
  # 형식: "DOMAIN:EXPECTED_CODE:PATH"
  endpoints =
    lib.optionals config.homeserver.immich.enable [
      "${subdomains.immich}.${base}:200:/"
    ]
    ++ lib.optionals config.homeserver.uptimeKuma.enable [
      "${subdomains.uptimeKuma}.${base}:302:/"
    ]
    ++ lib.optionals config.homeserver.copyparty.enable [
      "${subdomains.copyparty}.${base}:200:/"
    ]
    ++ lib.optionals config.homeserver.vaultwarden.enable [
      "${subdomains.vaultwarden}.${base}:200:/alive"
    ]
    ++ lib.optionals config.homeserver.karakeep.enable [
      "${subdomains.karakeep}.${base}:307:/"
    ]
    ++ lib.optionals config.homeserver.awesomeAnki.enable [
      "${subdomains.awesomeAnki}.${base}:200:/"
    ];

  smokeScript = pkgs.writeShellApplication {
    name = "homeserver-smoke-test";
    runtimeInputs = with pkgs; [
      curl
      coreutils
      findutils
    ];
    text = ''
      # shellcheck source=/dev/null
      source "$PUSHOVER_CRED_FILE"
      # shellcheck source=/dev/null
      source "$SERVICE_LIB"

      # Pushover credential 검증 (smartd.nix, check-temp.sh와 동일 패턴)
      if [ -z "''${PUSHOVER_TOKEN:-}" ] || [ -z "''${PUSHOVER_USER:-}" ]; then
        echo "ERROR: PUSHOVER_TOKEN or PUSHOVER_USER empty" >&2
        exit 1
      fi

      # 예기치 않은 크래시 시 Pushover 알림 (모니터링 서비스는 자체 장애를 보고해야 함)
      trap_on_error() {
        local exit_code=$?
        if [ $exit_code -ne 0 ]; then
          send_notification "Smoke Test" \
            "스크립트 크래시 (exit $exit_code). journalctl -u homeserver-smoke-test 확인 필요." 1
        fi
      }
      trap trap_on_error EXIT

      FAILURES=""
      CHECKS=0
      PASSED=0

      check() {
        local name="$1"
        local result="$2"
        CHECKS=$((CHECKS + 1))
        if [ "$result" -eq 0 ]; then
          PASSED=$((PASSED + 1))
          echo "OK: $name"
        else
          FAILURES="''${FAILURES}  - ''${name}"$'\n'
          echo "FAIL: $name"
        fi
      }

      # ─── 1. Caddy 핵심 엔드포인트 헬스체크 ───
      # Tailscale IP + SNI로 직접 접근, DNS 불필요
      # -s: silent, -o /dev/null: body 버림, -w: HTTP 코드만 추출
      # -f 없음: 4xx/5xx에서도 실제 코드를 캡처하기 위해 (DA #3)
      for endpoint in $ENDPOINT_LIST; do
        DOMAIN="''${endpoint%%:*}"
        REST="''${endpoint#*:}"
        EXPECTED_CODE="''${REST%%:*}"
        PATH_SUFFIX="''${REST#*:}"
        HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
          --resolve "''${DOMAIN}:443:''${TAILSCALE_IP}" \
          --max-time 10 \
          "https://''${DOMAIN}''${PATH_SUFFIX}" 2>/dev/null) || HTTP_CODE="000"
        RESULT=0
        [ "$HTTP_CODE" = "$EXPECTED_CODE" ] || RESULT=1
        check "HTTP ''${DOMAIN}''${PATH_SUFFIX} = ''${EXPECTED_CODE} (got ''${HTTP_CODE})" "$RESULT"
      done

      # ─── 2. 백업 신선도 검증 (활성 백업만, 비활성 서비스 false positive 방지) ───
      BACKUP_DIR="${mediaData}/backups"

      ${lib.optionalString config.homeserver.immichBackup.enable ''
        # immich: flat directory에 immich-db-*.dump 파일
        # || true: 디렉토리 미존재 시 find 비정상 종료 + pipefail 방지 (DA #1)
        LATEST_IMMICH=$(find "$BACKUP_DIR/immich" -maxdepth 1 -name "immich-db-*.dump" \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
        if [ -n "$LATEST_IMMICH" ]; then
          AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_IMMICH")) / 3600 ))
          RESULT=0
          [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
          check "Immich backup freshness (''${AGE_HOURS}h <= ''${BACKUP_MAX_AGE}h)" "$RESULT"
        else
          check "Immich backup exists" 1
        fi
      ''}

      ${lib.optionalString config.homeserver.vaultwarden.enable ''
        # vaultwarden: 날짜별 디렉토리의 db.sqlite3.gz
        LATEST_VW_DIR=$(find "$BACKUP_DIR/vaultwarden" -maxdepth 1 -type d -name "20*" \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
        if [ -n "$LATEST_VW_DIR" ] && [ -f "$LATEST_VW_DIR/db.sqlite3.gz" ]; then
          AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_VW_DIR/db.sqlite3.gz")) / 3600 ))
          RESULT=0
          [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
          check "Vaultwarden backup freshness (''${AGE_HOURS}h <= ''${BACKUP_MAX_AGE}h)" "$RESULT"
        else
          check "Vaultwarden backup exists" 1
        fi
      ''}

      ${lib.optionalString config.homeserver.karakeepBackup.enable ''
        # karakeep: 날짜별 디렉토리의 db.db.gz
        LATEST_KK_DIR=$(find "$BACKUP_DIR/karakeep" -maxdepth 1 -type d -name "20*" \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
        if [ -n "$LATEST_KK_DIR" ] && [ -f "$LATEST_KK_DIR/db.db.gz" ]; then
          AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_KK_DIR/db.db.gz")) / 3600 ))
          RESULT=0
          [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
          check "Karakeep backup freshness (''${AGE_HOURS}h <= ''${BACKUP_MAX_AGE}h)" "$RESULT"
        else
          check "Karakeep backup exists" 1
        fi
      ''}

      # ─── 결과 요약 + Pushover ───
      echo "=== Smoke test: ''${PASSED}/''${CHECKS} passed ==="
      if [ -n "$FAILURES" ]; then
        send_notification "Smoke Test" \
          "$(printf '%s/%s passed\n%s' "$PASSED" "$CHECKS" "$FAILURES")" 0
      fi
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # Pushover 시크릿 (smartd, temp-monitor와 공유 — 모듈 시스템이 merge)
    age.secrets.pushover-system-monitor = {
      file = ../../../secrets/pushover-system-monitor.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.homeserver-smoke-test = {
      description = "Homeserver runtime smoke test (healthcheck + backup freshness)";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "oneshot";
        TimeoutSec = "120";
        ExecStart = "${smokeScript}/bin/homeserver-smoke-test";
        ProtectSystem = "strict";
        ReadOnlyPaths = [ "${mediaData}/backups" ];
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        TAILSCALE_IP = minipcTailscaleIP;
        BACKUP_MAX_AGE = toString cfg.backupMaxAgeHours;
        ENDPOINT_LIST = builtins.concatStringsSep " " endpoints;
      };
    };

    systemd.timers.homeserver-smoke-test = {
      description = "Daily homeserver smoke test";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.timerInterval;
        RandomizedDelaySec = "5m";
        Persistent = true;
      };
    };
  };
}
