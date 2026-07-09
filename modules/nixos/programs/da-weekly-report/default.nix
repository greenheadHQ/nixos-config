# modules/nixos/programs/da-weekly-report/default.nix
# DA 세션 주간 리포트 자동 발행 timer.
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
      jq
      coreutils
    ];
    text = builtins.readFile ./files/da-weekly-report.sh;
  };

  baseEnvironment = {
    HOME = homeDir;
    USER = username;
    DA_WEEKLY_USERNAME = username;
    REPO_ROOT = nixosConfigDefaultPath;
    STATE_DIR = stateDir;
    HOSTS = "mac,minipc";
    HOST_HOME = "mac=/Users/${username},minipc=${homeDir}";
    GH_PAT_PATH = ghPatPath;
    WEEKLY_REPORT_PY = "${weeklyReportPy}";
    ANALYZE_PY = "${analyzePy}";
    # writeShellApplication runtimeInputs가 앞에 붙는다. 이 tail은 Home Manager가
    # 관리하는 user-scope codex/codex-exec-supervised wrapper를 해석하기 위해 필요하다.
    PATH = lib.mkForce "${homeDir}/.local/bin:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin";
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

        # 이 서비스는 사용자 SSH config/ControlMaster, ~/.codex/config.toml,
        # ~/.config/pushover/share, ~/.local/lib/pushover.sh, home state를 읽고 쓴다.
        # 따라서 ProtectHome 계열 hardening은 적용하지 않는다.
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
        baseEnvironment
        // lib.optionalAttrs (cfg.trackingIssueNumber != null) {
          TRACKING_ISSUE_NUMBER = toString cfg.trackingIssueNumber;
        };
    };

    systemd.timers.da-weekly-report = {
      description = "Weekly DA report generation";
      wantedBy = [ "timers.target" ];

      timerConfig = {
        OnCalendar = cfg.reportTime;
        Persistent = true;
      };
    };
  };
}
