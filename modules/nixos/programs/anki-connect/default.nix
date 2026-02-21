# modules/nixos/programs/anki-connect/default.nix
# Headless Anki + AnkiConnect API 서버
# QT_QPA_PLATFORM=offscreen으로 GUI 없이 실행
#
# 인증: Tailscale 네트워크 레벨 격리에 의존 (API key 불필요)
# withAddons + withConfig → 설정이 Nix store에 bake됨 (immutable)
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.ankiConnect;
  inherit (constants.network) minipcTailscaleIP;

  ankiWithConnect = pkgs.anki.withAddons [
    (pkgs.ankiAddons.anki-connect.withConfig {
      config = {
        webBindAddress = minipcTailscaleIP;
        webBindPort = cfg.port;
        webCorsOriginList = [
          "http://localhost"
          "http://localhost:3000"
          "http://localhost:5173"
          "http://${minipcTailscaleIP}"
        ];
      };
    })
  ];
in
{
  config = lib.mkIf cfg.enable {
    # 시스템 사용자
    users.users.anki = {
      isSystemUser = true;
      group = "anki";
      home = "/var/lib/anki";
    };
    users.groups.anki = { };

    # systemd 서비스
    systemd.services.anki-connect = {
      description = "Headless Anki with AnkiConnect API";
      after = [
        "tailscaled.service"
        "network.target"
      ];
      wants = [ "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        QT_QPA_PLATFORM = "offscreen";
        HOME = "/var/lib/anki";
        XDG_DATA_HOME = "/var/lib/anki/.local/share";
        XDG_CONFIG_HOME = "/var/lib/anki/.config";
      };

      serviceConfig = {
        Type = "simple";
        User = "anki";
        Group = "anki";
        StateDirectory = "anki";

        # Tailscale IP 할당 대기 → 프로필 디렉터리 보장 → Anki 실행
        ExecStartPre = [
          ("+" + (import ../../lib/tailscale-wait.nix { inherit pkgs; }))
          (
            "+"
            + pkgs.writeShellScript "anki-ensure-profile" ''
              profile_dir="/var/lib/anki/.local/share/Anki2/${cfg.profile}"
              if [ ! -d "$profile_dir" ]; then
                mkdir -p "$profile_dir"
                chown -R anki:anki /var/lib/anki/.local/share/Anki2
              fi
            ''
          )
        ];
        ExecStart = "${ankiWithConnect}/bin/anki -p ${cfg.profile}";

        Restart = "on-failure";
        RestartSec = 10;
        MemoryMax = "512M";

        # 보안 강화
        NoNewPrivileges = true;
        ProtectHome = true;
        PrivateTmp = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };
  };
}
