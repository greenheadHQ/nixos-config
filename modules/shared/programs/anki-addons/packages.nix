# Keep the exact AnkiWeb distributions: their bundled JS/vendor files can differ
# from repository HEAD. Hash mismatches fail closed; see README for updates.
{ pkgs }:
let
  sources = builtins.fromJSON (builtins.readFile ./sources.json);
in
pkgs.lib.mapAttrs (
  id: source:
  pkgs.runCommand "anki-addon-${id}-${toString source.mod}"
    {
      src = pkgs.fetchurl {
        inherit (source) url hash;
        name = "anki-addon-${id}.zip";
      };
      nativeBuildInputs = [ pkgs.unzip ];
      passthru = { inherit source; };
    }
    ''
      mkdir -p "$out"
      unzip -q "$src" -d "$out"
      test -f "$out/__init__.py"
      test ! -e "$out/meta.json"
    ''
) sources
