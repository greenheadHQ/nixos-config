{ pkgs }:
let
  shell = import ../libraries/claude-rc-shell.nix { inherit pkgs; };
  maint = import ../modules/nixos/lib/claude-rc-maint-package.nix { inherit pkgs; };
  wrapper = import ../modules/nixos/lib/claude-rc-package.nix { inherit pkgs; };
  flock = import ../libraries/claude-rc-flock.nix { inherit pkgs; };
in
assert pkgs.stdenv.hostPlatform.isDarwin;
pkgs.runCommand "claude-rc-runtime-check"
  {
    nativeBuildInputs = [
      pkgs.stdenv.cc
      pkgs.python3
    ];
  }
  ''
    $CC -Wall -Wextra -Werror -dynamiclib \
      ${./fixtures/claude-rc-pipe-pressure.c} -o pipe-pressure.dylib
    python3 ${./test-claude-rc-runtime.py} \
      --bash ${shell.bash}/bin/bash \
      --maint ${maint}/bin/claude-rc-maint \
      --wrapper ${wrapper}/bin/claude-rc \
      --flock ${flock}/bin/flock \
      --interposer "$PWD/pipe-pressure.dylib" \
      ${pkgs.lib.optionalString (
        pkgs.bashNonInteractive.version == "5.3p15"
      ) "--vulnerable-bash ${pkgs.bashNonInteractive}/bin/bash"}
    touch "$out"
  ''
