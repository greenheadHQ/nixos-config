#!/usr/bin/env bash
# tests/run-shell-script-tests.sh
# Shell script fixture 테스트 실행기.
# tomlkit bootstrap 정책은 scripts/ai/lib/tomlkit-bootstrap.sh 단일 소스에서 관리한다.
# 수동 실행(`bash tests/run-shell-script-tests.sh`)과 lefthook pre-push 경로가 동일한
# hermetic runtime (flake-pinned `.#pythonWithTomlkit`)을 쓰도록 강제한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
tomlkit_bootstrap_require "$REPO_ROOT" "${BASH_SOURCE[0]}" "$@"

echo "Running shell script tests..."
bash "$SCRIPT_DIR/shell-script-tests.sh"
echo "All shell script tests passed."
