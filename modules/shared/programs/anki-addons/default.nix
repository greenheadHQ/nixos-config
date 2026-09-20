{
  config,
  lib,
  pkgs,
  constants,
  hostType,
  ...
}:
let
  cfg = config.programs.ankiAddons;
  packages = import ./packages.nix { inherit pkgs; };
  manifest = pkgs.writeText "anki-addons.json" (
    builtins.toJSON (
      lib.mapAttrs (id: addon: {
        source = toString addon.package;
        name = addon.package.source.name;
        mod = addon.package.source.mod;
        inherit (addon) config enabled;
      }) cfg.addons
    )
  );
  manager = pkgs.writeShellScriptBin "anki-addons" ''
    exec ${pkgs.python3}/bin/python3 ${./manage.py} \
      --manifest ${manifest} --base ${lib.escapeShellArg cfg.baseDirectory} "$@"
  '';
in
{
  options.programs.ankiAddons = {
    enable = lib.mkEnableOption "pinned desktop Anki add-ons without managing Anki or its collection";
    baseDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/${constants.paths.ankiDesktopBaseRelative}";
      description = "Anki data directory; only addons21 and the adjacent backup directory are managed.";
    };
    addons = lib.mkOption {
      default = { };
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            package = lib.mkOption { type = lib.types.package; };
            config = lib.mkOption {
              type = (pkgs.formats.json { }).type;
              default = { };
              description = "Non-secret config keys enforced on apply; other runtime keys are preserved.";
            };
            enabled = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };
        }
      );
    };
  };

  config = lib.mkMerge [
    {
      # Personal desktop opt-in. Work Mac can enable this same module explicitly.
      programs.ankiAddons.enable = lib.mkDefault (hostType == "personal");
      programs.ankiAddons.addons = lib.mkMerge [
        (lib.mapAttrs (_: package: { inherit package; }) packages)
        {
          "1077002392".config = {
            showLinksPageAutomatically = false;
            showGraphPageAutomatically = false;
            showLinksPageInReviewerAutomatically = false;
            linkMaxLines = "5";
            shortcuts-copyNoteID = "Alt+Shift+C";
            shortcuts-copyNoteLink = "Alt+Shift+L";
            shortcuts-openNoteInNewWindow = "Alt+Shift+W";
            shortcuts-insertLinkWithClipboardID = "Alt+Shift+V";
            shortcuts-insertNewLink = "Alt+Shift+N";
            shortcuts-insertLinkTemplate = "Alt+Shift+T";
          };
          "805891399".config.auto_reset_number = 2;
        }
      ];
    }
    (lib.mkIf cfg.enable {
      home.packages = [ manager ];
      home.activation.ankiAddons = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${manager}/bin/anki-addons apply --defer-if-running
      '';
    })
  ];
}
