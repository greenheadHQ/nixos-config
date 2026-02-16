#!/usr/bin/env bash
# tests/run-eval-tests.sh
# Pre-commit hook wrapper: nix eval --impure로 E2E 설정 검증
#
# 검증 항목 (tests/eval-tests.nix 참조, 29개 테스트):
#   0. Tailscale CGNAT IP 범위 검증
#   1. 포트 충돌 없음
#   2. 컨테이너 포트 localhost-only + host network allowlist + publish 우회 방지
#   3. Caddy virtualHost Tailscale IP 전용 바인딩
#   4. Caddy globalConfig default_bind (존재 + 중복 방지)
#   5. 서비스 보안 (anki-sync, openssh, mosh, SSH 경화, vaultwarden)
#   6. 방화벽 정책 검증 (TCP/UDP/인터페이스/NAT)
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
