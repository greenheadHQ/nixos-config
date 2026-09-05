#!/usr/bin/env bash
# issuing-codex-pairing-code 스킬 스크립트의 unittest 계약 driver (pytest 로 수집).
#
# tests/run-all-tests.sh 가 이 파일을 호출한다. devShell 이 사전 빌드한 prePushRuntime profile 의
# pytest 를 재사용하고, profile 이 없으면 같은 flake package 의 검증된 profile 을 on-demand 로
# 준비한다(다른 pytest driver 와 동일한 계약).
set -euo pipefail

cd "$(dirname "$0")/.."

exec bash ./scripts/ai/test-runtime-profile.sh run "$PWD" -- pytest \
  modules/shared/programs/claude/files/skills/issuing-codex-pairing-code/tests/
