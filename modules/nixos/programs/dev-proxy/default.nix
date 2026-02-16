# modules/nixos/programs/dev-proxy/default.nix
# Dev server reverse proxy — dev.greenhead.dev
#
# 목적: MiniPC에서 pnpm run dev 등으로 띄운 로컬 개발 서버를
#        https://dev.greenhead.dev로 HTTPS 프록시하여
#        iPhone/iPad에서 실시간 미리보기 가능하게 함.
#
# 핵심 메커니즘:
#   1. /run/caddy/dev-upstream 파일에 Caddy 디렉티브를 동적으로 기록
#   2. Caddy virtualHost에서 `import /run/caddy/dev-upstream`으로 런타임 포함
#   3. dev-proxy 스크립트가 파일 업데이트 + `systemctl reload caddy`로 반영
#
# 비활성 상태: `respond "No dev server running" 503` (유효한 Caddyfile 구문)
# 활성 상태:   `reverse_proxy localhost:PORT`
#
# 파일 초기화 전략 (치명적 문제 해결):
#   - 첫 nrs에서 devProxy를 enable하면 Caddy reload 트리거 시
#     /run/caddy/dev-upstream 파일이 없으면 Caddy reload 실패
#     → immich, vaultwarden 등 모든 기존 서비스 접근 불가
#   - 해결: activationScripts(nrs 시 systemd보다 먼저 실행)
#           + caddy-dev-init oneshot(재부팅 시 tmpfs 초기화 대응) 이중 보장
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:

