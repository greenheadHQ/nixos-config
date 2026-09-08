# Runtime-only role credentials, durable restore points, and root schema approval.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:
let
  cfg = config.homeserver.ankiHost;
  inherit (constants.ankiHost) user;
  stateRoot = constants.paths.ankiHostState;
  credentialRoot = constants.paths.ankiHostCredentials;
  archive = "${constants.paths.mediaData}/${constants.paths.ankiHostRestorePointsRelPath}";
  script =
    name: inst:
    pkgs.writeShellApplication {
      name = "anki-host-operations-${name}";
      runtimeInputs = [
        pkgs.python3
        pkgs.systemd
      ];
      runtimeEnv = {
        INSTANCE = name;
        STATE_DIR = "${stateRoot}/${name}";
        STATE_GROUP = user;
        LOCAL_CREDENTIAL_ROOT = credentialRoot;
        RESTORE_POINT_ARCHIVE = archive;
        RESTORE_POINT_KEEP = toString constants.ankiHost.restorePointKeep;
        HELPER_PORT = toString inst.helperPort;
        OPERATION_TTL_SECS = toString constants.ankiHost.operationTtlSecs;
        HELPER_CURL_MAX_TIME = toString constants.ankiHost.helperCurlMaxTimeSecs;
      };
      text = ''exec python3 ${./files/operations-host.py} "$@"'';
    };
  keyUnit =
    name: inst:
    lib.nameValuePair "anki-host-keys-${name}" {
      description = "Create private local Anki credentials for '${name}'";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${script name inst}/bin/anki-host-operations-${name} keys";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ credentialRoot ];
      };
    };
  mirrorUnit =
    name: inst:
    lib.nameValuePair "anki-host-mirror-${name}@" {
      description = "Verify and retain an Anki restore point on HDD for '${name}'";
      unitConfig.RequiresMountsFor = [ constants.paths.mediaData ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${script name inst}/bin/anki-host-operations-${name} mirror %i";
        TimeoutStartSec = toString (constants.ankiHost.mirrorTimeoutSecs - 10);
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [
          "${stateRoot}/${name}/restore-points"
          archive
        ];
      };
    };
  approveCommand =
    name: inst:
    pkgs.writeShellApplication {
      name = "anki-host-approve-${name}";
      text = ''exec ${script name inst}/bin/anki-host-operations-${name} approve "$@"'';
    };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services = lib.mapAttrs' keyUnit cfg.instances // lib.mapAttrs' mirrorUnit cfg.instances;
    systemd.tmpfiles.rules = [
      "d ${credentialRoot} 0700 root root -"
      "d ${archive} 0700 root root -"
    ];
    environment.systemPackages = lib.mapAttrsToList approveCommand (
      lib.filterAttrs (_: inst: inst.sync.enable) cfg.instances
    );
    security.polkit.enable = true;
    security.polkit.extraConfig = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: _: ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              /^anki-host-mirror-${name}@[0-9a-f]{32}\.service$/.test(action.lookup("unit")) &&
              action.lookup("verb") == "start" && subject.user == "${user}") {
            return polkit.Result.YES;
          }
        });
      '') cfg.instances
    );
  };
}
