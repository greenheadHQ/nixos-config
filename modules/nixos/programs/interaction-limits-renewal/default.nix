# modules/nixos/programs/interaction-limits-renewal/default.nix
# GitHub interaction limits(외부인 PR/이슈/코멘트 차단) 자동 갱신 타이머.
# 제한은 GitHub 정책상 최장 six_months 후 자동 해제되므로, 이 타이머가 만료 임박을
# 감지해 재설정하고 Pushover로 감지/성공/실패를 알린다. 무인 gh 인증(opnix github-pat)과
# Pushover 헬퍼는 da-weekly-report와 같은 인프라를 재사용한다 — 신규 시크릿 없음.
{
  config,
  pkgs,
  lib,
  username,
  ...
}:

let
  cfg = config.homeserver.interactionLimitsRenewal;

  homeDir = "/home/${username}";

  # 정책 상수 — 현재 요구가 고정이라 옵션으로 열지 않는다 (사용처가 생기면 그때 일반화).
  # collaborators_only: 외부인 PR/이슈/코멘트 차단. six_months: GitHub이 허용하는 최장 만료.
  limitValue = "collaborators_only";
  expiry = "six_months";
  ghPatPath = config.homeserver.opnix.ghPatPath;

  renewalScript = pkgs.writeShellApplication {
    name = "interaction-limits-renewal";
    runtimeInputs = with pkgs; [
      gh
      jq
      coreutils
    ];
    text = builtins.readFile ./files/interaction-limits-renewal.sh;
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.interaction-limits-renewal = {
      description = "Renew GitHub interaction limits before expiry";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [ homeDir ];
      };

      serviceConfig = {
        Type = "oneshot";
        User = username;
        Group = "users";
        TimeoutSec = "300";
        ExecStart = "${renewalScript}/bin/interaction-limits-renewal";
        UMask = "0077";

        # user-scope Pushover helper/credential(~/.config, ~/.local)을 읽어야 하므로
        # ProtectHome은 끈다 (da-weekly-reminder와 동일 근거).
        ProtectSystem = "full";
        ProtectHome = false;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        ProtectClock = true;
        RestrictRealtime = true;
      };

      environment = {
        HOME = homeDir;
        USER = username;
        REPO = cfg.repo;
        LIMIT_VALUE = limitValue;
        EXPIRY = expiry;
        RENEW_THRESHOLD_DAYS = toString cfg.renewThresholdDays;
        GH_PAT_PATH = ghPatPath;
        PUSHOVER_SHARE_CRED = "${homeDir}/.config/pushover/share";
        PUSHOVER_HELPER = "${homeDir}/.local/lib/pushover.sh";
        # 공용 fail-soft 전송 헬퍼 — 소비 모듈들이 같은 store 파일을 source한다 (drift 방지).
        PUSHOVER_LIB = "${../../lib/pushover-fail-soft.sh}";
      };
    };

    systemd.timers.interaction-limits-renewal = {
      description = "Daily GitHub interaction limits expiry check";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.timerCalendar;
        Persistent = true;
      };
    };
  };
}
