# modules/nixos/programs/immich-cleanup/default.nix
# Immich 임시 앨범 자동 정리 (Claude Code Temp)
# 모바일 SSH에서 Claude Code로 전달한 이미지를 일정 기간 후 자동 삭제
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.immichCleanup;
  immichCfg = config.homeserver.immich;
  inherit (constants.network) minipcTailscaleIP;

  immichUrl = "http://${minipcTailscaleIP}:${toString immichCfg.port}";
  apiKeyPath = config.age.secrets.immich-api-key.path;

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
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.immich-api-key = {
      file = ../../../../secrets/immich-api-key.age;
      mode = "0400";
      owner = "root";
    };

    # ═══════════════════════════════════════════════════════════════
    # systemd 서비스
    # ═══════════════════════════════════════════════════════════════
    systemd.services.immich-cleanup = {
      description = "Immich temp album cleanup (${cfg.albumName})";
      after = [
        "network-online.target"
        "tailscaled.service"
      ];
      wants = [ "network-online.target" ];

      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = import ../../lib/tailscale-wait.nix { inherit pkgs; };
        ExecStart = "${cleanupScript}/bin/immich-cleanup";
        ConditionPathExists = apiKeyPath;

        # 환경변수
        Environment = [
          "IMMICH_URL=${immichUrl}"
          "API_KEY_FILE=${apiKeyPath}"
          "ALBUM_NAME=${cfg.albumName}"
          "RETENTION_DAYS=${toString cfg.retentionDays}"
        ];
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # systemd 타이머 (매일 03:00 실행)
    # ═══════════════════════════════════════════════════════════════
    systemd.timers.immich-cleanup = {
      description = "Daily Immich temp album cleanup";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = "*-*-* 03:00:00";
        Persistent = true; # 부팅 시 놓친 실행 보완
        RandomizedDelaySec = "5m"; # 정확히 같은 시간에 실행 방지
      };
    };
  };
}
