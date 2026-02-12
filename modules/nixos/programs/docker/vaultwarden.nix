# modules/nixos/programs/docker/vaultwarden.nix
# 셀프호스팅 비밀번호 관리자 (Bitwarden 호환)
# Tailscale VPN 내부 전용, Caddy HTTPS 리버스 프록시 뒤에서 동작
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.vaultwarden;
  inherit (constants.paths) dockerData;
  inherit (constants.containers) vaultwarden;
  inherit (constants.domain) base subdomains;

  adminTokenPath = config.age.secrets.vaultwarden-admin-token.path;
  # podman-vaultwarden의 RuntimeDirectory(/run/vaultwarden)와 분리해
  # 서비스 재시작 시 파일이 지워지지 않도록 별도 경로 사용
  envFilePath = "/run/vaultwarden-env";

  # agenix 시크릿에서 환경변수 파일 생성 (caddy-env 패턴)
  envScript = pkgs.writeShellScript "vaultwarden-env-gen" ''
    ADMIN_TOKEN=$(cat ${adminTokenPath})
    printf 'ADMIN_TOKEN=%s\n' "$ADMIN_TOKEN" > ${envFilePath}
    chmod 0400 ${envFilePath}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.vaultwarden-admin-token = {
      file = ../../../../secrets/vaultwarden-admin-token.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 데이터 디렉토리 (SSD, 비밀번호 저장소이므로 0700)
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${dockerData}/vaultwarden 0700 root root -"
      "d ${dockerData}/vaultwarden/data 0700 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 환경변수 파일 생성 서비스 (컨테이너 시작 전, tmpfs에 작성)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.vaultwarden-env = {
      description = "Generate Vaultwarden environment file with admin token";
      wantedBy = [ "podman-vaultwarden.service" ];
      before = [ "podman-vaultwarden.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = envScript;
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # Vaultwarden 컨테이너
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.vaultwarden = {
      image = "vaultwarden/server:1.35.2";
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.port}:80" ];
      volumes = [
        "${dockerData}/vaultwarden/data:/data"
      ];
      environmentFiles = [ envFilePath ];
      environment = {
        TZ = config.time.timeZone;
        DOMAIN = "https://${subdomains.vaultwarden}.${base}";
        SIGNUPS_ALLOWED = "false";
        INVITATIONS_ALLOWED = "false";
        SHOW_PASSWORD_HINT = "false";
        LOGIN_RATELIMIT = "5/60";
        ADMIN_RATELIMIT = "3/60";
        ROCKET_PORT = "80";
      };
      extraOptions = [
        "--memory=${vaultwarden.memory}"
        "--cpus=${vaultwarden.cpus}"
        "--health-cmd=curl -sf http://localhost:80/alive || exit 1"
        "--health-interval=60s"
        "--health-start-period=30s"
        "--health-retries=3"
      ];
    };

    # 시크릿 존재 확인 (런타임 생성 env 파일보다 안정적)
    systemd.services.podman-vaultwarden = {
      unitConfig = {
        ConditionPathExists = adminTokenPath;
      };
    };
  };
}
