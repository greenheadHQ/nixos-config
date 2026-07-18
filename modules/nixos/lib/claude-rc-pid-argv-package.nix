{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "claude-rc-pid-argv";
  version = "1";
  src = ../scripts/claude-rc-pid-argv.c;
  dontUnpack = true;
  strictDeps = true;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Werror "$src" -o claude-rc-pid-argv
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 claude-rc-pid-argv "$out/bin/claude-rc-pid-argv"
    runHook postInstall
  '';
}
