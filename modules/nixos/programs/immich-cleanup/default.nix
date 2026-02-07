# modules/nixos/programs/immich-cleanup/default.nix
# Immich 임시 앨범 자동 정리 (Claude Code Temp)
# 모바일 SSH에서 Claude Code로 전달한 임시 이미지를 매일 전체 삭제
{
  config,
  pkgs,
  lib,

  ...
}:

let
  cfg = config.homeserver.immichCleanup;
  immichCfg = config.homeserver.immich;
  immichUrl = "http://127.0.0.1:${toString immichCfg.port}";
  apiKeyPath = config.age.secrets.immich-api-key.path;
  pushoverCredPath = config.age.secrets.pushover-immich.path;

  cleanupScript = pkgs.writeShellApplication {
    name = "immich-cleanup";
    runtimeInputs = with pkgs; [
      curl
      jq
      coreutils
    ];
    text = builtins.readFile ./files/cleanup-script.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && immichCfg.enable) {
    # ═══════════════════════════════════════════════════════════════
    # systemd 서비스
    # 시크릿(immich-api-key, pushover-immich)은 immich.nix에서 정의
    # ═══════════════════════════════════════════════════════════════
    systemd.services.immich-cleanup = {
      description = "Immich temp album cleanup (${cfg.albumName})";
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
        ExecStart = "${cleanupScript}/bin/immich-cleanup";
      };

      # 환경변수 (공백 포함 값은 따옴표 필요)
      environment = {
        IMMICH_URL = immichUrl;
        API_KEY_FILE = apiKeyPath;
        ALBUM_NAME = cfg.albumName;
        PUSHOVER_CRED_FILE = pushoverCredPath;
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # systemd 타이머 (매일 07:00 KST 실행)
    # ═══════════════════════════════════════════════════════════════
    systemd.timers.immich-cleanup = {
      description = "Daily Immich temp album cleanup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "*-*-* 07:00:00";
        Persistent = true; # 부팅 시 놓친 실행 보완
        RandomizedDelaySec = "5m"; # 정확히 같은 시간에 실행 방지
      };
    };
  };
}
