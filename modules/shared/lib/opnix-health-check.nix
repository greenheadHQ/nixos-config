# Shared monitor: platform modules supply only paths, backend, and schedule.
{
  pkgs,
  backend,
  program,
  tokenFile,
  stateDir,
  pushoverFile,
  hostLabel,
  reference,
}:
let
  notifier = pkgs.writeShellApplication {
    name = "opnix-health-notify";
    runtimeInputs = [ pkgs.curl ];
    text = ''
      # shellcheck source=/dev/null
      source "${../scripts/lib/pushover.sh}"
      pushover_send ${pkgs.lib.escapeShellArg pushoverFile} "$@"
    '';
  };
  monitorConfig = pkgs.writeText "opnix-health-config.json" (
    builtins.toJSON {
      inherit
        backend
        program
        tokenFile
        stateDir
        hostLabel
        reference
        ;
      notifier = "${notifier}/bin/opnix-health-notify";
      timeoutSeconds = 20;
      retryDelaySeconds = 5;
      reminderSeconds = 86400;
    }
  );
in
pkgs.writeShellScriptBin "opnix-health-check" ''
  exec ${pkgs.python3}/bin/python3 ${../scripts/opnix-health-check.py} ${monitorConfig}
''
