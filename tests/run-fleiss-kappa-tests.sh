#!/usr/bin/env bash
# fleiss-kappa.py harness 계약 pytest driver (run-da 소유).
#
# lefthook.yml pre-push와 tests/run-all-tests.sh는 이 파일을 동일하게 호출한다.
# devShell이 사전 빌드한 prePushRuntime profile의 pytest를 재사용하고, profile이 없으면
# 같은 flake package의 검증된 profile을 on-demand로 준비한다.
set -euo pipefail

cd "$(dirname "$0")/.."

exec bash ./scripts/ai/test-runtime-profile.sh run "$PWD" -- pytest \
  modules/shared/programs/claude/files/scripts/tests/test_fleiss_kappa.py
