# Generic private job runner — 로컬 정의 작업의 스케줄 실행 + 실패 알림 (#1135)
#
# 이 모듈은 특정 작업을 알지 못한다. 작업 정의·이름·스케줄·시크릿·로그 내용은 전부
# 기기 로컬(비추적) 소유이며, repo·store·CI·PR 어디에도 작업 실체가 나타나지 않는다.
# Nix eval은 로컬 작업 디렉터리를 읽지 않는다(readDir/readFile/pathExists 금지) —
# discovery·스케줄은 sync 스크립트의 런타임 스캔만 소유한다.
#
# 로컬 작업 규약 (기기에서 사람이 준비):
#   ~/.local/private-jobs/<slug>/run.sh    실행 진입점 — owner 본인·실행 가능·
#                                          symlink 및 group/world-writable 금지
#   ~/.local/private-jobs/<slug>/schedule  systemd OnCalendar 식 1줄 (예: "Sat 03:00")
#                                          — 같은 소유·링크 기준 적용
#   <slug>는 ^[a-z0-9][a-z0-9-]{0,63}$ 의 중립 문자열만 — 작업 실체를 드러내지 않는 이름.
#   로그: ~/.local/state/private-jobs/<slug>/logs/<run-id>.log (0700/0600, bounded retention)
#   알림: 실패 시 unit의 ExecStopPost가 user-scope Pushover(~/.config/pushover/share)로
#   generic 필드(slug·invocation·result·exit)만 발송 — run당 외부 알림 1회는 이
#   runner 인프라가 소유하므로 개별 작업 래퍼는 자체 push 알림을 배선하지 않는다.
#
# 동작: private-jobs-sync(user timer)가 로컬 정의를 스캔해 runtime unit 영역에
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
  # 옵션 선언은 다른 homeserver.* 서비스와 같이 options/homeserver.nix가 소유한다
  # — 이 모듈은 구현만 갖는다 (중앙 모듈 import에 포함되는 단일 경로 유지).
  pushoverLib = pkgs.writeText "pushover-lib.sh" (
    builtins.readFile ../../../shared/scripts/lib/pushover.sh
  );
  privateJobLib = pkgs.writeText "private-job-lib.sh" (builtins.readFile ./lib.sh);
  # 두 스크립트가 공유하는 HOME 상대 경로 — env로 한 번만 주입한다 (스크립트별
  # 하드코딩은 discovery와 실행이 다른 디렉터리를 보는 drift를 만든다). 이 모듈
  # 밖 소비자가 없으므로 전역 constants가 아니라 여기가 소유한다.
  privateJobsDefinitions = ".local/private-jobs";
  privateJobsState = ".local/state/private-jobs";
  # user-scope Pushover 자격 (HM secrets가 배치하는 ~/.config/pushover/share) —
  # 경로만 참조한다. root-scope(age.secrets)와 달리 user unit이 읽을 수 있다.
  pushoverCredPath = "%h/.config/pushover/share";

  # 실행 책임별로 의존을 분리해 선언한다 — 합집합 공유는 한 책임의 의존 추가가
  # 나머지 실행기까지 자동 확장되는 결합을 만든다.
  mkApp =
    name: src: deps:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = deps;
      text = builtins.readFile src;
    };
  runnerApp = mkApp "private-job-run" ./runner.sh [ pkgs.coreutils ];
  syncApp = mkApp "private-jobs-sync" ./sync.sh [
    pkgs.coreutils
    pkgs.curl
    pkgs.gnugrep
    pkgs.systemd
  ];
  notifyApp = mkApp "private-job-notify" ./notify.sh [
    pkgs.coreutils
    pkgs.curl
  ];

  commonEnvironment = {
    PRIVATE_JOB_LIB = toString privateJobLib;
    PUSHOVER_LIB = toString pushoverLib;
    PUSHOVER_CRED_FILE = pushoverCredPath;
    PRIVATE_JOBS_DEFINITIONS = privateJobsDefinitions;
    PRIVATE_JOBS_STATE = privateJobsState;
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
  # linger는 mkIf 밖에서 enable 값을 그대로 선언한다 — mkIf 안에 두면 비활성화 시
  # 옵션이 null(미관리)로 돌아가 이미 실행된 enable-linger 상태가 잔존한다.
  # 파급 주의: linger는 이 runner만이 아니라 사용자 user manager 전체를 로그인
  # 전부터 상주시킨다 — ssh-agent 등 기존 user 서비스도 로그인 없이 시작되고
  # 로그아웃 후 유지된다 (수용 근거는 PR #1142 CIR — 무인 스케줄의 전제 조건).
  config = lib.mkMerge [
    { users.users.${username}.linger = cfg.enable; }
    (lib.mkIf cfg.enable {
      systemd.user.services."private-job@" = {
        description = "private job %i";
        serviceConfig = hardening // {
          Type = "oneshot";
          ExecStart = "${runnerApp}/bin/private-job-run %i";
          # 실패 알림의 단일 소유자 — runner 내부 알림은 timeout·강제 종료 경로에서
          # 증발하므로 종료 후 훅에서만 판정·발송한다 ($SERVICE_RESULT 기반).
          ExecStopPost = "${notifyApp}/bin/private-job-notify %i";
          # bounded timeout — 개별 작업의 자체 상한(현행 최대 6h급)보다 넉넉한
          # 최후 방어선이다. 초과 시 control-group 전체가 정리된다(잔존 자식 0).
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
          # 부팅 2분 뒤 최초 sync가 runtime timer를 재생성하고(재부팅 복구 경로),
          # 15분 간격은 "정의 변경이 다음 스케줄 전에 반영"과 스캔 비용의 절충이다
          # (주기 작업은 시간 단위라 15분 지연은 무해).
          OnBootSec = "2min";
          OnUnitActiveSec = "15min";
        };
      };
    })
  ];
}
