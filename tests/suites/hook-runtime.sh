# tests/suites/hook-runtime.sh — hook-runtime.sh 공통 helper 유닛 테스트 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수(REPO_ROOT/TEST_TMP_FILE)는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164

# hook_init_scan_dir 의 TMPDIR set-but-unusable fallback 계약 회귀 차단.
#
# 배경: codex 는 자식 프로세스에 ~/.codex/tmp/... 세션 임시경로를 TMPDIR/PATH 로 상속시키는데,
# 그 디렉토리가 세션 정리로 삭제되면 TMPDIR 이 "set 이지만 이미 삭제됨" 상태가 된다.
# ${TMPDIR:-/tmp} 는 unset/empty 만 fallback 하므로 이 경우 mktemp -d "$TMPDIR/..." 가 실패하고,
# pinning-guard.sh 는 이 실패를 fail-closed 로 처리해 Bash/Edit/Write/apply_patch 전 명령을 차단했다.
# hook_init_scan_dir 은 base 가 실제 사용 가능한 디렉토리인지 확인하고 아니면 /tmp 로 fallback 한다.

_hook_runtime_lib_path() {
  printf '%s' "$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh"
}

# 존재하지 않는 TMPDIR (codex dangling ~/.codex/tmp/... 재현) → /tmp fallback + 성공.
test_hook_init_scan_dir_falls_back_when_tmpdir_missing() {
  local sandbox out lib
  lib="$(_hook_runtime_lib_path)"
  sandbox=$(new_sandbox)
  out=$(TMPDIR="$sandbox/does-not-exist" HOOK_RT_LIB="$lib" \
    bash -c '. "$HOOK_RT_LIB"; hook_init_scan_dir pinning-guard') \
    || fail "hook_init_scan_dir must exit 0 with a missing TMPDIR"
  [ -d "$out" ] || fail "expected a created directory, got: $out"
  case "$out" in
    /tmp/pinning-guard-*) : ;;
    *) fail "expected /tmp fallback path, got: $out" ;;
  esac
  rmdir "$out" 2>/dev/null || true
}

# 쓰기 불가 TMPDIR → /tmp fallback + 성공. (root 는 -w 를 우회하므로 skip.)
test_hook_init_scan_dir_falls_back_when_tmpdir_unwritable() {
  local sandbox rodir out lib
  if [ "$(id -u)" = 0 ]; then
    echo "    (skip: root bypasses -w permission check)" >&2
    return 0
  fi
  lib="$(_hook_runtime_lib_path)"
  sandbox=$(new_sandbox)
  rodir="$sandbox/ro"
  mkdir -p "$rodir"
  chmod 000 "$rodir"
  out=$(TMPDIR="$rodir" HOOK_RT_LIB="$lib" \
    bash -c '. "$HOOK_RT_LIB"; hook_init_scan_dir pinning-guard') \
    || { chmod 755 "$rodir"; fail "hook_init_scan_dir must exit 0 with an unwritable TMPDIR"; }
  chmod 755 "$rodir"  # sandbox 자동 cleanup 이 rm -rf 할 수 있도록 권한 복구.
  [ -d "$out" ] || fail "expected a created directory, got: $out"
  case "$out" in
    /tmp/pinning-guard-*) : ;;
    *) fail "expected /tmp fallback path, got: $out" ;;
  esac
  rmdir "$out" 2>/dev/null || true
}

# 유효한 TMPDIR 은 그대로 사용 — 불필요한 /tmp fallback 금지 (임시경로 격리 의도 보존).
test_hook_init_scan_dir_uses_valid_tmpdir() {
  local sandbox out lib
  lib="$(_hook_runtime_lib_path)"
  sandbox=$(new_sandbox)
  out=$(TMPDIR="$sandbox" HOOK_RT_LIB="$lib" \
    bash -c '. "$HOOK_RT_LIB"; hook_init_scan_dir pinning-guard') \
    || fail "hook_init_scan_dir must exit 0 with a valid TMPDIR"
  [ -d "$out" ] || fail "expected a created directory, got: $out"
  case "$out" in
    "$sandbox"/pinning-guard-*) : ;;
    *) fail "expected scan dir under the valid TMPDIR ($sandbox), got: $out" ;;
  esac
  rmdir "$out" 2>/dev/null || true
}

# e2e: codex pinning-guard.sh 가 set-but-unusable TMPDIR 에서 fail-closed 로 명령을 차단하지
# 않고 정상 통과하는지 — 이 커밋이 고친 실제 사용자 영향(전 명령 deny 억제)을 직접 검증한다.
# 유닛 테스트는 hook_init_scan_dir 계약(rc=0 + 유효 경로)만 보므로, 그 계약이 실제 guard 의
# deny 경로를 억제한다는 것까지 e2e 로 못박는다. non-targeted 명령("true")을 써서 pinning 패턴
# 로직을 타지 않고 scan workspace 초기화 경로만 격리 검증한다.
test_pinning_guard_survives_unusable_tmpdir() {
  local sandbox out lib_rt lib_pin hook
  lib_rt="$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh"
  lib_pin="$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh"
  hook="$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-guard.sh"
  sandbox=$(new_sandbox)
  out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"true"}}' \
    | env TMPDIR="$sandbox/does-not-exist" \
        HOOK_RUNTIME_LIB="$lib_rt" PINNING_PATTERNS_LIB="$lib_pin" \
        bash "$hook") \
    || fail "pinning-guard.sh must exit 0 under a set-but-unusable TMPDIR"
  assert_not_contains "$out" '"permissionDecision": "deny"'
  assert_not_contains "$out" "failed to initialize scan workspace"
}
