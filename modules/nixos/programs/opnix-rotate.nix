# modules/nixos/programs/opnix-rotate.nix
# 1Password SA token 90일 rotation 알림 (PRD #780 Phase 3, FR-6 / NFR-4)
#
# weekly oneshot이 /etc/opnix-service-account-expiry(opnix stub이 배포한 평문 record)를 읽어
# 만료 14일 이하면 Pushover 알림을 보낸다. 만료일은 평문 record이므로 op CLI 의존이 없다.
# (1Password Individual은 SA 자동 만료를 미지원 → 90일 cadence를 정책으로 운용, Phase 1 발견.)
# timer는 homeserver.opnix.enable에 게이팅된다.
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.homeserver.opnix;
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../lib/service-lib.nix { inherit pkgs; };
  expiryFile = "/etc/opnix-service-account-expiry";
  warnDays = 14; # NFR-4: 90일 cadence, 만료 14일 전부터 알림

  rotateCheckScript = pkgs.writeShellApplication {
    name = "opnix-rotate-check";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      # 환경변수 검증
      : "''${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
      : "''${SERVICE_LIB:?SERVICE_LIB is required}"
      : "''${EXPIRY_FILE:?EXPIRY_FILE is required}"
      : "''${WARN_DAYS:?WARN_DAYS is required}"

      # shellcheck source=/dev/null
      source "$SERVICE_LIB"

      # 만료 record 부재/비가독 → non-fatal (stub 미배포 등). 알림 없이 종료.
      if [ ! -r "$EXPIRY_FILE" ]; then
        echo "WARNING: expiry record $EXPIRY_FILE not readable — skipping" >&2
        exit 0
      fi

      expiry_date="$(cat "$EXPIRY_FILE")"
      # ISO-8601 (YYYY-MM-DD)만 허용 — 형식 오류 시 non-fatal.
      if ! [[ "$expiry_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "WARNING: invalid expiry date format: '$expiry_date' — skipping" >&2
        exit 0
      fi

      if ! expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null)"; then
        echo "ERROR: cannot parse expiry date '$expiry_date'" >&2
        exit 1
      fi
      now_epoch="$(date +%s)"
      days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      echo "SA token expiry: $expiry_date ($days_left days left)"

      # 여유 충분 → silent (weekly 빈도가 사실상 cooldown 역할)
      if [ "$days_left" -gt "$WARN_DAYS" ]; then
        exit 0
      fi

      # shellcheck source=/dev/null
      source "$PUSHOVER_CRED_FILE"
      if [ -z "''${PUSHOVER_TOKEN:-}" ] || [ -z "''${PUSHOVER_USER:-}" ]; then
        echo "ERROR: Pushover credentials empty" >&2
        exit 1
      fi

      title="1Password SA token rotation needed"
      rotate_steps="1Password GUI에서 Service Account 토큰 재발급 → secrets/opnix-service-account-token.age re-encrypt → nrs minipc → opnix-secrets.service 재시작 검증."
      if [ "$days_left" -lt 0 ]; then
        message="SA token이 $expiry_date에 만료됨 ($(( -days_left ))일 경과). $rotate_steps"
        priority=1
      else
        message="SA token이 $expiry_date에 만료 예정 ($days_left일 남음). $rotate_steps"
        priority=0
      fi

      if send_notification_strict "$title" "$message" "$priority"; then
        echo "Pushover rotation alert sent ($days_left days left)"
      else
        echo "WARNING: Pushover send failed" >&2
      fi
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # pushover-system-monitor.age — temp-monitor/smartd/smoke-test와 동일 값 (NixOS 모듈 시스템이 merge).
    age.secrets.pushover-system-monitor = {
      file = ../../../secrets/pushover-system-monitor.age;
      mode = "0400";
      owner = "root";
    };

    systemd.services.opnix-rotate-check = {
      description = "1Password SA token expiry check with Pushover alert";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      # 만료 record와 Pushover 자격 증명이 모두 있어야 실행 (없으면 systemd가 skip).
      unitConfig.ConditionPathExists = [
        expiryFile
        pushoverCredPath
      ];

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${rotateCheckScript}/bin/opnix-rotate-check";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        EXPIRY_FILE = expiryFile;
        WARN_DAYS = toString warnDays;
      };
    };

    systemd.timers.opnix-rotate-check = {
      description = "Weekly 1Password SA token expiry check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "weekly";
        Persistent = true; # 부팅 시 놓친 실행 보완
        RandomizedDelaySec = "1h";
      };
    };
  };
}
