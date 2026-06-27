#!/usr/bin/env bash
# tests/run-all-tests.sh — 통합 검증 진입점
#
# 저장소의 모든 테스트 드라이버 + flake 평가 게이트를 한 번에 순차 실행한다. push 전(로컬
# 훅 우회 여부와 무관하게 재검증)과 신규 머신 온보딩 시 실행을 권장한다. 향후 원격 CI도 이
# 단일 진입점을 재사용해 중복 정의를 피한다.
#
# 커버리지 경계: 이 진입점은 pre-push 게이트(shell-script-tests · codex-hook-fixtures ·
#   flake-check · statusline-bats) + eval-tests + 어느 훅에도 미연결된 tests/test-*.sh 단위
#   드라이버(codex-exec-supervised · precommit-staged-snapshot)를 포함한다. 벤치마크
#   tests/bench-shell-startup.sh는 회귀 게이트가 아니라 측정 도구이므로(자체 헤더에 명시) 제외한다.
#   pre-commit의 staged 스냅샷 정책(gitleaks · nixfmt · shellcheck · skill-noise)은 staged index
#   기준이라 working-tree 통합 러너의 범위가 아니며, 커밋 시점 게이트로 별도 적용된다.
#
# 실패 정책: set -e 미사용 — 한 드라이버가 실패해도 나머지를 계속 실행하여 전체 그림을
#   확보한 뒤, 끝에서 통과/SKIP/실패를 구분 요약하고 하나라도 실패하면 non-zero로 종료한다.
#
# 런타임 의존성: 드라이버마다 다르다(일부는 `nix shell` wrap 필요). 각 호출 방식은
#   lefthook.yml의 해당 항목과 동일하게 유지한다(이 파일이 그 단일 진입점). 호출 방식을
#   바꿀 때는 lefthook.yml과 함께 갱신한다.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT" || exit 1

PASSED=()
SKIPPED=()
FAILED=()

# 드라이버를 실행하고 통과/SKIP/실패로 분류한다. SKIP은 드라이버가 환경/도구 미가용 시
# stdout/stderr에 "SKIP:" 마커를 출력하고 exit 0으로 종료하는 경우(예: precommit-staged-snapshot)
# 를 가리키며, 미실행을 통과로 오인하지 않도록 요약에서 별도로 집계한다.
run_driver() {
  local name="$1"
  shift
  local log
  log="$(mktemp "${TMPDIR:-/tmp}/run-all-tests.XXXXXX")"
  printf '\n━━━ %s ━━━\n' "$name"
  if "$@" 2>&1 | tee "$log"; then
    if grep -q 'SKIP:' "$log"; then
      printf '⊘ %s (skipped — 환경/도구 미가용)\n' "$name"
      SKIPPED+=("$name")
    else
      printf '✓ %s\n' "$name"
      PASSED+=("$name")
    fi
  else
    printf '✗ %s\n' "$name"
    FAILED+=("$name")
  fi
  rm -f "$log"
}

# 1) eval-tests — Nix 평가(E2E 설정 검증, 선택적 lazy 평가). wrap 불필요.
run_driver "eval-tests" bash tests/run-eval-tests.sh

# 2) shell-script-tests — 배포 레이아웃 fixture. runner가 repo-pinned pythonWithTomlkit으로
#    self-wrap하지만, 미가용 환경 대비 명시적으로 nix shell wrap + _TOMLKIT_BOOTSTRAP_READY=1로
#    중첩 nix shell 재실행을 방지한다(lefthook pre-push와 동일).
run_driver "shell-script-tests" \
  nix shell .#pythonWithTomlkit --command env _TOMLKIT_BOOTSTRAP_READY=1 \
  bash tests/run-shell-script-tests.sh

# 3) codex-hook-fixtures — Codex stable hook 회귀 차단 결정적 fixture. --no-live, Python stdlib only.
run_driver "codex-hook-fixtures" bash tests/test-codex-hook-fixtures.sh --no-live

# 4) codex-exec-supervised — codex-exec-supervised wrapper의 env validation 경계(타임아웃 cap/양수/
#    non-numeric) 단위 검증. invalid-env 케이스는 codex/setsid/timeout 부재 환경에서도 실행되어
#    핵심 거부 경계를 항상 검증한다. valid-env 케이스는 deps 부재 시 "WARN" + exit 0으로
#    capability-skip된다("SKIP:" 마커가 아니므로 SKIP 집계엔 잡히지 않고 PASS로 표기되나, 항상
#    실행되는 거부 경계 검증이 핵심이므로 PASS 집계는 유효).
run_driver "codex-exec-supervised" bash tests/test-codex-exec-supervised.sh

# 5) flake-check — 전 시스템 flake 평가 게이트(repo 전역). eval-tests의 선택적 평가가 강제하지
#    않는 darwin/nixos configuration toplevel 평가 오류까지 검출하므로 커버리지가 고유하다.
run_driver "flake-check" nix flake check --no-build --all-systems

# 6) statusline-bats — statusline Bats 테스트. nixpkgs#bats를 nix shell로 제공하고 TERM을 주입한다.
run_driver "statusline-bats" \
  env TERM="${TERM:-xterm-256color}" nix shell --inputs-from . nixpkgs#bats --command \
  bats modules/shared/programs/claude/files/scripts/tests/statusline.bats

# 7) precommit-staged-snapshot — 어느 훅에도 연결되지 않은 수동 전용 드라이버를 통합에 포함한다.
#    devShell 전체 도구(git/jq 등)를 요구하며, 미가용 시 스크립트가 자체적으로 "SKIP: ... not found"
#    출력 + exit 0 처리하므로(tests/test-precommit-staged-snapshot.sh) 통합에 포함해도 환경 부재 시
#    실패하지 않고, 위 run_driver가 이를 SKIP으로 분류한다.
run_driver "precommit-staged-snapshot" bash tests/test-precommit-staged-snapshot.sh

printf '\n━━━ 요약 ━━━\n'
printf '통과 %d · SKIP %d · 실패 %d\n' "${#PASSED[@]}" "${#SKIPPED[@]}" "${#FAILED[@]}"
if (( ${#SKIPPED[@]} )); then
  printf '⊘ SKIP(미실행): %s\n' "${SKIPPED[*]}"
fi
if (( ${#FAILED[@]} )); then
  printf '✗ 실패: %s\n' "${FAILED[*]}"
  exit 1
fi
printf '✓ 실패 없음 (SKIP이 있으면 환경/도구 미가용으로 미실행 — 위 목록 확인)\n'
