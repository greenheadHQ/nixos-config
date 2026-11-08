#!/usr/bin/env bash
# Copyparty의 생산 마운트 의존성을 실제 systemd가 해석하는 격리 Linux VM에서 검사한다.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "N/A: Copyparty 마운트 실행 검사는 x86_64-linux 대상이며 현재 플랫폼에서는 VM을 실행하지 않습니다."
  exit 0
fi
exec nix build --no-link --print-build-logs "${REPO_ROOT}#checks.x86_64-linux.copyparty-mount"
