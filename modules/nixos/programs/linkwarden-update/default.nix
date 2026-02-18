# modules/nixos/programs/linkwarden-update/default.nix
# Linkwarden 버전 체크 (자동) — NixOS 네이티브 서비스 패턴
# 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# 업데이트: nix flake update + nrs (수동)
# mk-update-module.nix 미사용: 컨테이너 전용 팩토리이므로 별도 구현
{
  config,
  pkgs,
  lib,
  ...
}:

let
  cfg = config.homeserver.linkwardenUpdate;
  linkwardenCfg = config.homeserver.linkwarden;
  pushoverCredPath = config.age.secrets.pushover-linkwarden.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  stateDir = "/var/lib/linkwarden-update";

  versionCheckScript = pkgs.writeShellApplication {
    name = "linkwarden-version-check";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
    text = builtins.readFile ./files/version-check.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && linkwardenCfg.enable) {
    # agenix 시크릿 (linkwarden-backup과 동일 선언, NixOS 모듈 시스템이 merge)
    age.secrets.pushover-linkwarden = {
      file = ../../../../secrets/pushover-linkwarden.age;
      owner = "root";
      mode = "0400";
    };

    # 상태 디렉토리
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
    ];

    # 버전 체크 서비스 (oneshot)
    systemd.services.linkwarden-version-check = {
      description = "Linkwarden version check and notification";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [ pushoverCredPath ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${versionCheckScript}/bin/linkwarden-version-check";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ stateDir ];
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        STATE_DIR = stateDir;
        GITHUB_REPO = "linkwarden/linkwarden";
        SERVICE_DISPLAY_NAME = "Linkwarden";
        CURRENT_VERSION = pkgs.linkwarden.version;
      };
    };

    # 타이머 (매일 06:00)
    systemd.timers.linkwarden-version-check = {
      description = "Daily Linkwarden version check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.checkTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
