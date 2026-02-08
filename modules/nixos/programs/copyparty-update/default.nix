# modules/nixos/programs/copyparty-update/default.nix
# Copyparty 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo copyparty-update 명령으로 안전한 업데이트 (pull → 재시작 → 헬스체크)
{
  config,
  pkgs,
  lib,

  ...
}:

let
  cfg = config.homeserver.copypartyUpdate;
  copypartyCfg = config.homeserver.copyparty;
  port = toString copypartyCfg.port;
  pushoverCredPath = config.age.secrets.pushover-copyparty.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  containerImage = config.virtualisation.oci-containers.containers.copyparty.image;

  versionCheckScript = pkgs.writeShellApplication {
    name = "copyparty-version-check";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      podman
    ];
    text = builtins.readFile ./files/version-check.sh;
  };

  updateScriptInner = pkgs.writeShellApplication {
    name = "copyparty-update-inner";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      podman
      systemd
    ];
    text = builtins.readFile ./files/update-script.sh;
  };

  updateScript = pkgs.writeShellScriptBin "copyparty-update" ''
    export PUSHOVER_CRED_FILE="${pushoverCredPath}"
    export SERVICE_LIB="${serviceLib}"
    export STATE_DIR="/var/lib/copyparty-update"
    export CONTAINER_NAME="copyparty"
    export CONTAINER_IMAGE="${containerImage}"
    export SERVICE_UNIT="podman-copyparty.service"
    export HEALTH_URL="http://127.0.0.1:${port}"
    export GITHUB_REPO="9001/copyparty"
    export SERVICE_DISPLAY_NAME="Copyparty"
    exec ${updateScriptInner}/bin/copyparty-update-inner "$@"
  '';
in
{
  config = lib.mkIf (cfg.enable && copypartyCfg.enable) {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿 (업데이트 모듈에 정의 — Pushover 전용이므로 응집도 높음)
    # age.identityPaths는 immich.nix에서 이미 정의되어 있으므로 중복 정의 금지
    # ═══════════════════════════════════════════════════════════════
    age.secrets.pushover-copyparty = {
      file = ../../../../secrets/pushover-copyparty.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 상태 디렉토리
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d /var/lib/copyparty-update 0700 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 버전 체크 서비스 (oneshot) — systemd hardening 적용
    # Tailscale 대기 불필요: localhost(podman) + 인터넷(GitHub/Pushover)만 사용
    # ═══════════════════════════════════════════════════════════════
    systemd.services.copyparty-version-check = {
      description = "Copyparty version check and notification";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [ pushoverCredPath ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${versionCheckScript}/bin/copyparty-version-check";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ "/var/lib/copyparty-update" ];
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        STATE_DIR = "/var/lib/copyparty-update";
        CONTAINER_NAME = "copyparty";
        CONTAINER_IMAGE = containerImage;
        GITHUB_REPO = "9001/copyparty";
        SERVICE_DISPLAY_NAME = "Copyparty";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 타이머 (매일 실행)
    # ═══════════════════════════════════════════════════════════════
    systemd.timers.copyparty-version-check = {
      description = "Daily Copyparty version check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.checkTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 수동 업데이트 스크립트 (sudo copyparty-update)
    # ═══════════════════════════════════════════════════════════════
    environment.systemPackages = [ updateScript ];
  };
}
