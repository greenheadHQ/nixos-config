#!/usr/bin/env bash
# 실제 init.lua의 Finder 단축키를 Hammerspoon 대역으로 검증한다. 앱·클립보드를 조작하지 않는다.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec nix shell --inputs-from "$REPO_ROOT" nixpkgs#luajit --command luajit \
  "$REPO_ROOT/tests/hammerspoon/finder-ghostty.test.lua" \
  "$REPO_ROOT/modules/darwin/programs/hammerspoon/files/init.lua"
