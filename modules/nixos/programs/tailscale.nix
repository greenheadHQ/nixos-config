# Tailscale VPN
{ config, pkgs, ... }:

let
  # ts-serve: 로컬 dev 포트를 tailnet 내부 HTTPS로 노출 (Tailscale Serve)
  # tailnet 기기(iPad 등)의 브라우저에서 https://<machine>.<tailnet>.ts.net 로 접근.
  # HTTPS라 secure-context 충족 → Clipboard/cookie/Service Worker 등 정상 동작.
  # 특정 프로젝트에 비종속 — dev 포트만 인자로 받는다 (가변 포트).
  #
  # 사전조건: Tailscale admin 콘솔에서 MagicDNS + HTTPS Certificates 활성화.
  # 권한: tailscale serve는 root 필요 → sudo 사용.
  #       (비번 없이 쓰려면 `sudo tailscale set --operator=$USER` 후 sudo 제거 가능)
  # serve 트래픽은 tailscale0(trustedInterfaces)에서 동작하므로 별도 방화벽 개방 불필요.
  tsServe = pkgs.writeShellApplication {
    name = "ts-serve";
    text = ''
      ts=${pkgs.tailscale}/bin/tailscale
      case "''${1:-}" in
        status)
          sudo "$ts" serve status
          ;;
        off | reset)
          # 주의: `tailscale serve reset`은 helper가 만든 preview만이 아니라
          # 이 노드의 "전체" serve config를 초기화한다. 현재 설정을 먼저 보여줘
          # 의도치 않은 다른 serve 설정 삭제를 사용자가 인지하게 한다.
          echo "현재 serve 설정 (reset 대상 — 이 노드의 모든 serve):" >&2
          sudo "$ts" serve status 2>/dev/null || true
          sudo "$ts" serve reset
          echo "Tailscale serve 전체 config가 reset됨"
          ;;
        "")
          echo "사용법: ts-serve <port> | status | off" >&2
          echo "  예: ts-serve 4200   # http://127.0.0.1:4200 → tailnet HTTPS" >&2
          exit 1
          ;;
        *)
          port="$1"
          if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "포트는 숫자여야 합니다: $port" >&2
            exit 1
          fi
          sudo "$ts" serve --bg "$port"
          echo "노출됨: http://127.0.0.1:$port → tailnet HTTPS (URL 확인: ts-serve status)"
          ;;
      esac
    '';
  };
in
{
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "server"; # subnet router만 허용 (exit node 비활성화)
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
    allowedUDPPorts = [ config.services.tailscale.port ];
  };

  # tailscale CLI + ts-serve 헬퍼 (dev 포트 → tailnet HTTPS 미리보기)
  environment.systemPackages = [
    pkgs.tailscale
    tsServe
  ];
}
