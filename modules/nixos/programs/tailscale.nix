# Tailscale VPN
{ config, pkgs, ... }:

let
  # ts-serve: 로컬 dev 포트를 tailnet 내부 HTTPS로 노출 (Tailscale Serve)
  # tailnet 기기(iPad 등)의 브라우저에서 https://<machine>.<tailnet>.ts.net 로 접근.
  # HTTPS라 secure-context 충족 → Clipboard/cookie/Service Worker 등 정상 동작.
  # 특정 프로젝트에 비종속 — dev 포트만 인자로 받는다 (가변 포트).
  #
  # 범위 주의: tailscale serve config는 "노드 전역" 상태다. 이 helper는 전용 service로
  # 격리하지 않으므로, <port> 노출은 노드 serve를 갱신하고 reset-all은 노드의 모든
  # serve를 초기화한다. 그래서 <port> 실행 시 현재 상태를 먼저 보여주고, 전체 초기화
  # 명령은 의미가 드러나도록 `reset-all`로 둔다 (`off`처럼 좁게 읽히지 않게).
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
        reset-all)
          # 이 노드의 "전체" serve config를 초기화한다 (helper preview 한정이 아님).
          # 현재 설정을 먼저 보여줘 의도치 않은 타 serve 설정 삭제를 인지하게 한다.
          echo "현재 serve 설정 (reset-all 대상 — 이 노드의 모든 serve):" >&2
          sudo "$ts" serve status 2>/dev/null || true
          sudo "$ts" serve reset
          echo "Tailscale serve 전체 config가 reset됨"
          ;;
        "")
          echo "사용법: ts-serve <port> | status | reset-all" >&2
          echo "  ts-serve 4200   # http://127.0.0.1:4200 → tailnet HTTPS" >&2
          echo "  reset-all       # 이 노드의 모든 serve config 초기화 (전역)" >&2
          exit 1
          ;;
        *)
          port="$1"
          if ! [[ "$port" =~ ^[0-9]+$ ]]; then
            echo "포트는 숫자여야 합니다: $port" >&2
            exit 1
          fi
          # 보안: 이 노드는 tailscale0이 trusted interface다. dev 서버가 0.0.0.0(또는
          # tailnet IP)에 바인딩하면 ts-serve의 HTTPS와 별개로 raw HTTP 포트가 tailnet에
          # 직접 노출된다. dev 서버는 반드시 127.0.0.1에 바인딩해야 한다.
          if command -v ss >/dev/null 2>&1; then
            _listen=$(ss -tlnH "sport = :$port" 2>/dev/null || true)
            if printf '%s' "$_listen" | grep -qE '0\.0\.0\.0|\[::\]|100\.'; then
              echo "경고: 포트 $port가 0.0.0.0/tailnet IP에 listen 중 — tailnet 직접 노출. dev 서버를 127.0.0.1에 바인딩하라." >&2
            fi
          fi
          # serve config는 노드 전역 상태다. <port> 노출은 기존 serve를 갱신/덮어쓸 수
          # 있으므로 현재 상태를 먼저 보여줘 사용자가 인지하게 한다.
          echo "현재 serve 설정 (ts-serve <port>는 노드 serve 설정을 갱신함):" >&2
          sudo "$ts" serve status 2>/dev/null || true
          sudo "$ts" serve --bg "$port"
          echo "노출됨: http://127.0.0.1:$port → tailnet HTTPS (dev 서버는 127.0.0.1 바인딩 권장)"
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
