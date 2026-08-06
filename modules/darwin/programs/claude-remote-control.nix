# modules/darwin/programs/claude-remote-control.nix
# Claude Code Remote Control bridge의 macOS(darwin) headless 배선
#
# NixOS systemd 버전(modules/nixos/programs/claude-remote-control.nix)의 launchd
# 이식판. 래퍼(~/.local/bin/claude-rc) 설치와 1분 주기 liveness/live-drift 감시
# (claude-rc-ensure launchd agent)를 한 모듈에 응집한다.
#
# NixOS와의 차이:
#   - 옵션 네임스페이스 없음: darwin에는 homeserver.*가 없어 선언 인스턴스
#     상수를 모듈 안에 둔다 (옵션화는 수요 생기면 도입 — YAGNI).
#   - Pushover: NixOS 전용 pushover-system-monitor.age 대신 shared secrets의
#     pushover-share.age(~/.config/pushover/share)를 쓴다.
#     파일 형식(PUSHOVER_TOKEN/PUSHOVER_USER env)은 maint의 source 인터페이스와 동일.
#     복호화 전(agenix 미완료)이면 maint의 graceful fallback이 알림만 스킵한다.
#   - Persistent 미대응: launchd StartInterval은 놓친 실행을 다음 주기로 수용.
{
  config,
  pkgs,
  lib,
  constants,
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
  headlessDispatcher = import ./ssh/headless-dispatcher.nix {
    inherit
      config
      pkgs
      lib
      constants
      hostType
      ;
  };
  baselinePath = "${homeDir}/.local/bin:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin";

  # 선언 인스턴스 운영 상수 — NixOS의 homeserver.claudeRemoteControl.* 대응.
  bridgeSpawn = "worktree";
  bridgeCapacity = null;
  bridgePermissionMode = "bypassPermissions";
  idleThresholdMinutes = 30;
  alertCooldownSeconds = 1800;
  declaredInstances = builtins.toJSON [
    {
      path = nixosConfigDefaultPath;
      spawn = bridgeSpawn;
      capacity = bridgeCapacity;
      permissionMode = bridgePermissionMode;
    }
  ];

  # NixOS HM 배선(shell/nixos.nix)과 같은 래퍼 패키지.
  claudeRcPkg = import ../../nixos/lib/claude-rc-package.nix { inherit pkgs; };
  maintenanceCli = import ../../nixos/lib/claude-rc-maint-package.nix { inherit pkgs; };
  # Manual start도 bridge child에만 private SSH PATH를 전달한다. 호출한 Ghostty의
  # 환경은 바꾸지 않으며 공통 NixOS Claude lifecycle package도 수정하지 않는다.
  claudeRcLauncher =
    if headlessDispatcher.enabled then
      pkgs.writeShellScriptBin "claude-rc" ''
        export NIXOS_CONFIG_HEADLESS_SSH=1
        export PATH="${headlessDispatcher.stableBinPath}:$PATH"
        exec ${claudeRcPkg}/bin/claude-rc "$@"
      ''
    else
      claudeRcPkg;
in
{
  home.file.".local/bin/claude-rc".source = "${claudeRcLauncher}/bin/claude-rc";
  home.file.".local/bin/claude-rc-maint".source = "${maintenanceCli}/bin/claude-rc-maint";

  launchd.agents.claude-rc-ensure = {
    enable = true;
    config = {
      ProgramArguments = [
        "${maintenanceCli}/bin/claude-rc-maint"
        "ensure"
      ];
      # 로그인 시 1회 실행하고, boot-time transient exit나 이후 bridge 종료를
      # 원격 운영자가 Mac 앞에 없어도 1분 안에 다시 ensure한다. NixOS의 30분
      # drift timer보다 짧은 이유는 Darwin에 network-online/OnBootSec gate가 없고,
      # 실제 reboot에서 첫 bridge가 종료된 뒤 30분 공백이 확인됐기 때문이다.
      StartInterval = 60;
      RunAtLoad = true;
      # launchd는 job 종료 시 같은 process group의 잔여 프로세스를 정리한다.
      # maint가 native launch-group supervisor(setpgid(0,0)로 자기 그룹 분리)로 headless
      # 서버를 띄우므로 서버는 별도 process group이 되지만, ensure가 방금 띄운 서버를
      # 같이 죽이지 않도록 안전하게 그룹 정리를 포기한다.
      AbandonProcessGroup = true;
      EnvironmentVariables = {
        HOME = homeDir;
        STATE_DIR = stateDir;
        CLAUDE_RC_DECLARED_INSTANCES = declaredInstances;
        # Missing/dead bridges still start automatically. A live bridge on an
        # older Claude version stays running until the operator explicitly
        # confirms an interactive maintenance restart.
        CLAUDE_RC_DRIFT_POLICY = "defer";
        SERVICE_LIB = "${serviceLib}";
        PUSHOVER_CRED_FILE = pushoverCredPath;
        IDLE_THRESHOLD_MINUTES = toString idleThresholdMinutes;
        ALERT_COOLDOWN_SECONDS = toString alertCooldownSeconds;
        # writeShellApplication runtimeInputs가 앞에 붙는다. Darwin runtimeInputs에는
        # procps가 없으므로 이 tail의 /usr/bin이 maint의 bare pgrep fallback을 제공한다.
        # Claude launcher는 CLAUDE_BIN의 기본 절대 경로(~/.local/bin/claude)로 실행되며,
        # 이 launchd job은 interactive wrapper나 그 내부 bare `claude`를 호출하지 않는다.
        PATH =
          lib.optionalString headlessDispatcher.enabled "${headlessDispatcher.stableBinPath}:" + baselinePath;
      }
      // lib.optionalAttrs headlessDispatcher.enabled {
        NIXOS_CONFIG_HEADLESS_SSH = "1";
      };
      StandardOutPath = "${homeDir}/Library/Logs/claude-rc-ensure.log";
      StandardErrorPath = "${homeDir}/Library/Logs/claude-rc-ensure.log";
    };
  };
}
