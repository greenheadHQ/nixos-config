# modules/nixos/programs/uptime-kuma-update/default.nix
# Uptime Kuma 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo uptime-kuma-update 명령으로 안전한 업데이트 (backup → pull → 재시작 → 헬스체크)
{
  config,
  pkgs,
  lib,
  constants,

  ...
}:

let
  cfg = config.homeserver.uptimeKumaUpdate;
  kumaCfg = config.homeserver.uptimeKuma;
  port = toString kumaCfg.port;
  pushoverCredPath = config.age.secrets.pushover-uptime-kuma.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };
  inherit (constants.paths) dockerData;

  containerImage = config.virtualisation.oci-containers.containers.uptime-kuma.image;

  versionCheckScript = pkgs.writeShellApplication {
    name = "uptime-kuma-version-check";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      podman
    ];
    text = builtins.readFile ./files/version-check.sh;
  };

  updateScriptInner = pkgs.writeShellApplication {
    name = "uptime-kuma-update-inner";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
      gzip
      podman
      systemd
      findutils
    ];
    text = builtins.readFile ./files/update-script.sh;
  };

  updateScript = pkgs.writeShellScriptBin "uptime-kuma-update" ''
    export PUSHOVER_CRED_FILE="${pushoverCredPath}"
    export SERVICE_LIB="${serviceLib}"
    export STATE_DIR="/var/lib/uptime-kuma-update"
    export BACKUP_DIR="/var/lib/uptime-kuma-update/backups"
    export CONTAINER_NAME="uptime-kuma"
    export CONTAINER_IMAGE="${containerImage}"
    export SERVICE_UNIT="podman-uptime-kuma.service"
    export HEALTH_URL="http://127.0.0.1:${port}"
    export DATA_DIR="${dockerData}/uptime-kuma/data"
    export GITHUB_REPO="louislam/uptime-kuma"
    export SERVICE_DISPLAY_NAME="Uptime Kuma"
    exec ${updateScriptInner}/bin/uptime-kuma-update-inner "$@"
  '';
in
{
  config = lib.mkIf (cfg.enable && kumaCfg.enable) {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿 (업데이트 모듈에 정의 — Pushover 전용이므로 응집도 높음)
    # age.identityPaths는 immich.nix에서 이미 정의되어 있으므로 중복 정의 금지
    # ═══════════════════════════════════════════════════════════════
    age.secrets.pushover-uptime-kuma = {
      file = ../../../../secrets/pushover-uptime-kuma.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 상태 디렉토리
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d /var/lib/uptime-kuma-update 0700 root root -"
      "d /var/lib/uptime-kuma-update/backups 0700 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 버전 체크 서비스 (oneshot) — systemd hardening 적용
    # Tailscale 대기 불필요: localhost(podman) + 인터넷(GitHub/Pushover)만 사용
    # ═══════════════════════════════════════════════════════════════
    systemd.services.uptime-kuma-version-check = {
      description = "Uptime Kuma version check and notification";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [ pushoverCredPath ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${versionCheckScript}/bin/uptime-kuma-version-check";

        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ "/var/lib/uptime-kuma-update" ];
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
        STATE_DIR = "/var/lib/uptime-kuma-update";
        CONTAINER_NAME = "uptime-kuma";
        CONTAINER_IMAGE = containerImage;
        GITHUB_REPO = "louislam/uptime-kuma";
        SERVICE_DISPLAY_NAME = "Uptime Kuma";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 타이머 (매일 실행)
    # ═══════════════════════════════════════════════════════════════
    systemd.timers.uptime-kuma-version-check = {
      description = "Daily Uptime Kuma version check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.checkTime;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 수동 업데이트 스크립트 (sudo uptime-kuma-update)
    # ═══════════════════════════════════════════════════════════════
    environment.systemPackages = [ updateScript ];
  };
}
