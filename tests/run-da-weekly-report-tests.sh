#!/usr/bin/env bash
# da-weekly-report pytest driver.
set -euo pipefail

cd "$(dirname "$0")/.."

exec nix run --inputs-from . nixpkgs#python3Packages.pytest -- \
  modules/nixos/programs/da-weekly-report/tests/
