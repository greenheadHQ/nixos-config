#!/usr/bin/env bash
# tests/test-codex-hook-fixtures.sh
# Codex 0.124+ stable hook 회귀 차단 fixture runner.
#
# 11 카테고리 (9 deterministic + 2 live opt-in subsets):
#   1. stdin schema baseline 0.124       — fixtures/codex-hooks/stdin/{userpromptsubmit-codex-0.124,stop-codex-0.124,stop-no-last-message}.json
#   2. dispatcher ordering / failure recovery — runner 내부 mock subscript
#   3. noise-guard env 변형              — runner 내부 helper (4 env 조합)
#   4. sync-codex-config.py preservation — fixtures/codex-hooks/sync-preservation/*.toml
#   5. programmatic env inheritance (live opt-in) — CODEX_HOOK_LIVE=1 / --live
#   5b. codex exec invocation matrix (live opt-in, must-pass-only) — issue #593 supervised wrapper 회귀 차단
#       (--live 시 invocation matrix를 programmatic env inheritance보다 먼저 실행)
#   6. stop-notification reliability/security — transcripts/ + stdin secret/transcript fixtures
#   7. pinning-alert behavioral          — fixtures/codex-hooks/stdin/pinning-{claude,codex}-*.json
#   7b. PreToolUse pinning-guard behavioral — hard-fail deny JSON + clean pass fixtures
#   7c. commit-msg pinning behavioral    — fixtures/codex-hooks/commit-msg/*.msg
#   8. sync.sh mcp-config fail-fast      — missing/no source가 기존 MCP 섹션을 지우지 않음
#
# nrs-session-cleanup.sh는 NRS_LOCK_FILE을 하드코딩하므로 (host /tmp/nrs-state 누수 위험)
# fixture는 real script를 직접 호출하지 않고 mock subscript로 대체한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/codex-hooks"

# ─── --help는 bootstrap 전에 처리 ───
# tomlkit bootstrap이 nix가 있는 환경에서 nix shell로 self-wrap(exec)하므로 --help도 그 후에야
# 출력된다. 도움말은 bootstrap이 필요 없으므로 인자만 빠르게 검사해 즉시 출력 + exit한다.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      cat <<EOF
Usage: $0 [--live | --no-live]
  default      deterministic fixture만 실행
  --live       live opt-in fixture까지 실행: codex exec invocation matrix(must-pass-only)
               + programmatic env inheritance live fixture (실행 순서대로)
  --no-live    deterministic 강제 (default와 동일; verify-ai-compat가 사용)
ENV: CODEX_HOOK_LIVE=1  (--live와 동등; CLI 인자가 env보다 우선하며 마지막 모드 인자가 이긴다)
EOF
      exit 0
      ;;
  esac
done

# ─── tomlkit bootstrap ───
# sync-preservation 시나리오는 sync-codex-config.py를 통해 tomlkit을 요구한다. 직접 실행과
# lefthook 경로의 runtime 일관성을 위해 tests/run-shell-script-tests.sh와 동일하게
# scripts/ai/lib/tomlkit-bootstrap.sh를 source하여 repo-pinned pythonWithTomlkit으로 self-wrap한다.
# `_TOMLKIT_BOOTSTRAP_READY=1`이 이미 set이면 즉시 반환되므로 lefthook 안에서 중첩 nix shell이 발생하지 않는다.
# bootstrap이 exec로 프로세스를 교체할 수 있으므로 sandbox tracking 임시 파일은 그 이후에 생성한다.
# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
tomlkit_bootstrap_require "$REPO_ROOT" "${BASH_SOURCE[0]}" "$@"

TEST_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-hook-fixtures-list.XXXXXX")"

# ─── Hook contract expectation oracle ───
# tests/lib/codex-hook-expectations.sh가 EXPECTED_* / LIVE_CODEX_TIMEOUT_SECONDS /
# CODEX_HOOK_SCHEMA_BASELINE의 expectation oracle. verify-ai-compat도 동일 파일을 source한다.
# 주의: 본 파일은 test/verifier oracle이며 runtime source of truth가 아니다 — hook 실제
# 정의는 modules/shared/programs/codex/files/config.toml(+ darwin)과 _stop-dispatcher.sh에
# 있고, hook 추가/rename 시 그 두 곳도 함께 수정해야 한다.
# shellcheck source=lib/codex-hook-expectations.sh
. "$SCRIPT_DIR/lib/codex-hook-expectations.sh"

HOOK_REPO_DIR="$REPO_ROOT/modules/shared/programs/codex/files/hooks"
PINNING_LIB_REPO_FILE="$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh"
# verify-ai-compat의 _TEMPLATE 분기와 동일하게 host platform에 맞는 template을 sync-preservation
# 검증에 사용한다. Darwin은 mcp_servers.chrome-devtools 같은 platform-specific managed leaves를
# 추가로 가지므로 platform-agnostic 검증은 부족하다.
if [ "$(uname -s)" = "Darwin" ]; then
  TEMPLATE_REPO_FILE="$REPO_ROOT/modules/shared/programs/codex/files/config.darwin.toml"
else
  TEMPLATE_REPO_FILE="$REPO_ROOT/modules/shared/programs/codex/files/config.toml"
fi
SYNC_SCRIPT="$REPO_ROOT/modules/shared/programs/codex/files/sync-codex-config.py"
SYNC_HARNESS_SH="$REPO_ROOT/modules/shared/programs/claude/files/skills/syncing-codex-harness/references/sync.sh"

# ─── CLI 인자 / opt-in 모드 ───
# Precedence: CODEX_HOOK_LIVE env가 default를 set하고, CLI 인자가 그 위에 적용된다.
# --live와 --no-live가 모두 등장하면 마지막에 등장한 모드 인자가 이긴다.
LIVE_MODE="${CODEX_HOOK_LIVE:-0}"
for arg in "$@"; do
  case "$arg" in
    --live) LIVE_MODE=1 ;;
    --no-live) LIVE_MODE=0 ;;
    -h|--help) ;;  # 위에서 이미 처리됨
    *)
      # 알 수 없는 인자가 silent하게 default deterministic 모드로 빠지지 않도록 차단.
      echo "FAIL: 알 수 없는 인자: $arg" >&2
      echo "Usage: $0 [--live | --no-live | -h]" >&2
      exit 2
      ;;
  esac
done

