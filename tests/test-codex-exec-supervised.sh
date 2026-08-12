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
#  11. CODEX_EXEC_REQUIRE_NONEMPT=x (REQUIRE 계열 오타) → exit 127
#
# 검증 대상 (CODEX_EXEC_REQUIRE_NONEMPTY 값 검증):
#  12. 빈 값 → exit 127 / 상대경로 → exit 127
#
# 검증 대상 (실행 wiring — pass-through stub으로 setsid→timeout→(shim)→codex 체인을 실제 실행):
#  13. REQUIRE 미설정: timeout argv에 --kill-after 존재·--foreground 부재·shim(bash -c) 부재,
#      codex 인자(빈 인자/공백/glob/선행 -) NUL-delimited 기록으로 보존 확인, codex rc(0/1/124/137) 전파
#  14. REQUIRE 설정: timeout argv에 shim 존재 + codex 인자 보존
#      / 정상(non-empty) 파일 → codex rc 전파
#      / 빈 파일·부재·디렉터리 + codex rc 0 → exit 3 + stderr "codex-exec-supervised: empty output"
#      / 빈 파일 + codex rc 124 → 124 보존 (식별자 부재 — timeout 신호를 덮어쓰지 않음)
#      / codex 자체 rc 3 → 3 전파 (식별자 부재로 wrapper rc 3과 구별)
#
# 검증 대상 (shim TERM 생존 실측 — 실제 GNU timeout, issue #1228 4단계 (c)):
#  15. TERM 무시 codex stub + 실제 GNU timeout → TERM→KILL 승급(rc 137) + 잔존 프로세스 0
#      (shim이 그룹 TERM에서 codex보다 먼저 죽으면 timeout이 --kill-after 승급을 취소하는
#       GNU timeout 함정의 회귀 차단). TERM 순응 stub → rc 124 (정상 timeout 경로 비회귀).
#
# `--check` 경계(1~12)는 host dependency와 무관하게 executable stub + explicit binary env로
# 검증한다. 실행 wiring(13~14)은 pass-through stub 체인으로 wrapper의 실제 exec 경로를 돌린다.
# TERM 실측(15)만 실제 GNU timeout을 요구한다 — devShell/prePushRuntime profile이 coreutils를
# 보장하므로(#1009) 부재는 환경 결함으로 fail 처리한다 (조용한 skip 금지).

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

# ── CODEX_EXEC_REQUIRE_NONEMPTY near-miss / 값 검증 케이스 (issue #1228) ──
# 계열(CODEX_EXEC_REQUIRE*)을 case에 추가하지 않고 정본 목록만 추가하면
# CODEX_EXEC_REQUIRE_NONEMPT 같은 오타가 조용히 통과한다 — 오타 fail-fast를 검증한다.
run_case "test_require_nonempty_near_miss_typo_rejected (REQUIRE 계열 오타 fail-fast)" \
  "CODEX_EXEC_REQUIRE_NONEMPT=/tmp/x" 127 "정본 변수명이 아님"
run_case "test_require_nonempty_valid_absolute_accepted (정상 절대경로 수용)" \
  "CODEX_EXEC_REQUIRE_NONEMPTY=/tmp/result.md" 0
run_case "test_require_nonempty_empty_value_rejected (빈 값 fail-closed)" \
  "CODEX_EXEC_REQUIRE_NONEMPTY=" 127 "절대경로만 허용"
run_case "test_require_nonempty_relative_path_rejected (상대경로 fail-closed)" \
  "CODEX_EXEC_REQUIRE_NONEMPTY=result.md" 127 "절대경로만 허용"

# ─── pass-through stub 체인 (실행 wiring 검증용) ───
# --check 케이스의 exit-0 stub과 달리, 실행 경로(wrapper 최상위 exec) 검증은 setsid→timeout→
# (shim)→codex 체인이 실제로 돌아야 한다. 각 stub은 받은 argv를 NUL-delimited로 기록한 뒤
# 다음 단계를 exec한다. 기록 경로는 caller가 STUB_*_ARGV_FILE env로 지정한다 (env -i 실행).
PASSTHRU_BIN="$TEST_TMP_DIR/passthru-bin"
mkdir -p "$PASSTHRU_BIN"

cat > "$PASSTHRU_BIN/setsid" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${STUB_SETSID_ARGV_FILE:?}"
[[ "${1:-}" == "--wait" ]] && shift
exec "$@"
EOF

