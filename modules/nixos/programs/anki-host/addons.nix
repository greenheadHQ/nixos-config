# Small addon derivations, independently buildable without rebuilding Anki.
{ pkgs }:
let
  version = "2.0.0";
in
{
  inherit version;
  helper = pkgs.anki-utils.buildAnkiAddon {
    pname = "anki_host_sync";
    inherit version;
    src = ./sync-addon;
  };
  # withConfig is a symlinkJoin and does not execute source patch phases.
  # Override the source derivation first; configure the returned addon later.
  connect = pkgs.ankiAddons.anki-connect.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [ ./anki-connect-access.patch ];
    postPatch = (old.postPatch or "") + ''
      cp ${./anki-connect-access.py} anki_host_access.py
    '';
  });
}
