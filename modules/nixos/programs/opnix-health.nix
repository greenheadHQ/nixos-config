# Probe without rematerializing secrets or restarting consumers.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:
let
  # Reuse the module's installed opnix; the flake's standalone package has a
  # different source derivation and would build a second copy of the same CLI.
  opnixPackage =
    lib.findFirst (package: (package.pname or "") == "opnix")
      (throw "opnix health check requires the installed opnix package")
      config.environment.systemPackages;
  monitor = import ../../shared/lib/opnix-health-check.nix {
    inherit pkgs;
    backend = "opnix";
    program = "${opnixPackage}/bin/opnix";
    tokenFile = config.services.onepassword-secrets.tokenFile;
    stateDir = constants.onePassword.healthStateLinuxPath;
    pushoverFile = config.age.secrets.pushover-system-monitor.path;
    hostLabel = "MiniPC";
    reference = config.services.onepassword-secrets.secrets.githubPat.reference;
  };
in
{
  config = lib.mkIf config.homeserver.opnix.enable {
    age.secrets.pushover-system-monitor = {
      file = ../../../secrets/pushover-system-monitor.age;
      mode = "0400";
      owner = "root";
    };
    systemd.services.opnix-health-check = {
      description = "Check actual 1Password SA secret access";
      after = [
        "network-online.target"
        "agenix.service"
      ];
      wants = [ "network-online.target" ];
      # No ConditionPathExists: missing credentials must be reported, not skipped.
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${monitor}/bin/opnix-health-check";
        StateDirectory = builtins.baseNameOf constants.onePassword.healthStateLinuxPath;
        StateDirectoryMode = "0700";
        TimeoutStartSec = 90;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
      };
    };
    systemd.timers.opnix-health-check = {
      description = "Hourly 1Password SA health check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "hourly";
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };
  };
}
