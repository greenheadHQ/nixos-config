# modules/nixos/programs/smartd.nix
# S.M.A.R.T. 디스크 건강 모니터링 + Pushover 알림
# NixOS services.smartd 모듈 활용 (nixpkgs smartd.nix 소스 검증 완료)
# NVMe + HDD 자동 감지, PreFailure/온도 경고 시 Pushover 전송
{
  config,
  pkgs,
  ...
}:

let
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;

  # smartd 알림 스크립트 (smartd가 -M exec로 호출)
  # 중요: smartd에 non-zero 반환 금지 — 전체를 ( ... ) || true로 래핑
  smartdNotify = pkgs.writeShellApplication {
    name = "smartd-notify";
    runtimeInputs = with pkgs; [
      curl
      coreutils
    ];
    # writeShellApplication은 set -euo pipefail 자동 적용
    # smartd에서 호출되므로 절대 non-zero exit 불가 → 전체 래핑
    text = ''
      (
        # SMARTD_* 환경변수 디폴트 처리 (set -u 호환)
        DEVICE="''${SMARTD_DEVICE:-unknown}"
        FAILTYPE="''${SMARTD_FAILTYPE:-unknown}"
        MESSAGE="''${SMARTD_MESSAGE:-No message}"

        # 시크릿 파일 로드
        CRED_FILE="${pushoverCredPath}"
        if [ ! -f "$CRED_FILE" ]; then
          echo "WARNING: Pushover credentials not found: $CRED_FILE" >&2
          exit 0
        fi
        # shellcheck source=/dev/null
        source "$CRED_FILE"

        if [ -z "''${PUSHOVER_TOKEN:-}" ] || [ -z "''${PUSHOVER_USER:-}" ]; then
          echo "WARNING: PUSHOVER_TOKEN or PUSHOVER_USER empty" >&2
          exit 0
        fi

        # 우선순위 결정: PreFailure/심각한 오류는 긴급(1), 나머지는 일반(0)
        PRIORITY=0
        case "$FAILTYPE" in
          PreFailure|CurrentPendingSector|OfflineUncorrectable)
            PRIORITY=1
            ;;
        esac

        TITLE="SMART Alert: $DEVICE"
        BODY="Type: $FAILTYPE
      Device: $DEVICE
      $MESSAGE"

        curl -sf --proto =https --max-time 10 \
          --form-string "token=$PUSHOVER_TOKEN" \
          --form-string "user=$PUSHOVER_USER" \
          --form-string "title=$TITLE" \
          --form-string "message=$BODY" \
          --form-string "priority=$PRIORITY" \
          https://api.pushover.net/1/messages.json > /dev/null 2>&1
      ) || true
    '';
  };
in
{
  # agenix 시크릿 정의
  age.secrets.pushover-system-monitor = {
    file = ../../../secrets/pushover-system-monitor.age;
    mode = "0400";
    owner = "root";
  };

  # smartmontools 패키지 (smartctl 명령어)
  environment.systemPackages = [ pkgs.smartmontools ];

  # smartd 서비스
  services.smartd = {
    enable = true;
    autodetect = true;

    # 내장 알림 전부 비활성화 (커스텀 스크립트 사용)
    # notifications.wall.enable 기본값이 true!
    # 명시적 false 필수 — 누락 시 모듈이 자체 -M exec 플래그를 삽입하여 커스텀 스크립트와 충돌
    notifications.wall.enable = false;
    notifications.mail.enable = false;

    # DEVICESCAN에 적용되는 기본 옵션
    # -a: 모든 SMART 속성 모니터링
    # -o on: 오프라인 테스트 자동 실행 (NVMe에서는 무시됨, 무해)
    # -S on: 속성 자동저장 (NVMe에서는 무시됨, 무해)
    # -n standby,q: 대기 모드 디스크 깨우지 않음 (조용히)
    # -W 5,50,60: 온도 5도 변화 로그 / 50도 경고 / 60도 위험
    # -m <nomailer>: 메일 발송 안 함 (커스텀 스크립트 사용)
    # -M exec <스크립트>: 알림 시 커스텀 스크립트 실행
    defaults.autodetected = "-a -o on -S on -n standby,q -W 5,50,60 -m <nomailer> -M exec ${smartdNotify}/bin/smartd-notify";
  };
}
