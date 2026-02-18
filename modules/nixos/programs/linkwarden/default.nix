# modules/nixos/programs/linkwarden/default.nix
# Linkwarden 셀프호스팅 북마크 매니저 + 웹 아카이버 (NixOS 네이티브 모듈 래핑)
# Meilisearch 풀텍스트 검색 + PostgreSQL (database.createLocally) + Caddy HTTPS
{
  config,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.linkwarden;
  meilisearchCfg = config.homeserver.meilisearch;
  inherit (constants.paths) mediaData;
  inherit (constants.domain) base subdomains;

  archiveDir = "${mediaData}/linkwarden/archives";
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.linkwarden-nextauth-secret = {
      file = ../../../../secrets/linkwarden-nextauth-secret.age;
      owner = "linkwarden";
      mode = "0400";
    };

    age.secrets.meilisearch-master-key = lib.mkIf meilisearchCfg.enable {
      file = ../../../../secrets/meilisearch-master-key.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 아카이브 디렉토리 (HDD)
    # ═══════════════════════════════════════════════════════════════
    systemd.tmpfiles.rules = [
      "d ${archiveDir} 0750 linkwarden linkwarden -"
    ];

    # ═══════════════════════════════════════════════════════════════
    # Meilisearch (풀텍스트 검색 엔진)
    # ═══════════════════════════════════════════════════════════════
    services.meilisearch = lib.mkIf meilisearchCfg.enable {
      enable = true;
      listenAddress = "127.0.0.1";
      listenPort = meilisearchCfg.port;
      settings.no_analytics = true;
      masterKeyFile = config.age.secrets.meilisearch-master-key.path;
    };

    # ═══════════════════════════════════════════════════════════════
    # Linkwarden (NixOS 네이티브 서비스)
    # ═══════════════════════════════════════════════════════════════
    services.linkwarden = {
      enable = true;
      host = "localhost";
      port = cfg.port;
      openFirewall = false;

      # Archive 파일 → HDD (스크린샷, PDF, HTML 등)
      storageLocation = archiveDir;

      enableRegistration = false;

      database.createLocally = true;
      database.name = "linkwarden";

      # 시크릿: LoadCredential로 안전하게 전달
      secretFiles = {
        NEXTAUTH_SECRET = config.age.secrets.linkwarden-nextauth-secret.path;
      }
      // lib.optionalAttrs meilisearchCfg.enable {
        MEILI_MASTER_KEY = config.age.secrets.meilisearch-master-key.path;
      };

      environment = {
        NEXTAUTH_URL = "https://${subdomains.linkwarden}.${base}/api/v1/auth";
      }
      // lib.optionalAttrs meilisearchCfg.enable {
        MEILI_HOST = "http://127.0.0.1:${toString meilisearchCfg.port}";
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # systemd 오버라이드: Meilisearch 의존성 + HDD 마운트 보장
    # ═══════════════════════════════════════════════════════════════
    systemd.services.linkwarden = {
      unitConfig.RequiresMountsFor = mediaData;
    }
    // lib.optionalAttrs meilisearchCfg.enable {
      after = [ "meilisearch.service" ];
      wants = [ "meilisearch.service" ];
    };
  };
}
