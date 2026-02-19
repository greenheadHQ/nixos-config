# modules/nixos/programs/docker/karakeep-notify.nix
# Karakeep 웹훅 → Pushover 알림 브리지
# socat TCP 리스너가 Karakeep 웹훅을 수신하여 Pushover로 전달
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.karakeepNotify;
  karakeepCfg = config.homeserver.karakeep;

  pushoverCredPath = config.age.secrets.pushover-karakeep.path;
  serviceLib = import ../../lib/service-lib.nix { inherit pkgs; };

  webhookBridgeScript = pkgs.writeShellApplication {
    name = "karakeep-webhook-bridge";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      curl
      gnused
    ];
    text = builtins.readFile ./karakeep-notify/files/webhook-bridge.sh;
  };
in
{
  config = lib.mkIf (cfg.enable && karakeepCfg.enable) {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.pushover-karakeep = {
      file = ../../../../secrets/pushover-karakeep.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 방화벽: Podman 브릿지에서 웹훅 포트 허용
    # ═══════════════════════════════════════════════════════════════
    networking.firewall.extraCommands = ''
      iptables -I nixos-fw 1 -i podman+ -p tcp --dport ${toString cfg.webhookPort} -j nixos-fw-accept
    '';
    networking.firewall.extraStopCommands = ''
      iptables -D nixos-fw -i podman+ -p tcp --dport ${toString cfg.webhookPort} -j nixos-fw-accept 2>/dev/null || true
    '';

    # ═══════════════════════════════════════════════════════════════
    # 웹훅 브리지 서비스 (socat TCP 리스너)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.karakeep-webhook-bridge = {
      description = "Karakeep webhook-to-Pushover bridge";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        ConditionPathExists = pushoverCredPath;
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString cfg.webhookPort},reuseaddr,fork EXEC:${webhookBridgeScript}/bin/karakeep-webhook-bridge";
        Restart = "on-failure";
        RestartSec = "5s";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        PUSHOVER_CRED_FILE = pushoverCredPath;
        SERVICE_LIB = "${serviceLib}";
      };
    };
  };
}
