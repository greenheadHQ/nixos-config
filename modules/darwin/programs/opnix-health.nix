# Existing personal SA -> actual secret read. Desktop authentication is never used.
{
  config,
  pkgs,
  lib,
  constants,
  hostType,
  ...
}:
let
  monitor = import ../../shared/lib/opnix-health-check.nix {
    inherit pkgs;
    backend = "op";
    program = constants.onePassword.cliMacPath;
    tokenFile = "${config.home.homeDirectory}/${constants.onePassword.saTokenMacRelPath}";
    stateDir = "${config.home.homeDirectory}/${constants.onePassword.healthStateMacRelPath}";
    pushoverFile = "${config.xdg.configHome}/pushover/share";
    hostLabel = "Mac";
    reference = "op://${constants.onePassword.vaults.automation}/github-pat/token";
  };
  logFile = "${config.home.homeDirectory}/${constants.onePassword.healthLogMacRelPath}";
in
{
  config = lib.mkIf (hostType == "personal") {
    launchd.agents.opnix-health-mac = {
      enable = true;
      config = {
        ProgramArguments = [ "${monitor}/bin/opnix-health-check" ];
        StartInterval = 3600;
        RunAtLoad = true;
        StandardOutPath = logFile;
        StandardErrorPath = logFile;
      };
    };
  };
}
