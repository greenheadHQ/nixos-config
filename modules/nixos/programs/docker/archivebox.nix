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

  syncAdminPasswordScript = pkgs.writeShellApplication {
    name = "archivebox-sync-admin-password";
    runtimeInputs = with pkgs; [
      coreutils
      podman
      ripgrep
    ];
    text = builtins.readFile ./archivebox/files/sync-admin-password.sh;
  };
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
    # admin 비밀번호 동기화 (컨테이너 시작 직후, drift 방지)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.archivebox-admin-password-sync = {
      description = "Sync ArchiveBox admin password from agenix secret";
      wantedBy = [ "podman-archivebox.service" ];
      wants = [ "podman-archivebox.service" ];
      after = [ "podman-archivebox.service" ];
      partOf = [ "podman-archivebox.service" ];

      unitConfig = {
        ConditionPathExists = adminPasswordPath;
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${syncAdminPasswordScript}/bin/archivebox-sync-admin-password";
        UMask = "0077";
        PrivateTmp = true;
        NoNewPrivileges = true;
      };

      environment = {
        CONTAINER_NAME = "archivebox";
        ADMIN_USERNAME = "admin";
        ADMIN_PASSWORD_FILE = adminPasswordPath;
        STARTUP_TIMEOUT_SEC = "60";
      };
    };

    # nrs/switch 시에도 실행 중 컨테이너 비밀번호를 즉시 동기화
    system.activationScripts.archivebox-admin-password-sync = lib.stringAfter [ "etc" ] ''
      if ${pkgs.systemd}/bin/systemctl is-active --quiet podman-archivebox.service; then
        ${pkgs.systemd}/bin/systemctl start archivebox-admin-password-sync.service || true
      fi
    '';

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
