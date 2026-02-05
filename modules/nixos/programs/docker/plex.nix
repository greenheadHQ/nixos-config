# modules/nixos/programs/docker/plex.nix
# 미디어 스트리밍
{
  config,
  pkgs,
  lib,
  username,
  constants,
  ...
}:

let
  cfg = config.homeserver.plex;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.paths) dockerData mediaData;
  inherit (constants.ids) user users;
  inherit (constants.containers) plex;
in
{
  config = lib.mkIf cfg.enable {
    # 데이터 디렉토리
    systemd.tmpfiles.rules = [
      "d ${dockerData}/plex/config 0755 ${username} users -"
      "d ${mediaData}/plex/media/movies 0755 ${username} users -"
      "d ${mediaData}/plex/media/tv 0755 ${username} users -"
    ];

    # Plex 컨테이너
    virtualisation.oci-containers.containers.plex = {
      image = "plexinc/pms-docker:latest";
      autoStart = true;
      ports = [ "${minipcTailscaleIP}:${toString cfg.port}:32400/tcp" ];
      volumes = [
        "${dockerData}/plex/config:/config"
        "${mediaData}/plex/media:/data"
        "${mediaData}/homeserver-data/media:/legacy-media:ro"
        "/tmp/plex-transcode:/transcode"
      ];
      environment = {
        TZ = config.time.timeZone;
        PLEX_UID = toString user;
        PLEX_GID = toString users;
      };
      extraOptions = [
        "--memory=${plex.memory}"
        "--cpus=${plex.cpus}"
      ];
    };

    # Tailscale IP 바인딩을 위한 서비스 의존성
    systemd.services.podman-plex = {
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig.ExecStartPre = import ../../lib/tailscale-wait.nix { inherit pkgs; };
    };

    # 방화벽
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
