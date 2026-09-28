#!/usr/bin/env bash
# Pure Lua fake-hs checks; never starts Hammerspoon, Anki, or an HTTP listener.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec nix shell --inputs-from "$REPO_ROOT" nixpkgs#luajit --command luajit \
  "$REPO_ROOT/tests/hammerspoon/anki-card-links.test.lua" \
  "$REPO_ROOT/modules/darwin/programs/hammerspoon/files/anki_card_links.lua"
