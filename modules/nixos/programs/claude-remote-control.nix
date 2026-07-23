# Claude Code Remote Control bridge의 headless multi-instance ensure.
#
# bridge(claude remote-control)는 시작 시점 바이너리로 고정된다.
# claude launcher(~/.local/bin/claude)는 자체 업데이터가 최신으로 굴리므로
# 방치하면 bridge만 구버전에 남는다. 이 모듈은 30분 timer로 claude-rc-maint를
# 실행해 선언 인스턴스를 유지하고, drift된 전체 인스턴스를 안전한 시점에 재시작한다.
{
  config,
  pkgs,
  lib,
  username,
  nixosConfigDefaultPath,
  ...
}:

let
  cfg = config.homeserver.claudeRemoteControl;

  homeDir = "/home/${username}";
  stateDir = "${homeDir}/.local/state/claude-rc";
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../lib/service-lib.nix { inherit pkgs; };

  # darwin launchd 모듈과 공유하는 패키징 (runtimeInputs 플랫폼 분기 포함).
  maintenanceCli = import ../lib/claude-rc-maint-package.nix { inherit pkgs; };

  declaredInstances = builtins.toJSON [
    {
      path = nixosConfigDefaultPath;
      spawn = cfg.spawn;
      capacity = cfg.capacity;
      permissionMode = cfg.permissionMode;
    }
  ];
in
{
  config = lib.mkIf cfg.enable {
    # 기존 Pushover 사용 모듈들(temp-monitor, smoke-test 등)과 동일하게 자체 선언.
    # Nix 모듈 시스템이 동일 정의를 병합하므로 다른 모듈 활성화 여부에 의존하지 않는다.
    age.secrets.pushover-system-monitor = {
      file = ../../../secrets/pushover-system-monitor.age;
      owner = "root";
      mode = "0400";
    };

    systemd.services.claude-rc-ensure = {
      description = "Ensure Claude Code Remote Control bridge runs the current binary";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
        # credential 부재(=agenix 장애) 시 LoadCredential 단계에서
        # EXIT_CREDENTIALS(243)로 실패하는 대신 unit을 조용히 skip한다
        # (codex-remote-control.nix와 동일 패턴; Condition 실패는 journal에 남는다).
        ConditionPathExists = [
          homeDir
          pushoverCredPath
        ];
      };

      serviceConfig = {
        Type = "oneshot";
        User = username;
        Group = "users";
        WorkingDirectory = homeDir;
        # maint 스크립트의 flock 대기(MAINT_LOCK_TIMEOUT_SECONDS=120)보다 커야
        # lock-acquire-timeout 실패 경로가 status.json 기록과 Pushover 알림까지
        # 완주한다 (codex-remote-control.nix와 동일 근거).
        TimeoutSec = "300";
        ExecStart = "${maintenanceCli}/bin/claude-rc-maint ensure";
        LoadCredential = [ "pushover-system-monitor:${pushoverCredPath}" ];
        # oneshot 종료 시 cgroup 정리가 방금 스폰한 headless 서버를
        # 죽이지 않도록 main process만 kill 대상으로 한다.
        KillMode = "process";

        # headless 서버와 상태/로그/worktree가 사용자 홈 아래에서 동작하므로
        # ProtectHome은 쓸 수 없다. PrivateTmp도 사용자 세션과 다른 /tmp view를
        # 만들 수 있어 보수적으로 쓰지 않는다.
        ProtectSystem = "full";
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };

      environment = {
        HOME = homeDir;
        STATE_DIR = stateDir;
        CLAUDE_RC_DECLARED_INSTANCES = declaredInstances;
        # Headless NixOS retains the established unattended drift-restart
        # policy; Darwin overrides this to defer live restarts for TCC DX.
        CLAUDE_RC_DRIFT_POLICY = "automatic";
        SERVICE_LIB = "${serviceLib}";
        IDLE_THRESHOLD_MINUTES = toString cfg.idleThresholdMinutes;
        ALERT_COOLDOWN_SECONDS = "1800";
        CLAUDE_RC_ALERT_HOST = config.networking.hostName;
        # writeShellApplication runtimeInputs가 앞에 붙는다. 이 tail은 자체 업데이터가
        # 관리하는 claude launcher(~/.local/bin/claude)와 maint/래퍼 내부의 bare
        # `claude` 호출을 해석하기 위해 필요하다 (codex 모듈 PATH 주석과 동일 패턴).
        PATH = lib.mkForce "${homeDir}/.local/bin:/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin";
      };
    };

    systemd.timers.claude-rc-ensure = {
      description = "Periodic Claude Code Remote Control bridge ensure";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = "30m";
        RandomizedDelaySec = "1m";
        Persistent = true;
      };
    };
  };
}
