# modules/nixos/programs/docker/immich.nix
# 사진 백업 서비스
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.immich;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.paths) dockerData mediaData;
  inherit (constants.ids) postgres user render;
  inherit (constants.containers.immich) redis ml server;
  postgresRes = constants.containers.immich.postgres;

  dbPasswordPath = config.age.secrets.immich-db-password.path;
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿 (NixOS 시스템 레벨)
    # ═══════════════════════════════════════════════════════════════
    # secrets/secrets.nix는 사용자 SSH 키로 암호화되어 있으므로
    # 사용자 SSH 비밀키 경로를 명시해야 복호화 가능
    age.identityPaths = [ "/home/greenhead/.ssh/id_ed25519" ];

    age.secrets.immich-db-password = {
      file = ../../../../secrets/immich-db-password.age;
      mode = "0400";
      owner = "root";
    };

    # 시크릿 파일 존재 확인 (agenix activation 이후 존재)
    systemd.services.podman-immich-postgres.serviceConfig = {
      ConditionPathExists = dbPasswordPath;
    };
    systemd.services.podman-immich-server.serviceConfig = {
      ConditionPathExists = dbPasswordPath;
    };

    # ═══════════════════════════════════════════════════════════════
    # 데이터 디렉토리
    # ═══════════════════════════════════════════════════════════════
    # 권한: PostgreSQL은 UID 999, Immich Server/Upload는 UID 1000으로 실행
    systemd.tmpfiles.rules = [
      "d ${dockerData}/immich/postgres 0755 ${toString postgres} ${toString postgres} -"
      "d ${dockerData}/immich/ml-cache 0755 root root -"
      "d ${dockerData}/immich/upload-cache 0755 ${toString user} ${toString user} -"
      "d ${mediaData}/immich/photos 0755 ${toString user} ${toString user} -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 네트워크 생성 서비스
    # ═══════════════════════════════════════════════════════════════
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
        ExecStartPre = import ../../lib/tailscale-wait.nix { inherit pkgs; };
        ExecStart = "${pkgs.podman}/bin/podman network create immich-network --ignore";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # PostgreSQL (pgvecto-rs)
    # ═══════════════════════════════════════════════════════════════
    # POSTGRES_PASSWORD_FILE: docker-entrypoint.sh가 지원하는 표준 기능
    # 시크릿 파일을 볼륨 마운트하여 컨테이너 내부에서 읽음
    virtualisation.oci-containers.containers.immich-postgres = {
      image = "tensorchord/pgvecto-rs:pg16-v0.2.0";
      autoStart = true;
      volumes = [
        "${dockerData}/immich/postgres:/var/lib/postgresql/data"
        "${dbPasswordPath}:/run/secrets/db-password:ro"
      ];
      environment = {
        POSTGRES_USER = "immich";
        POSTGRES_PASSWORD_FILE = "/run/secrets/db-password";
        POSTGRES_DB = "immich";
      };
      extraOptions = [
        "--network=immich-network"
        "--health-cmd=pg_isready -U immich -d immich"
        "--health-interval=30s"
        "--health-start-period=30s"
        "--memory=${postgresRes.memory}"
      ];
    };

    # ═══════════════════════════════════════════════════════════════
    # Redis (Job Queue/캐싱 전용 - 영속성 불필요)
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.immich-redis = {
      image = "redis:7-alpine";
      autoStart = true;
      extraOptions = [
        "--network=immich-network"
        "--health-cmd=redis-cli ping"
        "--health-interval=30s"
        "--memory=${redis.memory}"
      ];
    };

    # ═══════════════════════════════════════════════════════════════
    # Machine Learning (CPU 버전 - 안정성 우선)
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.immich-ml = {
      image = "ghcr.io/immich-app/immich-machine-learning:release";
      autoStart = true;
      volumes = [ "${dockerData}/immich/ml-cache:/cache" ];
      environment = {
        TZ = config.time.timeZone;
      };
      extraOptions = [
        "--network=immich-network"
        "--memory=${ml.memory}"
        "--memory-swap=${ml.memorySwap}"
        "--cpus=${ml.cpus}"
      ];
    };

    # ═══════════════════════════════════════════════════════════════
    # Immich Server
    # ═══════════════════════════════════════════════════════════════
    # DB_PASSWORD_FILE: Immich 공식 지원 환경변수
    # 시크릿 파일을 볼륨 마운트하여 컨테이너 내부에서 읽음
    virtualisation.oci-containers.containers.immich-server = {
      image = "ghcr.io/immich-app/immich-server:release";
      autoStart = true;
      ports = [ "${minipcTailscaleIP}:${toString cfg.port}:2283" ];
      volumes = [
        "${mediaData}/immich/photos:/usr/src/app/upload"
        "${dockerData}/immich/upload-cache:/usr/src/app/upload/upload"
        "/etc/localtime:/etc/localtime:ro"
        "${dbPasswordPath}:/run/secrets/db-password:ro"
      ];
      environment = {
        TZ = config.time.timeZone;
        DB_HOSTNAME = "immich-postgres";
        DB_USERNAME = "immich";
        DB_PASSWORD_FILE = "/run/secrets/db-password";
        DB_DATABASE_NAME = "immich";
        REDIS_HOSTNAME = "immich-redis";
        IMMICH_MACHINE_LEARNING_URL = "http://immich-ml:${toString constants.network.ports.immichMl}";
      };
      dependsOn = [
        "immich-postgres"
        "immich-redis"
        "immich-ml"
      ];
      extraOptions = [
        "--network=immich-network"
        "--memory=${server.memory}"
        "--memory-swap=${server.memorySwap}"
        "--device=/dev/dri:/dev/dri" # 비디오 트랜스코딩 하드웨어 가속
        # NixOS render 그룹 GID (하드웨어 가속, /dev/dri 접근)
        "--group-add=${toString render}"
      ];
    };

    # 방화벽
    networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ cfg.port ];
  };
}
