#!/usr/bin/env bash
# tests/run-eval-tests.sh
# Pre-commit hook wrapper: nix eval --impure로 E2E 설정 검증
#
# 검증 항목: tests/eval-tests.nix 참조
# 네트워크 노출 경계 중심 — 포트, 컨테이너, Caddy, 방화벽, 서비스 보안
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Running eval tests..."

if output=$(nix eval --impure --file "$SCRIPT_DIR/eval-tests.nix" 2>&1); then
  echo "All eval tests passed."
else
  echo "Eval tests FAILED:"
  echo "$output"
  exit 1
fi
