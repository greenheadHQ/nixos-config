# modules/nixos/programs/docker/uptime-kuma.nix
# 모니터링 서비스
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.uptimeKuma;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.paths) dockerData;
  inherit (constants.containers) uptimeKuma;
in
{
  config = lib.mkIf cfg.enable {
    # 데이터 디렉토리
    systemd.tmpfiles.rules = [
      "d ${dockerData}/uptime-kuma/data 0755 root root -"
    ];

    # Uptime Kuma 컨테이너 (포트 3002 - 기존 3001 충돌 방지)
    virtualisation.oci-containers.containers.uptime-kuma = {
      image = "louislam/uptime-kuma:1";
      autoStart = true;
      ports = [ "${minipcTailscaleIP}:${toString cfg.port}:3001" ];
      volumes = [ "${dockerData}/uptime-kuma/data:/app/data" ];
      environment = {
        TZ = "Asia/Seoul";
      };
      extraOptions = [
        "--memory=${uptimeKuma.memory}"
        "--cpus=${uptimeKuma.cpus}"
      ];
    };

    # Tailscale IP 바인딩을 위한 서비스 의존성
    systemd.services.podman-uptime-kuma = {
      after = [ "tailscaled.service" ];
      wants = [ "tailscaled.service" ];
      serviceConfig.ExecStartPre = import ../../lib/tailscale-wait.nix { inherit pkgs; };
    };

    # 방화벽
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
