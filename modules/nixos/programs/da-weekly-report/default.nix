# modules/nixos/programs/da-weekly-report/default.nix
# DA 세션 주간 리포트 자동 발행 retry window + 사전 리마인더 timer.
{
  config,
  pkgs,
  lib,
  username,
  nixosConfigDefaultPath,
  ...
}:

let
  cfg = config.homeserver.daWeeklyReport;

  homeDir = "/home/${username}";
  stateDir = "${homeDir}/.local/state/da-weekly-report";
  ghPatPath = "/run/opnix/${username}/github-pat";
  weeklyReportPy = ./files/weekly_report.py;
  analyzePy = ../../../shared/programs/claude/files/skills/analyzing-da-sessions/scripts/analyze.py;

  reportScript = pkgs.writeShellApplication {
    name = "da-weekly-report";
    runtimeInputs = with pkgs; [
      python3
      git
      openssh
      gh
      curl
      coreutils
    ];
    text = builtins.readFile ./files/da-weekly-report.sh;
  };

  reminderScript = pkgs.writeShellApplication {
    name = "da-weekly-reminder";
    runtimeInputs = with pkgs; [
      curl
      coreutils
    ];
    text = builtins.readFile ./files/da-weekly-reminder.sh;
  };

  commonEnvironment = {
    HOME = homeDir;
    USER = username;
    DA_WEEKLY_USERNAME = username;
    STATE_DIR = stateDir;
    PUSHOVER_SHARE_CRED = "${homeDir}/.config/pushover/share";
    PUSHOVER_HELPER = "${homeDir}/.local/lib/pushover.sh";
    # 공통 fail-soft 전송 헬퍼 — 두 entrypoint가 같은 store 파일을 source한다 (drift 방지).
    PUSHOVER_LIB = "${./files/pushover-lib.sh}";
    # writeShellApplication runtimeInputs가 앞에 붙는다. 이 tail은 Home Manager가
    # 관리하는 user-scope codex/codex-exec-supervised wrapper를 해석하기 위해 필요하다.
    PATH = lib.mkForce "${homeDir}/.local/bin:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin";
  };

  reportEnvironment = commonEnvironment // {
    REPO_ROOT = nixosConfigDefaultPath;
    HOSTS = "mac,minipc";
    HOST_HOME = "mac=/Users/${username},minipc=${homeDir}";
    GH_PAT_PATH = ghPatPath;
    WEEKLY_REPORT_PY = "${weeklyReportPy}";
    ANALYZE_PY = "${analyzePy}";
    DEADLINE_HOUR = toString cfg.deadlineHour;
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.da-weekly-report = {
      description = "Generate and publish DA weekly report";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [
          homeDir
          nixosConfigDefaultPath
        ];
      };

      serviceConfig = {
        Type = "oneshot";
        User = username;
        Group = "users";
        WorkingDirectory = nixosConfigDefaultPath;
        TimeoutSec = "3600";
        ExecStart = "${reportScript}/bin/da-weekly-report";
        UMask = "0077";

        # 이 서비스는 사용자 SSH config/ControlMaster, ~/.codex/config.toml,
        # ~/.config/pushover/share, ~/.local/lib/pushover.sh, home state를 읽고 쓴다.
        # 따라서 ProtectHome 계열 hardening은 적용하지 않는다. LLM commentary subprocess도
        # 같은 UID라 user-readable secret 파일 접근 자체는 완전히 막지 못한다. nested bwrap
        # 격리는 Codex 초기화 실패가 실측되어 기각했고, weekly_report.py finalize의 literal
        # secret sanitize gate로 공개 코멘트/알림 발행 경로를 차단한다.
        ProtectSystem = "full";
        ProtectHome = false;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };

      environment =
        reportEnvironment
        // lib.optionalAttrs (cfg.trackingIssueNumber != null) {
          TRACKING_ISSUE_NUMBER = toString cfg.trackingIssueNumber;
        };
    };

    systemd.timers.da-weekly-report = {
      description = "Weekly DA report generation retry window";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        # 사용자 기상 시각이 08~11시로 흔들리고 MacBook 절전 시 SSH가 무응답이므로
        # 월요일 09~14시 정시마다 재시도한다. 14시는 partial 확정 마감이다.
        OnCalendar = cfg.attemptCalendar;
        Persistent = true;
      };
    };

    systemd.services.da-weekly-reminder = {
      description = "Send DA weekly report preflight reminder";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        ConditionPathExists = [ homeDir ];
      };

      serviceConfig = {
        Type = "oneshot";
        User = username;
        Group = "users";
        ExecStart = "${reminderScript}/bin/da-weekly-reminder";
        UMask = "0077";

        # user-scope Pushover helper/credential을 읽어야 하므로 ProtectHome은 끈다.
        ProtectSystem = "full";
        ProtectHome = false;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };

      environment = commonEnvironment;
    };

    systemd.timers.da-weekly-reminder = {
      description = "Weekly DA report Sunday reminder";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.reminderCalendar;
        Persistent = true;
      };
    };
  };
}
