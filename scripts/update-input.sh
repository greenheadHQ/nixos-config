#!/usr/bin/env bash
# scripts/update-input.sh
# 특정 Flake input 업데이트 후 변경사항 표시
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "사용법: $0 <input-name> [input-name ...]"
  echo "예시:   $0 nixpkgs"
  echo "        $0 nixpkgs home-manager"
  echo
  echo "전체 업데이트: nix flake update"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR"

for input in "$@"; do
  echo "═══ Updating: $input ═══"
  nix flake lock --update-input "$input"
done

echo
echo "═══ flake.lock 변경사항 ═══"
git diff flake.lock