cat > "$PASSTHRU_BIN/timeout" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${STUB_TIMEOUT_ARGV_FILE:?}"
# GNU timeout 문법: [옵션...] duration cmd args... — 옵션과 duration을 건너뛰고 나머지를 exec.
while [[ "${1:-}" == -* ]]; do shift; done
shift
exec "$@"
EOF

cat > "$PASSTHRU_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${STUB_CODEX_ARGV_FILE:?}"
if [[ -n "${STUB_CODEX_WRITE_FILE:-}" ]]; then
  printf 'stub result\n' > "$STUB_CODEX_WRITE_FILE"
fi
exit "${STUB_CODEX_RC:-0}"
EOF
chmod +x "$PASSTHRU_BIN/setsid" "$PASSTHRU_BIN/timeout" "$PASSTHRU_BIN/codex"

# NUL-delimited argv 기록을 bash 배열 REPLY_ARGV로 읽는다 (bash 3.2 호환 — mapfile -d 미사용).
read_nul_argv() {
  REPLY_ARGV=()
  local item
  while IFS= read -r -d '' item; do
    REPLY_ARGV+=("$item")
  done < "$1"
}

# 기대 argv를 NUL 직렬화해 기록 파일과 바이트 비교한다.
assert_argv_file_eq() {
  # $1=label, $2=actual argv file, 나머지=expected argv
  local label="$1" actual="$2"; shift 2
  local expected_file="$TEST_TMP_DIR/expected.argv"
  printf '%s\0' "$@" > "$expected_file"
  if ! cmp -s "$actual" "$expected_file"; then
    fail "[$label] argv 불일치. expected=$(tr '\0' ' ' < "$expected_file") actual=$(tr '\0' ' ' < "$actual")"
  fi
}

# 실행 wiring 케이스 실행기 — env -i 클린 환경에서 supervised를 실행 경로(비 --check)로 호출.
# $1=REQUIRE 값("" = 미설정), $2=STUB_CODEX_RC, $3=STUB_CODEX_WRITE_FILE("" = 안 씀),
# 나머지=wrapper 인자(= codex exec 뒤에 보존되어야 할 인자). 결과는 전역 WIRING_* 에 남긴다.
run_wiring() {
  local require_val="$1" codex_rc="$2" write_file="$3"; shift 3
  local dir
  dir="$(mktemp -d "$TEST_TMP_DIR/wiring.XXXXXX")"
  WIRING_SETSID_ARGV="$dir/setsid.argv"
  WIRING_TIMEOUT_ARGV="$dir/timeout.argv"
  WIRING_CODEX_ARGV="$dir/codex.argv"
  WIRING_STDERR_LOG="$dir/stderr.log"
  WIRING_RC=0
  local -a env_extra=()
  [[ -n "$require_val" ]] && env_extra+=("CODEX_EXEC_REQUIRE_NONEMPTY=$require_val")
  [[ -n "$write_file" ]] && env_extra+=("STUB_CODEX_WRITE_FILE=$write_file")
  env -i \
    PATH="$PASSTHRU_BIN:$PATH" \
    CODEX_EXEC_TIMEOUT_BIN="$PASSTHRU_BIN/timeout" \
    CODEX_EXEC_SETSID_BIN="$PASSTHRU_BIN/setsid" \
    CODEX_EXEC_TIMEOUT_SECONDS=7 \
    CODEX_EXEC_KILL_AFTER_SECONDS=3 \
    STUB_SETSID_ARGV_FILE="$WIRING_SETSID_ARGV" \
    STUB_TIMEOUT_ARGV_FILE="$WIRING_TIMEOUT_ARGV" \
    STUB_CODEX_ARGV_FILE="$WIRING_CODEX_ARGV" \
    STUB_CODEX_RC="$codex_rc" \
    ${env_extra[@]+"${env_extra[@]}"} \
    "$SUPERVISED" "$@" </dev/null 2>"$WIRING_STDERR_LOG" || WIRING_RC=$?
}

assert_no_empty_output_marker() {
  # $1=label — timeout/codex rc 보존 케이스에서 postcondition 식별자가 나오면 안 된다.
  if grep -qF 'codex-exec-supervised: empty output' "$WIRING_STDERR_LOG"; then
    fail "[$1] postcondition 식별자가 출력됨 — rc 보존 계약 위반"
  fi
}

echo "==> 실행 wiring (pass-through stub 체인)"

# 빈 인자/공백/glob/선행 `-` 인자가 체인을 통과하며 보존되는지 검증하는 대표 인자 셋.
SPECIAL_ARGS=("" "a b" "*.md" "-x")

