# modules/nixos/programs/docker/archivebox.nix
# 웹 아카이버 (headless Chromium + SingleFile로 완전한 단일 HTML 생성)
# Tailscale VPN 내부 전용, Caddy HTTPS 리버스 프록시 뒤에서 동작
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.archiveBox;
  inherit (constants.paths) dockerData mediaData;
  inherit (constants.containers) archiveBox;
  inherit (constants.domain) base subdomains;

  adminPasswordPath = config.age.secrets.archivebox-admin-password.path;
  envFilePath = "/run/archivebox-env";

  # agenix 시크릿에서 환경변수 파일 생성 (vaultwarden-env 패턴)
  envScript = pkgs.writeShellScript "archivebox-env-gen" ''
    ADMIN_PASSWORD=$(cat ${adminPasswordPath})
    printf 'ADMIN_PASSWORD=%s\n' "$ADMIN_PASSWORD" > ${envFilePath}
    chmod 0400 ${envFilePath}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.archivebox-admin-password = {
      file = ../../../../secrets/archivebox-admin-password.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 데이터 디렉토리 (SSD: DB/config, HDD: 아카이브 파일)
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${dockerData}/archivebox 0755 root root -"
      "d ${dockerData}/archivebox/data 0755 root root -"
      "d ${mediaData}/archivebox 0755 root root -"
      "d ${mediaData}/archivebox/archive 0755 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 환경변수 파일 생성 서비스 (컨테이너 시작 전)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.archivebox-env = {
      description = "Generate ArchiveBox environment file with admin password";
      wantedBy = [ "podman-archivebox.service" ];
      before = [ "podman-archivebox.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = envScript;
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # ArchiveBox 컨테이너
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.archivebox = {
      image = "archivebox/archivebox:0.7.3";
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.port}:8000" ];
      volumes = [
        "${dockerData}/archivebox/data:/data"
        "${mediaData}/archivebox/archive:/data/archive"
      ];
      environmentFiles = [ envFilePath ];
      environment = {
        TZ = config.time.timeZone;
        SEARCH_BACKEND_ENGINE = "sqlite";
        ADMIN_USERNAME = "admin";
        PUBLIC_INDEX = "False";
        PUBLIC_SNAPSHOTS = "False";
        PUBLIC_ADD_VIEW = "False";
        SAVE_ARCHIVE_DOT_ORG = "False";
        MEDIA_MAX_SIZE = "750m";
      };
      extraOptions = [
        "--memory=${archiveBox.memory}"
        "--memory-swap=${archiveBox.memorySwap}"
        "--cpus=${archiveBox.cpus}"
      ];
    };

    # HDD 마운트 확인 + 시크릿 존재 확인
    systemd.services.podman-archivebox = {
      unitConfig = {
        ConditionPathExists = adminPasswordPath;
        RequiresMountsFor = mediaData;
      };
    };
  };
}
