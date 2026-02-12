# modules/nixos/programs/anki-sync-server/default.nix
# Anki 자체 호스팅 동기화 서버 (NixOS 네이티브 모듈 래핑)
{
  config,
  pkgs,
  lib,
  constants,
  username,
  ...
}:

let
  cfg = config.homeserver.ankiSync;
  inherit (constants.network) minipcTailscaleIP;
in
{
  imports = [ ./backup.nix ];

  config = lib.mkIf cfg.enable {
    # agenix 시크릿
    age.secrets.anki-sync-password = {
      file = ../../../../secrets/anki-sync-password.age;
      mode = "0400";
      owner = "root";
    };

    # NixOS 네이티브 anki-sync-server 설정
    services.anki-sync-server = {
      enable = true;
      address = minipcTailscaleIP;
      port = cfg.port;
      openFirewall = false; # trustedInterfaces로 tailscale0 전체 허용

      users = [
        {
          username = username;
          passwordFile = config.age.secrets.anki-sync-password.path;
        }
      ];
    };

    # Tailscale 대기 + 리소스 제한
    systemd.services.anki-sync-server = {
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig = {
        # "+" prefix: DynamicUser=true 환경에서도 root로 실행하여
        # tailscaled 소켓 접근 보장
        ExecStartPre = "+" + (import ../../lib/tailscale-wait.nix { inherit pkgs; });
        MemoryMax = "256M";
      };
    };

  };
}
