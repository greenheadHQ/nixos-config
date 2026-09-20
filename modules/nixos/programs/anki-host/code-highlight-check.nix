# Rebuild the checked-in offline asset and execute its real DOM adapter.
{ pkgs }:
pkgs.buildNpmPackage {
  pname = "anki-code-highlight-check";
  version = "1.0.0";
  src = pkgs.lib.cleanSourceWith {
    src = ./code-highlighting;
    filter = path: _type: builtins.baseNameOf path != "node_modules";
  };
  nodejs = pkgs.nodejs_24;
  npmDepsHash = "sha256-c4JUFuGHLvZKTCCP2trdmLLU99YwA7liRgKbcmOHKMs=";
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  dontNpmInstall = true;
  buildPhase = ''
    runHook preBuild
    npm run check
    npm run test:library
    export ANKI_SYNTAX_PACKAGE="$PWD"
    export ANKI_SYNTAX_ADDON=${./sync-addon}
    export ANKI_NOTE_LINK_FIXTURES=${../../../../tests/fixtures/anki-note-link}
    node --test ${../../../../tests/anki-web}/*.test.mjs
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p "$out"
    cp -r dist "$out/"
  '';
}
