#!/usr/bin/env bash
# 실제 암호문·identity를 읽지 않는 합성 공개 헤더 검사.
set -euo pipefail
cd "$(dirname "$0")/.."
exec nix shell --inputs-from . nixpkgs#age nixpkgs#openssh --command \
  python3 tests/secret-recipient-tests.py
