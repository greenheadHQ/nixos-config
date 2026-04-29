#!/usr/bin/env bash
# tests/test-codex-hook-fixtures.sh
# Codex 0.124+ stable hook 회귀 차단 fixture runner.
#
# 6 카테고리:
#   1. stdin schema baseline 0.124       — fixtures/codex-hooks/stdin/*.json
#   2. dispatcher ordering / failure recovery — runner 내부 mock subscript
#   3. noise-guard env 변형              — runner 내부 helper (4 env 조합)
#   4. sync-codex-config.py preservation — fixtures/codex-hooks/sync-preservation/*.toml
#   5. env propagation (live opt-in)      — CODEX_HOOK_LIVE=1 / --live
#   6. stop-notification reliability/security — transcripts/ + stdin secret/transcript fixtures
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
  --live       env propagation live fixture까지 실행 (codex exec 호출)
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
# verify-ai-compat의 _TEMPLATE 분기와 동일하게 host platform에 맞는 template을 sync-preservation
# 검증에 사용한다. Darwin은 mcp_servers.chrome-devtools 같은 platform-specific managed leaves를
# 추가로 가지므로 platform-agnostic 검증은 부족하다.
if [ "$(uname -s)" = "Darwin" ]; then
  TEMPLATE_REPO_FILE="$REPO_ROOT/modules/shared/programs/codex/files/config.darwin.toml"
else
  TEMPLATE_REPO_FILE="$REPO_ROOT/modules/shared/programs/codex/files/config.toml"
