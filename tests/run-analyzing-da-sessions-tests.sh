#!/usr/bin/env bash
# analyzing-da-sessions pytest 계약 fixture driver.
#
# lefthook.yml pre-push와 tests/run-all-tests.sh는 이 파일을 동일하게 호출한다.
# pytest는 pythonWithTomlkit 런타임 스코프에 넣지 않고, repo flake.lock에 pin된
# nixpkgs python3Packages.pytest를 ad-hoc으로 사용한다.
set -euo pipefail

cd "$(dirname "$0")/.."

exec nix run --inputs-from . nixpkgs#python3Packages.pytest -- \
  modules/shared/programs/claude/files/skills/analyzing-da-sessions/tests/
