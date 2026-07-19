# Generic private job runner — 로컬 정의 작업의 스케줄 실행 + 실패 알림 (#1135)
#
# 이 모듈은 특정 작업을 알지 못한다. 작업 정의·이름·스케줄·시크릿·로그 내용은 전부
# 기기 로컬(비추적) 소유이며, repo·store·CI·PR 어디에도 작업 실체가 나타나지 않는다.
# Nix eval은 로컬 작업 디렉터리를 읽지 않는다(readDir/readFile/pathExists 금지) —
# discovery·스케줄은 sync 스크립트의 런타임 스캔만 소유한다.
#
# 로컬 작업 규약 (기기에서 사람이 준비):
#   ~/.local/private-jobs/<slug>/run.sh    실행 진입점 (0700, owner 본인, symlink 금지)
#   ~/.local/private-jobs/<slug>/schedule  systemd OnCalendar 식 1줄 (예: "Sat 03:00")
#   <slug>는 ^[a-z0-9][a-z0-9-]{0,63}$ 의 중립 문자열만 — 작업 실체를 드러내지 않는 이름.
#   로그: ~/.local/state/private-jobs/<slug>/logs/<run-id>.log (0700/0600, bounded retention)
#   알림: 실패 시 runner가 user-scope Pushover(~/.config/pushover/share)로 generic
#   필드(slug·run id·exit class)만 발송 — run당 외부 알림 1회는 runner가 소유하므로
#   개별 작업 래퍼는 자체 push 알림을 배선하지 않는다.
#
# 동작: private-jobs-sync(user timer, 부팅 2분 후 + 15분 간격)가 로컬 정의를 스캔해
# private-job-<slug>.timer(Persistent=true)를 생성·정리하고, 각 timer는 template
# unit private-job@<slug>.service → runner를 발화한다. linger로 로그인 세션 없이도
# user manager가 부팅부터 상주한다.
{
  config,
  lib,
  pkgs,
  username,
  ...
}:

let
  cfg = config.homeserver.privateJobRunner;
  pushoverLib = pkgs.writeText "pushover-lib.sh" (
    builtins.readFile ../../../shared/scripts/lib/pushover.sh
  );
  # user-scope Pushover 자격 (HM secrets가 배치하는 ~/.config/pushover/share) —
  # 경로만 참조한다. root-scope(age.secrets)와 달리 user unit이 읽을 수 있다.
  pushoverCredPath = "%h/.config/pushover/share";

  runnerApp = pkgs.writeShellApplication {
    name = "private-job-run";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = builtins.readFile ./runner.sh;
  };

  syncApp = pkgs.writeShellApplication {
    name = "private-jobs-sync";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      gnugrep
      systemd
    ];
    text = builtins.readFile ./sync.sh;
  };

  commonEnvironment = {
    PUSHOVER_LIB = toString pushoverLib;
    PUSHOVER_CRED_FILE = pushoverCredPath;
  };

  # user unit hardening 공통값. RestrictNamespaces는 의도적으로 켜지 않는다 —
  # 일부 작업의 하위 도구(sandbox형 CLI)가 user namespace 생성을 요구하며, 이는
  # da-weekly-report의 실측 선례와 같은 제약이다. 이 선택은 eval-tests가 고정한다.
  hardening = {
    UMask = "0077";
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "full";
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    ProtectClock = true;
    RestrictRealtime = true;
    KillMode = "control-group";
  };
in
{
  options.homeserver.privateJobRunner = {
    enable = lib.mkEnableOption "generic private job runner (로컬 정의 작업의 user timer 실행)";
  };

  config = lib.mkIf cfg.enable {
    # 로그인 세션 없이도 user manager·timer가 부팅부터 상주해야 무인 스케줄이 성립한다.
    users.users.${username}.linger = true;

    systemd.user.services."private-job@" = {
      description = "private job %i";
      # 작업은 네트워크를 쓸 수 있다(수집·push류) — user unit에는
      # network-online.target이 없으므로 보수적으로 기본 target 이후로만 둔다.
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${runnerApp}/bin/private-job-run %i";
        # bounded timeout — 개별 작업의 자체 타임아웃보다 넉넉한 최후 상한이다.
        # 초과 시 control-group 전체가 정리된다(잔존 자식 0).
        TimeoutStartSec = "8h";
      };
      environment = commonEnvironment;
    };

    systemd.user.services."private-jobs-sync" = {
      description = "sync private job definitions to user timers";
      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${syncApp}/bin/private-jobs-sync";
        TimeoutStartSec = "5min";
      };
      environment = commonEnvironment;
    };

    systemd.user.timers."private-jobs-sync" = {
      description = "periodic private job definition sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
      };
    };
  };
}
