# Start from pinned AnkiWeb distributions: their bundled JS/vendor files can
# differ from repository HEAD. Reviewed local patches are explicit below.
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
      nativeBuildInputs = [
        pkgs.unzip
        pkgs.patch
      ];
      passthru = { inherit source; };
    }
    ''
      mkdir -p "$out"
      unzip -q "$src" -d "$out"
      test -f "$out/__init__.py"
      test ! -e "$out/meta.json"
      ${pkgs.lib.optionalString (id == "1077002392") ''
        # Keep code samples literal without changing Note Linker's graph/index.
        patch --batch --fuzz=0 -d "$out" -p1 < ${./note-linker-code-literals.patch}
        cp ${./note-linker-html.py} "$out/anki_note_linker/core/html_links.py"
      ''}
    ''
) sources
// {
  "nixos-difficulty-badge" =
    pkgs.runCommand "anki-addon-difficulty-badge-1"
      {
        passthru.source = {
          name = "점검 후보";
          mod = 1;
        };
      }
      ''
        mkdir -p "$out"
        cp ${./difficulty-badge/__init__.py} "$out/__init__.py"
        cp ${./difficulty-badge/manifest.json} "$out/manifest.json"
        # The host/MCP and desktop evaluate one policy source, not separate copies.
        cp ${../../../nixos/programs/anki-host/sync-addon/difficulty.py} "$out/difficulty.py"
      '';
}
