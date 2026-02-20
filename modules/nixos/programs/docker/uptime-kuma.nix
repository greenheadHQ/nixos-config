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

    # Uptime Kuma 컨테이너
    # --network=host: localhost 서비스 모니터링을 위해 호스트 네트워크 사용
    virtualisation.oci-containers.containers.uptime-kuma = {
      # Rolling tag: uptime-kuma-update 스크립트가 이미지 digest로 버전 관리.
      # 새 환경 구성 시 현재 운영 버전과 다를 수 있음 (재현성 trade-off)
      image = "louislam/uptime-kuma:2";
      autoStart = true;
      volumes = [ "${dockerData}/uptime-kuma/data:/app/data" ];
      environment = {
        TZ = config.time.timeZone;
        UPTIME_KUMA_HOST = "127.0.0.1";
        UPTIME_KUMA_PORT = toString cfg.port;
      };
      extraOptions = [
        "--network=host"
        "--memory=${uptimeKuma.memory}"
        "--cpus=${uptimeKuma.cpus}"
      ];
    };

  };
}
