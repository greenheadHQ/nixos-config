# Codex mobile remote-control regression guard for greenhead-minipc.
{
  config,
  pkgs,
  lib,
  username,
  ...
}:

let
  cfg = config.homeserver.codexRemoteControl;
  pin = builtins.fromJSON (builtins.readFile ../../shared/programs/codex/codex-pin.json);
  system = pkgs.stdenv.hostPlatform.system;
  # CLI 패키징(#1219)이 codex-package 통합 tarball을 단일 소스로 쓰므로, remote-control
  # standalone payload도 같은 platform asset을 그대로 공유한다 (별도 standalonePackage 선언 불필요).
  platform = pin.platforms.${system} or (throw "codexRemoteControl: unsupported system '${system}'");
  standaloneTriple =
    if system == "x86_64-linux" then
      "x86_64-unknown-linux-musl"
    else
      throw "codexRemoteControl: standalone remote-control is only supported on x86_64-linux";

  homeDir = "/home/${username}";
  codexHome = "${homeDir}/.codex";
  stateDir = "/var/lib/codex-remote-control";
  pushoverCredPath = config.age.secrets.pushover-system-monitor.path;
  serviceLib = import ../lib/service-lib.nix { inherit pkgs; };

  standalonePackage = pkgs.fetchurl {
    url = "https://github.com/openai/codex/releases/download/${pin.tag}/${platform.asset}";
    hash = platform.hash;
  };

  maintenanceCli = pkgs.writeShellApplication {
    name = "codex-remote-control-maint";
    runtimeInputs = with pkgs; [
      coreutils
      curl
      findutils
      gawk
      gnugrep
      gnused
      gnutar
      gzip
      jq
      procps
      util-linux
    ];
    text = builtins.readFile ./codex-remote-control/files/codex-remote-control-maint.sh;
  };
in
{
  config = lib.mkIf cfg.enable {
    age.secrets.pushover-system-monitor = {
      file = ../../../secrets/pushover-system-monitor.age;
      owner = "root";
      mode = "0400";
    };

    systemd.tmpfiles.rules = [
      "d ${codexHome} 0700 ${username} users -"
      "d ${codexHome}/packages 0700 ${username} users -"
      "d ${codexHome}/packages/standalone 0700 ${username} users -"
      "d ${stateDir} 0750 ${username} users -"
    ];

    systemd.services.codex-remote-control-ensure = {
      description = "Ensure Codex mobile remote-control app-server is current";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      unitConfig = {
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
        # 완주한다. 120으로 동률이면 SIGTERM과 레이스해 알림이 소실될 수 있다.
        TimeoutSec = "300";
        ExecStart = "${maintenanceCli}/bin/codex-remote-control-maint ensure-running";
        LoadCredential = [ "pushover-system-monitor:${pushoverCredPath}" ];
        KillMode = "process";

        # The maintenance service mutates only the Codex app-server package/state and its own status.
        # Codex remote-control app-server can serve sessions that write under ~/Workspace. Keep
        # /usr, /boot, /efi, and /etc read-only, but do not make the whole home tree read-only.
        ProtectSystem = "full";
        ProtectHome = false;
        ReadWritePaths = [
          codexHome
          stateDir
        ];
        ReadOnlyPaths = [ "${standalonePackage}" ];
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };

      environment = {
        HOME = homeDir;
        CODEX_HOME = codexHome;
        STATE_DIR = stateDir;
        DESIRED_VERSION = pin.version;
        STANDALONE_TRIPLE = standaloneTriple;
        STANDALONE_PACKAGE = "${standalonePackage}";
        SERVICE_LIB = "${serviceLib}";
        ALERT_COOLDOWN_SECONDS = "1800";
        # writeShellApplication prepends its runtime inputs; this tail lets `command -v codex`
        # resolve to the Nix-managed user profile after stale ~/.local/bin shadows are removed.
        PATH = lib.mkForce "/etc/profiles/per-user/${username}/bin:/run/current-system/sw/bin";
      };
    };

    systemd.timers.codex-remote-control-ensure = {
      description = "Periodic Codex mobile remote-control ensure";
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
