#!/usr/bin/env bash
# Darwin-only runtime regression: no live services or host pipe exhaustion.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "N/A: Claude RC dynamic pipe regression targets Darwin; lifecycle fixtures still apply."
  exit 0
fi
exec nix build --no-link -L "${REPO_ROOT}#claudeRcRuntimeCheck"
