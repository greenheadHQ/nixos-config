#!/usr/bin/env bash
# Build the same check that blocks a MiniPC system build before activation.
# Darwin evaluates its wiring via eval-tests, without building Linux Anki.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "N/A: Anki runtime checks target the x86_64-linux host; evaluation checks still apply."
  exit 0
fi
exec nix build --no-link "${REPO_ROOT}#checks.x86_64-linux.anki-host-runtime"
