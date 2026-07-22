{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "claude-rc-launch-group";
  version = "1";
  src = ../scripts/claude-rc-launch-group.c;
  dontUnpack = true;
  strictDeps = true;

  buildPhase = ''
    runHook preBuild
    $CC -std=c11 -O2 -Wall -Wextra -Werror "$src" -o claude-rc-launch-group
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0755 claude-rc-launch-group "$out/bin/claude-rc-launch-group"
    runHook postInstall
  '';
}
