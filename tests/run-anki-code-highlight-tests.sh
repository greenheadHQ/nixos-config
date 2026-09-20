#!/usr/bin/env bash
# Offline, locked npm dependency closure; no live Anki or remote CDN involved.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec nix build --no-link "${REPO_ROOT}#ankiCodeHighlightCheck"
