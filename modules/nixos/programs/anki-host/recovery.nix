# Root-only offline field extraction; no running service or MCP file access.
{
  config,
  pkgs,
  lib,
  constants,
  ...
}:
let
  cfg = config.homeserver.ankiHost;
  command = pkgs.writeShellApplication {
    name = "anki-host-recover-fields";
    runtimeInputs = [ pkgs.util-linux ];
    runtimeEnv = {
      ANKI_RECOVERY_INSTANCES = builtins.toJSON (builtins.attrNames cfg.instances);
      ANKI_RECOVERY_STATE_ROOT = constants.paths.ankiHostState;
      ANKI_RECOVERY_DAILY_ROOT = "${constants.paths.mediaData}/${constants.paths.ankiHostBackupsRelPath}";
      ANKI_RECOVERY_RESTORE_ROOT = "${constants.paths.mediaData}/${constants.paths.ankiHostRestorePointsRelPath}";
    };
    # Anki's cached lib output contains its official Python wheels and their
    # dependencies. -I ignores caller Python paths; no Anki derivation override.
    text = ''
      if [ "$EUID" -ne 0 ]; then
        echo '{"ok":false,"error":"root-required"}' >&2
        exit 1
      fi
      exec unshare --net ${pkgs.python3}/bin/python3 -I -c ${lib.escapeShellArg ''
        import runpy, site
        site.addsitedir("${pkgs.anki.lib}/${pkgs.python3.sitePackages}")
        runpy.run_path("${./files/recover-fields.py}", run_name="__main__")
      ''} "$@"
    '';
  };
in
{
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ command ];
  };
}
