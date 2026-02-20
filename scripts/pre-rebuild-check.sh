#!/usr/bin/env bash
# scripts/pre-rebuild-check.sh
# 빌드 전 검증 (flake check + format check)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

echo "═══ Flake Check ═══"
nix flake check --no-build --all-systems

echo
echo "═══ Format Check ═══"
git ls-files '*.nix' | xargs nixfmt --check

echo
echo "✓ 모든 검증 통과"
