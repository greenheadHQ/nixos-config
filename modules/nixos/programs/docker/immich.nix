# modules/nixos/programs/docker/immich.nix
# 사진 백업 서비스
{ config, pkgs, ... }:

let
  # ⚠️ IP 변경 시 docker/*.nix 모든 파일 수정 필요
  tailscaleIP = "100.79.80.95";
  dockerDataPath = "/var/lib/docker-data";
  mediaDataPath = "/mnt/data";
in
{
  # 데이터 디렉토리
  # ⚠️ 권한 중요: PostgreSQL은 UID 999, Immich Server/Upload는 UID 1000으로 실행
  systemd.tmpfiles.rules = [
    "d ${dockerDataPath}/immich/postgres 0755 999 999 -" # postgres UID
    "d ${dockerDataPath}/immich/ml-cache 0755 root root -"
    "d ${dockerDataPath}/immich/upload-cache 0755 1000 1000 -" # 업로드 캐시
    "d ${mediaDataPath}/immich/photos 0755 1000 1000 -" # ⚠️ 1000:1000 필수!
  ];

  # 네트워크 생성 서비스
  systemd.services.create-immich-network = {
    description = "Create Immich Docker network";
    after = [
      "podman.socket"
      "network-online.target"
      "tailscaled.service"
    ];
    wants = [
      "podman.socket"
      "tailscaled.service"
      "network-online.target"
    ];
    wantedBy = [ "multi-user.target" ];
    before = [
      "podman-immich-postgres.service"
      "podman-immich-redis.service"
      "podman-immich-ml.service"
      "podman-immich-server.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Tailscale IP 할당 완료까지 대기 (최대 60초)
      ExecStartPre = "${pkgs.bash}/bin/bash -c 'for i in $(seq 1 60); do ${pkgs.tailscale}/bin/tailscale ip -4 2>/dev/null | grep -q \"^100\\.\" && exit 0; sleep 1; done; echo \"Tailscale IP not ready after 60s\" >&2; exit 1'";
      ExecStart = "${pkgs.podman}/bin/podman network create immich-network --ignore";
    };
  };

  # PostgreSQL
  virtualisation.oci-containers.containers.immich-postgres = {
    image = "tensorchord/pgvecto-rs:pg16-v0.2.0";
    autoStart = true;
    volumes = [ "${dockerDataPath}/immich/postgres:/var/lib/postgresql/data" ];
    environment = {
      POSTGRES_USER = "immich";
      POSTGRES_PASSWORD = "immich"; # TODO: secrets로 이동
      POSTGRES_DB = "immich";
    };
    extraOptions = [
      "--network=immich-network"
      "--health-cmd=pg_isready -U immich -d immich"
      "--health-interval=30s"
      "--health-start-period=30s"
      "--memory=1g"
    ];
  };

  # Redis (Job Queue/캐싱 전용 - 영속성 불필요, 공식 Immich 설정과 동일)
  virtualisation.oci-containers.containers.immich-redis = {
    image = "redis:7-alpine";
    autoStart = true;
    extraOptions = [
      "--network=immich-network"
      "--health-cmd=redis-cli ping"
      "--health-interval=30s"
      "--memory=512m"
    ];
  };

  # Machine Learning (CPU 버전 - 안정성 우선)
  virtualisation.oci-containers.containers.immich-ml = {
    image = "ghcr.io/immich-app/immich-machine-learning:release";
    autoStart = true;
    volumes = [ "${dockerDataPath}/immich/ml-cache:/cache" ];
    environment = {
      TZ = "Asia/Seoul";
    };
    extraOptions = [
      "--network=immich-network"
      "--memory=2g"
      "--memory-swap=3g"
      "--cpus=2"
    ];
  };

  # Immich Server
  # 💡 프로덕션에서는 버전 고정 권장: ghcr.io/immich-app/immich-server:v1.94.1
  virtualisation.oci-containers.containers.immich-server = {
    image = "ghcr.io/immich-app/immich-server:release";
    autoStart = true;
    ports = [ "${tailscaleIP}:2283:2283" ];
    volumes = [
      "${mediaDataPath}/immich/photos:/usr/src/app/upload"
      "${dockerDataPath}/immich/upload-cache:/usr/src/app/upload/upload"
      "/etc/localtime:/etc/localtime:ro"
    ];
    environment = {
      TZ = "Asia/Seoul";
      DB_HOSTNAME = "immich-postgres";
      DB_USERNAME = "immich";
      DB_PASSWORD = "immich";
      DB_DATABASE_NAME = "immich";
      REDIS_HOSTNAME = "immich-redis";
      IMMICH_MACHINE_LEARNING_URL = "http://immich-ml:3003";
    };
    dependsOn = [
      "immich-postgres"
      "immich-redis"
      "immich-ml"
    ];
    extraOptions = [
      "--network=immich-network"
      "--memory=4g"
      "--memory-swap=6g"
      "--device=/dev/dri:/dev/dri" # 비디오 트랜스코딩 하드웨어 가속
      "--group-add=303" # render 그룹
    ];
  };

  # 방화벽
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 2283 ];
}
