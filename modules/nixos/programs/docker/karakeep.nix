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
  openaiKeyPath = config.age.secrets.karakeep-openai-key.path;
  sharedEnvFilePath = "/run/karakeep-env";
  openaiEnvFilePath = "/run/karakeep-openai-env";

  # 암호문의 개별 store path — 재시작 트리거용. 위 *Path(런타임 복호화 경로 /run/agenix/...)와
  # 달리 .age 내용이 바뀌면 값이 바뀐다. 문자열 보간이 필수다: .file을 path 값 그대로 리스트에
  # 넣으면 toString 경로를 타서 flake source 전체(/nix/store/<hash>-source/secrets/...)에
  # 결합되고, 무관한 커밋마다 재시작이 발생한다. "${...}"는 그 파일 하나를 개별 store 객체로
  # 복사해 암호문 내용에만 의존한다 (실측 확인).
  nextauthCiphertext = "${config.age.secrets.karakeep-nextauth-secret.file}";
  meiliCiphertext = "${config.age.secrets.karakeep-meili-master-key.file}";
  openaiSecretCiphertext = "${config.age.secrets.karakeep-openai-key.file}";

  # agenix 시크릿에서 공통 환경변수 파일 생성 (karakeep + meilisearch)
  sharedEnvScript = pkgs.writeShellScript "karakeep-env-gen" ''
    set -euo pipefail
    NEXTAUTH_SECRET=$(cat ${nextauthSecretPath})
    MEILI_MASTER_KEY=$(cat ${meiliMasterKeyPath})
    printf 'NEXTAUTH_SECRET=%s\nMEILI_MASTER_KEY=%s\n' \
      "$NEXTAUTH_SECRET" "$MEILI_MASTER_KEY" > ${sharedEnvFilePath}
    chmod 0400 ${sharedEnvFilePath}
  '';

  # agenix 시크릿에서 OpenAI 전용 환경변수 파일 생성 (karakeep only)
  openaiEnvScript = pkgs.writeShellScript "karakeep-openai-env-gen" ''
    set -euo pipefail
    OPENAI_API_KEY_RAW=$(cat ${openaiKeyPath})
    case "$OPENAI_API_KEY_RAW" in
      OPENAI_API_KEY=*)
        OPENAI_API_KEY="''${OPENAI_API_KEY_RAW#OPENAI_API_KEY=}"
        ;;
      *)
        OPENAI_API_KEY="$OPENAI_API_KEY_RAW"
        ;;
    esac
    printf 'OPENAI_API_KEY=%s\n' "$OPENAI_API_KEY" > ${openaiEnvFilePath}
    chmod 0400 ${openaiEnvFilePath}
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
    age.secrets.karakeep-openai-key = {
      file = ../../../../secrets/karakeep-openai-key.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 데이터 디렉토리 (HDD 단일)
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${mediaData}/karakeep 0755 root root -"
      "d ${mediaData}/karakeep/meilisearch 0755 root root -"
      "d ${mediaData}/archive-fallback 0755 root root -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # 환경변수 파일 생성 서비스 (컨테이너 시작 전)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.karakeep-env = {
      description = "Generate Karakeep shared environment file from agenix secrets";
      wantedBy = [ "podman-karakeep.service" ];
      before = [ "podman-karakeep.service" ];
      # 생성 스크립트는 시크릿의 런타임 '경로'만 담으므로 .age를 재암호화해도 store path가
      # 그대로다. 암호문을 트리거로 걸어야 시크릿 교체가 env 파일 재생성으로 이어진다.
      # 이 파일에는 두 시크릿이 모두 쓰이므로 둘 다 건다.
      restartTriggers = [
        nextauthCiphertext
        meiliCiphertext
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = sharedEnvScript;
        RemainAfterExit = true;
        UMask = "0077";
      };
    };

    systemd.services.karakeep-openai-env = {
      description = "Generate Karakeep OpenAI environment file from agenix secrets";
      wantedBy = [ "podman-karakeep.service" ];
      before = [ "podman-karakeep.service" ];
      # karakeep-env와 동일한 계약 — 암호문 변경이 env 파일 재생성으로 이어진다.
      restartTriggers = [ openaiSecretCiphertext ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = openaiEnvScript;
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
      image = "ghcr.io/karakeep-app/karakeep:0.31.0";
      autoStart = true;
      ports = [ "127.0.0.1:${toString cfg.port}:3000" ];
      volumes = [ "${mediaData}/karakeep:/data" ];
      environmentFiles = [
        sharedEnvFilePath
        openaiEnvFilePath
      ];
      environment = {
        NEXTAUTH_URL = "https://${subdomains.karakeep}.${base}";
        MEILI_ADDR = "http://karakeep-meilisearch:7700";
        BROWSER_WEB_URL = "http://karakeep-chrome:9222";
        DATA_DIR = "/data";
        CRAWLER_FULL_PAGE_ARCHIVE = "false";
        CRAWLER_STORE_SCREENSHOT = "true";
        CRAWLER_VIDEO_DOWNLOAD = "false";
        CRAWLER_NUM_WORKERS = "2";
        CRAWLER_JOB_TIMEOUT_SEC = "180";
        CRAWLER_SCREENSHOT_TIMEOUT_SEC = "30";
        # SingleFile 브리지가 대용량 파일을 /api/v1/assets + fullPageArchive로 우회 연결하므로
        # 자산 업로드 자체는 100MB 허용, 파싱 OOM 경로는 브리지 임계값(기본 50MB)으로 제어한다.
        MAX_ASSET_SIZE_MB = "100";
        INFERENCE_LANG = "korean";
        INFERENCE_ENABLE_AUTO_SUMMARIZATION = "true";
        NODE_OPTIONS = "--max-old-space-size=1536";
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
      environmentFiles = [ sharedEnvFilePath ];
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
        "karakeep-openai-env.service"
      ];
      wants = [
        "create-karakeep-network.service"
        "karakeep-env.service"
        "karakeep-openai-env.service"
      ];
      # env 파일 내용은 컨테이너 유닛에 들어가지 않고 경로만 들어간다. 소비하는 두 env 파일의
      # 원천 암호문을 모두 트리거로 걸어야 시크릿 교체가 컨테이너 재시작으로 이어진다
      # (env 파일은 시작 시점에만 읽힌다). 생성 유닛에만 걸면 파일만 갱신되고 프로세스는 옛 값을 유지한다.
      restartTriggers = [
        nextauthCiphertext
        meiliCiphertext
        openaiSecretCiphertext
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
      # shared env 파일에서 실제 사용하는 credential은 MEILI_MASTER_KEY뿐이므로 그 암호문만
      # 트리거로 건다 — nextauth 교체로 검색 서비스가 재시작될 이유가 없다.
      # karakeep-chrome은 environmentFiles가 없어 트리거 대상이 아니다.
      restartTriggers = [ meiliCiphertext ];
      unitConfig = {
        RequiresMountsFor = mediaData;
      };
    };
  };
}
