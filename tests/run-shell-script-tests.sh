#!/usr/bin/env bash
# tests/run-shell-script-tests.sh
# Shell script fixture 테스트 실행기.
# 테스트 런타임 bootstrap 정책은 scripts/ai/lib/tomlkit-bootstrap.sh 단일 소스에서 관리한다.
# required CI는 flake-pinned `.#prePushRuntime` profile을 사용한다. 수동 실행도 current profile을
# 우선 재사용하되, profile 부재/stale 시 repo-pinned composite nix shell로 같은 필수 도구 계약
# (tomlkit + GNU coreutils/findutils 등, #1009)을 유지한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
tomlkit_bootstrap_require "$REPO_ROOT" "${BASH_SOURCE[0]}" "$@"

echo "Running shell script tests..."
bash "$SCRIPT_DIR/shell-script-tests.sh"
echo "All shell script tests passed."
