# fail2ban 설정 - SSH 공격 차단 시 Pushover 알림 전송
{
  config,
  pkgs,
  username,
  ...
}:

let
  # 사용자 홈 디렉토리의 credentials 파일 (agenix로 관리됨)
  # 형식: PUSHOVER_TOKEN=xxx / PUSHOVER_USER=yyy (shell 변수 형식)
  # 주의: fail2ban은 root로 실행되므로 $HOME 대신 절대 경로 사용 필수
  credentialsFile = "/home/${username}/.config/pushover/fail2ban";

  # Pushover 알림 스크립트
  pushoverNotifyScript = pkgs.writeShellScript "fail2ban-pushover-notify" ''
        # 주의: set -euo pipefail 사용하지 않음
        # 이유: 알림 실패가 ban 동작을 방해하면 안 됨. 모든 에러를 graceful하게 처리

        ACTION="$1"
        JAIL="$2"
        IP="''${3:-}"
        FAILURES="''${4:-}"

        # Pushover credentials 로드
        if [[ ! -f "${credentialsFile}" ]]; then
          logger -t fail2ban-pushover "Credentials not found: ${credentialsFile}"
          exit 0  # 알림 실패해도 ban은 성공으로 처리
        fi
        # shellcheck source=/dev/null
        source "${credentialsFile}"

        HOSTNAME=$(hostname)

        # IP 위치 조회 함수
        # 주의: ip-api.com은 HTTP만 지원 (무료 버전)
        # 보안: 내부 서버에서만 호출하고 민감 정보를 전송하지 않으므로 문제없음
        # 제한: 분당 45회 요청 (일반적인 SSH 공격 빈도로 충분)
        get_ip_location() {
          local ip="$1"
          local response
          response=$(${pkgs.curl}/bin/curl -s --max-time 5 --fail \
            "http://ip-api.com/json/$ip?fields=status,country,city,isp" 2>/dev/null) || response='{}'

          local status
          status=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.status // "fail"')
          if [[ "$status" == "success" ]]; then
            local country city isp
            country=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.country // "?"')
            city=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.city // "?"')
            isp=$(echo "$response" | ${pkgs.jq}/bin/jq -r '.isp // "?"')
            echo "$city, $country ($isp)"
          else
            echo "위치 조회 실패"
          fi
        }

        # 메시지 생성
        case "$ACTION" in
          ban)
            LOCATION=$(get_ip_location "$IP")
            TITLE="[Fail2Ban] SSH 공격 차단"
            MESSAGE="IP: $IP
    위치: $LOCATION
    실패 횟수: $FAILURES회
    호스트: $HOSTNAME"
            PRIORITY=0
            SOUND="falling"
            ;;
          start)
            TITLE="[Fail2Ban] 서비스 시작"
            MESSAGE="$JAIL jail이 $HOSTNAME에서 시작됨"
            PRIORITY=-1
            SOUND="none"
            ;;
          stop)
            TITLE="[Fail2Ban] 서비스 중지"
            MESSAGE="$JAIL jail이 $HOSTNAME에서 중지됨
    (서버 재부팅 또는 서비스 장애 가능성)"
            PRIORITY=1
            SOUND="siren"
            ;;
          *)
            logger -t fail2ban-pushover "Unknown action: $ACTION"
            exit 0
            ;;
        esac

        # Pushover 전송 (실패해도 계속 진행)
        if ! ${pkgs.curl}/bin/curl -s --max-time 10 \
          --form-string "token=$PUSHOVER_TOKEN" \
          --form-string "user=$PUSHOVER_USER" \
          --form-string "title=$TITLE" \
          --form-string "message=$MESSAGE" \
          --form-string "priority=$PRIORITY" \
          --form-string "sound=$SOUND" \
          https://api.pushover.net/1/messages.json > /dev/null 2>&1; then
          logger -t fail2ban-pushover "Failed to send $ACTION notification"
          exit 0
        fi

        logger -t fail2ban-pushover "Sent $ACTION notification (IP: ''${IP:-N/A})"
  '';
in
{
  services.fail2ban = {
    enable = true;
    # extraPackages 불필요 - 스크립트에서 ${pkgs.curl}, ${pkgs.jq} 절대 경로 사용

    jails = {
      sshd = {
        settings = {
          enabled = true;
          port = "ssh";
          filter = "sshd";
          maxretry = 3;
          findtime = "10m";
          bantime = "24h";
          # 주의: 멀티라인 대신 단일 문자열 + \n 사용 (fail2ban INI 파싱 호환성)
          action = "iptables-allports[name=sshd, protocol=all]\n         pushover-notify[name=sshd]";
        };
      };
    };
  };

  # 커스텀 Pushover 액션 정의
  environment.etc."fail2ban/action.d/pushover-notify.local".text = ''
    [Definition]
    # norestored = true: fail2ban 재시작 시 기존 ban된 IP에 대해 재알림 방지
    norestored = true

    actionstart = ${pushoverNotifyScript} start <name>
    actionstop = ${pushoverNotifyScript} stop <name>
    actionban = ${pushoverNotifyScript} ban <name> <ip> <failures>

    [Init]
    name = default
  '';
}
