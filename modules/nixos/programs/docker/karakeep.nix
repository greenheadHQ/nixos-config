# modules/nixos/programs/docker/karakeep.nix
# 웹 아카이버/북마크 관리 (3컨테이너: 앱 + Chrome + Meilisearch)
# SingleFile 브라우저 확장으로 push, Tailscale VPN 내부 전용
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.karakeep;
  notifyCfg = config.homeserver.karakeepNotify;
  inherit (constants.paths) mediaData;
  inherit (constants.containers) karakeep;
  inherit (constants.domain) base subdomains;

  nextauthSecretPath = config.age.secrets.karakeep-nextauth-secret.path;
  meiliMasterKeyPath = config.age.secrets.karakeep-meili-master-key.path;
  envFilePath = "/run/karakeep-env";

  # agenix 시크릿에서 환경변수 파일 생성
  envScript = pkgs.writeShellScript "karakeep-env-gen" ''
    set -euo pipefail
    NEXTAUTH_SECRET=$(cat ${nextauthSecretPath})
    MEILI_MASTER_KEY=$(cat ${meiliMasterKeyPath})
    printf 'NEXTAUTH_SECRET=%s\nMEILI_MASTER_KEY=%s\n' \
      "$NEXTAUTH_SECRET" "$MEILI_MASTER_KEY" > ${envFilePath}
    chmod 0400 ${envFilePath}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.karakeep-nextauth-secret = {
      file = ../../../../secrets/karakeep-nextauth-secret.age;
      owner = "root";
      mode = "0400";
    };
    age.secrets.karakeep-meili-master-key = {
      file = ../../../../secrets/karakeep-meili-master-key.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 데이터 디렉토리 (HDD 단일)
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${mediaData}/karakeep 0755 root root -"
      "d ${mediaData}/karakeep/meilisearch 0755 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 환경변수 파일 생성 서비스 (컨테이너 시작 전)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.karakeep-env = {
      description = "Generate Karakeep environment file from agenix secrets";
      wantedBy = [ "podman-karakeep.service" ];
      before = [ "podman-karakeep.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = envScript;
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # Podman 네트워크 생성
    # ═══════════════════════════════════════════════════════════════
    systemd.services.create-karakeep-network = {
      description = "Create Karakeep Podman network";
      after = [
        "podman.socket"
        "network-online.target"
      ];
      wants = [
        "podman.socket"
        "network-online.target"
      ];
      wantedBy = [ "multi-user.target" ];
      before = [
        "podman-karakeep.service"
        "podman-karakeep-chrome.service"
        "podman-karakeep-meilisearch.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.podman}/bin/podman network create karakeep-network --ignore";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # Karakeep 앱 컨테이너
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.karakeep = {
      image = "ghcr.io/karakeep-app/karakeep:release";
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.port}:3000" ];
      volumes = [ "${mediaData}/karakeep:/data" ];
      environmentFiles = [ envFilePath ];
      environment = {
        NEXTAUTH_URL = "https://${subdomains.karakeep}.${base}";
        MEILI_ADDR = "http://karakeep-meilisearch:7700";
        BROWSER_WEB_URL = "http://karakeep-chrome:9222";
        DATA_DIR = "/data";
        CRAWLER_FULL_PAGE_ARCHIVE = "false";
        CRAWLER_STORE_SCREENSHOT = "true";
        CRAWLER_VIDEO_DOWNLOAD = "false";
        MAX_ASSET_SIZE_MB = "100";
        INFERENCE_ENABLED = "false";
      }
      // lib.optionalAttrs notifyCfg.enable {
        # 사용자가 UI(Settings → Webhooks)에서 http://host.containers.internal:<port> 등록 시
        # SSRF 보호가 내부 IP를 차단하므로 이 hostname을 허용
        CRAWLER_ALLOWED_INTERNAL_HOSTNAMES = "host.containers.internal";
      };
      extraOptions = [
        "--network=karakeep-network"
        "--memory=${karakeep.app.memory}"
        "--memory-swap=${karakeep.app.memorySwap}"
        "--cpus=${karakeep.app.cpus}"
      ];
      dependsOn = [
        "karakeep-meilisearch"
        "karakeep-chrome"
      ];
    };

    # ═══════════════════════════════════════════════════════════════
    # Chrome 컨테이너 (스크린샷/크롤링용)
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.karakeep-chrome = {
      image = "gcr.io/zenika-hub/alpine-chrome:124";
      autoStart = true;
      cmd = [
        "chromium-browser"
        "--headless"
        "--no-sandbox"
        "--disable-gpu"
        "--disable-dev-shm-usage"
        "--remote-debugging-address=0.0.0.0"
        "--remote-debugging-port=9222"
      ];
      extraOptions = [
        "--network=karakeep-network"
        "--memory=${karakeep.chrome.memory}"
        "--memory-swap=${karakeep.chrome.memorySwap}"
        "--cpus=${karakeep.chrome.cpus}"
      ];
    };

    # ═══════════════════════════════════════════════════════════════
    # Meilisearch 컨테이너 (전문 검색)
    # ═══════════════════════════════════════════════════════════════
    virtualisation.oci-containers.containers.karakeep-meilisearch = {
      image = "getmeili/meilisearch:v1.13.3";
      autoStart = true;
      volumes = [ "${mediaData}/karakeep/meilisearch:/meili_data" ];
      environmentFiles = [ envFilePath ];
      environment = {
        MEILI_NO_ANALYTICS = "true";
      };
      extraOptions = [
        "--network=karakeep-network"
        "--memory=${karakeep.meilisearch.memory}"
        "--memory-swap=${karakeep.meilisearch.memorySwap}"
        "--cpus=${karakeep.meilisearch.cpus}"
      ];
    };

    # ═══════════════════════════════════════════════════════════════
    # systemd 의존성
    # ═══════════════════════════════════════════════════════════════
    systemd.services.podman-karakeep = {
      after = [
        "create-karakeep-network.service"
        "karakeep-env.service"
      ];
      wants = [
        "create-karakeep-network.service"
        "karakeep-env.service"
      ];
      unitConfig = {
        ConditionPathExists = nextauthSecretPath;
        RequiresMountsFor = mediaData;
      };
    };

    systemd.services.podman-karakeep-chrome = {
      after = [ "create-karakeep-network.service" ];
      wants = [ "create-karakeep-network.service" ];
    };

    systemd.services.podman-karakeep-meilisearch = {
      after = [
        "create-karakeep-network.service"
        "karakeep-env.service"
      ];
      wants = [
        "create-karakeep-network.service"
        "karakeep-env.service"
      ];
      unitConfig = {
        RequiresMountsFor = mediaData;
      };
    };
  };
}