let
  cfg = config.homeserver.devProxy;
  inherit (constants.network) minipcTailscaleIP;
  inherit (constants.domain) base subdomains;

  # caddy.nix과 공유하는 보안 헤더 (HSTS, X-Content-Type-Options 등)
  securityHeaders = import ../../lib/caddy-security-headers.nix;

  # Caddy import 대상 파일 경로 (/run = tmpfs, 재부팅 시 사라짐)
  upstreamFile = "/run/caddy/dev-upstream";

  # 기본값: 유효한 Caddyfile 구문으로 503 응답 반환
  # `caddy adapt`로 검증 완료된 구문
  defaultContent = ''respond "No dev server running" 503'';

  # constants.nix에 정의된 서비스 포트 목록 (off --hard 안전장치용)
  # 이 포트들은 시스템 서비스가 사용하므로 fuser -k로 죽이면 안 됨
  systemPorts = with constants.network.ports; [
    immich
    immichMl
    uptimeKuma
    ankiSync
    copyparty
    vaultwarden
    caddy
  ];
  # Bash case 패턴용 문자열: "2283|3003|3002|27701|3923|8222|443"
  systemPortsPattern = lib.concatMapStringsSep "|" toString systemPorts;

  # activationScripts + caddy-dev-init 공용 초기화 스크립트
  # [I3 fix] set -euo pipefail 추가 — writeShellScript는 자동 삽입하지 않으므로
  # mkdir -p 실패 시 후속 명령이 실행되지 않도록 보장
  # - mkdir -p: /run/caddy 디렉토리 보장 (caddy-env가 먼저 만들 수도 있음)
  # - if [ ! -f ]: 이미 dev-proxy로 설정한 값이 있으면 덮어쓰지 않음
  #   (nrs 실행 시 기존 프록시 설정 유지)
  initScript = pkgs.writeShellScript "caddy-dev-init" ''
    set -euo pipefail
    mkdir -p /run/caddy
    if [ ! -f ${upstreamFile} ]; then
      printf '%s\n' '${defaultContent}' > ${upstreamFile}
      chmod 0644 ${upstreamFile}
    fi
  '';

  # dev-proxy CLI 스크립트 (비대화형, 즉시 종료)
  # cd/ls처럼 실행 → 설정 변경 → 출력 → 즉시 종료하는 스크립트
  #
  # sudo가 필요한 이유:
  #   - /run/caddy/는 root 소유 디렉토리 → 파일 생성/쓰기에 sudo 필요
  #   - systemctl reload도 root 권한 필요
  #   - fuser -k도 다른 사용자 프로세스 종료에 root 필요
  #   - 사용자는 security.sudo.wheelNeedsPassword = false 설정 → 비밀번호 불필요
  #
  # 보안:
  #   - 포트 번호를 정규식 + 범위로 검증하여 Caddy 디렉티브 인젝션 방지
  #   - 원자적 파일 쓰기 (mktemp + mv)로 부분 쓰기 방지
  #   - Caddy reload 실패 시 이전 상태 자동 복원
  #   - 시스템 서비스 포트(443, 2283 등) kill 방지 (off --hard 안전장치)
  devProxyScript = pkgs.writeShellApplication {
    name = "dev-proxy";
    runtimeInputs = with pkgs; [
      coreutils # mktemp, mv, cat, printf, chmod
      gnugrep # grep -oP (PCRE, 포트 번호 추출)
      psmisc # fuser -k (off --hard: 포트 프로세스 종료)
    ];
    # NOTE: writeShellApplication은 set -euo pipefail을 자동 삽입하고
    #       runtimeInputs를 PATH에 추가함. shellcheck도 자동 실행.
    # NOTE: Nix 문자열에서 ${ 이스케이프는 ''${ 로 작성.
    #       Bash 변수 ${1:-}은 Nix에서 ''${1:-}로 이스케이프.
    text = ''
      UPSTREAM_FILE="${upstreamFile}"
      HARD_KILL=false

      case "''${1:-}" in
        ""|"-h"|"--help")
          echo "Usage: dev-proxy <PORT|off [--hard]|status>"
          echo ""
          echo "Commands:"
          echo "  <PORT>      Proxy dev.greenhead.dev to localhost:PORT"
          echo "  off         Restore 503 (keep dev server running)"
          echo "  off --hard  Restore 503 + kill process on proxied port"
          echo "  status      Show current upstream config"
          exit 0
          ;;
        status)
          # [I4 fix] 파일 미존재 시 친절한 에러 메시지
          if [ -f "$UPSTREAM_FILE" ]; then
            cat "$UPSTREAM_FILE"
          else
            echo "No upstream file found (caddy-dev-init may not have run yet)" >&2
            echo "Try: sudo systemctl restart caddy-dev-init" >&2
            exit 1
          fi
          exit 0
          ;;
        off)
          # [M10 fix] --hard 외 인자가 있으면 에러
          case "''${2:-}" in
            "") ;;
            "--hard") HARD_KILL=true ;;
            *)
              echo "Error: Unknown option: ''${2}" >&2
              echo "Usage: dev-proxy off [--hard]" >&2
              exit 1
              ;;
          esac
          # [M10 fix] 3번째 이상 인자가 있으면 에러
          if [ $# -gt 2 ]; then
            echo "Error: Too many arguments" >&2
            echo "Usage: dev-proxy off [--hard]" >&2
            exit 1
          fi
          CONTENT='respond "No dev server running" 503'
          ;;
        *)
          PORT="$1"
          # 포트 번호 검증: 숫자만 허용 + 유효 범위 (1-65535)
          # 이 검증이 없으면 임의 Caddy 디렉티브를 주입할 수 있음
          if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
            echo "Error: Invalid port number: $PORT (must be 1-65535)" >&2
            exit 1
          fi
          CONTENT="reverse_proxy localhost:$PORT"
          ;;
      esac

      # 이전 상태 백업 — Caddy reload 실패 시 이 내용으로 복원
      # 파일 미존재 시 빈 문자열이 되므로 defaultContent로 대체 (빈 내용 복원 방지)
      BACKUP=$(cat "$UPSTREAM_FILE" 2>/dev/null || true)
      [ -n "$BACKUP" ] || BACKUP='${defaultContent}'

      # 원자적 파일 쓰기: sudo mktemp으로 같은 파일시스템에 임시 파일 생성 후
      # sudo mv(rename syscall)로 원자적 교체. 부분 쓰기/전원 차단 시에도 안전.
      # /run/caddy/는 root 소유이므로 모든 파일 연산에 sudo 필요
      # (wheelNeedsPassword = false → 비밀번호 불필요)
      TMPFILE=$(sudo mktemp /run/caddy/dev-upstream.XXXXXX)
      # [M7 fix] 스크립트 중단 시 임시 파일 잔류 방지
      # SIGKILL 이외의 모든 종료 시 임시 파일 정리
      trap 'sudo rm -f "$TMPFILE" 2>/dev/null' EXIT
      printf '%s\n' "$CONTENT" | sudo tee "$TMPFILE" > /dev/null
      sudo chmod 0644 "$TMPFILE"
      sudo mv "$TMPFILE" "$UPSTREAM_FILE"
      # mv 성공 후 trap에서 rm이 실행돼도 이미 TMPFILE이 없으므로 무해
      # (rm -f는 파일 미존재 시 에러 없이 종료)

      # [I6 fix] Caddy reload — 에러 출력을 표시하여 디버깅 가능하게
      # reload 실패 시: 이전 상태로 복원하고 다시 reload하여 기존 서비스 보호
      # (immich, vaultwarden 등 다른 서비스가 영향받지 않도록)
      if ! sudo systemctl reload caddy; then
        echo "Error: Caddy reload failed. Restoring previous config." >&2
        printf '%s\n' "$BACKUP" | sudo tee "$UPSTREAM_FILE" > /dev/null
        # 복원 reload도 에러를 표시하되, 실패해도 스크립트는 진행
        sudo systemctl reload caddy || echo "Warning: Restore reload also failed. Check: sudo journalctl -u caddy -n 20" >&2
        exit 1
      fi

      echo "→ dev.greenhead.dev proxying to: $CONTENT"

      # [M6 fix] --hard 모드: 파일 업데이트 + Caddy reload 후에 프로세스 종료
      # 이전 순서(kill → update)에서는 kill~reload 사이에 502 window 발생.
      # 현재 순서(update → reload → kill)는 503으로 즉시 전환 후 프로세스 정리.
      # upstream 파일에서 'localhost:PORT' 패턴을 추출하여
      # fuser -k로 해당 포트를 사용 중인 프로세스에 SIGTERM 전송
      if [ "$HARD_KILL" = true ]; then
        CURRENT_PORT=$(echo "$BACKUP" | grep -oP 'localhost:\K[0-9]+' || true)
        if [ -n "$CURRENT_PORT" ]; then
          # [I5 fix] 시스템 서비스 포트 보호
          # constants.nix에 정의된 포트(443, 2283, 3002 등)는 kill 거부
          # 이 포트들을 죽이면 Caddy/immich/vaultwarden 등 전체 서비스 중단
          case "$CURRENT_PORT" in
            ${systemPortsPattern}|22)
              echo "Error: Port $CURRENT_PORT is a system service port. Refusing to kill." >&2
              echo "Known system ports: 22 (ssh), ${systemPortsPattern}" >&2
              ;;
            *)
              echo "Killing processes on port $CURRENT_PORT..."
              # fuser -k: 해당 포트의 TCP 리스너에 SIGTERM 전송
              # sudo 필요: 다른 사용자 프로세스일 수 있음
              # || true: 이미 종료된 경우 에러 무시
              sudo fuser -k -TERM "$CURRENT_PORT/tcp" 2>/dev/null || true
              ;;
          esac
        else
          echo "No active proxy port found (already off)."
        fi
      fi
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    # [M3 fix] devProxy는 reverseProxy(Caddy) 없이 동작할 수 없음
    # reverseProxy.enable = false인데 devProxy.enable = true이면 빌드 실패
    assertions = [
      {
        assertion = config.homeserver.reverseProxy.enable;
        message = "homeserver.devProxy requires homeserver.reverseProxy to be enabled (Caddy reverse proxy)";
      }
    ];

    # ═══════════════════════════════════════════════════════════════
    # activationScripts: nrs(nixos-rebuild switch) 시 systemd 서비스보다 먼저 실행
    #
    # 왜 필요한가:
    #   devProxy를 처음 enable하면 Caddy 설정이 변경되어 systemd가
    #   caddy.service를 reload함. 이때 /run/caddy/dev-upstream 파일이
    #   없으면 `import /run/caddy/dev-upstream`이 실패 → Caddy 전체 다운
    #   → immich, vaultwarden 등 모든 서비스 접근 불가 (치명적)
    #
    # activationScripts는 switch-to-configuration(systemd 서비스 reload)보다
    # 확실히 먼저 실행됨 → 파일 존재 보장
    #
    # lib.stringAfter [ "etc" ]: /etc 파일 배치 후 실행 (의존성 순서)
    # ═══════════════════════════════════════════════════════════════
    system.activationScripts.caddy-dev-upstream = lib.stringAfter [ "etc" ] ''
      ${initScript}
    '';

    # ═══════════════════════════════════════════════════════════════
    # caddy-dev-init oneshot: 재부팅 시 /run (tmpfs) 초기화 대응
    #
    # activationScripts만으로는 부족한 이유:
    #   재부팅 시 /run은 tmpfs이므로 내용이 사라짐.
    #   activationScripts는 nrs 실행 시에만 동작하고 부팅 시에는 미실행.
    #   따라서 부팅 → Caddy 시작 경로에서 파일 부재 가능.
    #
    # systemd ordering:
    #   before = [ "caddy.service" ]
    #     → caddy.service에 After=caddy-dev-init.service 암묵 추가
    #     → 검증: systemctl show caddy.service --property=After | grep dev-init
    #   after = [ "caddy-env.service" ]
    #     → Cloudflare 토큰 환경변수 파일 생성 후 실행 (같은 /run/caddy 디렉토리 사용)
    #   wantedBy = [ "caddy.service" "multi-user.target" ]
    #     → Caddy가 이 서비스를 pull + 일반 부팅 시에도 실행
    #
    # RemainAfterExit = true: oneshot 완료 후에도 active 상태 유지
    #   → systemd가 "이 서비스는 이미 실행 완료됨"으로 인식
    # ═══════════════════════════════════════════════════════════════
    systemd.services.caddy-dev-init = {
      description = "Initialize dev proxy upstream file";
      wantedBy = [
        "caddy.service"
        "multi-user.target"
      ];
      before = [ "caddy.service" ];
      after = [ "caddy-env.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = initScript;
      };
    };

    # ═══════════════════════════════════════════════════════════════
    # Caddy virtualHost: dev.greenhead.dev
    #
    # listenAddresses: Tailscale IP에만 바인딩 (공개 인터넷 노출 방지)
    #
    # `import /run/caddy/dev-upstream`:
    #   Caddyfile의 import 디렉티브는 런타임에 해석됨.
    #   파일 내용이 해당 위치에 인라인으로 삽입되는 효과.
    #   예: reverse_proxy localhost:5173 → 해당 포트로 프록시
    #   예: respond "No dev server running" 503 → 503 응답
    #
    # [주의] NixOS caddy 모듈은 빌드 시 `caddy fmt`만 실행함.
    #   caddy fmt는 import 대상의 존재 여부를 검증하지 않으므로 빌드는 안전.
    #   그러나 향후 NixOS 모듈이 `caddy validate`를 추가하면
    #   빌드 시 /run/caddy/dev-upstream이 없어서 실패할 수 있음.
    #   그때는 이 import 방식을 재검토해야 함.
    #
    # WebSocket: Caddy v2 reverse_proxy가 WebSocket Upgrade 헤더를
    #   자동으로 프록시하므로 HMR(Hot Module Replacement) 별도 설정 불필요.
    #   단, Vite는 clientPort: 443 설정이 필요 (HMR 클라이언트 측 연결 포트).
    # ═══════════════════════════════════════════════════════════════
    services.caddy.virtualHosts."${subdomains.dev}.${base}" = {
      listenAddresses = [ minipcTailscaleIP ];
      extraConfig = ''
        ${securityHeaders}
        import ${upstreamFile}
      '';
    };

    # ═══════════════════════════════════════════════════════════════
    # dev-proxy 스크립트를 시스템 PATH에 설치
    # 사용법: dev-proxy 5173 / dev-proxy off / dev-proxy status
    # 단축 alias: dp (modules/shared/programs/shell/nixos.nix)
    # ═══════════════════════════════════════════════════════════════
    environment.systemPackages = [ devProxyScript ];
  };
}
