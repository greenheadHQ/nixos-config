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
# Dependency 부재(codex/setsid/timeout) 환경에서는 valid-env 케이스(1, 2, 3)는 dependency 부재로
# exit 127이 되어 의미 있는 검증이 안 되므로 capability skip 패턴(WARN + exit 0)으로 동작한다.
# Invalid-env 케이스(4, 5, 6, 7)는 wrapper가 dependency resolution 이전에 env validation을 수행하므로
# dependency 부재 환경에서도 검증 가능하다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }
pass() { echo "  ok: $*"; }

# supervised resolution: nrs activation 후 PATH 또는 repo absolute path fallback.
if command -v codex-exec-supervised >/dev/null 2>&1; then
  SUPERVISED="$(command -v codex-exec-supervised)"
else
  SUPERVISED="$REPO_ROOT/modules/shared/scripts/codex-exec-supervised.sh"
  if [[ ! -x "$SUPERVISED" ]]; then
    fail "codex-exec-supervised 미설치 (~/.local/bin 또는 $SUPERVISED)"
  fi
fi

# Capability probe: codex/setsid/timeout 부재 시 valid-env 케이스 skip.
# wrapper의 dependency resolution(timeout/setsid/codex)이 통과해야 valid env + --check가 exit 0.
HAS_DEPS=1
for bin in codex setsid timeout; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    if [[ "$bin" == "timeout" ]] && command -v gtimeout >/dev/null 2>&1; then
      continue
    fi
    HAS_DEPS=0
    warn "$bin 부재 — valid-env 케이스(unset/1800/7200) skip"
    break
  fi
done

# ─── Helper: env 1개로 supervised --check 호출 후 exit code + stderr 검증 ───
# 인자: <케이스명> <env_assignment | "unset"> <expected_rc> [<expected_stderr_pattern>]
run_case() {
  local name="$1" env_spec="$2" expected_rc="$3" expected_stderr_pattern="${4:-}"
  local rc=0 stderr_log
  stderr_log="$(mktemp "${TMPDIR:-/tmp}/codex-exec-supervised-test.XXXXXX")"

  if [[ "$env_spec" == "unset" ]]; then
    env -u CODEX_EXEC_TIMEOUT_SECONDS "$SUPERVISED" --check 2>"$stderr_log" || rc=$?
  else
    env "$env_spec" "$SUPERVISED" --check 2>"$stderr_log" || rc=$?
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
echo "    HAS_DEPS=$HAS_DEPS"

# ── valid-env 케이스 (dependency 가용 시만) ──
# 함수명은 "1800 default 검증"이 아닌 "1800 explicit override 수용 검증"임을 명확화한다.
if [[ "$HAS_DEPS" -eq 1 ]]; then
  run_case "test_unset_env_default_path (default 1800 적용 path)" \
    "unset" 0
  run_case "test_explicit_1800_override_accepted (explicit 1800 수용)" \
    "CODEX_EXEC_TIMEOUT_SECONDS=1800" 0
  run_case "test_explicit_7200_cap_boundary_accepted (cap 경계 수용)" \
    "CODEX_EXEC_TIMEOUT_SECONDS=7200" 0
else
  warn "dependency 부재 — test_unset_env_default_path / test_explicit_1800_override_accepted / test_explicit_7200_cap_boundary_accepted skip"
fi

# ── invalid-env 케이스 (dependency 부재여도 wrapper가 env validation을 먼저 수행하므로 검증 가능) ──
run_case "test_explicit_7201_rejected_above_cap" \
  "CODEX_EXEC_TIMEOUT_SECONDS=7201" 127 "상한(7200)을 초과"
run_case "test_zero_rejected_not_positive" \
  "CODEX_EXEC_TIMEOUT_SECONDS=0" 127 "양수 정수만 허용"
run_case "test_negative_rejected" \
  "CODEX_EXEC_TIMEOUT_SECONDS=-1" 127
run_case "test_non_numeric_rejected" \
  "CODEX_EXEC_TIMEOUT_SECONDS=abc" 127

echo "==> All wrapper env validation boundary cases passed"