# 13. REQUIRE 미설정: 기존 동작 — shim 미개입(codex 직접), --kill-after 존재, --foreground 부재.
run_wiring "" 0 "" --sandbox read-only "${SPECIAL_ARGS[@]}"
assert_eq_rc() { [[ "$WIRING_RC" -eq "$1" ]] || fail "[$2] rc=$1 기대, got $WIRING_RC. stderr: $(tail -3 "$WIRING_STDERR_LOG" 2>/dev/null || true)"; }
assert_eq_rc 0 "wiring/no-require"
read_nul_argv "$WIRING_SETSID_ARGV"
[[ "${REPLY_ARGV[0]}" == "--wait" ]] || fail "[wiring/no-require] setsid argv[0]=--wait 기대: ${REPLY_ARGV[0]}"
assert_argv_file_eq "wiring/no-require/timeout" "$WIRING_TIMEOUT_ARGV" \
  --kill-after=3 7 codex exec --sandbox read-only "${SPECIAL_ARGS[@]}"
assert_argv_file_eq "wiring/no-require/codex" "$WIRING_CODEX_ARGV" \
  exec --sandbox read-only "${SPECIAL_ARGS[@]}"
pass "wiring: REQUIRE 미설정 — shim 미개입 + --kill-after 존재 + --foreground 부재 + 인자 보존"

# 13b. codex rc 전파 (0은 위에서 확인).
for rc_case in 1 124 137; do
  run_wiring "" "$rc_case" "" --sandbox read-only
  assert_eq_rc "$rc_case" "wiring/rc-passthrough/$rc_case"
done
pass "wiring: codex rc(1/124/137) 그대로 전파"

# 14. REQUIRE 설정 케이스들.
REQUIRE_DIR="$(mktemp -d "$TEST_TMP_DIR/require.XXXXXX")"

# 14a. 정상(non-empty) 파일 → codex rc 전파 + shim 경유 + 인자 보존.
run_wiring "$REQUIRE_DIR/ok.md" 0 "$REQUIRE_DIR/ok.md" --sandbox read-only "${SPECIAL_ARGS[@]}"
assert_eq_rc 0 "wiring/require-ok"
read_nul_argv "$WIRING_TIMEOUT_ARGV"
[[ "${REPLY_ARGV[2]}" == "bash" && "${REPLY_ARGV[3]}" == "-c" ]] \
  || fail "[wiring/require-ok] timeout argv에 shim(bash -c) 기대: ${REPLY_ARGV[2]} ${REPLY_ARGV[3]}"
assert_argv_file_eq "wiring/require-ok/codex" "$WIRING_CODEX_ARGV" \
  exec --sandbox read-only "${SPECIAL_ARGS[@]}"
pass "wiring: REQUIRE 설정 + non-empty 파일 — shim 경유 + rc 0 전파 + 인자 보존"

# 14b~14d. 부재 / 빈 파일 / 디렉터리 + codex rc 0 → exit 3 + stderr 식별자.
: > "$REQUIRE_DIR/empty.md"
mkdir -p "$REQUIRE_DIR/dir.md"
for target in "$REQUIRE_DIR/absent.md" "$REQUIRE_DIR/empty.md" "$REQUIRE_DIR/dir.md"; do
  run_wiring "$target" 0 "" --sandbox read-only
  assert_eq_rc 3 "wiring/require-empty/$(basename "$target")"
  grep -qF 'codex-exec-supervised: empty output' "$WIRING_STDERR_LOG" \
    || fail "[wiring/require-empty/$(basename "$target")] stderr 식별자 부재"
done
pass "wiring: REQUIRE 설정 + 부재/빈 파일/디렉터리 + rc 0 → exit 3 + 식별자"

# 14e. 빈 파일 + codex rc 124 → 124 보존 (postcondition이 timeout 신호를 덮어쓰지 않음).
run_wiring "$REQUIRE_DIR/empty.md" 124 "" --sandbox read-only
assert_eq_rc 124 "wiring/require-rc124-preserved"
assert_no_empty_output_marker "wiring/require-rc124-preserved"
pass "wiring: REQUIRE 설정 + 빈 파일 + codex rc 124 → 124 보존 (식별자 부재)"

