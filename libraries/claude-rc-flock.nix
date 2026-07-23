{ pkgs }:

# Claude RC production and its functional tests must exercise the same flock
# implementation on each platform. util-linux is the NixOS runtime; discoteq
# flock is the Darwin runtime because util-linux is unavailable there.
if pkgs.stdenv.isLinux then pkgs.util-linux else pkgs.flock
