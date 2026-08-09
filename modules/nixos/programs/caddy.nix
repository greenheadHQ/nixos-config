# modules/nixos/programs/caddy.nix
# HTTPS 리버스 프록시 (Caddy + Cloudflare DNS-01 ACME)
# Tailscale 내부 전용: 100.79.80.95:443에만 바인딩
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.reverseProxy;
  singlefileBridgeCfg = config.homeserver.karakeepSinglefileBridge;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.domain) base subdomains;

  caddyWithPlugins = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.2" ];
    hash = "sha256-7g8zDx5RhbptXFyEPtexxkHX8hw/gF001bZ7wX4Mjhs=";
  };

  envFilePath = "/run/caddy/env";

  # 암호문의 개별 store path — 재시작 트리거용. 문자열 보간이 필수다:
  # .file을 path 값 그대로 리스트에 넣으면 toString 경로를 타서 flake source 전체
  # (/nix/store/<hash>-source/secrets/...)에 결합되고, 무관한 커밋마다 Caddy가 재시작된다
  # (= 전체 리버스 프록시 순간 단절). "${...}"는 그 파일 하나를 개별 store 객체로 복사해
  # 암호문 내용에만 의존한다 (실측 확인).
  tokenCiphertext = "${config.age.secrets.cloudflare-dns-api-token.file}";

  # 보안 헤더 (모든 virtualHost에 공통 적용)
  securityHeaders = import ../lib/caddy-security-headers.nix;

  # agenix 시크릿에서 환경변수 파일 생성 (copyparty-config 패턴)
  envScript = pkgs.writeShellScript "caddy-env-gen" ''
    mkdir -p /run/caddy
    TOKEN=$(cat ${config.age.secrets.cloudflare-dns-api-token.path})
    printf 'CLOUDFLARE_API_TOKEN=%s\n' "$TOKEN" > ${envFilePath}
    chmod 0400 ${envFilePath}
    chown caddy:caddy ${envFilePath}
  '';
in
{
  config = lib.mkIf cfg.enable {
    # ═══════════════════════════════════════════════════════════════
    # agenix 시크릿
    # ═══════════════════════════════════════════════════════════════
    age.secrets.cloudflare-dns-api-token = {
      file = ../../../secrets/cloudflare-dns-api-token.age;
      owner = "root";
      mode = "0400";
    };

    # ═══════════════════════════════════════════════════════════════
    # 환경변수 파일 생성 서비스 (Caddy 시작 전)
    # ═══════════════════════════════════════════════════════════════
    systemd.services.caddy-env = {
      description = "Generate Caddy environment file with Cloudflare token";
      wantedBy = [ "caddy.service" ];
      before = [ "caddy.service" ];
      # envScript는 시크릿의 런타임 '경로'(/run/agenix/...)만 담으므로 .age를 재암호화해도
      # store path가 그대로다. 암호문을 트리거로 걸어야 토큰 교체가 env 파일 재생성으로 이어진다.
      # 이게 없으면 RemainAfterExit=true라 소비 서비스를 재시작해도 이 유닛은 재실행되지 않아
      # 구 토큰이 계속 유효하다.
      restartTriggers = [ tokenCiphertext ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = envScript;
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # Caddy 리버스 프록시
    # ═══════════════════════════════════════════════════════════════
    services.caddy = {
      enable = true;
      package = caddyWithPlugins;

      globalConfig = ''
        acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
        default_bind ${minipcTailscaleIP}
      '';

      virtualHosts."${subdomains.immich}.${base}" = {
        listenAddresses = [ minipcTailscaleIP ];
        extraConfig = ''
          ${securityHeaders}
          reverse_proxy localhost:${toString constants.network.ports.immich}
        '';
      };

      virtualHosts."${subdomains.uptimeKuma}.${base}" = {
        listenAddresses = [ minipcTailscaleIP ];
        extraConfig = ''
          ${securityHeaders}
          reverse_proxy localhost:${toString constants.network.ports.uptimeKuma}
        '';
      };

      virtualHosts."${subdomains.copyparty}.${base}" = {
        listenAddresses = [ minipcTailscaleIP ];
        extraConfig = ''
          ${securityHeaders}
          reverse_proxy localhost:${toString constants.network.ports.copyparty}
        '';
      };

      virtualHosts."${subdomains.karakeep}.${base}" = {
        listenAddresses = [ minipcTailscaleIP ];
        extraConfig = ''
          ${securityHeaders}
          route {
            @karakeepArchiveAssets path /api/assets/*
            handle @karakeepArchiveAssets {
              # CSP는 아카이브 자산 경로에서만 제거 (렌더링 호환) -- 앱 셸은 표준 CSP 유지.
              # 이전에는 vhost 전체 제거였음. ref: https://github.com/karakeep-app/karakeep/issues/1977
              header -Content-Security-Policy
              header -Content-Security-Policy-Report-Only
              reverse_proxy localhost:${toString constants.network.ports.karakeep}
            }
            ${
              if singlefileBridgeCfg.enable then
                ''
                  @singlefile path /api/v1/bookmarks/singlefile*
                  handle @singlefile {
                    reverse_proxy localhost:${toString singlefileBridgeCfg.port}
                  }
                ''
              else
                ""
            }
            handle {
              reverse_proxy localhost:${toString constants.network.ports.karakeep}
            }
          }
        '';
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # systemd 오버라이드: Tailscale 대기 + 환경변수 파일
    # ═══════════════════════════════════════════════════════════════
    systemd.services.caddy = {
      after = [
        "tailscaled.service"
        "caddy-env.service"
      ];
      wants = [
        "tailscaled.service"
        "caddy-env.service"
      ];
      # env 파일 내용은 유닛 정의에 들어가지 않고 경로만 들어간다. 암호문을 트리거로 걸어야
      # 토큰 교체가 Caddy 재시작(새 env 파일 로드)으로 이어진다. Caddy는 env를 시작 시점에만 읽는다.
      restartTriggers = [ tokenCiphertext ];
      serviceConfig = {
        ExecStartPre = import ../lib/tailscale-wait.nix { inherit pkgs; };
        EnvironmentFile = envFilePath;
      };
    };
  };
}
