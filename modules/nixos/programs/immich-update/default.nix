# modules/nixos/programs/immich-update/default.nix
# Immich 버전 체크 (자동) 및 업데이트 (수동) 자동화
# - 매일 GitHub Releases API로 최신 버전 확인 → Pushover 알림
# - sudo immich-update 명령으로 안전한 업데이트 (DB 백업 → pull → 재시작 → 헬스체크)
{
  config,
  pkgs,
  lib,

  ...
}:

let
  cfg = config.homeserver.immichUpdate;
  immichCfg = config.homeserver.immich;
  immichUrl = "http://127.0.0.1:${toString immichCfg.port}";
  apiKeyPath = config.age.secrets.immich-api-key.path;
  pushoverCredPath = config.age.secrets.pushover-immich.path;

  versionCheckScript = pkgs.writeShellApplication {
    name = "immich-version-check";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
    text = builtins.readFile ./files/version-check.sh;
  };

  # 업데이트 스크립트 본체 (writeShellApplication으로 runtimeInputs 보장)
  updateScriptInner = pkgs.writeShellApplication {
    name = "immich-update-inner";
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

  # 래퍼: 환경변수 설정 후 본체 실행 (standalone 실행용)
  updateScript = pkgs.writeShellScriptBin "immich-update" ''
    export IMMICH_URL="${immichUrl}"
    export API_KEY_FILE="${apiKeyPath}"
    export PUSHOVER_CRED_FILE="${pushoverCredPath}"
    export BACKUP_DIR="/var/lib/immich-update/backups"
    exec ${updateScriptInner}/bin/immich-update-inner "$@"
  '';
in
{
  config = lib.mkIf (cfg.enable && immichCfg.enable) {
    # ═══════════════════════════════════════════════════════════════
    # 상태 디렉토리
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d /var/lib/immich-update 0700 root root -"
      "d /var/lib/immich-update/backups 0700 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 버전 체크 서비스 (oneshot) — systemd hardening 적용
    # ═══════════════════════════════════════════════════════════════
    systemd.services.immich-version-check = {
      description = "Immich version check and notification";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [
          apiKeyPath
          pushoverCredPath
        ];
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = import ../../lib/tailscale-wait.nix { inherit pkgs; };
        ExecStart = "${versionCheckScript}/bin/immich-version-check";

        # systemd hardening (읽기 전용 + 네트워크만 필요)
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ReadWritePaths = [ "/var/lib/immich-update" ];
      };

      # 환경변수 (immich-cleanup 패턴과 동일)
      environment = {
        IMMICH_URL = immichUrl;
        API_KEY_FILE = apiKeyPath;
        PUSHOVER_CRED_FILE = pushoverCredPath;
        STATE_DIR = "/var/lib/immich-update";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 타이머 (매일 실행)
    # ═══════════════════════════════════════════════════════════════
    systemd.timers.immich-version-check = {
      description = "Daily Immich version check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.checkTime;
        Persistent = true; # 부팅 시 놓친 실행 보완
        RandomizedDelaySec = "5m"; # immich-cleanup과 통일
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # 수동 업데이트 스크립트 (sudo immich-update)
    # ═══════════════════════════════════════════════════════════════
    environment.systemPackages = [ updateScript ];
  };
}
