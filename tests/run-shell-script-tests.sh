#!/usr/bin/env bash
# tests/run-shell-script-tests.sh
# Shell script fixture 테스트 실행기
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running shell script tests..."
bash "$SCRIPT_DIR/shell-script-tests.sh"
echo "All shell script tests passed."
