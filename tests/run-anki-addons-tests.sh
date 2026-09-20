#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
exec bash ./scripts/ai/test-runtime-profile.sh run "$PWD" -- \
  python3 -m unittest discover -s tests/anki-addons -v
