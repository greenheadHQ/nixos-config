# modules/nixos/programs/temp-monitor/default.nix
# lm-sensors 온도 모니터링 + Pushover 알림
# CPU Package + NVMe Composite 온도를 5분마다 체크
# 임계값 초과 시 단계별(경고/위험) Pushover 알림 발송
{
  config,
  pkgs,
  constants,
  ...
}:

let
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };
  stateDir = "/var/lib/temp-monitor";
  tc = constants.tempMonitor;

  checkTempScript = pkgs.writeShellApplication {
    name = "temp-monitor-check";
    runtimeInputs = with pkgs; [
      lm_sensors
      jq
      curl
      coreutils
    ];
    text = builtins.readFile ./files/check-temp.sh;
  };
in
{
  # agenix 시크릿 독립 정의 (smartd.nix와 동일 값 — NixOS 모듈 시스템이 merge)
  age.secrets.pushover-system-monitor = {
    file = ../../../../secrets/pushover-system-monitor.age;
    mode = "0400";
    owner = "root";
  };

  systemd.tmpfiles.rules = [ "d ${stateDir} 0700 root root -" ];

  systemd.services.temp-monitor = {
    description = "Hardware temperature monitoring with Pushover alerts";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    unitConfig.ConditionPathExists = [ pushoverCredPath ];

    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${checkTempScript}/bin/temp-monitor-check";
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      NoNewPrivileges = true;
      ProtectKernelTunables = true; # sysfs read-only — sensors는 읽기만. 검증 후 문제 시 제거.
      ProtectControlGroups = true;
      ReadWritePaths = [ stateDir ];
    };

    environment = {
      PUSHOVER_CRED_FILE = pushoverCredPath;
      SERVICE_LIB = "${serviceLib}";
      STATE_DIR = stateDir;
      CPU_WARN = toString tc.cpu.warning;
      CPU_CRIT = toString tc.cpu.critical;
      NVME_WARN = toString tc.nvme.warning;
      NVME_CRIT = toString tc.nvme.critical;
      COOLDOWN_WARNING = toString tc.cooldown.warning;
      COOLDOWN_CRITICAL = toString tc.cooldown.critical;
    };
  };

  systemd.timers.temp-monitor = {
    description = "Periodic hardware temperature check";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
      RandomizedDelaySec = "30s";
    };
  };
}
