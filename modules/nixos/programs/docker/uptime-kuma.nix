# modules/nixos/programs/docker/uptime-kuma.nix
# 모니터링 서비스
{
  config,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.uptimeKuma;
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
      ports = [ "127.0.0.1:${toString cfg.port}:3001" ];
      volumes = [ "${dockerData}/uptime-kuma/data:/app/data" ];
      environment = {
        TZ = config.time.timeZone;
      };
      extraOptions = [
        "--memory=${uptimeKuma.memory}"
        "--cpus=${uptimeKuma.cpus}"
      ];
    };

  };
}
