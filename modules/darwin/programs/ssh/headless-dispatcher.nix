{
  config,
  pkgs,
  lib,
  constants,
  hostType,
  managedDestinations ? [
    "minipc"
    "minipc-headless"
    constants.network.minipcTailscaleIP
  ],
  rawDestinations ? [ "minipc-emergency" ],
}:
let
  enabled = hostType == "personal";
  homeDir = config.home.homeDirectory;
  core = ./files/headless-ssh-dispatcher.py;
  manifest = ./files/darwin-openssh-10.3p1-26A5388g.json;
  targetHost = constants.network.minipcTailscaleIP;
  targetUser = "greenhead";
  targetPort = 22;
  headlessKeyPath = "${homeDir}/${constants.onePassword.headlessKeyRelPath}";
  authDeadline = 15;
  controlDeadline = 3;
  cleanupGrace = 2;
  runtimeGeneration = builtins.hashString "sha256" (
    builtins.toJSON {
      schemaVersion = 2;
      core = builtins.readFile core;
      optionArity = (builtins.fromJSON (builtins.readFile manifest)).shortOptionArity;
      contract = {
        realSsh = "/usr/bin/ssh";
        timeoutBin = "${pkgs.coreutils}/bin/timeout";
        inherit
          headlessKeyPath
          targetHost
          targetUser
          targetPort
          managedDestinations
          rawDestinations
          authDeadline
          controlDeadline
          cleanupGrace
          ;
      };
    }
  );
  repeatedArgs =
    values: flag: lib.concatMapStringsSep " " (value: "${flag} ${lib.escapeShellArg value}") values;
  dispatchWrapper = pkgs.writeShellScript "headless-ssh-dispatch" ''
    _darwin_tmp="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
    case "$_darwin_tmp" in
      /*/) ;;
      *) printf '%s\n' 'HEADLESS_SSH_RUNTIME_DIR_INVALID' >&2; exit 125 ;;
    esac
    exec ${pkgs.python3}/bin/python3 ${core} \
      --real-ssh /usr/bin/ssh \
      --timeout-bin ${pkgs.coreutils}/bin/timeout \
      --manifest ${manifest} \
      --headless-key ${lib.escapeShellArg headlessKeyPath} \
      --runtime-dir "''${_darwin_tmp%/}/headless-ssh" \
      --target-host ${lib.escapeShellArg targetHost} \
      --target-user ${lib.escapeShellArg targetUser} \
      --target-port ${toString targetPort} \
      ${repeatedArgs managedDestinations "--managed-destination"} \
      ${repeatedArgs rawDestinations "--raw-destination"} \
      --auth-deadline ${toString authDeadline} \
      --control-deadline ${toString controlDeadline} \
      --cleanup-grace ${toString cleanupGrace} \
      -- "$@"
  '';
  package =
    pkgs.runCommand "headless-ssh-dispatcher-${builtins.substring 0 12 runtimeGeneration}" { }
      ''
        mkdir -p "$out/bin"
        ln -s ${dispatchWrapper} "$out/bin/ssh"
      '';
in
{
  inherit
    enabled
    homeDir
    package
    runtimeGeneration
    managedDestinations
    rawDestinations
    ;
  binPath = "${package}/bin";
  marker = if enabled then "1" else "0";
}
