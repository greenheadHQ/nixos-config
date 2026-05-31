# modules/nixos/programs/pushover-purge-reminder.nix
# Password manager backup archive 6개월 보관 만료 1회성 reminder
#
# 2026-12-01 09:00 KST에 oneshot이 발화하여 중립 경로의 backup archive 보관
# 만료를 Pushover로 알린다. 운영자가 manual integrity check 후 purge를 검토한다.
# (epic #780 — 셀프호스팅 비밀번호 관리자 서비스 EOL 시 백업을 중립
#  경로로 archive하고 6개월 후 정리 검토 알림. 메시지/경로에 특정 서비스 브랜드명을
#  남기지 않아 repo 잔존 게이트를 통과하도록 중립 표현(password-manager)을 쓴다.)
{
  config,
  pkgs,
  ...
}:

let
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../lib/service-lib.nix { inherit pkgs; };
  archivePath = "/mnt/data/backups/archives/password-manager-2026-06-01";

  purgeReminderScript = pkgs.writeShellApplication {
    name = "pushover-purge-reminder";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      : "''${PUSHOVER_CRED_FILE:?PUSHOVER_CRED_FILE is required}"
      : "''${SERVICE_LIB:?SERVICE_LIB is required}"
      : "''${ARCHIVE_PATH:?ARCHIVE_PATH is required}"

      # shellcheck source=/dev/null
      source "$SERVICE_LIB"

      # shellcheck source=/dev/null
      source "$PUSHOVER_CRED_FILE"
      if [ -z "''${PUSHOVER_TOKEN:-}" ] || [ -z "''${PUSHOVER_USER:-}" ]; then
        echo "ERROR: Pushover credentials empty" >&2
        exit 1
      fi

      title="Password manager backup archive 보관 만료"
      message="Password manager backup archive ($ARCHIVE_PATH) 6개월 보관 만료. manual integrity check 후 purge 검토."

      if send_notification_strict "$title" "$message" 0; then
        echo "Pushover purge reminder sent"
      else
        echo "WARNING: Pushover send failed" >&2
        exit 1
      fi
    '';
  };
in
{
  # pushover-system-monitor.age — temp-monitor/smartd/smoke-test/opnix-rotate와 동일 값 (NixOS 모듈 시스템이 merge).
  age.secrets.pushover-system-monitor = {
    file = ../../../secrets/pushover-system-monitor.age;
    mode = "0400";
    owner = "root";
  };

  systemd.services.pushover-purge-reminder = {
    description = "Backup archive 6개월 보관 만료 Pushover 알림 (1회성)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    # Pushover 자격 증명이 있어야 실행 (없으면 systemd가 skip).
    unitConfig.ConditionPathExists = [ pushoverCredPath ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${purgeReminderScript}/bin/pushover-purge-reminder";
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
      ARCHIVE_PATH = archivePath;
    };
  };

  systemd.timers.pushover-purge-reminder = {
    description = "Backup archive 6개월 보관 만료 reminder (2026-12-01 1회성)";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "2026-12-01 09:00:00 Asia/Seoul";
      Persistent = true; # 부팅 시 놓친 1회성 실행 보완
    };
  };
}