# 14f. codex 자체 rc 3 + 정상 파일 → 3 전파, 식별자 부재로 wrapper rc 3과 구별됨을 확인.
run_wiring "$REQUIRE_DIR/ok.md" 3 "$REQUIRE_DIR/ok.md" --sandbox read-only
assert_eq_rc 3 "wiring/codex-rc3-passthrough"
assert_no_empty_output_marker "wiring/codex-rc3-passthrough"
pass "wiring: codex 자체 rc 3 → 3 전파 (식별자 부재로 wrapper rc 3과 구별)"

# ─── 15. shim TERM 생존 실측 (실제 GNU timeout — issue #1228 4단계 (c)) ───
# GNU timeout 함정: timeout의 직접 자식(shim)이 그룹 TERM에서 codex보다 먼저 죽으면 timeout이
# "감시 대상 종료"로 판단해 --kill-after SIGKILL 승급을 취소한다. shim의 `trap : TERM` 생존
# 성질은 문서 검토가 아니라 실측으로 판정한다 (이 케이스가 그 통과 조건).
echo "==> shim TERM 생존 실측 (실제 GNU timeout)"

REAL_TIMEOUT=""
if command -v timeout >/dev/null 2>&1 && timeout --version 2>/dev/null | grep -q 'GNU coreutils'; then
  REAL_TIMEOUT="$(command -v timeout)"
elif command -v gtimeout >/dev/null 2>&1 && gtimeout --version 2>/dev/null | grep -q 'GNU coreutils'; then
  REAL_TIMEOUT="$(command -v gtimeout)"
else
  fail "GNU timeout 부재 — TERM 실측 케이스는 실제 GNU timeout이 필요 (devShell/prePushRuntime coreutils, #1009)"
fi

TERM_BIN="$TEST_TMP_DIR/term-bin"
mkdir -p "$TERM_BIN"
# TERM 무시 codex stub: 자기 PID를 기록한 뒤 sleep으로 대체(exec — SIG_IGN은 exec를 넘어 상속).
cat > "$TERM_BIN/codex" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$$" > "${STUB_CODEX_PID_FILE:?}"
if [[ "${STUB_CODEX_IGNORE_TERM:-0}" == "1" ]]; then
  trap '' TERM
fi
exec sleep 30
EOF
chmod +x "$TERM_BIN/codex"

run_term_case() {
  # $1=ignore_term(0|1), $2=expected_rc
  local ignore="$1" expected_rc="$2"
  local dir rc=0
  dir="$(mktemp -d "$TEST_TMP_DIR/term.XXXXXX")"
  local pid_file="$dir/codex.pid" stderr_log="$dir/stderr.log"
  env -i \
    PATH="$TERM_BIN:$PATH" \
    CODEX_EXEC_TIMEOUT_BIN="$REAL_TIMEOUT" \
    CODEX_EXEC_SETSID_BIN="$PASSTHRU_BIN/setsid" \
    CODEX_EXEC_TIMEOUT_SECONDS=2 \
    CODEX_EXEC_KILL_AFTER_SECONDS=2 \
    CODEX_EXEC_REQUIRE_NONEMPTY="$dir/result.md" \
    STUB_SETSID_ARGV_FILE="$dir/setsid.argv" \
    STUB_CODEX_PID_FILE="$pid_file" \
    STUB_CODEX_IGNORE_TERM="$ignore" \
    "$SUPERVISED" </dev/null 2>"$stderr_log" || rc=$?
  if [[ "$rc" -ne "$expected_rc" ]]; then
    fail "[term/ignore=$ignore] rc=$expected_rc 기대, got $rc. stderr: $(tail -3 "$stderr_log" 2>/dev/null || true)"
  fi
  # 잔존 0: 기록된 codex(→sleep) PID가 소멸했는지 확인 (그룹 KILL/TERM 정리 입증).
  sleep 1
  if [[ ! -s "$pid_file" ]]; then
    fail "[term/ignore=$ignore] codex stub이 PID를 기록하지 못함 — 케이스 무효"
  fi
  local codex_pid
  codex_pid="$(cat "$pid_file")"
  if kill -0 "$codex_pid" 2>/dev/null; then
    kill -KILL "$codex_pid" 2>/dev/null || true
    fail "[term/ignore=$ignore] codex stub PID $codex_pid 잔존 — 그룹 정리 회귀"
  fi
}

run_term_case 1 137
pass "TERM 무시 codex + 실제 GNU timeout → --kill-after KILL 승급(rc 137) + 잔존 0"
run_term_case 0 124
pass "TERM 순응 codex + 실제 GNU timeout → 정상 timeout(rc 124) + 잔존 0"

echo "==> All wrapper env validation / wiring / postcondition / TERM-survival cases passed"
