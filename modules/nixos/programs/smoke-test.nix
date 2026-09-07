# modules/nixos/programs/smoke-test.nix
# 홈서버 런타임 스모크 테스트 (curl 헬스체크 + 백업 신선도)
# systemd timer로 주기적 실행, 실패 시 Pushover 알림
#
# 패턴 참조: immich-backup.nix (service-lib.sh + Pushover)
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
  # headless Anki 백업 대상 인스턴스 — anki-host/backup.nix와 같은 필터(backup.enable). 활성일 때만 신선도 검사
  ankiBackupInstances = lib.optionals config.homeserver.ankiHost.enable (
    builtins.attrNames (
      lib.filterAttrs (_: inst: inst.backup.enable) config.homeserver.ankiHost.instances
    )
  );

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
    ++ lib.optionals config.homeserver.karakeep.enable [
      "${subdomains.karakeep}.${base}:307:/"
    ];

  smokeScript = pkgs.writeShellApplication {
    name = "homeserver-smoke-test";
    runtimeInputs = with pkgs; [
      curl
      coreutils
      findutils
      systemd # failed 유닛 검출(systemctl --failed)
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
      # -f 없음: 4xx/5xx에서도 실제 코드를 캡처하기 위해
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
        # || true: 디렉토리 미존재 시 find 비정상 종료 + pipefail 방지
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

      ${lib.concatMapStringsSep "\n" (name: ''
        # anki-host ${name}: 인스턴스 디렉터리에 anki-host-${name}-*.colpkg (일일, 04:15)
        LATEST_ANKI=$(find "$BACKUP_DIR/anki-host/${name}" -maxdepth 1 -name "anki-host-${name}-*.colpkg" \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)
        if [ -n "$LATEST_ANKI" ]; then
          AGE_HOURS=$(( ($(date +%s) - $(stat -c %Y "$LATEST_ANKI")) / 3600 ))
          RESULT=0
          [ "$AGE_HOURS" -le "$BACKUP_MAX_AGE" ] || RESULT=1
          check "Anki ${name} backup freshness (''${AGE_HOURS}h <= ''${BACKUP_MAX_AGE}h)" "$RESULT"
        else
          check "Anki ${name} backup exists" 1
        fi
      '') ankiBackupInstances}

      # ─── 3. 실패한 systemd 유닛 검출 ───
      # 알림 경로가 죽으면 유닛 실패가 아무 데도 통보되지 않는다 — 2026-08-16~25
      # interaction-limits-renewal이 매일 실패했으나 그 실패를 알릴 curl이 없어 10일간
      # 묻혔다. 매일 도는 이 smoke-test가 failed 유닛을 훑어 그 침묵을 덮는다.
      # 유닛마다 OnFailure=를 다는 대신 여기 한 곳에 둔 이유: OnFailure가 호출할 알림
      # 유닛도 같은 종류의 의존(curl)을 필요로 해 같은 결함을 재생산하고, 새 유닛이
      # 생길 때마다 배선이 필요하다. 이 검사 하나는 신규 유닛까지 자동으로 덮는다.
      # 범위: 시스템 유닛 한정 — --user를 쓰지 않으므로 시스템 매니저만 조회한다
      # (스코프를 정하는 것은 실행 사용자가 아니라 --system/--user 플래그이고 전자가 기본값).
      # --plain은 행 앞의 상태 마커(실패 유닛에 붙는 ●) 열을 제거해 첫 필드가 유닛명이
      # 되게 한다 — 빼면 cut -f1이 유닛명 대신 ●를 뽑아 보고에 유닛명이 사라진다.
      # 조회 성공 여부를 먼저 보존한다: systemctl이 매니저와 통신하지 못하면 빈 출력으로
      # 끝나는데, 그것을 "실패 유닛 없음"으로 읽으면 이 검사가 덮으려는 침묵을 그대로
      # 재현한다("확인 못 함"과 "이상 없음"은 다르다). stderr도 버리지 않는다 — 이번
      # 사고의 근본 원인 메시지가 2>/dev/null에 삼켜져 진단이 늦어졌다.
      if FAILED_RAW=$(systemctl --failed --no-legend --plain); then
        FAILED_UNITS=$(printf '%s' "$FAILED_RAW" | cut -d' ' -f1 | tr '\n' ' ')
        RESULT=0
        [ -z "$FAILED_UNITS" ] || RESULT=1
        check "No failed systemd units (''${FAILED_UNITS:-none})" "$RESULT"
      else
        QUERY_RC=$?
        check "systemd failed-unit query (systemctl rc=''${QUERY_RC})" 1
      fi

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
