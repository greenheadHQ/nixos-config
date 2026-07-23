{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "shottr-cfpreferences-writer";
  version = "1";
  src = ./cfpreferences-writer.c;
  dontUnpack = true;
  strictDeps = true;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Werror \
      "$src" -framework CoreFoundation -o shottr-cfpreferences-writer
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 shottr-cfpreferences-writer \
      "$out/bin/shottr-cfpreferences-writer"
    runHook postInstall
  '';
}
