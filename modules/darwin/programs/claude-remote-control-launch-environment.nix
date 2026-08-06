{
  pkgs,
  lib,
  hostType,
  headlessDispatcher ? null,
}:
let
  dispatcherAvailable =
    hostType == "personal" && headlessDispatcher != null && headlessDispatcher.enabled;
  homeDir =
    if headlessDispatcher != null && headlessDispatcher ? homeDir then
      headlessDispatcher.homeDir
    else
      throw "Darwin Claude Remote Control launch environment requires headlessDispatcher.homeDir";
  username = builtins.baseNameOf homeDir;
  baselinePathEntries = [
    "${homeDir}/.local/bin"
    "/etc/profiles/per-user/${username}/bin"
    "/run/current-system/sw/bin"
    "/usr/bin"
    "/bin"
    "/usr/sbin"
    "/sbin"
  ];
  bridgePathEntries =
    lib.optionals dispatcherAvailable [ headlessDispatcher.binPath ] ++ baselinePathEntries;
  bridgePath = lib.concatStringsSep ":" bridgePathEntries;
  marker = if dispatcherAvailable then "1" else "0";
  environmentGeneration = builtins.hashString "sha256" (
    builtins.toJSON {
      schemaVersion = 1;
      inherit bridgePathEntries marker;
    }
  );
  controlEnvironment = {
    CLAUDE_RC_BRIDGE_PATH = bridgePath;
    CLAUDE_RC_HEADLESS_SSH_MARKER = marker;
    CLAUDE_RC_ENVIRONMENT_GENERATION = environmentGeneration;
  };
  childEnvironment = {
    PATH = bridgePath;
    NIXOS_CONFIG_HEADLESS_SSH = marker;
    NIXOS_CONFIG_HEADLESS_SSH_GENERATION = environmentGeneration;
  };
in
{
  inherit
    bridgePathEntries
    bridgePath
    marker
    environmentGeneration
    controlEnvironment
    childEnvironment
    ;
}
