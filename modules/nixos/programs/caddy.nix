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
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.domain) base subdomains;

  caddyWithPlugins = pkgs.caddy.withPlugins {
    plugins = [ "github.com/caddy-dns/cloudflare@v0.2.2" ];
    hash = "sha256-dnhEjopeA0UiI+XVYHYpsjcEI6Y1Hacbi28hVKYQURg=";
  };

  envFilePath = "/run/caddy/env";

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

      virtualHosts."${subdomains.vaultwarden}.${base}" = {
        listenAddresses = [ minipcTailscaleIP ];
        extraConfig = ''
          ${securityHeaders}
          reverse_proxy localhost:${toString constants.network.ports.vaultwarden}
        '';
      };

      virtualHosts."${subdomains.karakeep}.${base}" = {
        listenAddresses = [ minipcTailscaleIP ];
        extraConfig = ''
          ${securityHeaders}
          # CSP 헤더 제거: Karakeep iframe 내 SingleFile HTML의 CSS 렌더링 차단 방지
          # Tailscale VPN 전용이므로 XSS 위험 무시 가능
          # ref: https://github.com/karakeep-app/karakeep/issues/1977
          header -Content-Security-Policy
          header -Content-Security-Policy-Report-Only
          reverse_proxy localhost:${toString constants.network.ports.karakeep}
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
      serviceConfig = {
        ExecStartPre = import ../lib/tailscale-wait.nix { inherit pkgs; };
        EnvironmentFile = envFilePath;
      };
    };
  };
}
