# Tailscale VPN
{
  config,
  pkgs,
  constants,
  ...
}:

let
  # ts-serve: 로컬 dev 포트를 tailnet 내부 HTTPS로 노출 (Tailscale Serve)
  # tailnet 기기(iPad 등)의 브라우저에서 https://<machine>.<tailnet>.ts.net:<previewPort> 로 접근.
  # HTTPS라 secure-context 충족 → Clipboard/cookie/Service Worker 등 정상 동작.
  # 특정 프로젝트에 비종속 — dev 포트만 인자로 받는다 (가변 포트).
  #
  # 범위 주의: tailscale serve config는 "노드 전역" 상태다. 8443·9443은 anki-mcp-tailscale 유닛이
  # 소유하므로(이전 Funnel 제거·승인 화면), 이 helper는 전용 HTTPS 포트(previewPort) 한 칸만 만진다 —
  # <port> 노출은 그 칸을 갱신하고 `off`는 그 칸만 끈다. 노드의 모든 serve config를 지우는
  # `tailscale serve reset`은 MCP 배선까지 지우므로 helper에 두지 않는다.
  #
  # 사전조건: Tailscale admin 콘솔에서 MagicDNS + HTTPS Certificates 활성화.
  # 권한: tailscale serve는 operator 미설정 시 root 필요 → sudo 사용.
  #       (비번 없이 쓰려면 `sudo tailscale set --operator=$USER` 후 sudo 제거 가능)
  # serve 트래픽은 tailscale0(trustedInterfaces)에서 동작하므로 별도 방화벽 개방 불필요.
  previewPort = toString constants.network.ports.tailscaleDevPreviewHttps;
  tsServe = pkgs.writeShellApplication {
    name = "ts-serve";
    text = ''
      ts=${pkgs.tailscale}/bin/tailscale
      https_port=${previewPort}
      if [ "$#" -gt 1 ]; then
        echo "인자는 하나만 받습니다: ts-serve <port> | status | off" >&2
        exit 1
      fi
      case "''${1:-}" in
        status)
          sudo "$ts" serve status
          ;;
        off)
          # 이 helper의 HTTPS 칸(:$https_port)만 끈다 — 8443/9443의 MCP 배선은 건드리지 않는다.
          sudo "$ts" serve --https="$https_port" off
          echo "Tailscale serve :$https_port 미리보기 해제됨 (다른 serve 설정은 유지)"
          ;;
        reset-all)
          echo "reset-all은 제거됨: 노드의 모든 serve config(원격 MCP 배선 포함)를 지우던 명령이다." >&2
          echo "미리보기만 끄려면 'ts-serve off', 정말 전체 초기화가 필요하면 'sudo tailscale serve reset' 뒤 'systemctl restart anki-mcp-tailscale'." >&2
          exit 1
          ;;
        "")
          echo "사용법: ts-serve <port> | status | off" >&2
          echo "  ts-serve 4200   # http://127.0.0.1:4200 → https://<machine>.<tailnet>.ts.net:$https_port" >&2
          echo "  off             # 이 미리보기 칸(:$https_port)만 해제" >&2
          exit 1
          ;;
        *)
          port="$1"
          if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$port" -gt 65535 ]; then
            echo "포트는 1-65535 범위의 숫자여야 합니다: $port" >&2
            exit 1
          fi
          # 보안: 이 노드는 tailscale0이 trusted interface다. dev 서버가 0.0.0.0(또는
          # tailnet IP)에 바인딩하면 ts-serve의 HTTPS와 별개로 raw HTTP 포트가 tailnet에
          # 직접 노출된다. ss의 local address 필드만 검사해 실제 bind 주소를 판정한다
          # (LISTEN 행의 peer 주소 0.0.0.0:* 오탐 방지). dev 서버는 127.0.0.1에 바인딩하라.
          if command -v ss >/dev/null 2>&1; then
            _laddr=$(ss -H -ltn "sport = :$port" 2>/dev/null | awk '{print $4}' || true)
            if printf '%s\n' "$_laddr" | grep -qE '^(0\.0\.0\.0|\*|\[::\]|100\.)'; then
              # 조사 앞 확장은 중괄호로 경계를 준다. UTF-8 로케일의 bash는 한글을 식별자
              # 문자로 취급해 조사까지 변수명으로 파싱한다 → set -u에 걸려 경고 대신
              # unbound variable로 죽어 ts-serve 전체가 중단된다.
              echo "경고: 포트 ''${port}가 0.0.0.0/tailnet IP에 바인딩됨 — tailnet 직접 노출. dev 서버를 127.0.0.1에 바인딩하라." >&2
            fi
          fi
          # serve config는 노드 전역 상태다. 이 helper는 :$https_port 칸만 갱신하지만
          # 현재 상태를 먼저 보여줘 사용자가 전체 그림을 인지하게 한다.
          echo "현재 serve 설정 (ts-serve <port>는 :$https_port 칸만 갱신함):" >&2
          sudo "$ts" serve status 2>/dev/null || true
          sudo "$ts" serve --bg --https="$https_port" "http://127.0.0.1:$port"
          echo "노출됨: http://127.0.0.1:$port → tailnet HTTPS :$https_port (dev 서버는 127.0.0.1 바인딩 권장)"
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