# ─── cleanup / 출력 helper ───
cleanup() {
  local dir
  if [[ -f "$TEST_TMP_FILE" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && rm -rf "$dir"
    done < "$TEST_TMP_FILE"
    rm -f "$TEST_TMP_FILE"
  fi
  return 0
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
warn() { echo "WARN: $*" >&2; }

sed_replacement_escape() {
  printf '%s' "$1" | sed 's/[&#]/\\&/g'
}

assert_eq() {
  # $1=actual $2=expected $3=message
  [[ "$1" == "$2" ]] || fail "$3 (actual='$1' expected='$2')"
}

assert_file_exists() {
  # $1=path, $2=scenario context (실패 메시지에 같이 출력해 fixture 단계명 식별 가능하게).
  local path="$1" scenario="${2:-}"
  if [[ ! -f "$path" ]]; then
    if [[ -n "$scenario" ]]; then
      fail "[$scenario] 파일이 존재해야 함: $path"
    else
      fail "파일이 존재해야 함: $path"
    fi
  fi
}

assert_file_absent() {
  local path="$1" scenario="${2:-}"
  if [[ -e "$path" ]]; then
    if [[ -n "$scenario" ]]; then
      fail "[$scenario] 파일이 없어야 함: $path"
    else
      fail "파일이 없어야 함: $path"
    fi
  fi
}

# ─── new_hook_sandbox / run_hook_in_sandbox ───
# 모든 sandbox는 umask 077 + mktemp -d로 생성되고 EXIT trap에서 일괄 정리된다.
# hook 호출 시 HOME / XDG_DATA_HOME / XDG_CONFIG_HOME / CODEX_HOME을 모두 sandbox로
# 강제하여 host 상태를 만지지 않도록 한다.
new_hook_sandbox() {
  local sandbox
  sandbox=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/codex-hook-fixture.XXXXXX") \
    || fail "mktemp -d 실패"
  printf '%s\n' "$sandbox" >> "$TEST_TMP_FILE"

  mkdir -p \
    "$sandbox/home" \
    "$sandbox/xdg-data" \
    "$sandbox/xdg-config" \
    "$sandbox/codex-home" \
    "$sandbox/home/.codex/hooks" \
    "$sandbox/home/.codex/lib" \
    "$sandbox/home/.claude/lib" \
    "$sandbox/home/.local/share/claude-hooks" \
    "$sandbox/bin-stubs"

  cp -L "$HOOK_REPO_DIR"/*.sh "$sandbox/home/.codex/hooks/"
  chmod +x "$sandbox/home/.codex/hooks/"*.sh
  cp -L "$PINNING_LIB_REPO_FILE" "$sandbox/home/.codex/lib/"
  cp -L "$PINNING_LIB_REPO_FILE" "$sandbox/home/.claude/lib/"

  # macOS 외부 채널 차단: Darwin runner의 host PATH가 fixture에 누수되면 stop-notification.sh가
  # 실제 Hammerspoon 알림을 발사할 수 있다. sandbox/bin-stubs를 PATH 최우선으로 두어 hs 호출이
  # 항상 exit 1로 빠지게 한다 (HS_SENT=false 유지).
  cat > "$sandbox/bin-stubs/hs" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$sandbox/bin-stubs/hs"

  printf '%s\n' "$sandbox"
}

run_hook_in_sandbox() {
  # $1=sandbox, $2=hook 파일명, 나머지는 hook 인자, stdin은 caller가 pipe.
  # guard env (CLAUDECODE/CODEX_PROGRAMMATIC) 주입이 필요하면 run_hook_in_sandbox_with_env 사용.
  local sandbox="$1"; shift
  local hook="$1"; shift
  _run_hook_in_sandbox_core "$sandbox" "" "$hook" "$@"
}

run_hook_in_sandbox_with_env() {
  # $1=sandbox, $2=env-pair-list ("CLAUDECODE=1 CODEX_PROGRAMMATIC=1" 등 공백 구분), $3=hook
  local sandbox="$1"; shift
  local env_pairs="$1"; shift
  local hook="$1"; shift
  _run_hook_in_sandbox_core "$sandbox" "$env_pairs" "$hook" "$@"
}

# env injection 외 sandbox/PATH/XDG/CODEX_HOME 설정은 두 wrapper가 공유.
# env_pairs_string 계약: "" 또는 공백 구분 K=V 단일 토큰만 허용 (예: "CLAUDECODE=1 CODEX_PROGRAMMATIC=1").
# 따옴표 / 공백 포함 값 / 다중 단어 값은 지원하지 않는다 — read -ra의 word-splitting이 quote-aware하지 않다.
# 본 fixture가 다루는 noise-guard env 변형은 모두 단일 토큰 K=V라 이 제약으로 충분하다.
_run_hook_in_sandbox_core() {
  local sandbox="$1"; shift
  local env_pairs_string="$1"; shift
  local hook="$1"; shift
  _exec_with_sandbox_env "$sandbox" "$env_pairs_string" \
    "$sandbox/home/.codex/hooks/$hook" "$@"
}

# Wrapper 공용: sandbox 격리 env를 적용한 뒤 caller 명령을 실행한다.
# 격리 계약: CLAUDECODE / CODEX_PROGRAMMATIC / host PINNING_PATTERNS_LIB unset, sandbox bin-stubs를
# PATH 앞에 prepend(host PATH는 뒤에 보존하여 jq 등 시스템 도구 접근 유지), HOME /
# XDG_DATA_HOME / XDG_CONFIG_HOME / CODEX_HOME은 sandbox로 강제. _run_hook_in_sandbox_core
# (sandbox 내부 hook copy)와 카테고리 7 pinning-alert 외부 절대경로 hook 실행이 이 helper 한 곳을 공유한다.
# 첫 인자는 sandbox, 두 번째는 추가 env_pairs_string("" 또는 "K=V K=V"), 이후는 실행 명령 + 인자들.
_exec_with_sandbox_env() {
  local sandbox="$1"; shift
  local env_pairs_string="$1"; shift
  local env_array=()
  if [[ -n "$env_pairs_string" ]]; then
    read -ra env_array <<<"$env_pairs_string"
  fi
  env -u CLAUDECODE -u CODEX_PROGRAMMATIC -u PINNING_PATTERNS_LIB "${env_array[@]}" \
      PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" \
      HOME="$sandbox/home" \
      XDG_DATA_HOME="$sandbox/xdg-data" \
      XDG_CONFIG_HOME="$sandbox/xdg-config" \
      CODEX_HOME="$sandbox/codex-home" \
      "$@"
}

# 카테고리 6 (stop-notification reliability/security) 공용: Pushover credential + curl mock 설치.
# - sandbox/home/.config/pushover/codex: dummy credential (실제 Pushover API 차단)
# - sandbox/bin-stubs/curl: 호출 인자를 sandbox/curl-args.log에 dump 후 exit 0 (redaction 검증용)
# heredoc unquoted라 $sandbox는 expansion되고 \$@/\$arg는 stub 안에 escape 상태로 남는다.
install_pushover_mock_with_curl_log() {
  local sandbox="$1"
  local credential_name="${2:-codex}"
  local creds_dir="$sandbox/home/.config/pushover"
  mkdir -p "$creds_dir"
  cat > "$creds_dir/$credential_name" <<'CRED'
PUSHOVER_TOKEN=dummy_token_for_fixture_only
PUSHOVER_USER=dummy_user_for_fixture_only
CRED
  chmod 0600 "$creds_dir/$credential_name"

  cat > "$sandbox/bin-stubs/curl" <<STUB
#!/usr/bin/env bash
# fixture curl mock — 호출 단위로 invocation marker + 각 인자를 줄바꿈 구분 dump.
{
  echo "===CURL_INVOCATION==="
  for arg in "\$@"; do
    printf '%s\n' "\$arg"
  done
} >> "$sandbox/curl-args.log"
exit 0
STUB
  chmod +x "$sandbox/bin-stubs/curl"
}

install_mock_subscripts_with_log() {
  # dispatcher가 호출하는 3 sub-script를 mock으로 교체.
  # $1=sandbox, $2=ordering log path, $3..=각 sub-script의 exit 코드.
  # 인자 순서는 dispatcher 호출 순서와 동일 (issue #590): record-last-stop, nrs-session-cleanup, stop-notification.
  local sandbox="$1" log="$2"
  local rls_rc="${3:-0}" nsc_rc="${4:-0}" sn_rc="${5:-0}"

  cat > "$sandbox/home/.codex/hooks/record-last-stop.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo record-last-stop >> "$log"
exit $rls_rc
EOF
  cat > "$sandbox/home/.codex/hooks/stop-notification.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo stop-notification >> "$log"
exit $sn_rc
EOF
  cat > "$sandbox/home/.codex/hooks/nrs-session-cleanup.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo nrs-session-cleanup >> "$log"
exit $nsc_rc
EOF
  chmod +x "$sandbox/home/.codex/hooks/"{record-last-stop,stop-notification,nrs-session-cleanup}.sh
}

install_mock_nrs_session_cleanup_unguarded() {
  # noise-guard 카테고리에서 nrs-session-cleanup이 env 가드 없이 호출됨을 검증할 mock.
  # real script의 NRS_LOCK_FILE 하드코딩(host /tmp/nrs-state)을 회피하기 위해 mock으로 대체한다.
  # $1=sandbox, $2=invocation marker path
  local sandbox="$1" marker="$2"
  cat > "$sandbox/home/.codex/hooks/nrs-session-cleanup.sh" <<EOF
#!/usr/bin/env bash
# unguarded mock: CLAUDECODE/CODEX_PROGRAMMATIC 무시하고 항상 marker append.
cat >/dev/null
echo invoked >> "$marker"
exit 0
EOF
  chmod +x "$sandbox/home/.codex/hooks/nrs-session-cleanup.sh"
}

# ─── 카테고리 1: stdin schema baseline ───
# Codex 0.124+ stdin payload (session_id / transcript_path / cwd / prompt|last_assistant_message)가
# record-prompt-submit / record-last-stop hook에서 expected artifact를 만들어내는지 검증.
test_stdin_payloads_create_expected_hook_artifacts_codex_0_124() {
  local sandbox
  sandbox=$(new_hook_sandbox)

  local fixed_session_id="01234567-89ab-cdef-0123-456789abcdef"
  local datadir="$sandbox/xdg-data/claude-hooks"

  # ── UserPromptSubmit: record-prompt-submit ──
  run_hook_in_sandbox "$sandbox" "record-prompt-submit.sh" \
    < "$FIXTURE_DIR/stdin/userpromptsubmit-codex-0.124.json" \
    || fail "record-prompt-submit (UserPromptSubmit $CODEX_HOOK_SCHEMA_BASELINE) 비정상 종료"
  assert_file_exists "$datadir/last-stop-${fixed_session_id}" "stdin baseline UserPromptSubmit marker"
  assert_eq "$(cat "$datadir/last-stop-${fixed_session_id}")" "0" \
    "record-prompt-submit는 in-flight marker '0'을 기록해야 함"

  # ── Stop: record-last-stop (정상 last_assistant_message) ──
  run_hook_in_sandbox "$sandbox" "record-last-stop.sh" \
    < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
    || fail "record-last-stop (Stop $CODEX_HOOK_SCHEMA_BASELINE) 비정상 종료"
  local ts_value
  ts_value=$(cat "$datadir/last-stop-${fixed_session_id}")
  [[ "$ts_value" =~ ^[0-9]+$ ]] || fail "record-last-stop 결과가 unix timestamp가 아님: '$ts_value'"

  # ── Stop: last_assistant_message=null degraded mode ──
  # record-last-stop은 last_assistant_message를 안 쓰므로 여전히 timestamp 기록.
  # stop-notification은 외부 채널 부재(Pushover/HS) → exit 0이어야 한다.
  run_hook_in_sandbox "$sandbox" "record-last-stop.sh" \
    < "$FIXTURE_DIR/stdin/stop-no-last-message.json" \
    || fail "record-last-stop (last_assistant_message null) 비정상 종료"
  run_hook_in_sandbox "$sandbox" "stop-notification.sh" \
    < "$FIXTURE_DIR/stdin/stop-no-last-message.json" \
    || fail "stop-notification (last_assistant_message null) 비정상 종료"
}

# ─── 카테고리 2: dispatcher ordering & 실패 회복 ───
expected_dispatcher_ordering() {
  # mock subscript들이 ordering.log에 출력하는 형식(.sh 확장자 제거된 라인)으로 EXPECTED_*를 변환.
  local expected="" sub
  for sub in "${EXPECTED_DISPATCHER_SUB_SCRIPTS[@]}"; do
    expected+="${sub%.sh}"$'\n'
  done
  printf '%s' "${expected%$'\n'}"
}

test_dispatcher_ordering_with_mock_subscripts() {
  local sandbox log
  sandbox=$(new_hook_sandbox)
  log="$sandbox/ordering.log"

  install_mock_subscripts_with_log "$sandbox" "$log" 0 0 0

  run_hook_in_sandbox "$sandbox" "_stop-dispatcher.sh" \
    < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
    || fail "_stop-dispatcher 정상 경로에서 비정상 종료"

  local actual expected
  actual=$(cat "$log")
  expected=$(expected_dispatcher_ordering)
  assert_eq "$actual" "$expected" "dispatcher sub-script ordering 어긋남"
}

test_dispatcher_recovers_from_subscript_failures() {
  # 시나리오 순서는 dispatcher 호출 순서(record-last-stop → nrs-session-cleanup → stop-notification)를 따른다.
  local scenarios=(
    "1 0 0:record-last-stop"
    "0 1 0:nrs-session-cleanup"
    "0 0 1:stop-notification"
  )

  # expected ordering 은 baseline test와 동일 helper 사용.
  local expected
  expected=$(expected_dispatcher_ordering)

  local entry
  for entry in "${scenarios[@]}"; do
    local rc_triple="${entry%%:*}"
    local fail_target="${entry##*:}"
    # shellcheck disable=SC2086  # 의도된 word-splitting (rc_triple은 "0 0 1" 형태)
    set -- $rc_triple
    local rls_rc="$1" nsc_rc="$2" sn_rc="$3"

    local sandbox log err
    sandbox=$(new_hook_sandbox)
    log="$sandbox/ordering.log"
    err="$sandbox/dispatcher.stderr"

    install_mock_subscripts_with_log "$sandbox" "$log" "$rls_rc" "$nsc_rc" "$sn_rc"

    if ! run_hook_in_sandbox "$sandbox" "_stop-dispatcher.sh" \
        < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" 2>"$err"; then
      fail "dispatcher가 sub-script 실패에서 회복하지 못하고 비정상 종료 (target=$fail_target)"
    fi

    local actual
    actual=$(cat "$log")
    assert_eq "$actual" "$expected" "dispatcher가 $fail_target 실패 후 후속 sub-script를 건너뜀"

    grep -qE "codex stop dispatcher: ${fail_target} exited non-zero" "$err" \
      || fail "dispatcher stderr에 진단 메시지 없음 (target=$fail_target)"
  done
}

# ─── 카테고리 3: noise-guard env 변형 ───
# CLAUDECODE=1 또는 CODEX_PROGRAMMATIC=1 둘 중 하나라도 set이면
# record-prompt-submit / record-last-stop / stop-notification은 immediate exit 0 (가드 발동).
# nrs-session-cleanup은 가드 비적용 (real script는 host /tmp/nrs-state 누수 위험이라 mock 사용).
test_noise_guard_env_variants_with_cleanup_unguarded() {
  local fixed_session_id="01234567-89ab-cdef-0123-456789abcdef"
  # 두 parallel array로 변형(env)과 기대 동작(expectation)을 분리해 colon-delimited
  # 문자열 + word-splitting 규약을 피한다.
  local variants_env=(
    "CLAUDECODE=1"
    "CODEX_PROGRAMMATIC=1"
    "CLAUDECODE=1 CODEX_PROGRAMMATIC=1"
    ""  # 둘 다 unset → 가드 미발동
  )
  local variants_expectation=(guarded guarded guarded unguarded)
  [[ "${#variants_env[@]}" -eq "${#variants_expectation[@]}" ]] \
    || fail "noise-guard variants_env / variants_expectation array length mismatch"

  local i env_pairs expectation
  for i in "${!variants_env[@]}"; do
    env_pairs="${variants_env[$i]}"
    expectation="${variants_expectation[$i]}"

    local sandbox datadir marker
    sandbox=$(new_hook_sandbox)
    datadir="$sandbox/xdg-data/claude-hooks"
    marker="$sandbox/nrs-cleanup-marker"
    install_mock_nrs_session_cleanup_unguarded "$sandbox" "$marker"

    # 3 가드 대상 hook (record-prompt-submit / record-last-stop / stop-notification)
    run_hook_in_sandbox_with_env "$sandbox" "$env_pairs" "record-prompt-submit.sh" \
      < "$FIXTURE_DIR/stdin/userpromptsubmit-codex-0.124.json" \
      || fail "record-prompt-submit (env='$env_pairs') 비정상 종료"
    run_hook_in_sandbox_with_env "$sandbox" "$env_pairs" "record-last-stop.sh" \
      < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
      || fail "record-last-stop (env='$env_pairs') 비정상 종료"
    run_hook_in_sandbox_with_env "$sandbox" "$env_pairs" "stop-notification.sh" \
      < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
      || fail "stop-notification (env='$env_pairs') 비정상 종료"

    # mock nrs-session-cleanup은 env와 무관하게 항상 호출되어야 한다.
    run_hook_in_sandbox_with_env "$sandbox" "$env_pairs" "nrs-session-cleanup.sh" \
      < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
      || fail "nrs-session-cleanup mock (env='$env_pairs') 비정상 종료"
    [[ "$(cat "$marker" 2>/dev/null)" == "invoked" ]] \
      || fail "unguarded nrs-session-cleanup이 호출되지 않음 (env='$env_pairs')"

    case "$expectation" in
      guarded)
        # 가드 발동 → last-stop 파일 미생성
        assert_file_absent "$datadir/last-stop-${fixed_session_id}" \
          "noise-guard guarded (env='$env_pairs') marker 미생성"
        ;;
      unguarded)
        # 가드 미발동 → record-prompt-submit이 '0' 작성, record-last-stop가 timestamp로 덮음
        assert_file_exists "$datadir/last-stop-${fixed_session_id}" \
          "noise-guard unguarded (env='$env_pairs') timestamp marker"
        local val
        val=$(cat "$datadir/last-stop-${fixed_session_id}")
        [[ "$val" =~ ^[0-9]+$ ]] \
          || fail "noise-guard unguarded 경로에서 last-stop 값이 timestamp가 아님: '$val'"
        ;;
      *)
        fail "noise-guard: unknown expectation '$expectation' (variants_expectation 오타?)"
        ;;
    esac
  done
}

# ─── 카테고리 4: sync-codex-config.py preservation ───
_sync_preservation_run_one() {
  # $1=fixture file, $2=description (logging only)
  local fixture="$1" desc="$2"
  local sandbox target stderr_log
  sandbox=$(new_hook_sandbox)
  target="$sandbox/codex-home/config.toml"
  stderr_log="$sandbox/sync-codex.stderr"
  cp "$fixture" "$target"
  chmod 0600 "$target"

  if ! python3 "$SYNC_SCRIPT" sync "$TEMPLATE_REPO_FILE" "$target" >/dev/null 2>"$stderr_log"; then
    # subprocess 진단 메시지를 fail 출력에 포함해 회귀 시 원인 식별성을 높인다.
    fail "sync-codex-config.py sync 실패 ($desc) stderr=$(cat "$stderr_log" 2>/dev/null || true)"
  fi

  printf '%s\n' "$target"
}

test_sync_preservation_scenarios() {
  # tomlkit이 없으면 sync-codex-config.py가 sync 모드에서 fail하므로 sync-preservation 카테고리가
  # 누락된 상태로 "All passed"가 출력될 위험이 있다. hard fail로 회귀 차단.
  if ! python3 -c 'import tomlkit' >/dev/null 2>&1; then
    fail "tomlkit 미가용 — pre-commit/pre-push hook 또는 'nix shell .#pythonWithTomlkit' 환경에서 실행 필요"
  fi

  local target
  # ── A: template event preserved ──
  target=$(_sync_preservation_run_one \
    "$FIXTURE_DIR/sync-preservation/scenario-A-template-event.toml" "scenario-A")
  python3 - "$target" "$EXPECTED_USER_PROMPT_COMMAND" <<'PY' \
    || fail "scenario-A: hooks.UserPromptSubmit가 template과 일치하지 않음"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
expected_cmd = sys.argv[2]
ups = d.get("hooks", {}).get("UserPromptSubmit", [])
assert isinstance(ups, list) and len(ups) == 1, f"UserPromptSubmit len={len(ups)}"
sub = ups[0].get("hooks", [])
assert len(sub) == 1, f"UserPromptSubmit.hooks len={len(sub)}"
cmd = sub[0].get("command", "")
assert cmd == expected_cmd, f"command={cmd!r} expected={expected_cmd!r}"
PY

  # ── B: user same-event entry lost (sync-codex-config.py의 template-owned leaf 정책) ──
  # tomlkit이 round-trip에서 fixture 헤더 주석을 보존하므로 grep 대신 parsed array의
  # 실제 hook command 값만 검사한다. 사용자 marker가 hooks 배열 안에 남아 있으면 정책 위반.
  target=$(_sync_preservation_run_one \
    "$FIXTURE_DIR/sync-preservation/scenario-B-user-added-same-event.toml" "scenario-B")
  python3 - "$target" <<'PY' || fail "scenario-B: 사용자 entry가 손실되어야 하지만 보존됨 (template-owned leaf 정책 위반)"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
ups = d.get("hooks", {}).get("UserPromptSubmit", [])
assert isinstance(ups, list) and len(ups) == 1, f"UserPromptSubmit len={len(ups)} (expected 1)"
commands = [h.get("command", "") for entry in ups for h in entry.get("hooks", [])]
assert all("USER-ENTRY-LOST" not in c for c in commands), f"user marker still present: {commands}"
PY

  # ── C: user-different-event preserved ──
  target=$(_sync_preservation_run_one \
    "$FIXTURE_DIR/sync-preservation/scenario-C-user-different-event.toml" "scenario-C")
  python3 - "$target" <<'PY' || fail "scenario-C: hooks.SessionStart user entry가 보존되지 않음"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
ss = d.get("hooks", {}).get("SessionStart", [])
assert isinstance(ss, list) and len(ss) == 1, f"SessionStart len={len(ss)}"
commands = [h.get("command", "") for entry in ss for h in entry.get("hooks", [])]
assert any("USER-SESSIONSTART-PRESERVED" in c for c in commands), f"user marker missing: {commands}"
PY

  # ── D: mcp_servers ↔ hooks 공존 ──
  target=$(_sync_preservation_run_one \
    "$FIXTURE_DIR/sync-preservation/scenario-D-mcp-servers-coexist.toml" "scenario-D")
  python3 - "$target" "$EXPECTED_STOP_DISPATCHER_COMMAND" <<'PY' \
    || fail "scenario-D: mcp_servers user entry 보존 또는 hooks.Stop dispatcher 적용 실패"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
expected_stop_cmd = sys.argv[2]
mcps = d.get("mcp_servers", {})
user_mcp = mcps.get("test-marker-user-mcp", {})
assert user_mcp.get("command", "") == "/tmp/test-marker-USER-MCP-PRESERVED.sh", \
    f"mcp_servers.test-marker-user-mcp.command={user_mcp.get('command')!r}"
stop = d.get("hooks", {}).get("Stop", [])
assert isinstance(stop, list) and len(stop) == 1
sub = stop[0].get("hooks", [])
assert len(sub) == 1
cmd = sub[0].get("command", "")
assert cmd == expected_stop_cmd, f"command={cmd!r} expected={expected_stop_cmd!r}"
PY

  # ── E: PostToolUse template-owned (issue #603) ──
  # PostToolUse도 template이 declare한 array이므로 사용자가 동일 event에 별도 entry를 추가하면
  # template-owned leaf 정책에 따라 손실된다. scenario-B의 UserPromptSubmit 변형으로,
  # PostToolUse에도 동일 정책이 적용됨을 강제한다.
  target=$(_sync_preservation_run_one \
    "$FIXTURE_DIR/sync-preservation/scenario-E-posttooluse-template-owned.toml" "scenario-E")
  python3 - "$target" "$EXPECTED_POST_TOOL_USE_PINNING_COMMAND" <<'PY' \
    || fail "scenario-E: PostToolUse 사용자 entry가 손실되어야 하지만 보존됨 (template-owned leaf 정책 위반)"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
expected_post_cmd = sys.argv[2]
post = d.get("hooks", {}).get("PostToolUse", [])
assert isinstance(post, list) and len(post) == 1, f"PostToolUse len={len(post)} (expected 1)"
sub = post[0].get("hooks", [])
assert len(sub) == 1, f"PostToolUse.hooks len={len(sub)}"
cmd = sub[0].get("command", "")
assert cmd == expected_post_cmd, f"command={cmd!r} expected={expected_post_cmd!r}"
# 사용자 marker는 손실되어야 함
all_commands = [h.get("command", "") for entry in post for h in entry.get("hooks", [])]
assert all("USER-POSTTOOLUSE-LOST" not in c for c in all_commands), \
    f"user marker still present: {all_commands}"
PY

  # ── F: PreToolUse template-owned (issue #587) ──
  # PreToolUse도 template이 declare한 array이므로 사용자가 동일 event에 별도 entry를 추가하면
  # template-owned leaf 정책에 따라 손실된다.
  target=$(_sync_preservation_run_one \
    "$FIXTURE_DIR/sync-preservation/scenario-F-pretooluse-template-owned.toml" "scenario-F")
  python3 - "$target" "$EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND" <<'PY' \
    || fail "scenario-F: PreToolUse 사용자 entry가 손실되어야 하지만 보존됨 (template-owned leaf 정책 위반)"
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    d = tomllib.load(f)
expected_pre_cmd = sys.argv[2]
pre = d.get("hooks", {}).get("PreToolUse", [])
assert isinstance(pre, list) and len(pre) == 1, f"PreToolUse len={len(pre)} (expected 1)"
sub = pre[0].get("hooks", [])
assert len(sub) == 1, f"PreToolUse.hooks len={len(sub)}"
cmd = sub[0].get("command", "")
assert cmd == expected_pre_cmd, f"command={cmd!r} expected={expected_pre_cmd!r}"
all_commands = [h.get("command", "") for entry in pre for h in entry.get("hooks", [])]
assert all("USER-PRETOOLUSE-LOST" not in c for c in all_commands), \
    f"user marker still present: {all_commands}"
PY
}

# ─── 카테고리 8: syncing-codex-harness mcp-config fail-fast (#609) ───
_write_existing_mcp_config() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<'EOF'
model = "gpt-5.5"

[mcp_servers.existing]
command = "/tmp/existing-mcp"
EOF
}

_assert_existing_mcp_preserved() {
  local target="$1" scenario="$2"
  grep -Fqx '[mcp_servers.existing]' "$target" \
    || fail "[$scenario] 기존 mcp_servers.existing 섹션이 보존되어야 함"
  grep -Fqx 'command = "/tmp/existing-mcp"' "$target" \
    || fail "[$scenario] 기존 MCP command가 보존되어야 함"
}

test_sync_sh_mcp_config_valid_sources() {
  local sandbox project_root config_file plugin_dir
  sandbox=$(new_hook_sandbox)
  project_root="$sandbox/project"
  config_file="$project_root/.codex/config.toml"
  plugin_dir="$project_root/plugin"
  mkdir -p "$project_root/.codex" "$plugin_dir"

  cat > "$project_root/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "project-server": {
      "command": "/tmp/project-server"
    }
  }
}
EOF
  cat > "$plugin_dir/.mcp.json" <<'EOF'
{
  "mcpServers": {
    "plugin-server": {
      "command": "${CLAUDE_PLUGIN_ROOT}/bin/plugin-server",
      "args": ["--root", "${CLAUDE_PLUGIN_ROOT}"]
    }
  }
}
EOF

  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" \
    --project-mcp="$project_root/.mcp.json" \
    --plugin-mcp="$plugin_dir/.mcp.json:$plugin_dir:test-plugin" \
    >"$sandbox/valid-sources.stdout" 2>"$sandbox/valid-sources.stderr" \
    || fail "[valid-sources] valid MCP sources should succeed: $(cat "$sandbox/valid-sources.stderr" 2>/dev/null || true)"

  grep -Fqx '[mcp_servers.project-server]' "$config_file" \
    || fail "[valid-sources] project MCP server missing"
  grep -Fqx 'command = "/tmp/project-server"' "$config_file" \
    || fail "[valid-sources] project MCP command missing"
  grep -Fqx '[mcp_servers.plugin-server]' "$config_file" \
    || fail "[valid-sources] plugin MCP server missing"
  grep -Fqx "command = \"$plugin_dir/bin/plugin-server\"" "$config_file" \
    || fail "[valid-sources] plugin MCP command did not substitute CLAUDE_PLUGIN_ROOT"
  grep -Fqx "args = [\"--root\", \"$plugin_dir\"]" "$config_file" \
    || fail "[valid-sources] plugin MCP args did not substitute CLAUDE_PLUGIN_ROOT"
}

test_sync_sh_mcp_config_failfast() {
  local sandbox project_root config_file stderr_log rc
  sandbox=$(new_hook_sandbox)
  project_root="$sandbox/project"
  config_file="$project_root/.codex/config.toml"
  stderr_log="$sandbox/sync-sh.stderr"
  mkdir -p "$project_root/.codex"

  _write_existing_mcp_config "$config_file"
  rc=0
  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" \
    --project-mcp="$project_root/.mcp.json" >"$sandbox/missing-project.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[missing-project] missing --project-mcp가 non-zero로 실패해야 함"
  grep -Fq "sync.sh mcp-config: --project-mcp source missing:" "$stderr_log" \
    || fail "[missing-project] stderr에 missing source 진단이 있어야 함"
  _assert_existing_mcp_preserved "$config_file" "missing-project"

  _write_existing_mcp_config "$config_file"
  rc=0
  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" \
    --user-mcp="$project_root/missing-user-mcp.json" \
    --user-codex-config="$config_file" >"$sandbox/missing-user.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[missing-user] missing --user-mcp가 non-zero로 실패해야 함"
  grep -Fq "sync.sh mcp-config: --user-mcp source missing:" "$stderr_log" \
    || fail "[missing-user] stderr에 missing user source 진단이 있어야 함"
  _assert_existing_mcp_preserved "$config_file" "missing-user"

  _write_existing_mcp_config "$config_file"
  rc=0
  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" \
    --plugin-mcp="$project_root/missing-plugin-mcp.json:$project_root/plugin:missing-plugin" \
    >"$sandbox/missing-plugin.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[missing-plugin] missing --plugin-mcp가 non-zero로 실패해야 함"
  grep -Fq "sync.sh mcp-config: --plugin-mcp source missing:" "$stderr_log" \
    || fail "[missing-plugin] stderr에 missing plugin source 진단이 있어야 함"
  _assert_existing_mcp_preserved "$config_file" "missing-plugin"

  mkdir -p "$project_root/plugin"
  printf '{}\n' > "$project_root/plugin/.mcp.json"
  _write_existing_mcp_config "$config_file"
  rc=0
  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" \
    --plugin-mcp="$project_root/plugin/.mcp.json:$project_root/plugin" \
    >"$sandbox/malformed-plugin.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[malformed-plugin] malformed --plugin-mcp가 non-zero로 실패해야 함"
  grep -Fq "sync.sh mcp-config: malformed --plugin-mcp source:" "$stderr_log" \
    || fail "[malformed-plugin] stderr에 malformed plugin source 진단이 있어야 함"
  _assert_existing_mcp_preserved "$config_file" "malformed-plugin"

  _write_existing_mcp_config "$config_file"
  rc=0
  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" \
    --plugin-mcp="$project_root/plugin/.mcp.json:$project_root/plugin:plugin-name:extra" \
    >"$sandbox/malformed-plugin-extra.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[malformed-plugin-extra] extra field --plugin-mcp가 non-zero로 실패해야 함"
  grep -Fq "sync.sh mcp-config: malformed --plugin-mcp source:" "$stderr_log" \
    || fail "[malformed-plugin-extra] stderr에 malformed plugin source 진단이 있어야 함"
  _assert_existing_mcp_preserved "$config_file" "malformed-plugin-extra"

  _write_existing_mcp_config "$config_file"
  rc=0
  bash "$SYNC_HARNESS_SH" mcp-config "$project_root" >"$sandbox/no-source.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[no-source] source 옵션 없는 mcp-config가 non-zero로 실패해야 함"
  grep -Fq "at least one source option" "$stderr_log" \
    || fail "[no-source] stderr에 source option 필수 진단이 있어야 함"
  _assert_existing_mcp_preserved "$config_file" "no-source"

  local all_project_root="$sandbox/all-project"
  mkdir -p "$all_project_root"
  rc=0
  bash "$SYNC_HARNESS_SH" all "$all_project_root" \
    --user-mcp="$all_project_root/missing-user-mcp.json" \
    >"$sandbox/all-missing-user.stdout" 2>"$stderr_log" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "[all-missing-user] sync all missing --user-mcp가 non-zero로 실패해야 함"
  grep -Fq "sync.sh all: --user-mcp source missing:" "$stderr_log" \
    || fail "[all-missing-user] stderr에 sync all missing user source 진단이 있어야 함"
  [[ ! -e "$all_project_root/.agents" ]] \
    || fail "[all-missing-user] source preflight 전에 .agents를 생성하면 안 됨"
  [[ ! -e "$all_project_root/.codex" ]] \
    || fail "[all-missing-user] source preflight 전에 .codex를 생성하면 안 됨"
}

# ─── 카테고리 6: stop-notification reliability/security ───
# 6.1 Codex JSONL transcript fallback 추출 검증.
# fixture stdin은 last_assistant_message=null + transcript_path를 sandbox 안의 Codex schema
# JSONL fixture로 가리키게 만든다. extract_last_assistant_text 호출 결과가 fixture transcript의
# output_text 본문(FIXTURE_LAST_ASSISTANT_OUTPUT)을 반환하여 Pushover 본문에 포함됨을 검증한다.
test_stop_notification_codex_transcript_fallback() {
  local sandbox transcript_dest stdin_dest
  sandbox=$(new_hook_sandbox)
  install_pushover_mock_with_curl_log "$sandbox"

  transcript_dest="$sandbox/codex-transcript.jsonl"
  cp "$FIXTURE_DIR/transcripts/codex-0.124-sample.jsonl" "$transcript_dest"

  # fixture stdin의 __SANDBOX_TRANSCRIPT_PATH__ placeholder를 실제 sandbox path로 치환.
  stdin_dest="$sandbox/stop-input.json"
  sed "s|__SANDBOX_TRANSCRIPT_PATH__|$transcript_dest|g" \
    "$FIXTURE_DIR/stdin/stop-no-last-message-codex-transcript.json" > "$stdin_dest"

  run_hook_in_sandbox "$sandbox" "stop-notification.sh" \
    < "$stdin_dest" \
    || fail "[6.1] stop-notification (codex transcript fallback) 비정상 종료"

  [[ -s "$sandbox/curl-args.log" ]] \
    || fail "[6.1] curl mock이 호출되지 않음 (Pushover fallback 미진입)"
  grep -q "FIXTURE_LAST_ASSISTANT_OUTPUT" "$sandbox/curl-args.log" \
    || fail "[6.1] Codex schema transcript의 output_text가 Pushover 본문에 추출되지 않음"
}

# 6.2 secret pattern redaction 검증.
# last_assistant_message에 7 token family 패턴을 모두 포함하고, Pushover curl mock 호출 인자에서
# 각 family 원본이 사라지고 ***REDACTED***가 등장하는지 family별로 assert. 회귀 시 어느 family가
# 깨졌는지 즉시 식별 가능하도록 family 이름을 fail 메시지에 포함한다.
test_stop_notification_secret_redaction() {
  local sandbox
  sandbox=$(new_hook_sandbox)
  install_pushover_mock_with_curl_log "$sandbox"

  run_hook_in_sandbox "$sandbox" "stop-notification.sh" \
    < "$FIXTURE_DIR/stdin/stop-with-secret-reply.json" \
    || fail "[6.2] stop-notification (secret reply) 비정상 종료"

  [[ -s "$sandbox/curl-args.log" ]] \
    || fail "[6.2] curl mock이 호출되지 않음 (Pushover fallback 미진입)"

  local log="$sandbox/curl-args.log"

  # PROBE 마커는 본문이 실제로 message 인자에 포함됐음을 확인 (sanity check).
  grep -q "PROBE_PREFIX" "$log" \
    || fail "[6.2] message 본문이 curl 인자에 전달되지 않음 (sanity check 실패)"

  # family별 원본 fragment 부재 + ***REDACTED*** 등장.
  # 각 family 고유의 원본 fragment를 검사한다 (full 원본 토큰 일부; ***REDACTED***로 치환됐다면 부재).
  local families_negative=(
    "sk-ant:sk-ant-aBcDeFgHiJkLmNoPqRsTuVwXyZ"
    "sk-openai:sk-aBcDeFgHiJkLmNoPqRsTuVwXyZ"
    "gh-classic-ghp:ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
    "gh-classic-ghs:ghs_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
    "gh-classic-gho:gho_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
    "gh-classic-ghu:ghu_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"
    "github-pat:github_pat_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789aBcDeFgHiJkL"
    "jwt-standard:eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOjEyMzR9.signature_segment_xyz"
    "jwt-whitespace-header:eyAhbGciOiJIUzI1NiJ9.eyJzdWIiOjEyMzR9.whitespace_jwt_var"
    "aws-akia:AKIA0123456789ABCDEF"
    "aws-asia:ASIA0123456789ABCDEF"
  )

  local entry family fragment
  for entry in "${families_negative[@]}"; do
    family="${entry%%:*}"
    fragment="${entry#*:}"
    if grep -qF "$fragment" "$log"; then
      fail "[6.2/$family] 원본 secret fragment가 curl 인자에 그대로 남아 있음: '$fragment'"
    fi
  done

  grep -q "\*\*\*REDACTED\*\*\*" "$log" \
    || fail "[6.2] ***REDACTED*** 마커가 curl 인자에 등장하지 않음 (redaction 자체 실패 가능성)"
}

# 6.2b Codex hook은 Claude Code credential path를 fallback으로 쓰면 안 된다.
test_stop_notification_requires_codex_pushover_credentials() {
  local sandbox
  sandbox=$(new_hook_sandbox)
  install_pushover_mock_with_curl_log "$sandbox" "claude-code"

  run_hook_in_sandbox "$sandbox" "stop-notification.sh" \
    < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
    || fail "[6.2b] stop-notification (old claude-code credential only) 비정상 종료"

  [[ ! -e "$sandbox/curl-args.log" ]] \
    || fail "[6.2b] Codex hook이 ~/.config/pushover/claude-code credential을 사용함"
}

# 6.3 timeout 미가용 fail-open 검증 (Darwin 전용).
# bin-stubs에 timeout을 exit 127 stub으로 둬서 macOS BSD coreutils 환경(GNU coreutils 부재) 시나리오를
# 시뮬레이션한다. hook의 run_with_timeout 호출은 `[[ "$OSTYPE" == darwin* ]] && command -v hs` 블록
# 내부이므로 non-Darwin runner에서는 Hammerspoon 블록이 통째로 skip되어 검증 의미가 없다 → skip.
# Darwin runner에서는 timeout stub의 exit 127로 HS_SENT=false 유지 → Pushover fallback (curl mock).
test_stop_notification_timeout_unavailable_failopen() {
  if [[ "$(uname -s)" != "Darwin" ]]; then
    warn "[6.3] non-Darwin runner — Hammerspoon 블록 skip되므로 검증 의미 없음. skip."
    return 0
  fi

  local sandbox
  sandbox=$(new_hook_sandbox)
  install_pushover_mock_with_curl_log "$sandbox"

  cat > "$sandbox/bin-stubs/timeout" <<'STUB'
#!/usr/bin/env bash
exit 127
STUB
  chmod +x "$sandbox/bin-stubs/timeout"

  run_hook_in_sandbox "$sandbox" "stop-notification.sh" \
    < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
    || fail "[6.3] stop-notification (timeout 부재 stub) 비정상 종료"

  [[ -s "$sandbox/curl-args.log" ]] \
    || fail "[6.3] timeout 부재 시 Pushover fallback으로 전이되지 않음 (HS_SENT=false 보존 실패)"
}

# 6.4 양쪽 hook helper 블록 동등성 검증.
# Codex 사본과 Claude 원본의 redact_secrets()/run_with_timeout() 함수 본문이 byte-for-byte
# 동일함을 보장한다. hook이 cp 동기화 패턴이라 한쪽만 패턴 추가/regex 수정하는 drift를 차단.
# Marker 기반 추출: helper 위/아래에 `# === HELPER_BEGIN: <name> ===` / `HELPER_END` 주석을 두고
# 그 사이를 추출한다. 함수 선언부 포맷(공백/괄호 위치) 변화에 robust하다.
_extract_function_block() {
  local file="$1" name="$2"
  awk -v name="$name" '
    $0 == "# === HELPER_BEGIN: " name " ===" { in_block = 1; next }
    in_block && $0 == "# === HELPER_END: " name " ===" { in_block = 0; exit }
    in_block { print }
  ' "$file"
}

test_stop_notification_helper_equivalence() {
  local codex_hook="$REPO_ROOT/modules/shared/programs/codex/files/hooks/stop-notification.sh"
  local claude_hook="$REPO_ROOT/modules/shared/programs/claude/files/hooks/stop-notification.sh"

  local fn
  for fn in redact_secrets run_with_timeout; do
    local codex_block claude_block
    codex_block=$(_extract_function_block "$codex_hook" "$fn")
    claude_block=$(_extract_function_block "$claude_hook" "$fn")

    [[ -n "$codex_block" ]] || fail "[6.4/$fn] Codex 사본에서 함수 본문을 추출하지 못함"
    [[ -n "$claude_block" ]] || fail "[6.4/$fn] Claude 원본에서 함수 본문을 추출하지 못함"

    if [[ "$codex_block" != "$claude_block" ]]; then
      fail "[6.4/$fn] Codex 사본과 Claude 원본의 helper 본문이 drift 됨 — sync 필요"
    fi
  done
}

# ─── 카테고리 7: pinning-alert behavioral ───
# Claude/Codex pinning-alert.sh(PostToolUse warn-only, #603/#605 도입)의 입력→출력 동작을
# deterministic stdin fixture로 박제한다. fixture는 stdin/pinning-{claude,codex}-*.json이고,
# 옆에 위치한 *.expected에 stderr 출력을 박는다. exit code는 모두 0(warn-only contract).
# Codex apply_patch envelope V4A awk parser의 핵심 분기(*** Move to: rename, multi-file
# attribution, removeonly added-line filter, backtick HASH_MIN 미만)를 함께 보호한다.
test_pinning_shared_library_behavioral() {
  local sandbox scan_file da_symlink_dir
  sandbox=$(new_hook_sandbox)
  scan_file="$sandbox/pinning-shared-scan.txt"
  {
    printf '%s\n' "Ro""und 1"
    printf '%s\n' "Correctness""-1"
    printf '%s\n' "DA ""for_plan"
    printf '%s\n' "dead""bee"
  } > "$scan_file"
  mkdir -p \
    "$sandbox/.claude/prds" \
    "$sandbox/.claude/plans" \
    "$sandbox/docs/examples/.claude/prds"

  # shellcheck source=../modules/shared/programs/claude/files/lib/pinning-patterns.sh
  . "$PINNING_LIB_REPO_FILE"

  assert_eq "$(pinning_match_count "$scan_file")" "4" \
    "[7/lib] raw helper must keep PATTERN_A visible"
  assert_eq "$(pinning_match_count_for_path "$scan_file" "$sandbox/outside.md")" "4" \
    "[7/lib] outside path must keep PATTERN_A visible"
  assert_eq "$(PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/prds/prd.md")" "3" \
    "[7/lib] PRD path must skip only PATTERN_A"
  assert_eq "$(PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/docs/examples/.claude/prds/prd.md")" "4" \
    "[7/lib] nested PRD-looking path must not skip PATTERN_A"
  assert_eq "$(if PINNING_PROJECT_ROOT="$sandbox" pinning_should_check_path "$sandbox/.claude/prds/spec.txt"; then printf check; else printf skip; fi)" "check" \
    "[7/lib] PRD/plan path should_check must bypass generic extension gate"
  assert_eq "$(if PINNING_PROJECT_ROOT="$sandbox" pinning_should_check_path "$sandbox/outside.txt"; then printf check; else printf skip; fi)" "skip" \
    "[7/lib] outside non-durable extension should still skip"

  cat > "$sandbox/bin-stubs/realpath" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  cat > "$sandbox/bin-stubs/readlink" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$sandbox/bin-stubs/realpath" "$sandbox/bin-stubs/readlink"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/plans/plan.md")" "3" \
    "[7/lib] PRD/plan path fallback must not require GNU realpath/readlink"
  assert_eq "$(if PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_should_check_path "$sandbox/.claude/plans/plan.yaml"; then printf check; else printf skip; fi)" "check" \
    "[7/lib] PRD/plan should_check fallback must not require durable extension"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}"; if pinning_should_check_path "/home/test/repo/scripts/ai/commit-msg-pinning.sh"; then printf check; else printf skip; fi)" "skip" \
    "[7/lib] should_check fallback must preserve self-exclude paths without GNU realpath/readlink"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}"; if pinning_should_check_path "/tmp/da-test-abc/scratch.md"; then printf check; else printf skip; fi)" "skip" \
    "[7/lib] should_check fallback must preserve DA scratch whitelist without GNU realpath/readlink"
  mkdir -p "$sandbox/.claude/plans"
  : > "$sandbox/.claude/plans/existing.md"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/plans/existing.md")" "3" \
    "[7/lib] PRD/plan path fallback must cover existing regular files"
  mkdir -p "$sandbox/.claude/prds"
  : > "$sandbox/outside.md"
  ln -s "$sandbox/outside.md" "$sandbox/.claude/prds/symlink.md"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/prds/symlink.md")" "4" \
    "[7/lib] PRD/plan fallback must fail closed for existing symlink targets"
  da_symlink_dir=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/da-test-symlink.XXXXXX") \
    || fail "[7/lib] DA symlink mktemp -d 실패"
  printf '%s\n' "$da_symlink_dir" >> "$TEST_TMP_FILE"
  ln -s "$sandbox/outside.md" "$da_symlink_dir/link.md"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}"; if pinning_should_check_path "$da_symlink_dir/link.md"; then printf check; else printf skip; fi)" "check" \
    "[7/lib] should_check fallback must fail closed for existing symlink targets"
}

_assert_pinning_expectation() {
  local fixture="$1" stderr_log="$2"
  local expected="${fixture%.json}.expected"
  if ! diff -u "$expected" "$stderr_log" >/dev/null 2>&1; then
    # diff 비매치 + head pipeline은 nonzero를 반환하므로 set -euo pipefail 환경에서 assignment 자체가
    # 중단되지 않도록 diff 캡처만 성공 처리한다 (`|| true`). 실제 실패 보고는 바로 아래 `fail`이 담당 (#606).
    local diff_out
    diff_out=$(diff -u "$expected" "$stderr_log" 2>&1 | head -40 || true)
    fail "[7] $(basename "$fixture") stderr expectation drift:
$diff_out"
  fi
}

test_pinning_alert_behavioral() {
  local hook_claude="$REPO_ROOT/modules/shared/programs/claude/files/hooks/pinning-alert.sh"
  local hook_codex="$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-alert.sh"
  local fixture sandbox materialized stderr_log hook exit_code pinning_root_env

  for fixture in "$FIXTURE_DIR"/stdin/pinning-*.json; do
    assert_file_exists "${fixture%.json}.expected" "7/$(basename "$fixture")"

    # new_hook_sandbox 재사용: TEST_TMP_FILE 등록을 통해 EXIT trap이 자동 정리한다. hook 실행은
    # _exec_with_sandbox_env로 sandbox 격리 env(CLAUDECODE/CODEX_PROGRAMMATIC unset, sandbox
    # bin-stubs PATH prepend, HOME/XDG/CODEX_HOME sandbox 강제)를 적용해 host 상태 누수를 차단한다.
    # pinning-alert.sh는 sandbox 내부 hook copy가 아닌 repo root path를 직접 호출하지만 env 격리
    # 계약은 카테고리 6 helper와 단일 source를 공유한다.
    sandbox=$(new_hook_sandbox)
    materialized="$(_materialize_pinning_fixture "$fixture" "$sandbox")"
    stderr_log="$sandbox/pinning-stderr.log"
    pinning_root_env="PINNING_PROJECT_ROOT=$sandbox/fixture-pinning"

    case "$(basename "$fixture")" in
      pinning-claude-*) hook="$hook_claude" ;;
      pinning-codex-*)  hook="$hook_codex" ;;
      *) fail "[7] unexpected fixture name: $(basename "$fixture")" ;;
    esac

    if _exec_with_sandbox_env "$sandbox" "$pinning_root_env" "$hook" < "$materialized" 2>"$stderr_log"; then
      exit_code=0
    else
      exit_code=$?
    fi
    assert_eq "$exit_code" "0" "[7] $(basename "$fixture"): warn-only contract 위반 (exit must be 0)"
    _assert_pinning_expectation "$materialized" "$stderr_log"
  done
}

# ─── 카테고리 7b: PreToolUse pinning-guard behavioral ───
# Claude/Codex pinning-guard.sh(PreToolUse hard-fail, issue #587)의 입력→deny JSON/clean pass
# 동작을 별도 namespace로 박제한다. expected 파일은 deny reason 원문이고, 빈 expected는 clean pass.
_assert_pretooluse_guard_expectation() {
  local fixture="$1" stdout_log="$2" reason_log="$3"
  local expected="${fixture%.json}.expected"
  if [ -s "$expected" ]; then
    local event decision
    event="$(jq -r '.hookSpecificOutput.hookEventName // empty' "$stdout_log" 2>/dev/null)" \
      || fail "[7b] $(basename "$fixture"): stdout JSON parse failed"
    decision="$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$stdout_log" 2>/dev/null)" \
      || fail "[7b] $(basename "$fixture"): stdout JSON parse failed"
    assert_eq "$event" "PreToolUse" "[7b] $(basename "$fixture"): hook event mismatch"
    assert_eq "$decision" "deny" "[7b] $(basename "$fixture"): permission decision mismatch"
    jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$stdout_log" > "$reason_log" \
      || fail "[7b] $(basename "$fixture"): reason extract failed"
  else
    if [ -s "$stdout_log" ]; then
      local unexpected
      unexpected="$(head -40 "$stdout_log")"
      fail "[7b] $(basename "$fixture"): expected clean pass with empty stdout, got:
$unexpected"
    fi
    : > "$reason_log"
  fi

  if ! diff -u "$expected" "$reason_log" >/dev/null 2>&1; then
    local diff_out
    diff_out=$(diff -u "$expected" "$reason_log" 2>&1 | head -40 || true)
    fail "[7b] $(basename "$fixture") PreToolUse expectation drift:
$diff_out"
  fi
}

_materialize_pinning_fixture() {
  local fixture="$1" sandbox="$2"
  local materialized
  materialized="$sandbox/$(basename "$fixture")"
  local materialized_meta="$materialized.with-meta"
  local sandbox_sed
  sandbox_sed="$(sed_replacement_escape "$sandbox")"
  local da_sandbox da_sandbox_sed
  da_sandbox=$(umask 077 && mktemp -d "${TMPDIR:-/tmp}/da-codex-hook-fixture.XXXXXX") \
    || fail "DA scratch mktemp -d 실패"
  printf '%s\n' "$da_sandbox" >> "$TEST_TMP_FILE"
  da_sandbox_sed="$(sed_replacement_escape "$da_sandbox")"
  local placeholders=(
    "__SANDBOX_EXISTING_PINNED_MD__"
    "__SANDBOX_EXISTING_PRD_MD__"
    "__SANDBOX_EXISTING_PLAN_MD__"
  )
  local paths=(
    "$sandbox/existing-pinned.md"
    "$sandbox/fixture-pinning/.claude/prds/existing.md"
    "$sandbox/fixture-pinning/.claude/plans/existing.md"
  )
  local sed_args=(
    -e "s#/tmp/da-test-abc/#${da_sandbox_sed}/#g"
    -e "s#/tmp/da-x/../../home/greenhead/Workspace/nixos-config/#${sandbox_sed}/da-x/../repo/#g"
    -e "s#/tmp/fixture-pinning-#${sandbox_sed}/fixture-pinning-#g"
    -e "s#/tmp/fixture-pinning/#${sandbox_sed}/fixture-pinning/#g"
    -e "s#/tmp/fixture-pretooluse-#${sandbox_sed}/fixture-pretooluse-#g"
  )
  local i

  mkdir -p \
    "$sandbox/da-x" \
    "$sandbox/fixture-pinning/.claude/prds" \
    "$sandbox/fixture-pinning/.claude/plans" \
    "$sandbox/fixture-pinning/docs/examples/.claude/prds"
  for i in "${!placeholders[@]}"; do
    mkdir -p "$(dirname "${paths[$i]}")"
    sed_args+=(-e "s#${placeholders[$i]}#$(sed_replacement_escape "${paths[$i]}")#g")
  done

  sed "${sed_args[@]}" "$fixture" > "$materialized_meta"
  sed "${sed_args[@]}" "${fixture%.json}.expected" > "${materialized%.json}.expected"
  for i in "${!placeholders[@]}"; do
    if grep -q "${placeholders[$i]}" "$fixture"; then
      jq -r '._fixture_existing_content // .tool_input.old_string // empty' "$materialized_meta" > "${paths[$i]}"
    fi
  done
  jq 'del(._fixture_existing_content)' "$materialized_meta" > "$materialized"
  rm -f "$materialized_meta"
  printf '%s\n' "$materialized"
}

test_pretooluse_pinning_guard_behavioral() {
  local hook_claude="$REPO_ROOT/modules/shared/programs/claude/files/hooks/pinning-guard.sh"
  local hook_codex="$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-guard.sh"
  local fixture sandbox hook materialized stdout_log stderr_log reason_log exit_code stderr_head pinning_root_env

  for fixture in "$FIXTURE_DIR"/stdin/pretooluse-pinning-guard-*.json; do
    assert_file_exists "${fixture%.json}.expected" "7b/$(basename "$fixture")"

    sandbox=$(new_hook_sandbox)
    materialized="$(_materialize_pinning_fixture "$fixture" "$sandbox")"
    stdout_log="$sandbox/pretooluse-stdout.log"
    stderr_log="$sandbox/pretooluse-stderr.log"
    reason_log="$sandbox/pretooluse-reason.log"
    pinning_root_env="PINNING_PROJECT_ROOT=$sandbox/fixture-pinning"

    case "$(basename "$fixture")" in
      pretooluse-pinning-guard-claude-*) hook="$hook_claude" ;;
      pretooluse-pinning-guard-codex-*)  hook="$hook_codex" ;;
      *) fail "[7b] unexpected fixture name: $(basename "$fixture")" ;;
    esac

    if _exec_with_sandbox_env "$sandbox" "$pinning_root_env" "$hook" < "$materialized" >"$stdout_log" 2>"$stderr_log"; then
      exit_code=0
    else
      exit_code=$?
    fi
    assert_eq "$exit_code" "0" "[7b] $(basename "$fixture"): hook must exit 0 and communicate deny via JSON"
    if [ -s "$stderr_log" ]; then
      stderr_head="$(head -40 "$stderr_log")"
      fail "[7b] $(basename "$fixture"): expected empty stderr, got:
$stderr_head"
    fi
    _assert_pretooluse_guard_expectation "$materialized" "$stdout_log" "$reason_log"
  done
}

test_pretooluse_pinning_guard_meta_behavioral() {
  local clean_fixture="$FIXTURE_DIR/stdin/pretooluse-pinning-guard-codex-applypatch-clean.json"
  local sandbox stdout_log stderr_log exit_code unexpected event decision reason

  sandbox=$(new_hook_sandbox)
  stdout_log="$sandbox/pretooluse-env-clean-stdout.log"
  stderr_log="$sandbox/pretooluse-env-clean-stderr.log"
  if PINNING_PATTERNS_LIB="$sandbox/host-leaked-pinning-patterns.sh" \
      _exec_with_sandbox_env "$sandbox" "" "$sandbox/home/.codex/hooks/pinning-guard.sh" \
        < "$clean_fixture" >"$stdout_log" 2>"$stderr_log"; then
    exit_code=0
  else
    exit_code=$?
  fi
  assert_eq "$exit_code" "0" "[7b/meta] host PINNING_PATTERNS_LIB leak check: hook must exit 0"
  if [ -s "$stderr_log" ]; then
    unexpected="$(head -40 "$stderr_log")"
    fail "[7b/meta] host PINNING_PATTERNS_LIB leak check: expected empty stderr, got:
$unexpected"
  fi
  if [ -s "$stdout_log" ]; then
    unexpected="$(head -40 "$stdout_log")"
    fail "[7b/meta] host PINNING_PATTERNS_LIB leak check: expected clean pass with empty stdout, got:
$unexpected"
  fi

  local label hook_source hook_target fixture
  for label in claude codex; do
    sandbox=$(new_hook_sandbox)
    rm -f "$sandbox/home/.claude/lib/pinning-patterns.sh" "$sandbox/home/.codex/lib/pinning-patterns.sh"
    stdout_log="$sandbox/pretooluse-missing-lib-stdout.log"
    stderr_log="$sandbox/pretooluse-missing-lib-stderr.log"

    case "$label" in
      claude)
        fixture="$FIXTURE_DIR/stdin/pretooluse-pinning-guard-claude-write-clean.json"
        mkdir -p "$sandbox/home/.claude/hooks"
        hook_source="$REPO_ROOT/modules/shared/programs/claude/files/hooks/pinning-guard.sh"
        hook_target="$sandbox/home/.claude/hooks/pinning-guard.sh"
        cp -L "$hook_source" "$hook_target"
        chmod +x "$hook_target"
        ;;
      codex)
        fixture="$FIXTURE_DIR/stdin/pretooluse-pinning-guard-codex-applypatch-clean.json"
        hook_target="$sandbox/home/.codex/hooks/pinning-guard.sh"
        ;;
      *) fail "[7b/meta] unexpected runtime label: $label" ;;
    esac

    if _exec_with_sandbox_env "$sandbox" "" "$hook_target" < "$fixture" >"$stdout_log" 2>"$stderr_log"; then
      exit_code=0
    else
      exit_code=$?
    fi
    assert_eq "$exit_code" "0" "[7b/meta/$label] missing shared lib: hook must exit 0 and deny via JSON"
    if [ -s "$stderr_log" ]; then
      unexpected="$(head -40 "$stderr_log")"
      fail "[7b/meta/$label] missing shared lib: expected empty stderr, got:
$unexpected"
    fi
    event="$(jq -r '.hookSpecificOutput.hookEventName // empty' "$stdout_log" 2>/dev/null)" \
      || fail "[7b/meta/$label] missing shared lib: stdout JSON parse failed"
    decision="$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$stdout_log" 2>/dev/null)" \
      || fail "[7b/meta/$label] missing shared lib: stdout JSON parse failed"
    reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$stdout_log" 2>/dev/null)" \
      || fail "[7b/meta/$label] missing shared lib: stdout JSON parse failed"
    assert_eq "$event" "PreToolUse" "[7b/meta/$label] missing shared lib: hook event mismatch"
    assert_eq "$decision" "deny" "[7b/meta/$label] missing shared lib: permission decision mismatch"
    case "$reason" in
      "[pinning-guard] shared pinning policy library is missing:"*) ;;
      *) fail "[7b/meta/$label] missing shared lib: unexpected reason: $reason" ;;
    esac
  done
}

# ─── 카테고리 7c: commit-msg pinning behavioral ───
# commit-msg-pinning.sh도 guard/alert와 같은 shared partial-hash helper를 소비한다.
_assert_commit_msg_expectation() {
  local fixture="$1" stderr_log="$2"
  local expected="${fixture%.msg}.expected"
  if ! diff -u "$expected" "$stderr_log" >/dev/null 2>&1; then
    local diff_out
    diff_out=$(diff -u "$expected" "$stderr_log" 2>&1 | head -40 || true)
    fail "[7c] $(basename "$fixture") stderr expectation drift:
$diff_out"
  fi
}

test_commit_msg_pinning_behavioral() {
  local hook="$REPO_ROOT/scripts/ai/commit-msg-pinning.sh"
  local fixture sandbox stderr_log exit_code

  for fixture in "$FIXTURE_DIR"/commit-msg/*.msg; do
    assert_file_exists "${fixture%.msg}.expected" "7c/$(basename "$fixture")"
    sandbox=$(new_hook_sandbox)
    stderr_log="$sandbox/commit-msg-stderr.log"

    if _exec_with_sandbox_env "$sandbox" "" "$hook" "$fixture" 2>"$stderr_log"; then
      exit_code=0
    else
      exit_code=$?
    fi
    assert_eq "$exit_code" "0" "[7c] $(basename "$fixture"): warn-only contract 위반 (exit must be 0)"
    _assert_commit_msg_expectation "$fixture" "$stderr_log"
  done
}

# ─── 카테고리 5: programmatic env inheritance live (opt-in) ───
# programmatic codex exec 호출자가 CODEX_PROGRAMMATIC=1을 codex 프로세스에 붙이면,
# UserPromptSubmit hook subprocess까지 해당 marker가 상속되는지 검증한다. managed hook
# early-exit 자체는 deterministic noise-guard fixture(카테고리 3)가 검증한다.
# 환경 결함(codex/wrapper 부재, wrapper capability-probe 실패, session 실패)이면 WARN skip.
test_programmatic_env_inheritance_live() {
  if ! command -v codex >/dev/null 2>&1; then
    warn "programmatic env inheritance live: codex 바이너리 부재 — skip"
    return 0
  fi

  local supervised
  if command -v codex-exec-supervised >/dev/null 2>&1; then
    supervised="codex-exec-supervised"
  else
    supervised="$REPO_ROOT/modules/shared/scripts/codex-exec-supervised.sh"
    if [[ ! -x "$supervised" ]]; then
      warn "programmatic env inheritance live: codex-exec-supervised 미설치 (~/.local/bin 또는 $supervised) — skip (환경 결함)"
      return 0
    fi
  fi

  local sandbox dump_log
  sandbox=$(new_hook_sandbox)
  dump_log="$sandbox/dump-env.log"

  # 임시 dump-env hook을 sandbox에 작성해 UserPromptSubmit으로 등록.
  cat > "$sandbox/home/.codex/hooks/dump-env.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
{
  printf 'CLAUDECODE=%s\n' "\${CLAUDECODE:-<unset>}"
  printf 'CODEX_PROGRAMMATIC=%s\n' "\${CODEX_PROGRAMMATIC:-<unset>}"
} >> "$dump_log"
exit 0
EOF
  chmod +x "$sandbox/home/.codex/hooks/dump-env.sh"

  # 최소 ephemeral config: dump-env만 등록.
  # sandbox_mode는 read-only로 설정 — host filesystem 보호. dump_log는 hook이 자체적으로
  # `>>` 로 작성하므로 ephemeral codex의 sandbox와 무관하게 host shell이 connect한 fd 통해 기록된다.
  local ephemeral_cfg="$sandbox/codex-home/config.toml"
  cat > "$ephemeral_cfg" <<EOF
approval_policy = "never"
sandbox_mode = "read-only"

[[hooks.UserPromptSubmit]]
[[hooks.UserPromptSubmit.hooks]]
type = "command"
command = "$sandbox/home/.codex/hooks/dump-env.sh"
EOF

  # 본 fixture의 검증 의도는 "programmatic 호출자가 codex 프로세스에 붙인 CODEX_PROGRAMMATIC=1이
  # hook subprocess까지 상속되는지"이다. CLAUDECODE는 부모에서 제거해 이 fixture가 Claude nesting
  # marker에 의존하지 않음을 보인다.
  #
  # dump-env hook 등록은 sandbox CODEX_HOME/config.toml에 있으므로 --ignore-user-config를 쓰지 않는다.
  # 쓰면 sandbox config 자체가 무시되어 hook이 발화하지 않는다. stdin은 wrapper 책임이 아니므로
  # pipe + '-'로 EOF를 명시해 inherited-stdin hang shape를 차단한다.
  local codex_rc=0
  local codex_stderr="$sandbox/codex-exec.stderr"
  ( cd "$sandbox" && printf 'noop\n' | env -u CLAUDECODE \
       CODEX_PROGRAMMATIC=1 \
       CODEX_EXEC_TIMEOUT_SECONDS="$LIVE_CODEX_TIMEOUT_SECONDS" \
       CODEX_EXEC_KILL_AFTER_SECONDS="$CODEX_EXEC_KILL_AFTER_SECONDS" \
       CODEX_HOME="$sandbox/codex-home" \
       HOME="$sandbox/home" \
       XDG_DATA_HOME="$sandbox/xdg-data" \
       XDG_CONFIG_HOME="$sandbox/xdg-config" \
       "$supervised" \
         --ephemeral --skip-git-repo-check --sandbox read-only --ignore-rules \
         -c model="gpt-5.5" -c model_reasoning_effort="medium" \
         - >/dev/null 2>"$codex_stderr" ) \
    || codex_rc=$?

  # hook이 codex exec 실패 전에 실행되었을 수 있으므로 dump_log를 우선 검사한다. dump_log에
  # 기록이 있으면 inheritance 결과를 직접 확인 (환경 결함으로 가리지 않는다). dump_log가 비어 있고
  # codex exec도 실패한 경우에만 환경 결함 WARN skip으로 분류한다.
  if [[ -s "$dump_log" ]]; then
    grep -qE '^CODEX_PROGRAMMATIC=1$' "$dump_log" \
      || fail "programmatic env inheritance live: CODEX_PROGRAMMATIC=1 미도달 (dump_log=$(cat "$dump_log"))"
    if (( codex_rc != 0 )); then
      warn "programmatic env inheritance live: hook inheritance 도달 확인 + codex exec 후속 비정상(rc=$codex_rc) — inheritance 통과"
    fi
    return 0
  fi

  if (( codex_rc != 0 )); then
    # codex exec 실패 + dump_log 부재 → hook이 한 번도 실행 안 됨. 환경 결함.
    # codex exec stderr 마지막 부분을 진단에 포함해 운영자가 timeout/auth/network 원인을 식별 가능하게.
    local stderr_tail
    stderr_tail=$(tail -c 800 "$codex_stderr" 2>/dev/null | tr '\n' ' ' || true)
    warn "programmatic env inheritance live: codex exec 비정상(rc=$codex_rc) 또는 timeout(${LIVE_CODEX_TIMEOUT_SECONDS}s) + dump_log empty — skip (환경 결함). stderr_tail: ${stderr_tail:-<empty>}"
    return 0
  fi

  # codex exec 정상 종료 + dump_log 부재 → hook inheritance 미도달 회귀.
  fail "programmatic env inheritance live: codex exec 정상 종료했으나 dump_log empty — hook inheritance 미도달"
}

# ─── 카테고리 5b: codex exec invocation matrix (live opt-in, must-pass-only — issue #593) ───
# fix 적용 후 PASS가 기대되는 시나리오만 검증한다. vJ (PR #595 fixture pattern hang)는 본 matrix
# 제외 — known caveat (using-codex-exec/references/known-issues.md §15) + 별도 follow-up.
#
# 시나리오:
#   1. host_home_no_override_stdin_pipe_supervised_pass — vH 입증 패턴 (Layer 1 + supervisor)
#   2. raw_override_inline_toml_hang_with_supervisor_pass — issue #593 raw PoC + supervisor 적용
#      (supervisor가 timeout 안에 SIGTERM/SIGKILL grace로 정리 → 124/137 exit가 정상)
#
# 환경 결함 (codex/codex-exec-supervised 부재) 시만 WARN skip (capability-probe 정책).
# preflight 통과 후 timeout/no-result는 fail (must-pass-only 계약).
# scenario-2는 supervisor 정리 + 잔존 process 부재까지 검증.
test_codex_exec_invocation_live_matrix() {
  # preflight: codex 가용성 (wrapper가 자체 capability-probe하므로 timeout/setsid 별도 검사 불필요).
  if ! command -v codex >/dev/null 2>&1; then
    warn "invocation matrix: codex 바이너리 부재 — skip (환경 결함)"
    return 0
  fi

  # codex-exec-supervised는 nrs activation 후 ~/.local/bin/에 노출된다
  # (modules/shared/programs/shell/default.nix의 home.file + pkgs.writeShellScript wrapper).
  # 미설치 환경(test 직접 실행 등)에서는 repo absolute path fallback.
  local supervised
  if command -v codex-exec-supervised >/dev/null 2>&1; then
    supervised="codex-exec-supervised"
  else
    supervised="$REPO_ROOT/modules/shared/scripts/codex-exec-supervised.sh"
    if [[ ! -x "$supervised" ]]; then
      warn "invocation matrix: codex-exec-supervised 미설치 (~/.local/bin 또는 $supervised) — skip (환경 결함)"
      return 0
    fi
  fi

  local sandbox
  sandbox=$(new_hook_sandbox)

  # ── Scenario 1: host_home_no_override_stdin_pipe_supervised_pass ──
  # host HOME (auth 정상) + no override + stdin pipe + Layer 1 안전 패턴 (supervised + read-only +
  # ignore-user-config + explicit model pin + CODEX_PROGRAMMATIC=1 marker) — supervisor 정상 종료 기대.
  # preflight 통과 후 timeout 또는 빈 result는 회귀로 처리한다 (must-pass-only 계약).
  # env 격리 시 CODEX_PROGRAMMATIC marker는 유지 (Layer 1 + host hook early-exit guard).
  # --ignore-user-config 추가로 user config MCP/plugin 표면 차단.
  local result1="$sandbox/scenario-1-result.md"
  local stderr1="$sandbox/scenario-1.stderr"
  local rc1=0
  printf 'Reply PONG\n' | env -u CLAUDECODE \
    CODEX_PROGRAMMATIC=1 \
    CODEX_EXEC_TIMEOUT_SECONDS="$INVOCATION_MATRIX_TIMEOUT_SECONDS" \
    CODEX_EXEC_KILL_AFTER_SECONDS="$CODEX_EXEC_KILL_AFTER_SECONDS" \
    "$supervised" \
      --ephemeral --skip-git-repo-check --sandbox read-only --ignore-user-config --ignore-rules \
      -c model="gpt-5.5" -c model_reasoning_effort="medium" \
      -o "$result1" \
      - >/dev/null 2>"$stderr1" || rc1=$?

  # rc=127은 supervisor capability-probe 실패 → scenario-2와 동일하게 WARN skip.
  if (( rc1 == 127 )); then
    local stderr_tail1
    stderr_tail1=$(tail -c 400 "$stderr1" 2>/dev/null | tr '\n' ' ' || true)
    warn "invocation matrix scenario-1: supervisor BLOCKED (capability-probe 실패) — skip. stderr_tail: ${stderr_tail1:-<empty>}"
    return 0
  fi

  # PASS 우선 분기: codex 정상 종료 + result 정상이면 PASS (stderr 부수 메시지 무관).
  if (( rc1 == 0 )) && [[ -s "$result1" ]]; then
    : # PASS — supervisor + Layer 1 패턴 정상 동작
  else
    local stderr_tail1
    stderr_tail1=$(tail -c 400 "$stderr1" 2>/dev/null | tr '\n' ' ' || true)
    # 명시적 codex auth/network 결함 신호만 좁게 매치 (Slack MCP 등 부수 신호 제외).
    if grep -qE 'codex login status: Not logged in|ChatCompletionsAPI.*401|connection refused.*api\.openai' "$stderr1" 2>/dev/null; then
      warn "invocation matrix scenario-1: codex auth/network 결함 — skip. stderr_tail: ${stderr_tail1:-<empty>}"
      return 0
    fi
    fail "invocation matrix scenario-1 (host_home_no_override_supervised_pass): rc=$rc1 + result $(test -s "$result1" && echo present || echo empty) — must-pass 회귀. stderr_tail: ${stderr_tail1:-<empty>}"
  fi

  # ── Scenario 2: raw_override_inline_toml_hang_with_supervisor_pass ──
  # issue #593 raw PoC 패턴(`-c hooks.<event>` override 포함). supervisor 미적용 시 hang 확정.
  # supervisor 적용 시 timeout 안에 SIGTERM/SIGKILL grace로 정리되어 0/124/137 exit 모두 PASS.
  # 잔존 codex 프로세스가 없는지 추가 검증 (process group kill 입증).
  local hook_log="$sandbox/scenario-2-hook.log"
  local hook_script="$sandbox/scenario-2-dump.sh"
  cat > "$hook_script" <<EOF
#!/usr/bin/env bash
echo "fired at \$(date +%T)" >> "$hook_log"
exit 0
EOF
  chmod +x "$hook_script"
  : > "$hook_log"

  local result2="$sandbox/scenario-2-result.md"
  local stderr2="$sandbox/scenario-2.stderr"
  local rc2=0
  local override="[{hooks=[{type=\"command\",command=\"$hook_script\"}]}]"
  local sandbox_path="$sandbox"
  local self_pid=$$
  printf 'Reply PONG\n' | env -u CLAUDECODE \
    CODEX_PROGRAMMATIC=1 \
    CODEX_EXEC_TIMEOUT_SECONDS="$INVOCATION_MATRIX_TIMEOUT_SECONDS" \
    CODEX_EXEC_KILL_AFTER_SECONDS="$CODEX_EXEC_KILL_AFTER_SECONDS" \
    "$supervised" \
      --ephemeral --skip-git-repo-check --sandbox read-only --ignore-user-config --ignore-rules \
      -c model="gpt-5.5" -c model_reasoning_effort="medium" \
      -c "hooks.UserPromptSubmit=$override" \
      -c "hooks.Stop=$override" \
      -o "$result2" \
      - >/dev/null 2>"$stderr2" || rc2=$?

  case "$rc2" in
    0|124|137)
      # 0=정상, 124=SIGTERM-by-timeout, 137=SIGKILL-by-timeout — 모두 supervisor가 정리한 PASS.
      # inline `-c hooks.<event>` override가 실제로 발화했는지 검증한다. UserPromptSubmit hook은
      # prompt 처리 직전 발화하므로 supervisor SIGTERM/SIGKILL 시점에도 hook_log에 entry가 있어야
      # 한다. hook_log empty → override 미발화 회귀 (issue #593 PoC가 검증한 핵심 경로).
      if [[ ! -s "$hook_log" ]]; then
        fail "invocation matrix scenario-2: -c hooks override 미발화 (hook_log empty) — override 회귀"
      fi

      # rc=0 (정상 종료)인데 result file이 비어 있으면 codex가 final message를 만들지 않은 것 — success
      # path 회귀 (124/137은 timeout 정리이므로 result는 비어 있을 수 있다).
      if (( rc2 == 0 )) && [[ ! -s "$result2" ]]; then
        fail "invocation matrix scenario-2: rc=0 but result2 empty — final message 누락 회귀"
      fi

      # 잔존 codex/timeout 프로세스가 sandbox path로 식별되는지 확인 (process group kill 입증).
      # macOS pgrep -fc/-fa 미지원 → portable ps + grep -F (fixed string).
      sleep 1  # SIGKILL grace 후 OS reaper에 시간 부여
      local lingering_pids lingering_count lingering_lines
      lingering_pids=$(ps -axo pid=,command= 2>/dev/null | grep -F -- "$sandbox_path" | grep -v "^[[:space:]]*${self_pid}[[:space:]]" | grep -v 'grep -F -- ' | awk '{print $1}' || true)
      if [[ -n "$lingering_pids" ]]; then
        lingering_count=$(printf '%s\n' "$lingering_pids" | wc -l | tr -d ' ')
        lingering_lines=$(ps -axo pid=,command= 2>/dev/null | grep -F -- "$sandbox_path" | grep -v "^[[:space:]]*${self_pid}[[:space:]]" | grep -v 'grep -F -- ' | head -5 || true)
        fail "invocation matrix scenario-2: supervisor 종료 후 sandbox 관련 프로세스 ${lingering_count}개 잔존 — process group kill 회귀. ${lingering_lines}"
      fi
      ;;
    127)
      warn "invocation matrix scenario-2: supervisor BLOCKED (capability probe 실패) — skip"
      return 0
      ;;
    *)
      local stderr_tail2
      stderr_tail2=$(tail -c 400 "$stderr2" 2>/dev/null | tr '\n' ' ' || true)
      fail "invocation matrix scenario-2 (raw_override_supervised_pass): 비정상 exit($rc2) — supervisor 미정리 회귀. stderr_tail: ${stderr_tail2:-<empty>}"
      ;;
  esac
}

# ─── 실행 진입점 ───
run_test() {
  local label="$1"; shift
  echo "==> $label"
  "$@"
}

run_test "stdin payloads (codex $CODEX_HOOK_SCHEMA_BASELINE) create expected hook artifacts" \
  test_stdin_payloads_create_expected_hook_artifacts_codex_0_124
run_test "dispatcher ordering with mock sub-scripts" \
  test_dispatcher_ordering_with_mock_subscripts
run_test "dispatcher recovers from sub-script failures" \
  test_dispatcher_recovers_from_subscript_failures
run_test "noise-guard env variants (cleanup unguarded)" \
  test_noise_guard_env_variants_with_cleanup_unguarded
run_test "sync-codex-config preservation scenarios A/B/C/D/E/F" \
  test_sync_preservation_scenarios

run_test "stop-notification codex transcript fallback (6.1)" \
  test_stop_notification_codex_transcript_fallback
run_test "stop-notification secret redaction (6.2)" \
  test_stop_notification_secret_redaction
run_test "stop-notification requires codex pushover credential (6.2b)" \
  test_stop_notification_requires_codex_pushover_credentials
run_test "stop-notification timeout unavailable fail-open (6.3)" \
  test_stop_notification_timeout_unavailable_failopen
run_test "stop-notification helper equivalence (6.4)" \
  test_stop_notification_helper_equivalence

run_test "pinning shared library behavioral" \
  test_pinning_shared_library_behavioral
run_test "pinning-alert behavioral (#606)" \
  test_pinning_alert_behavioral
run_test "pretooluse pinning-guard behavioral (#587)" \
  test_pretooluse_pinning_guard_behavioral
run_test "pretooluse pinning-guard meta behavioral (#587)" \
  test_pretooluse_pinning_guard_meta_behavioral
run_test "commit-msg pinning behavioral" \
  test_commit_msg_pinning_behavioral
run_test "sync.sh mcp-config valid sources (#609)" \
  test_sync_sh_mcp_config_valid_sources
run_test "sync.sh mcp-config fail-fast (#609)" \
  test_sync_sh_mcp_config_failfast

if [[ "$LIVE_MODE" == "1" ]]; then
  # invocation matrix를 programmatic env inheritance보다 먼저 실행한다 (issue #593):
  # wrapper/process-group 회귀 차단 신호를 먼저 확보한 뒤, sandbox CODEX_HOME에 등록한
  # dump hook이 caller-supplied CODEX_PROGRAMMATIC marker를 상속받는지 확인한다.
  run_test "codex exec invocation matrix (supervised wrapper, must-pass-only)" \
    test_codex_exec_invocation_live_matrix
  run_test "programmatic env inheritance live (codex exec --ephemeral)" \
    test_programmatic_env_inheritance_live
else
  echo "==> codex exec invocation matrix  (skip; --live 또는 CODEX_HOOK_LIVE=1로 활성화)"
  echo "==> programmatic env inheritance live  (skip; --live 또는 CODEX_HOOK_LIVE=1로 활성화)"
fi

echo "All codex hook fixture tests passed."
