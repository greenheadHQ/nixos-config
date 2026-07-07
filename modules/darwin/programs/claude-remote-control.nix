# modules/darwin/programs/claude-remote-control.nix
# Claude Code Remote Control bridge의 macOS(darwin) 배선 (#1007)
#
# MiniPC의 systemd 버전(modules/nixos/programs/claude-remote-control.nix)의 launchd
# 이식판. 래퍼(~/.local/bin/claude-rc) 설치와 30분 주기 version-drift 감시
# (claude-rc-ensure launchd agent)를 한 모듈에 응집한다 — bridge 이름/capacity가
# 래퍼 기본값과 maint env 양쪽에 일관되게 흘러야 하기 때문.
#
# NixOS와의 차이:
#   - 옵션 네임스페이스 없음: darwin에는 homeserver.*가 없어 hostType 분기 상수로
#     시작한다 (opnix-rotate.nix 관례, 옵션화는 수요 생기면 도입 — YAGNI).
#   - Pushover: minipcOnly인 pushover-system-monitor.age 대신 shared secrets의
#     pushover-share.age(~/.config/pushover/share, 양쪽 맥북 복호화 가능)를 쓴다.
#     파일 형식(PUSHOVER_TOKEN/PUSHOVER_USER env)은 maint의 source 인터페이스와 동일.
#     복호화 전(agenix 미완료)이면 maint의 graceful fallback이 알림만 스킵한다.
#   - Persistent 미대응: launchd StartInterval은 놓친 실행을 다음 주기로 수용.
{
  config,
  pkgs,
  hostType,
  nixosConfigDefaultPath,
  ...
}:

let
  homeDir = config.home.homeDirectory;
  username = config.home.username;
  stateDir = "${homeDir}/.local/state/claude-rc";
  pushoverCredPath = "${config.xdg.configHome}/pushover/share";
  serviceLib = import ../../nixos/lib/service-lib.nix { inherit pkgs; };

  # bridge 운영 상수 — NixOS의 homeserver.claudeRemoteControl.* 대응.
  # 자동 재시작이 이 값들을 명시 전달해야 래퍼 기본값으로 되돌아가는 회귀가 없다.
  bridgeName = if hostType == "work" then "work-MacBook" else "MacBook";
  bridgeCapacity = 8; # work-MacBookPro 수동 운영 실측값 승계
  bridgePermissionMode = "bypassPermissions";
  idleThresholdMinutes = 30;
  alertCooldownSeconds = 1800;

  # NixOS HM 배선(shell/nixos.nix)과 같은 표현식 — flakePath/defaultName만 darwin 값.
  claudeRcPkg = import ../../nixos/lib/claude-rc-package.nix {
    inherit pkgs;
    flakePath = nixosConfigDefaultPath;
    defaultName = bridgeName;
  };
  maintenanceCli = import ../../nixos/lib/claude-rc-maint-package.nix { inherit pkgs; };
in
{
  home.file.".local/bin/claude-rc".source = "${claudeRcPkg}/bin/claude-rc";

  launchd.agents.claude-rc-ensure = {
    enable = true;
    config = {
      ProgramArguments = [
        "${maintenanceCli}/bin/claude-rc-maint"
        "ensure"
      ];
      # 30분 주기 (systemd OnUnitActiveSec=30m 대응) + 로그인 시 1회
      # (OnBootSec=2m 대응 — ensure가 bridge 부재 시 시작하므로 부팅 후 자동 구동).
      StartInterval = 1800;
      RunAtLoad = true;
      EnvironmentVariables = {
        HOME = homeDir;
        STATE_DIR = stateDir;
        CLAUDE_RC_BIN = "${claudeRcPkg}/bin/claude-rc";
        SERVICE_LIB = "${serviceLib}";
        PUSHOVER_CRED_FILE = pushoverCredPath;
        IDLE_THRESHOLD_MINUTES = toString idleThresholdMinutes;
        ALERT_COOLDOWN_SECONDS = toString alertCooldownSeconds;
        CLAUDE_RC_PERMISSION_MODE = bridgePermissionMode;
        CLAUDE_RC_CAPACITY = toString bridgeCapacity;
        CLAUDE_RC_NAME = bridgeName;
        CLAUDE_RC_ALERT_HOST = bridgeName;
        # writeShellApplication runtimeInputs가 앞에 붙는다. 이 tail은
        # ~/.local/bin(claude launcher + claude-rc 내부 bare `claude` 호출),
        # nix 프로필, 그리고 /usr/bin(시스템 pgrep — darwin은 procps 미지원이라
        # maint 패키징이 시스템 바이너리에 의존)을 해석하기 위해 필요하다.
        PATH = "${homeDir}/.local/bin:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";
      };
      StandardOutPath = "${homeDir}/Library/Logs/claude-rc-ensure.log";
      StandardErrorPath = "${homeDir}/Library/Logs/claude-rc-ensure.log";
    };
  };
}