fi
SYNC_SCRIPT="$REPO_ROOT/modules/shared/programs/codex/files/sync-codex-config.py"

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
    "$sandbox/home/.local/share/claude-hooks" \
    "$sandbox/bin-stubs"

  cp -L "$HOOK_REPO_DIR"/*.sh "$sandbox/home/.codex/hooks/"
  chmod +x "$sandbox/home/.codex/hooks/"*.sh

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
  local env_array=()
  if [[ -n "$env_pairs_string" ]]; then
    read -ra env_array <<<"$env_pairs_string"
  fi
  env -u CLAUDECODE -u CODEX_PROGRAMMATIC "${env_array[@]}" \
      PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" \
      HOME="$sandbox/home" \
      XDG_DATA_HOME="$sandbox/xdg-data" \
      XDG_CONFIG_HOME="$sandbox/xdg-config" \
      CODEX_HOME="$sandbox/codex-home" \
      "$sandbox/home/.codex/hooks/$hook" "$@"
}

# 카테고리 6 (stop-notification reliability/security) 공용: Pushover credential + curl mock 설치.
# - sandbox/home/.config/pushover/claude-code: dummy credential (실제 Pushover API 차단)
# - sandbox/bin-stubs/curl: 호출 인자를 sandbox/curl-args.log에 dump 후 exit 0 (redaction 검증용)
# heredoc unquoted라 $sandbox는 expansion되고 \$@/\$arg는 stub 안에 escape 상태로 남는다.
install_pushover_mock_with_curl_log() {
  local sandbox="$1"
  local creds_dir="$sandbox/home/.config/pushover"
  mkdir -p "$creds_dir"
  cat > "$creds_dir/claude-code" <<'CRED'
PUSHOVER_TOKEN=dummy_token_for_fixture_only
PUSHOVER_USER=dummy_user_for_fixture_only
CRED
  chmod 0600 "$creds_dir/claude-code"

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
  # $1=sandbox, $2=ordering log path, $3..=각 sub-script의 exit 코드 (인자 순서: record-last-stop, stop-notification, nrs-session-cleanup).
  local sandbox="$1" log="$2"
  local rls_rc="${3:-0}" sn_rc="${4:-0}" nsc_rc="${5:-0}"

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
  # (record-last-stop fail), (stop-notification fail), (nrs-session-cleanup fail) 각 시나리오.
  local scenarios=(
    "1 0 0:record-last-stop"
    "0 1 0:stop-notification"
    "0 0 1:nrs-session-cleanup"
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
    local rls_rc="$1" sn_rc="$2" nsc_rc="$3"

    local sandbox log err
    sandbox=$(new_hook_sandbox)
    log="$sandbox/ordering.log"
    err="$sandbox/dispatcher.stderr"

    install_mock_subscripts_with_log "$sandbox" "$log" "$rls_rc" "$sn_rc" "$nsc_rc"

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

# ─── 카테고리 5: env propagation live (opt-in) ───
# codex exec --ephemeral로 임시 dump-env hook을 실행해 CLAUDECODE/CODEX_PROGRAMMATIC propagation
# 도달을 검증한다. 환경 결함(timeout 부재 / codex 부재 / hang / session 실패)이면 WARN skip.
test_env_propagation_live() {
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin="gtimeout"
  else
    warn "live env propagation: timeout/gtimeout 부재 — skip"
    return 0
  fi

  if ! command -v codex >/dev/null 2>&1; then
    warn "live env propagation: codex 바이너리 부재 — skip"
    return 0
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

  # 본 fixture의 검증 의도는 "codex CLI가 hook subprocess에 CLAUDECODE/CODEX_PROGRAMMATIC을
  # 자체 propagate한다"이다. 부모 env에 CODEX_PROGRAMMATIC=1을 미리 set하면 codex CLI가
  # set하는지가 아니라 부모 값이 inherit되는지를 측정하게 되므로 의도가 약화된다.
  # CLAUDECODE도 동일 이유로 부모에서 set하지 않고 codex CLI가 propagate하는지를 본다.
  # cwd는 sandbox로 강제하고 codex exec에 --skip-git-repo-check + --sandbox read-only를 명시해
  # outside-git 거부가 환경 결함으로 분류되지 않도록 + filesystem 보호가 강제되도록 한다.
  local codex_rc=0
  local codex_stderr="$sandbox/codex-exec.stderr"
  ( cd "$sandbox" && env -u CLAUDECODE -u CODEX_PROGRAMMATIC \
       CODEX_HOME="$sandbox/codex-home" \
       HOME="$sandbox/home" \
       XDG_DATA_HOME="$sandbox/xdg-data" \
       XDG_CONFIG_HOME="$sandbox/xdg-config" \
       "$timeout_bin" "$LIVE_CODEX_TIMEOUT_SECONDS" \
       codex exec --ephemeral --skip-git-repo-check --sandbox read-only 'noop' >/dev/null 2>"$codex_stderr" ) \
    || codex_rc=$?

  # hook이 codex exec 실패 전에 실행되었을 수 있으므로 dump_log를 우선 검사한다. dump_log에
  # 기록이 있으면 propagation 결과를 직접 확인 (환경 결함으로 가리지 않는다). dump_log가 비어 있고
  # codex exec도 실패한 경우에만 환경 결함 WARN skip으로 분류한다.
  if [[ -s "$dump_log" ]]; then
    grep -qE '^CLAUDECODE=1$' "$dump_log" \
      || fail "live env propagation: CLAUDECODE=1 미도달 (dump_log=$(cat "$dump_log"))"
    grep -qE '^CODEX_PROGRAMMATIC=1$' "$dump_log" \
      || fail "live env propagation: CODEX_PROGRAMMATIC=1 미도달 (dump_log=$(cat "$dump_log"))"
    if (( codex_rc != 0 )); then
      warn "live env propagation: hook propagation 도달 확인 + codex exec 후속 비정상(rc=$codex_rc) — propagation 통과"
    fi
    return 0
  fi

  if (( codex_rc != 0 )); then
    # codex exec 실패 + dump_log 부재 → hook이 한 번도 실행 안 됨. 환경 결함.
    # codex exec stderr 마지막 부분을 진단에 포함해 운영자가 timeout/auth/network 원인을 식별 가능하게.
    local stderr_tail
    stderr_tail=$(tail -c 800 "$codex_stderr" 2>/dev/null | tr '\n' ' ' || true)
    warn "live env propagation: codex exec 비정상(rc=$codex_rc) 또는 timeout(${LIVE_CODEX_TIMEOUT_SECONDS}s) + dump_log empty — skip (환경 결함). stderr_tail: ${stderr_tail:-<empty>}"
    return 0
  fi

  # codex exec 정상 종료 + dump_log 부재 → hook propagation 미도달 회귀.
  fail "live env propagation: codex exec 정상 종료했으나 dump_log empty — hook propagation 미도달"
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
run_test "sync-codex-config preservation scenarios A/B/C/D" \
  test_sync_preservation_scenarios

run_test "stop-notification codex transcript fallback (6.1)" \
  test_stop_notification_codex_transcript_fallback
run_test "stop-notification secret redaction (6.2)" \
  test_stop_notification_secret_redaction
run_test "stop-notification timeout unavailable fail-open (6.3)" \
  test_stop_notification_timeout_unavailable_failopen
run_test "stop-notification helper equivalence (6.4)" \
  test_stop_notification_helper_equivalence

if [[ "$LIVE_MODE" == "1" ]]; then
  run_test "env propagation live (codex exec --ephemeral)" \
    test_env_propagation_live
else
  echo "==> env propagation live  (skip; --live 또는 CODEX_HOOK_LIVE=1로 활성화)"
fi

echo "All codex hook fixture tests passed."
