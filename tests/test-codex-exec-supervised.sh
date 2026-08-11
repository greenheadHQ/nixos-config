#!/usr/bin/env bash
# tests/test-codex-exec-supervised.sh
# codex-exec-supervised wrapper의 env validation boundary를 검증하는 unit fixture.
#
# 책임 경계: 본 fixture는 hook fixture runner(tests/test-codex-hook-fixtures.sh)와 분리되어 있다.
# hook runner는 tomlkit bootstrap + hook sandbox + live codex matrix를 포함하는 통합 시나리오이고,
# wrapper의 env validation은 그 책임 경계 밖이다. wrapper만 빠르게 회귀 검증할 때 hook 인프라
# 의존 없이 실행 가능하도록 별도 entry point로 둔다.
#
# 검증 대상 (CODEX_EXEC_TIMEOUT_SECONDS env validation):
#   1. unset env + --check         → exit 0  (default 1800 path, dependency 가용 시)
#   2. 1800 (explicit override)    → exit 0
#   3. 7200 (cap 경계)             → exit 0
#   4. 7201 (cap+1)                → exit 127 + stderr "상한(7200)을 초과"
#   5. 0    (양수 검증)            → exit 127 + stderr "양수 정수만 허용"
#   6. -1   (음수)                 → exit 127
#   7. abc  (non-numeric)          → exit 127
#
# 검증 대상 (정본 변수명 near-miss fail-fast):
#   8. CODEX_EXEC_TIMEOUT=1500 (정본 _SECONDS 오타) → exit 127 + stderr "정본 변수명이 아님"
#   9. CODEX_EXEC_KILL_AFTER_SECONDS=5 (known 변수) → exit 0 (fail-fast 미발동 확인)
#  10. CODEX_EXEC_SERVER_URL=x (upstream codex 예약 접두사) → exit 0 (계열 밖 통과 확인)
#
# Host dependency와 무관하게 위 목록의 모든 경계를 검증한다. `--check`는 dependency를 실행하지 않고
# resolution만 확인하므로 codex/setsid/timeout executable stub과 explicit binary env를 주입한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "  ok: $*"; }

SUPERVISED="$REPO_ROOT/modules/shared/scripts/codex-exec-supervised.sh"
[[ -x "$SUPERVISED" ]] || fail "codex-exec-supervised source script is not executable: $SUPERVISED"

TEST_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-exec-supervised-fixture.XXXXXX")"
trap 'rm -rf "$TEST_TMP_DIR"' EXIT
STUB_BIN="$TEST_TMP_DIR/bin"
mkdir -p "$STUB_BIN"
for bin in codex setsid timeout; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/$bin"
  chmod +x "$STUB_BIN/$bin"
done

# ─── Helper: env 1개로 supervised --check 호출 후 exit code + stderr 검증 ───
# 인자: <케이스명> <env_assignment | "unset"> <expected_rc> [<expected_stderr_pattern>]
run_case() {
  local name="$1" env_spec="$2" expected_rc="$3" expected_stderr_pattern="${4:-}"
  local rc=0 stderr_log
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/codex-exec-supervised-test.XXXXXX")"

  # env -i로 부모 셸의 CODEX_EXEC_* 상속을 차단한다 — 부모 환경에 near-miss/invalid 값이
  # 있으면 케이스가 지정한 값보다 먼저 걸려 false fail이 난다. 각 케이스는 자신이 명시한
  # 변수만 갖는 클린 환경에서 실행된다.
  if [[ "$env_spec" == "unset" ]]; then
    env -i \
      PATH="$STUB_BIN:$PATH" \
      CODEX_EXEC_TIMEOUT_BIN="$STUB_BIN/timeout" \
      CODEX_EXEC_SETSID_BIN="$STUB_BIN/setsid" \
      "$SUPERVISED" --check 2>"$stderr_log" || rc=$?
  else
    env -i "$env_spec" \
      PATH="$STUB_BIN:$PATH" \
      CODEX_EXEC_TIMEOUT_BIN="$STUB_BIN/timeout" \
      CODEX_EXEC_SETSID_BIN="$STUB_BIN/setsid" \
      "$SUPERVISED" --check 2>"$stderr_log" || rc=$?
  fi

  if [[ "$rc" -ne "$expected_rc" ]]; then
    local stderr_tail
    stderr_tail="$(tail -5 "$stderr_log" 2>/dev/null || true)"
    rm -f "$stderr_log"
    fail "[$name] expected rc=$expected_rc, got rc=$rc. stderr_tail: ${stderr_tail:-<empty>}"
  fi

  if [[ -n "$expected_stderr_pattern" ]]; then
    if ! grep -qF "$expected_stderr_pattern" "$stderr_log"; then
      local stderr_tail
      stderr_tail="$(tail -5 "$stderr_log" 2>/dev/null || true)"
      rm -f "$stderr_log"
      fail "[$name] stderr에 '$expected_stderr_pattern' 미포함. stderr_tail: ${stderr_tail:-<empty>}"
    fi
  fi

  rm -f "$stderr_log"
  pass "$name"
}

echo "==> codex-exec-supervised env validation boundary fixture"
echo "    SUPERVISED=$SUPERVISED"
echo "    DEPENDENCY_STUBS=$STUB_BIN"

# ── valid-env 케이스 ──
# 함수명은 "1800 default 검증"이 아닌 "1800 explicit override 수용 검증"임을 명확화한다.
run_case "test_unset_env_default_path (default 1800 적용 path)" \
  "unset" 0
run_case "test_explicit_1800_override_accepted (explicit 1800 수용)" \
  "CODEX_EXEC_TIMEOUT_SECONDS=1800" 0
run_case "test_explicit_7200_cap_boundary_accepted (cap 경계 수용)" \
  "CODEX_EXEC_TIMEOUT_SECONDS=7200" 0

# ── invalid-env 케이스 ──
run_case "test_explicit_7201_rejected_above_cap" \
  "CODEX_EXEC_TIMEOUT_SECONDS=7201" 127 "상한(7200)을 초과"
run_case "test_zero_rejected_not_positive" \
  "CODEX_EXEC_TIMEOUT_SECONDS=0" 127 "양수 정수만 허용"
run_case "test_negative_rejected" \
  "CODEX_EXEC_TIMEOUT_SECONDS=-1" 127
run_case "test_non_numeric_rejected" \
  "CODEX_EXEC_TIMEOUT_SECONDS=abc" 127

# ── 정본 변수명 near-miss fail-fast 케이스 ──
# 정본 변수명 오타(CODEX_EXEC_TIMEOUT — _SECONDS 누락)가 침묵으로 무시되어 호출 의도가
# 소실되는 사고 방지 (2026-08-06 실사례). known 변수는 fail-fast를 발동시키지 않아야 하고,
# 계열 밖 CODEX_EXEC_*(upstream codex가 예약한 CODEX_EXEC_SERVER_* 등)는 통과해야 한다.
run_case "test_near_miss_codex_exec_var_rejected (오타 변수 fail-fast)" \
  "CODEX_EXEC_TIMEOUT=1500" 127 "정본 변수명이 아님"
run_case "test_known_kill_after_var_accepted (known 변수 fail-fast 미발동)" \
  "CODEX_EXEC_KILL_AFTER_SECONDS=5" 0
run_case "test_upstream_reserved_prefix_accepted (upstream 예약 접두사 통과)" \
  "CODEX_EXEC_SERVER_URL=http://localhost:1" 0

echo "==> All wrapper env validation boundary cases passed"
