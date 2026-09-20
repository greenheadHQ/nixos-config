#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ANKI_ADDONS_OUT="$(nix build --no-link --print-out-paths .#ankiDesktopAddons)"
export ANKI_NOTE_LINKER_SOURCE="$ANKI_ADDONS_OUT/1077002392"
exec bash ./scripts/ai/test-runtime-profile.sh run "$PWD" -- \
  python3 -m unittest discover -s tests/anki-addons -v
