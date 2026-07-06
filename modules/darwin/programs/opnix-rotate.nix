# modules/darwin/programs/opnix-rotate.nix
# Mac 전용 1Password SA token 90일 rotation 알림 (#872 후속)
#
# weekly launchd user agent가 ~/.config/op/sa-expiry-mac(평문 ISO date record)를 읽어
# 만료 14일 이하면 Pushover 알림을 보낸다. 만료일은 평문 record이므로 op CLI 의존이 없다
# (1Password Individual은 SA 자동 만료를 미지원 → 90일 cadence를 정책으로 운용).
# MiniPC의 systemd 버전(modules/nixos/programs/opnix-rotate.nix)의 launchd 이식판.
# personal hostType 전용 — work 호스트는 Mac 전용 SA를 미배포(#872)하므로 알림 대상이 아니다.
{
  config,
  pkgs,
  lib,
  hostType,
  ...
}:

let
  expiryPath = "${config.xdg.configHome}/op/sa-expiry-mac";
  pushoverPath = "${config.xdg.configHome}/pushover/share";
  pushoverHelper = ../../shared/scripts/lib/pushover.sh;
  warnDays = 14; # 90일 cadence, 만료 14일 전부터 알림

  rotateCheckScript = pkgs.writeShellApplication {
    name = "opnix-rotate-check-mac";
    runtimeInputs = with pkgs; [
      coreutils # GNU date -d (BSD date 회피)
      curl
    ];
    text = ''
      EXPIRY_FILE="${expiryPath}"
      PUSHOVER_FILE="${pushoverPath}"

      # shellcheck source=/dev/null
      source "${pushoverHelper}"

      # record/자격증명 부재 → non-fatal (미배포 등). 알림 없이 종료.
      [ -r "$EXPIRY_FILE" ] || { echo "expiry record 없음 — skip" >&2; exit 0; }
      [ -r "$PUSHOVER_FILE" ] || { echo "pushover cred 없음 — skip" >&2; exit 0; }

      expiry_date="$(tr -d '[:space:]' < "$EXPIRY_FILE")"
      # ISO-8601 (YYYY-MM-DD)만 허용 — 형식 오류 시 non-fatal.
      if ! [[ "$expiry_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        echo "WARNING: invalid Mac SA expiry '$expiry_date' — skip" >&2
        exit 0
      fi
      if ! expiry_epoch="$(date -d "$expiry_date" +%s 2>/dev/null)"; then
        echo "ERROR: cannot parse expiry '$expiry_date'" >&2
        exit 1
      fi
      now_epoch="$(date +%s)"
      days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
      echo "Mac SA token expiry: $expiry_date ($days_left days left)"

      # 여유 충분 → silent (weekly 빈도가 사실상 cooldown)
      if [ "$days_left" -gt ${toString warnDays} ]; then
        exit 0
      fi

      # shellcheck source=/dev/null
      source "$PUSHOVER_FILE"
      if [ -z "''${PUSHOVER_TOKEN:-}" ] || [ -z "''${PUSHOVER_USER:-}" ]; then
        echo "ERROR: Pushover credentials empty" >&2
        exit 1
      fi

      steps="1Password 콘솔에서 nixos-automation-mac 재발급 → secrets/opnix-service-account-token-mac.age 재암호화(개인 Mac 키) → secrets/opnix-service-account-expiry-mac.txt 갱신 → nrs."
      if [ "$days_left" -lt 0 ]; then
        msg="Mac SA token이 $expiry_date에 만료됨 ($(( -days_left ))일 경과). $steps"
        prio=1
      else
        msg="Mac SA token이 $expiry_date에 만료 예정 ($days_left일 남음). $steps"
        prio=0
      fi

      if pushover_send "$PUSHOVER_FILE" "1Password Mac SA token rotation needed" "$msg" "$prio"; then
        echo "Pushover rotation alert sent ($days_left days left)"
      else
        echo "WARNING: Pushover send failed" >&2
      fi
    '';
  };
in
{
  config = lib.mkIf (hostType == "personal") {
    # Mac 전용 SA token 만료 record (평문 ISO date — op CLI 만료 조회 미지원 대체).
    # SA 재발급 시 secrets/opnix-service-account-expiry-mac.txt를 갱신한다 (SSOT).
    home.file.".config/op/sa-expiry-mac".source = ../../../secrets/opnix-service-account-expiry-mac.txt;

    launchd.agents.opnix-rotate-mac = {
      enable = true;
      config = {
        ProgramArguments = [ "${rotateCheckScript}/bin/opnix-rotate-check-mac" ];
        # 매주 월요일 10:00 (Persistent 미지원 → 놓친 실행은 다음 주, weekly 빈도로 충분)
        StartCalendarInterval = [
          {
            Weekday = 1;
            Hour = 10;
            Minute = 0;
          }
        ];
        StandardOutPath = "${config.home.homeDirectory}/Library/Logs/opnix-rotate-mac.log";
        StandardErrorPath = "${config.home.homeDirectory}/Library/Logs/opnix-rotate-mac.log";
        RunAtLoad = false;
      };
    };
  };
}
