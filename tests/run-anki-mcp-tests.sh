#!/usr/bin/env bash
# anki-mcp 오프라인 단위 테스트 — flake 패키지 ankiMcpTestEnv(서비스와 같은 핀된 mcp SDK)로 pytest를 돈다.
# AnkiConnect·헬퍼·systemctl은 전부 fake라 네트워크·호스트 상태와 무관하다.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
exec nix shell "${REPO_ROOT}#ankiMcpTestEnv" -c python -m pytest -q -p no:cacheprovider tests/anki-mcp
