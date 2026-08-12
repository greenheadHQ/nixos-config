#!/usr/bin/env bash
# tests/test-codex-hook-fixtures.sh
# Codex 0.124+ stable hook 회귀 차단 fixture runner.
#
# 카테고리 (deterministic + live opt-in subsets):
#   1. stdin schema baseline 0.124       — fixtures/codex-hooks/stdin/{userpromptsubmit-codex-0.124,stop-codex-0.124,stop-no-last-message}.json
#   2. dispatcher ordering / failure recovery — runner 내부 mock subscript
#   3. noise-guard env 변형              — runner 내부 helper (4 env 조합)
#   4. sync-codex-config.py preservation — fixtures/codex-hooks/sync-preservation/*.toml
#   4b. inline shim command contract — template byte match + missing/delegation policy
#   5. programmatic env inheritance (live opt-in) — CODEX_HOOK_LIVE=1 / --live
#   5b. codex exec invocation matrix (live opt-in, must-pass-only) — issue #593 supervised wrapper 회귀 차단
#       (--live 시 invocation matrix를 programmatic env inheritance보다 먼저 실행)
#   5c. marker 기반 잔존 프로세스 검증 (live opt-in — issue #1228 1단계) + deterministic
#       negative control(탐지기 실효 검증)·supervised 해석 predicate 자체 테스트
#   7. pinning-alert behavioral          — fixtures/codex-hooks/stdin/pinning-{claude,codex}-*.json
#   7b. PreToolUse pinning-guard behavioral — hard-fail deny JSON + clean pass fixtures
#   7c. commit-msg pinning behavioral    — fixtures/codex-hooks/commit-msg/*.msg
# (카테고리 6 stop-notification reliability/security는 native push 도입으로 제거됨.)
#
# live 통과 판정 계약 (issue #1228): 필수 live 시나리오(invocation matrix / marker residual /
# env inheritance — REQUIRED_LIVE_SCENARIOS가 단일 선언) 전부가 검증·정리까지 완료된 경우에만
# aggregate sentinel `LIVE_REQUIRED_ALL_PASS` 1줄이 stdout에 출력되고 전체 통과 문구와 exit 0으로
# 종결된다. 하나라도 미완(환경 결함 WARN skip 포함)이면 전체 통과 문구 없이 exit 1로 종결된다 —
# 통과 판정은 exit 0 하나로 닫히며, sentinel은 성공 경로의 이중 확인 신호다.
#
# 검증 대상 wrapper 선택 (issue #1228): CODEX_HOOK_SUPERVISED_BIN=source|installed (default: source)
#   source     워크트리 소스(modules/shared/scripts/codex-exec-supervised.sh)를 실행하고 Nix wrapper
#              계층이 export하는 CODEX_EXEC_*_BIN을 설치본에서 추출해 주입한다 — nrs 전에도 워크트리
#              수정본을 검증한다 (종전 PATH-우선 해석은 구 설치본을 검증하는 허상이었다).
#   installed  PATH 설치본(~/.local/bin)을 env 주입 없이 실행한다 (post-nrs 실제 Nix 배선 검증).
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
               → marker residual → programmatic env inheritance (실행 순서대로).
               필수 시나리오가 하나라도 미완(WARN skip 포함)이면 exit 1로 종결된다.
               성공 시 stdout에 LIVE_REQUIRED_ALL_PASS sentinel 1줄 (이중 확인 신호)
  --no-live    deterministic 강제 (default와 동일; verify-ai-compat가 사용)
ENV: CODEX_HOOK_LIVE=1  (--live와 동등; CLI 인자가 env보다 우선하며 마지막 모드 인자가 이긴다)
     CODEX_HOOK_SUPERVISED_BIN=source|installed  (검증 대상 wrapper 선택; default source —
               워크트리 소스 + 설치본 추출 env 주입. installed는 post-nrs Nix 배선 검증용)
EOF
      exit 0
      ;;
  esac
done

# ─── tomlkit bootstrap ───
# sync-preservation 시나리오는 sync-codex-config.py를 통해 tomlkit을 요구한다. 직접 실행과
# lefthook 경로의 runtime 일관성을 위해 tests/run-shell-script-tests.sh와 동일하게
# scripts/ai/lib/tomlkit-bootstrap.sh를 source하여 repo-pinned pythonWithTomlkit으로 self-wrap한다.
# `_TOMLKIT_BOOTSTRAP_READY=1`이 이미 set이면 즉시 반환되므로 profile runner 안에서 중첩 nix shell이 발생하지 않는다.
# bootstrap이 exec로 프로세스를 교체할 수 있으므로 sandbox tracking 임시 파일은 그 이후에 생성한다.
# shellcheck disable=SC1091  # source file은 repo 내부 고정 경로
. "$REPO_ROOT/scripts/ai/lib/tomlkit-bootstrap.sh"
tomlkit_bootstrap_require "$REPO_ROOT" "${BASH_SOURCE[0]}" "$@"

TEST_TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-hook-fixtures-list.XXXXXX")"
# 필수 live 시나리오의 pass mark 수집 파일 — aggregate sentinel(LIVE_REQUIRED_ALL_PASS) 판정용.
# WARN skip 경로는 mark를 남기지 않는다 (헤더 "live 통과 판정 계약" 참조).
LIVE_PASS_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-hook-fixtures-live-pass.XXXXXX")"
# 필수 live 시나리오 ID의 단일 선언 — 각 시나리오의 _live_mark_passed 호출 리터럴과 함께
# 갱신한다 (집계 루프는 이 배열만 소비).
REQUIRED_LIVE_SCENARIOS=(invocation_matrix marker_residual env_inheritance)
# live가 기동한 장수명 프로세스(wrapper·marker helper)의 등록 파일 — Ctrl-C/CI 취소 등
# 중단 경로에서도 EXIT trap이 임시 디렉터리 삭제 전에 이 목록을 identity 확인 후 정리한다
# (디렉터리를 먼저 지우면 marker 경로 기반 재탐색이 불가능해진다). 라인 형식은
# `ps -o pid=,ppid=,pgid=,command=` 출력이며 정상 종료 시 이미 정리된 PID는 identity
# 불일치(부재)로 스킵되어 무해하다.
LIVE_PROC_REGISTRY="$(mktemp "${TMPDIR:-/tmp}/codex-hook-fixtures-procs.XXXXXX")"

_register_live_proc() {
  # $1=PID — 기동 직후 호출해 중단 경로 정리 대상으로 등록한다. 같은 PID를 argv가 안정된
  # 시점(예: wrapper exec 체인이 timeout에 도달한 뒤)에 다시 호출하면 라인이 추가 등록된다 —
  # 정리기는 라인 단위 identity 검사라 stale 라인은 불일치로 스킵되고 fresh 라인이 매치된다.
  ps -o pid=,ppid=,pgid=,command= -p "$1" >> "$LIVE_PROC_REGISTRY" 2>/dev/null || true
}

_register_live_proc_lines() {
  # $1=ps 라인들 — 이미 관측된 표본 라인(예: marker helper)을 그대로 등록한다.
  [[ -n "$1" ]] && printf '%s\n' "$1" >> "$LIVE_PROC_REGISTRY" || true
}

_copy_active_codex_auth() {
  # $1=대상 codex-home 디렉터리. 정본 경로는 활성 CODEX_HOME이다 — $HOME/.codex 고정은
  # 다중 계정 환경(부모가 custom CODEX_HOME 사용)에서 다른 계정의 인증으로 실행된다.
  local host_codex_home="${CODEX_HOME:-$HOME/.codex}"
  if [[ -f "$host_codex_home/auth.json" ]]; then
    cp "$host_codex_home/auth.json" "$1/auth.json"
  fi
}

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
HOOK_RUNTIME_LIB_REPO_FILE="$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh"
# verify-ai-compat의 _TEMPLATE 분기와 동일하게 host platform에 맞는 template을 sync-preservation
# 검증에 사용한다. Darwin은 platform별로 다른 managed leaves를 가질 수 있으므로
# platform-agnostic 검증만으로는 부족하다.
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
  # 프로세스 정리를 디렉터리 삭제보다 먼저 수행한다 (중단 경로에서 marker 경로 기반 재탐색이
  # 가능한 동안 identity 확인 정리 — _cleanup_pid_lines_with_children은 이 시점에 이미 정의됨).
  if [[ -s "$LIVE_PROC_REGISTRY" ]] && declare -f _cleanup_pid_lines_with_children >/dev/null; then
    _cleanup_pid_lines_with_children "$(cat "$LIVE_PROC_REGISTRY")" || true
  fi
  rm -f "$LIVE_PROC_REGISTRY"
  if [[ -f "$TEST_TMP_FILE" ]]; then
    while IFS= read -r dir; do
      [[ -n "$dir" ]] && rm -rf "$dir"
    done < "$TEST_TMP_FILE"
    rm -f "$TEST_TMP_FILE"
  fi
  rm -f "$LIVE_PASS_FILE"
  return 0
}
trap cleanup EXIT
# INT/TERM은 명시 exit로 변환해 EXIT trap(위 cleanup)의 발화를 보장한다 — 중단 경로에서도
# 장수명 프로세스(wrapper·marker helper)가 정리되게 한다.
trap 'exit 130' INT
trap 'exit 143' TERM

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
  cp -L "$HOOK_RUNTIME_LIB_REPO_FILE" "$sandbox/home/.codex/lib/"
  cp -L "$HOOK_RUNTIME_LIB_REPO_FILE" "$sandbox/home/.claude/lib/"

  # 공유 staged-snapshot 캐시(REPO_ROOT)가 read-only(chmod a-w)이면 cp -L 사본도
  # read-only 로 복제된다. sandbox 안에서는 mock 교체(install_mock_subscripts_with_log)
  # 등 쓰기가 필요하므로 사본 권한을 복구한다(공유 캐시 자체는 건드리지 않는다).
  chmod -R u+w "$sandbox"

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
# (이전에는 카테고리 6 stop-notification reliability/security 도 이 helper를 공유했으나,
# native push 대체로 hook과 카테고리 6이 함께 제거되었다.)
# 첫 인자는 sandbox, 두 번째는 추가 env_pairs_string("" 또는 "K=V K=V"), 이후는 실행 명령 + 인자들.
_exec_with_sandbox_env() {
  local sandbox="$1"; shift
  local env_pairs_string="$1"; shift
  local env_array=()
  if [[ -n "$env_pairs_string" ]]; then
    read -ra env_array <<<"$env_pairs_string"
  fi
  env -u CLAUDECODE -u CODEX_PROGRAMMATIC -u PINNING_PATTERNS_LIB -u HOOK_RUNTIME_LIB "${env_array[@]}" \
      PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" \
      HOME="$sandbox/home" \
      XDG_DATA_HOME="$sandbox/xdg-data" \
      XDG_CONFIG_HOME="$sandbox/xdg-config" \
      CODEX_HOME="$sandbox/codex-home" \
      "$@"
}

install_mock_subscripts_with_log() {
  # dispatcher가 호출하는 2 sub-script를 mock으로 교체.
  # $1=sandbox, $2=ordering log path, $3..=각 sub-script의 exit 코드.
  # 인자 순서는 dispatcher 호출 순서와 동일: record-last-stop, nrs-session-cleanup.
  local sandbox="$1" log="$2"
  local rls_rc="${3:-0}" nsc_rc="${4:-0}"

  cat > "$sandbox/home/.codex/hooks/record-last-stop.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo record-last-stop >> "$log"
exit $rls_rc
EOF
  cat > "$sandbox/home/.codex/hooks/nrs-session-cleanup.sh" <<EOF
#!/usr/bin/env bash
cat >/dev/null
echo nrs-session-cleanup >> "$log"
exit $nsc_rc
EOF
  chmod +x "$sandbox/home/.codex/hooks/"{record-last-stop,nrs-session-cleanup}.sh
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
  run_hook_in_sandbox "$sandbox" "record-last-stop.sh" \
    < "$FIXTURE_DIR/stdin/stop-no-last-message.json" \
    || fail "record-last-stop (last_assistant_message null) 비정상 종료"
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

  install_mock_subscripts_with_log "$sandbox" "$log" 0 0

  run_hook_in_sandbox "$sandbox" "_stop-dispatcher.sh" \
    < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
    || fail "_stop-dispatcher 정상 경로에서 비정상 종료"

  local actual expected
  actual=$(cat "$log")
  expected=$(expected_dispatcher_ordering)
  assert_eq "$actual" "$expected" "dispatcher sub-script ordering 어긋남"
}

test_dispatcher_recovers_from_subscript_failures() {
  # 시나리오 순서는 dispatcher 호출 순서(record-last-stop → nrs-session-cleanup)를 따른다.
  local scenarios=(
    "1 0:record-last-stop"
    "0 1:nrs-session-cleanup"
  )

  # expected ordering 은 baseline test와 동일 helper 사용.
  local expected
  expected=$(expected_dispatcher_ordering)

  local entry
  for entry in "${scenarios[@]}"; do
    local rc_pair="${entry%%:*}"
    local fail_target="${entry##*:}"
    # shellcheck disable=SC2086  # 의도된 word-splitting (rc_pair는 "0 1" 형태)
    set -- $rc_pair
    local rls_rc="$1" nsc_rc="$2"

    local sandbox log err
    sandbox=$(new_hook_sandbox)
    log="$sandbox/ordering.log"
    err="$sandbox/dispatcher.stderr"

    install_mock_subscripts_with_log "$sandbox" "$log" "$rls_rc" "$nsc_rc"

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
# record-prompt-submit / record-last-stop은 immediate exit 0 (가드 발동).
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

    # 2 가드 대상 hook (record-prompt-submit / record-last-stop)
    run_hook_in_sandbox_with_env "$sandbox" "$env_pairs" "record-prompt-submit.sh" \
      < "$FIXTURE_DIR/stdin/userpromptsubmit-codex-0.124.json" \
      || fail "record-prompt-submit (env='$env_pairs') 비정상 종료"
    run_hook_in_sandbox_with_env "$sandbox" "$env_pairs" "record-last-stop.sh" \
      < "$FIXTURE_DIR/stdin/stop-codex-0.124.json" \
      || fail "record-last-stop (env='$env_pairs') 비정상 종료"

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
    fail "tomlkit 미가용 — pre-commit/profile runner 또는 'nix shell .#pythonWithTomlkit' 환경에서 실행 필요"
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

# ─── 카테고리 4b: inline shim command contract ───
_codex_command_for_top_level_hook() {
  case "$1" in
    record-prompt-submit.sh) printf '%s' "$EXPECTED_USER_PROMPT_COMMAND" ;;
    _stop-dispatcher.sh) printf '%s' "$EXPECTED_STOP_DISPATCHER_COMMAND" ;;
    pinning-guard.sh) printf '%s' "$EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND" ;;
    pinning-alert.sh) printf '%s' "$EXPECTED_POST_TOOL_USE_PINNING_COMMAND" ;;
    *) fail "[4b] unknown top-level hook: $1" ;;
  esac
}

_codex_policy_for_top_level_hook() {
  case "$1" in
    record-prompt-submit.sh|_stop-dispatcher.sh|pinning-alert.sh) printf '%s' advisory ;;
    pinning-guard.sh) printf '%s' blocking ;;
    *) fail "[4b] unknown top-level hook: $1" ;;
  esac
}

_run_codex_shim_command() {
  # $1=sandbox, $2=command string, stdin inherited from caller.
  # This intentionally uses POSIX sh to pin the inline command to sh-compatible syntax.
  local sandbox="$1" command="$2"
  _exec_with_sandbox_env "$sandbox" "" sh -c "$command"
}

_install_shim_path_lookup_tripwires() {
  local sandbox="$1" name
  for name in printf '['; do
    cat > "$sandbox/bin-stubs/$name" <<'EOF'
#!/usr/bin/env sh
echo "unexpected PATH lookup from inline shim" >&2
exit 86
EOF
    chmod +x "$sandbox/bin-stubs/$name"
  done
}

test_template_hook_commands_match_builder() {
  local template check_script
  check_script='import sys, tomllib

template_path = sys.argv[1]
expected = {
    "UserPromptSubmit": sys.argv[2],
    "Stop": sys.argv[3],
    "PreToolUse": sys.argv[4],
    "PostToolUse": sys.argv[5],
}
direct_commands = {
    "UserPromptSubmit": "$HOME/.codex/hooks/record-prompt-submit.sh",
    "Stop": "$HOME/.codex/hooks/_stop-dispatcher.sh",
    "PreToolUse": "$HOME/.codex/hooks/pinning-guard.sh",
    "PostToolUse": "$HOME/.codex/hooks/pinning-alert.sh",
}

with open(template_path, "rb") as f:
    data = tomllib.load(f)

hooks = data.get("hooks", {})
for event, expected_command in expected.items():
    entries = hooks.get(event, [])
    assert isinstance(entries, list) and len(entries) == 1, f"{event}: entry count={len(entries)}"
    inner = entries[0].get("hooks", [])
    assert isinstance(inner, list) and len(inner) == 1, f"{event}: inner count={len(inner)}"
    command = inner[0].get("command", "")
    assert command == expected_command, f"{event}: command={command!r} expected={expected_command!r}"
    assert command != direct_commands[event], f"{event}: direct command regression"
'
  for template in \
    "$REPO_ROOT/modules/shared/programs/codex/files/config.toml" \
    "$REPO_ROOT/modules/shared/programs/codex/files/config.darwin.toml"; do
    if ! python3 -c "$check_script" "$template" \
      "$EXPECTED_USER_PROMPT_COMMAND" \
      "$EXPECTED_STOP_DISPATCHER_COMMAND" \
      "$EXPECTED_PRE_TOOL_USE_PINNING_GUARD_COMMAND" \
      "$EXPECTED_POST_TOOL_USE_PINNING_COMMAND"; then
      fail "[4b] template command drift: $template"
    fi
  done
}

_assert_advisory_shim_skip() {
  local hook="$1" stdout_log="$2" stderr_log="$3" context="$4"
  if [ -s "$stdout_log" ]; then
    fail "[4b/$context/$hook] advisory missing path must keep stdout empty, got: $(head -20 "$stdout_log")"
  fi
  local expected="$stderr_log.expected"
  {
    printf '%s\n' "[codex-hook] target missing or not executable: ~/.codex/hooks/$hook. Impact: hook skipped to avoid raw 127."
    printf '%s\n' "Action: run nrs --force, then ./scripts/ai/verify-ai-compat.sh."
  } > "$expected"
  if ! diff -u "$expected" "$stderr_log" >/dev/null 2>&1; then
    local diff_out
    diff_out=$(diff -u "$expected" "$stderr_log" 2>&1 | head -40 || true)
    fail "[4b/$context/$hook] advisory stderr drift:
$diff_out"
  fi
}

_assert_blocking_shim_deny() {
  local hook="$1" stdout_log="$2" stderr_log="$3" context="$4"
  local event decision reason expected_reason
  if [ -s "$stderr_log" ]; then
    fail "[4b/$context/$hook] blocking missing path must keep stderr empty, got: $(head -20 "$stderr_log")"
  fi
  event="$(jq -r '.hookSpecificOutput.hookEventName // empty' "$stdout_log" 2>/dev/null)" \
    || fail "[4b/$context/$hook] blocking stdout JSON parse failed"
  decision="$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$stdout_log" 2>/dev/null)" \
    || fail "[4b/$context/$hook] blocking stdout JSON parse failed"
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$stdout_log" 2>/dev/null)" \
    || fail "[4b/$context/$hook] blocking stdout JSON parse failed"
  expected_reason="Codex managed hook target is missing or not executable: ~/.codex/hooks/$hook. Impact: edit is denied until the hook is restored. Action: run nrs --force, then ./scripts/ai/verify-ai-compat.sh."
  assert_eq "$event" "PreToolUse" "[4b/$context/$hook] hook event mismatch"
  assert_eq "$decision" "deny" "[4b/$context/$hook] permission decision mismatch"
  assert_eq "$reason" "$expected_reason" "[4b/$context/$hook] permission reason mismatch"
}

test_inline_shim_target_missing_and_non_executable_policy() {
  local hook policy command sandbox target stdout_log stderr_log exit_code context
  for hook in record-prompt-submit.sh _stop-dispatcher.sh pinning-guard.sh pinning-alert.sh; do
    policy="$(_codex_policy_for_top_level_hook "$hook")"
    command="$(_codex_command_for_top_level_hook "$hook")"
    for context in missing non-executable; do
      sandbox=$(new_hook_sandbox)
      _install_shim_path_lookup_tripwires "$sandbox"
      target="$sandbox/home/.codex/hooks/$hook"
      stdout_log="$sandbox/shim-$context-stdout.log"
      stderr_log="$sandbox/shim-$context-stderr.log"
      case "$context" in
        missing)
          rm -f "$target"
          ;;
        non-executable)
          rm -f "$target"
          printf '%s\n' '#!/usr/bin/env sh' 'exit 99' > "$target"
          chmod 0644 "$target"
          ;;
        *) fail "[4b] unknown context: $context" ;;
      esac

      if _run_codex_shim_command "$sandbox" "$command" >"$stdout_log" 2>"$stderr_log"; then
        exit_code=0
      else
        exit_code=$?
      fi
      assert_eq "$exit_code" "0" "[4b/$context/$hook] shim must exit 0 without raw 127"

      case "$policy" in
        advisory) _assert_advisory_shim_skip "$hook" "$stdout_log" "$stderr_log" "$context" ;;
        blocking) _assert_blocking_shim_deny "$hook" "$stdout_log" "$stderr_log" "$context" ;;
        *) fail "[4b] unknown policy: $policy" ;;
      esac
    done
  done
}

test_inline_shim_delegates_existing_targets_transparently() {
  local hook command sandbox target stdout_log stderr_log exit_code
  for hook in record-prompt-submit.sh _stop-dispatcher.sh pinning-guard.sh pinning-alert.sh; do
    command="$(_codex_command_for_top_level_hook "$hook")"
    sandbox=$(new_hook_sandbox)
    _install_shim_path_lookup_tripwires "$sandbox"
    target="$sandbox/home/.codex/hooks/$hook"
    stdout_log="$sandbox/shim-delegate-stdout.log"
    stderr_log="$sandbox/shim-delegate-stderr.log"

    cat > "$target" <<EOF
#!/usr/bin/env sh
printf '%s\n' 'stdout:$hook'
printf '%s\n' 'stderr:$hook' >&2
exit 7
EOF
    chmod +x "$target"

    if _run_codex_shim_command "$sandbox" "$command" >"$stdout_log" 2>"$stderr_log"; then
      exit_code=0
    else
      exit_code=$?
    fi

    assert_eq "$exit_code" "7" "[4b/delegate/$hook] shim must preserve target exit code"
    assert_eq "$(cat "$stdout_log")" "stdout:$hook" "[4b/delegate/$hook] shim must preserve target stdout"
    assert_eq "$(cat "$stderr_log")" "stderr:$hook" "[4b/delegate/$hook] shim must preserve target stderr"
  done
}

# ─── 카테고리 7: pinning-alert behavioral ───
# Claude/Codex pinning-alert.sh(PostToolUse warn-only, #603/#605 도입)의 입력→출력 동작을
# deterministic stdin fixture로 박제한다. fixture는 stdin/pinning-{claude,codex}-*.json이고,
# 옆에 위치한 *.expected에 stderr 출력을 박는다. exit code는 모두 0(warn-only contract).
# Codex apply_patch envelope V4A awk parser의 핵심 분기(*** Move to: rename, multi-file
# attribution, removeonly added-line filter)를 함께 보호한다.
test_pinning_shared_library_behavioral() {
  local sandbox scan_file da_symlink_dir
  sandbox=$(new_hook_sandbox)
  scan_file="$sandbox/pinning-shared-scan.txt"
  {
    printf '%s\n' "Ro""und 1"
    printf '%s\n' "Correctness""-1"
    printf '%s\n' "DA ""for_plan"
  } > "$scan_file"
  mkdir -p \
    "$sandbox/.claude/prds" \
    "$sandbox/.claude/plans" \
    "$sandbox/docs/examples/.claude/prds"

  # shellcheck source=../modules/shared/programs/claude/files/lib/pinning-patterns.sh
  . "$PINNING_LIB_REPO_FILE"

  assert_eq "$(pinning_match_count "$scan_file")" "3" \
    "[7/lib] raw helper must keep PATTERN_A visible"
  assert_eq "$(pinning_match_count_for_path "$scan_file" "$sandbox/outside.md")" "3" \
    "[7/lib] outside path must keep PATTERN_A visible"
  assert_eq "$(PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/prds/prd.md")" "2" \
    "[7/lib] PRD path must skip only PATTERN_A"
  assert_eq "$(PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/docs/examples/.claude/prds/prd.md")" "3" \
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
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/plans/plan.md")" "2" \
    "[7/lib] PRD/plan path fallback must not require GNU realpath/readlink"
  assert_eq "$(if PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_should_check_path "$sandbox/.claude/plans/plan.yaml"; then printf check; else printf skip; fi)" "check" \
    "[7/lib] PRD/plan should_check fallback must not require durable extension"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}"; if pinning_should_check_path "/home/test/repo/scripts/ai/commit-msg-pinning.sh"; then printf check; else printf skip; fi)" "skip" \
    "[7/lib] should_check fallback must preserve self-exclude paths without GNU realpath/readlink"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}"; if pinning_should_check_path "/tmp/da-test-abc/scratch.md"; then printf check; else printf skip; fi)" "skip" \
    "[7/lib] should_check fallback must preserve DA scratch whitelist without GNU realpath/readlink"
  assert_eq "$(if pinning_should_check_path "/tmp/nix-shell.test/da-foo/bar.md"; then printf check; else printf skip; fi)" "skip" \
    "[7/lib] nested TMPDIR da-* scratch must hit whitelist (issue #852)"
  mkdir -p "$sandbox/.claude/plans"
  : > "$sandbox/.claude/plans/existing.md"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/plans/existing.md")" "2" \
    "[7/lib] PRD/plan path fallback must cover existing regular files"
  mkdir -p "$sandbox/.claude/prds"
  : > "$sandbox/outside.md"
  ln -s "$sandbox/outside.md" "$sandbox/.claude/prds/symlink.md"
  assert_eq "$(PATH="$sandbox/bin-stubs:${PATH:-/usr/bin:/bin}" PINNING_PROJECT_ROOT="$sandbox" pinning_match_count_for_path "$scan_file" "$sandbox/.claude/prds/symlink.md")" "3" \
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
    # 계약은 _exec_with_sandbox_env helper와 단일 source를 공유한다.
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
  da_sandbox=$(umask 077 && mktemp -d "/tmp/da-codex-hook-fixture.XXXXXX") \
    || fail "DA scratch mktemp -d 실패"
  printf '%s\n' "$da_sandbox" >> "$TEST_TMP_FILE"
  da_sandbox_sed="$(sed_replacement_escape "$da_sandbox")"
  local placeholders=(
    "__SANDBOX_EXISTING_PINNED_MD__"
    "__SANDBOX_EXISTING_PRD_MD__"
    "__SANDBOX_EXISTING_PLAN_MD__"
    "__SANDBOX_BODY_FILE__"
  )
  local paths=(
    "$sandbox/existing-pinned.md"
    "$sandbox/fixture-pinning/.claude/prds/existing.md"
    "$sandbox/fixture-pinning/.claude/plans/existing.md"
    "$sandbox/fixture-pinning/body-file.md"
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

  # Issue #759 — host HOOK_RUNTIME_LIB leak check.
  sandbox=$(new_hook_sandbox)
  stdout_log="$sandbox/pretooluse-hookruntime-leak-stdout.log"
  stderr_log="$sandbox/pretooluse-hookruntime-leak-stderr.log"
  if HOOK_RUNTIME_LIB="$sandbox/host-leaked-hook-runtime.sh" \
      _exec_with_sandbox_env "$sandbox" "" "$sandbox/home/.codex/hooks/pinning-guard.sh" \
        < "$clean_fixture" >"$stdout_log" 2>"$stderr_log"; then
    exit_code=0
  else
    exit_code=$?
  fi
  assert_eq "$exit_code" "0" "[7b/meta] host HOOK_RUNTIME_LIB leak check: hook must exit 0"
  if [ -s "$stderr_log" ]; then
    unexpected="$(head -40 "$stderr_log")"
    fail "[7b/meta] host HOOK_RUNTIME_LIB leak check: expected empty stderr, got:
$unexpected"
  fi
  if [ -s "$stdout_log" ]; then
    unexpected="$(head -40 "$stdout_log")"
    fail "[7b/meta] host HOOK_RUNTIME_LIB leak check: expected clean pass with empty stdout, got:
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
# commit-msg-pinning.sh도 guard/alert와 같은 shared pinning records helper를 소비한다.
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

# ─── supervised wrapper 해석 + marker 잔존 탐지기 (live fixture 공통 — issue #1228 1단계) ───

_supervised_source_has_setsid_assignment() {
  # 워크트리 소스에 setsid 실행 할당문이 존재하는가. 주석·역사 각주는 `#`로 시작해 매치되지
  # 않으므로 setsid 제거 커밋 후에는 predicate가 자동으로 꺼진다 (SETSID_BIN 주입도 중단 —
  # 제거 후 설치본에 export가 없는 것이 정상이므로 무조건 추출 fail로 걸면 fixture가 전부 죽는다).
  grep -q '^SETSID_BIN=' "$1"
}

_extract_installed_env_bin() {
  # $1=env 변수 이름. 설치본 Nix wrapper(writeShellScript)의 export 라인에서 store 절대경로 추출.
  local var="$1" installed
  installed="$(command -v codex-exec-supervised 2>/dev/null)" || return 1
  grep -o "${var}=\"[^\"]*\"" "$installed" 2>/dev/null | head -1 | cut -d'"' -f2
}

resolve_supervised() {
  # 검증 대상 wrapper 결정 (헤더 "검증 대상 wrapper 선택" 참조). 성공 시 전역
  # SUPERVISED_BIN(실행 경로)과 SUPERVISED_ENV(주입 env K=V 배열)를 설정한다.
  # 모드 결함·추출 실패는 fail — 조용한 skip은 검증 대상이 뒤바뀌는 허상을 만든다.
  local mode="${CODEX_HOOK_SUPERVISED_BIN:-source}"
  SUPERVISED_ENV=()
  case "$mode" in
    installed)
      SUPERVISED_BIN="$(command -v codex-exec-supervised 2>/dev/null)" \
        || fail "supervised 해석: installed 모드인데 PATH에 codex-exec-supervised 부재 (nrs 후 재시도)"
      ;;
    source)
      SUPERVISED_BIN="$REPO_ROOT/modules/shared/scripts/codex-exec-supervised.sh"
      [[ -x "$SUPERVISED_BIN" ]] || fail "supervised 해석: 워크트리 소스가 실행 불가: $SUPERVISED_BIN"
      local timeout_bin=""
      timeout_bin="$(_extract_installed_env_bin CODEX_EXEC_TIMEOUT_BIN)" || timeout_bin=""
      [[ -n "$timeout_bin" ]] \
        || fail "supervised 해석: 설치본에서 CODEX_EXEC_TIMEOUT_BIN 추출 실패 — source 모드는 설치본의 store 경로 추출이 필요하다 (nrs로 설치 후 재시도)"
      SUPERVISED_ENV+=("CODEX_EXEC_TIMEOUT_BIN=$timeout_bin")
      if _supervised_source_has_setsid_assignment "$SUPERVISED_BIN"; then
        local setsid_bin=""
        setsid_bin="$(_extract_installed_env_bin CODEX_EXEC_SETSID_BIN)" || setsid_bin=""
        [[ -n "$setsid_bin" ]] \
          || fail "supervised 해석: 소스가 setsid를 요구하는데 설치본에서 CODEX_EXEC_SETSID_BIN 추출 실패"
        SUPERVISED_ENV+=("CODEX_EXEC_SETSID_BIN=$setsid_bin")
      fi
      ;;
    *)
      fail "supervised 해석: CODEX_HOOK_SUPERVISED_BIN=$mode — source|installed만 허용"
      ;;
  esac
}

_live_mark_passed() {
  # 필수 live 시나리오가 검증·정리까지 완료했을 때만 호출한다 (WARN skip 경로 금지).
  printf '%s\n' "$1" >> "$LIVE_PASS_FILE"
}

_ps_lines_matching() {
  # argv에 $1 문자열을 포함한 프로세스 라인(pid ppid pgid command) 추출. grep 자신은 제외.
  # 종전 검증이 이 방식을 sandbox 경로에 적용했는데, 명령줄에 그 경로가 없는 프로세스는
  # 구조적으로 통과했다 — 지금은 고유 marker helper 경로(argv에 유지됨)에만 적용한다.
  ps -axo pid=,ppid=,pgid=,command= 2>/dev/null | grep -F -- "$1" | grep -Fv 'grep -F' || true
}

_direct_child_ps_lines() {
  # $1=부모 PID 목록(공백/개행 구분 — marker helper든 wrapper 그룹 구성원이든 임의 부모).
  # 그 PID를 PPID로 갖는 직계 자식 프로세스 라인을 추출한다 (1단계만, 재귀 아님).
  # 예: marker helper의 자식 sleep은 argv에 marker 경로가 없으므로 PPID로만 찾을 수 있다.
  local parent_pids="$1"
  [[ -n "$parent_pids" ]] || return 0
  ps -axo pid=,ppid=,pgid=,command= 2>/dev/null | awk -v pids="$parent_pids" '
    BEGIN { n = split(pids, a, /[[:space:]]+/); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    ($2 in want)' || true
}

_pid_has_ancestor_in_snapshot() {
  # $1=시작 PID, $2=조상 후보 PID, $3=ps 스냅샷 파일(pid ppid pgid command).
  # 스냅샷 기반 PPID 체인 추적 (최대 16단계) — 시작 PID가 조상 후보의 후손이면 rc 0.
  local cur="$1" target="$2" snap="$3" depth=0
  while [[ -n "$cur" && "$cur" != "0" && "$cur" != "1" ]] && (( depth < 16 )); do
    [[ "$cur" == "$target" ]] && return 0
    cur="$(awk -v p="$cur" '$1 == p { print $2; exit }' "$snap")"
    depth=$(( depth + 1 ))
  done
  [[ "$cur" == "$target" ]]
}

_ps_line_command() {
  # $1=ps 라인(pid ppid pgid command) — 앞 3개 숫자 필드를 제거해 command 원문을 보존 추출한다
  # (awk 필드 재조합은 연속 공백을 붕괴시켜 identity 비교가 깨진다).
  sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]+//' <<<"$1"
}

_pid_identity_matches() {
  # $1=pid, $2=수집 시점 command. 현재 그 PID의 argv가 수집 시점과 일치하는가 — kill 신호
  # 발사 직전의 PID 재사용 방어 (kill→sleep→kill 사이 원 프로세스가 죽고 PID가 재사용되면
  # 무관한 프로세스에 후속 KILL이 가는 표준 race). 프로세스 부재도 불일치(=발사 불필요)다.
  local pid="$1" expected_cmd="$2" current_cmd
  current_cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [[ -n "$current_cmd" && "$current_cmd" == "$expected_cmd" ]]
}

_cleanup_pid_lines_with_children() {
  # $1=ps 라인들(pid ppid pgid command — marker helper든 wrapper 그룹 구성원이든 임의 대상).
  # 각 대상과 그 직계 자식(1단계만 확장 — 재귀 아님)을 child-first(TERM→KILL)로 종료하고
  # 기록 PID 전부의 소멸을 확인한다 — 부모만 죽이면 자식(sleep 등)이 고아로 남아 이후
  # 관측을 오염시킨다. 각 신호는 수집 시점 argv와 현재 argv가 일치할 때만 발사한다
  # (PID 재사용 시 무관 프로세스 오살 방지 — 불일치=원 프로세스 소멸로 취급).
  # 반환: 소멸 확인까지 완료하면 0, 하나라도 잔존하면 1 — caller가 이 rc를 무시하면
  # 잔존 상태로 pass mark/sentinel이 발행될 수 있으므로, pass 경로의 caller는 반드시 확인한다.
  local lines="$1"
  [[ -n "$lines" ]] || return 0
  local parent_pids child_lines all_lines survivors=0 line pid cmd
  parent_pids="$(awk '{print $1}' <<<"$lines" | tr '\n' ' ')"
  child_lines="$(_direct_child_ps_lines "$parent_pids")"
  all_lines="$(printf '%s\n%s\n' "$child_lines" "$lines" | awk 'NF')"
  while IFS= read -r line; do
    pid="$(awk '{print $1}' <<<"$line")"
    cmd="$(_ps_line_command "$line")"
    _pid_identity_matches "$pid" "$cmd" && kill -TERM "$pid" 2>/dev/null || true
  done <<<"$all_lines"
  sleep 1
  while IFS= read -r line; do
    pid="$(awk '{print $1}' <<<"$line")"
    cmd="$(_ps_line_command "$line")"
    _pid_identity_matches "$pid" "$cmd" && kill -KILL "$pid" 2>/dev/null || true
  done <<<"$all_lines"
  sleep 1
  while IFS= read -r line; do
    pid="$(awk '{print $1}' <<<"$line")"
    cmd="$(_ps_line_command "$line")"
    if _pid_identity_matches "$pid" "$cmd"; then
      warn "process cleanup: PID $pid 소멸 확인 실패 — 수동 확인 필요"
      survivors=$(( survivors + 1 ))
    fi
  done <<<"$all_lines"
  [[ "$survivors" -eq 0 ]]
}

_collect_marker_and_direct_children_lines() {
  # $1=marker helper 경로. 현재 잔존하는 helper(argv 매칭) + 그 직계 자식(1단계만 확장 —
  # 재귀 아님; sleep은 helper의 직계 자식이므로 충분)의 ps 라인을 병합해 출력한다 —
  # 종료 이후의 모든 경로(fail 포함)에서 정리 대상 수집에 쓴다.
  local marker_path="$1" lingering helper_pids child_lines
  lingering="$(_ps_lines_matching "$marker_path")"
  helper_pids="$(awk '{print $1}' <<<"$lingering" | tr '\n' ' ')"
  child_lines="$(_direct_child_ps_lines "$helper_pids")"
  printf '%s\n%s\n' "$lingering" "$child_lines" | awk 'NF'
}

_marker_fail() {
  # $1=marker helper 경로, 나머지=fail 메시지. 실패 보고 전에 marker와 직계 자식을 best-effort
  # 정리한다 (fail 직전 정리이므로 rc 무시 — 잔존 시 warn이 수동 확인을 안내한다). 실패·무효
  # 분기가 정리를 각자 반복하다 누락되는 것을 막는 단일 계약이다. 성공 경로의 strict 정리
  # (rc 확인 후 sentinel mark)는 known leak 분기가 별도로 수행한다.
  local marker_path="$1"; shift
  _cleanup_pid_lines_with_children "$(_collect_marker_and_direct_children_lines "$marker_path")" || true
  fail "$@"
}

_negative_control_abort() {
  # $1=helper PID, $2=fail 메시지. negative control 실패 분기의 공통 정리 — helper만 죽이면
  # exec 없이 실행된 자식 sleep이 고아로 남으므로, helper PID로 라인을 구성해 직계 자식까지
  # 함께 정리한 뒤 실패를 보고한다. 탐지기(_ps_lines_matching) 자체를 검증하는 테스트이므로
  # 탐지기 출력에 의존하지 않고 PID로 직접 수집한다.
  local helper_pid="$1" msg="$2" helper_line
  helper_line="$(ps -o pid=,ppid=,pgid=,command= -p "$helper_pid" 2>/dev/null || true)"
  _cleanup_pid_lines_with_children "$helper_line" || true
  fail "$msg"
}

# ─── 카테고리 5: programmatic env inheritance live (opt-in) ───
# programmatic codex exec 호출자가 CODEX_PROGRAMMATIC=1을 codex 프로세스에 붙이면,
# UserPromptSubmit hook subprocess까지 해당 marker가 상속되는지 검증한다. managed hook
# early-exit 자체는 deterministic noise-guard fixture(카테고리 3)가 검증한다.
# 환경 결함(codex 부재, capability-probe 실패, session 실패)이면 WARN skip — 단 wrapper
# 해석(source/installed 모드·설치본 추출)은 resolve_supervised가 fail-closed로 처리한다
# (skip이 아니라 fail; 검증 대상이 뒤바뀌는 허상 방지).
test_programmatic_env_inheritance_live() {
  if ! command -v codex >/dev/null 2>&1; then
    warn "programmatic env inheritance live: codex 바이너리 부재 — skip"
    return 0
  fi

  # 검증 대상 wrapper 해석 — CODEX_HOOK_SUPERVISED_BIN=source|installed (헤더 참조).
  resolve_supervised

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

  # sandbox CODEX_HOME은 host auth를 상속하지 않아 API 호출이 401로 죽는다 (2026-08-12 실측 —
  # hook 발화 여부와 무관한 구조적 결함). host auth.json이 있으면 복사해 정상 완주를 허용한다.
  # 부재 시 복사 없이 진행 — dump_log 검증은 가능하나 codex 후속이 비정상이면 sentinel mark가
  # 남지 않는다 (원인 해소 요구 신호).
  _copy_active_codex_auth "$sandbox/codex-home"

  # 본 fixture의 검증 의도는 "programmatic 호출자가 codex 프로세스에 붙인 CODEX_PROGRAMMATIC=1이
  # hook subprocess까지 상속되는지"이다. CLAUDECODE는 부모에서 제거해 이 fixture가 Claude nesting
  # marker에 의존하지 않음을 보인다.
  #
  # dump-env hook 등록은 sandbox CODEX_HOME/config.toml에 있으므로 --ignore-user-config를 쓰지 않는다.
  # 쓰면 sandbox config 자체가 무시되어 hook이 발화하지 않는다. stdin은 wrapper 책임이 아니므로
  # pipe + '-'로 EOF를 명시해 inherited-stdin hang shape를 차단한다.
  #
  # --dangerously-bypass-hook-trust: codex 0.129.0부터 hooks는 persisted hook trust가 없으면
  # 조용히 발화하지 않는다 (upstream 도입: openai/codex#21615; 0.147.0에서 2026-08-12 mac 재관측 —
  # 미발화가 에러 없이 정상 종료로 보인다). 본 fixture는
  # hook source를 자신이 작성하므로 upstream이 명시한 "automation that already vets hook sources"
  # 용례에 해당한다.
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
       ${SUPERVISED_ENV[@]+"${SUPERVISED_ENV[@]}"} \
       "$SUPERVISED_BIN" \
         --ephemeral --skip-git-repo-check --sandbox read-only --ignore-rules \
         --dangerously-bypass-hook-trust \
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
      # inheritance 검증 자체는 통과했으나 codex 후속 비정상 — sentinel 판정에는 포함하지
      # 않는다 (원인 해소 전까지 필수 시나리오 미완 취급).
      warn "programmatic env inheritance live: hook inheritance 도달 확인 + codex exec 후속 비정상(rc=$codex_rc) — inheritance 통과"
      return 0
    fi
    _live_mark_passed env_inheritance
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
# 환경 결함 (codex 부재) 시만 WARN skip (capability-probe 정책).
# preflight 통과 후 timeout/no-result는 fail (must-pass-only 계약).
# 잔존 프로세스 검증은 카테고리 5c(marker residual)가 담당한다 — 종전 scenario-2의
# sandbox 경로 문자열 매칭 검증은 명령줄에 그 경로가 없는 프로세스를 구조적으로 통과시키고,
# Reply PONG 프롬프트는 shell 자식을 만들지 않아 검증 표면 자체가 없는 허상이었다 (#1228).
test_codex_exec_invocation_live_matrix() {
  # preflight: codex 가용성 (wrapper가 자체 capability-probe하므로 timeout/setsid 별도 검사 불필요).
  if ! command -v codex >/dev/null 2>&1; then
    warn "invocation matrix: codex 바이너리 부재 — skip (환경 결함)"
    return 0
  fi

  # 검증 대상 wrapper 해석 — CODEX_HOOK_SUPERVISED_BIN=source|installed (헤더 참조).
  resolve_supervised

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
    ${SUPERVISED_ENV[@]+"${SUPERVISED_ENV[@]}"} \
    "$SUPERVISED_BIN" \
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
  # --dangerously-bypass-hook-trust: codex 0.129.0부터 hooks는 persisted hook trust가 없으면
  # 조용히 발화하지 않는다 (upstream 도입: openai/codex#21615; 0.147.0에서 2026-08-12 mac 재관측).
  # 본 fixture는 hook source를 자신이 작성하므로 upstream이 명시한
  # "automation that already vets hook sources" 용례에 해당한다.
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
  # trust 우회 반경 격리: --dangerously-bypass-hook-trust는 로드된 모든 hook에 적용되므로,
  # host CODEX_HOME(user hook)과 repo cwd(project .codex/config.toml)를 그대로 두면 fixture
  # 자작 hook 밖의 미검증 hook까지 우회 반경에 들어간다. sandbox CODEX_HOME(+auth 복사) +
  # sandbox cwd로 로드 가능한 hook을 inline override 하나로 좁힌다 — 이 조건에서만
  # "automation that already vets hook sources" 전제가 실제로 성립한다.
  mkdir -p "$sandbox/scenario2-codex-home"
  _copy_active_codex_auth "$sandbox/scenario2-codex-home"
  ( cd "$sandbox" && printf 'Reply PONG\n' | env -u CLAUDECODE \
    CODEX_PROGRAMMATIC=1 \
    CODEX_EXEC_TIMEOUT_SECONDS="$INVOCATION_MATRIX_TIMEOUT_SECONDS" \
    CODEX_EXEC_KILL_AFTER_SECONDS="$CODEX_EXEC_KILL_AFTER_SECONDS" \
    CODEX_HOME="$sandbox/scenario2-codex-home" \
    ${SUPERVISED_ENV[@]+"${SUPERVISED_ENV[@]}"} \
    "$SUPERVISED_BIN" \
      --ephemeral --skip-git-repo-check --sandbox read-only --ignore-user-config --ignore-rules \
      --dangerously-bypass-hook-trust \
      -c model="gpt-5.5" -c model_reasoning_effort="medium" \
      -c "hooks.UserPromptSubmit=$override" \
      -c "hooks.Stop=$override" \
      -o "$result2" \
      - >/dev/null 2>"$stderr2" ) || rc2=$?

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

      # 잔존 프로세스 검증은 여기서 하지 않는다 — 종전 sandbox 경로 문자열 매칭은 검증 표면이
      # 없는 허상이었다 (함수 헤더 참조). marker 기반 잔존 검증은 카테고리 5c가 수행한다.
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

  _live_mark_passed invocation_matrix
}

# ─── 카테고리 5c: marker 기반 잔존 프로세스 검증 (live opt-in — issue #1228 1단계) ───
# codex에게 고유 marker helper(sleep 150을 exec 없이 실행 — helper 프로세스의 argv에 고유
# 경로가 유지된다; exec sleep이면 argv가 sleep으로 교체되어 식별자가 사라진다)를 shell 도구로
# 실행시키고,
#   ① 실행 중 process tree 표본화(1초 간격 ps)로 wrapper 후손의 PID·PPID·PGID를 기록하고
#   ② supervisor 종료 후 잔존을 확인한다.
# positive control (시나리오 유효 조건 — 전부 충족해야 판정에 사용):
#   - marker helper가 실행 중 표본에서 실제 관측되고, PPID 체인이 wrapper(timeout PID)에 닿는다
#     (= wrapper 후손 — codex가 명령을 실제 실행했다는 직접 증거)
#   - codex 프로세스가 timeout 소유 PGID의 구성원으로 관측된다 (그룹 잔존 판정의 표면 존재 증거)
#   주: issue #1228 문면의 원 가정("marker가 timeout 소유 PGID에 속했음을 확인")은 codex
#   0.147.0 실측(2026-08-12)에서 구조적으로 성립 불가 — codex는 shell 도구 자식을 항상 자체
#   process group으로 분리한다 (known-issues.md §15 실증 갱신 ④가 조건부가 아닌 기본 동작).
#   따라서 in-group 표면은 codex 프로세스 자신이고, marker는 후손 도달·leak 관측 표면이다.
# 판정 분리: (a) wrapper 소유 그룹(timeout이 만든 그룹)의 잔존 = fail — PGID 전수 검사,
#            (b) codex가 자체 그룹으로 분리한 세션 이탈 자식(marker subtree)의 잔존 = known
#            leak으로 기록·정리만 (fail 아님 — §15 실증 갱신 ④의 원리적 커버 불가 축).
test_codex_exec_marker_residual_live() {
  if ! command -v codex >/dev/null 2>&1; then
    warn "marker residual: codex 바이너리 부재 — skip (환경 결함)"
    return 0
  fi
  resolve_supervised

  local sandbox
  sandbox=$(new_hook_sandbox)

  local marker_helper
  marker_helper="$(mktemp "$sandbox/marker-XXXXXX.sh")"
  printf '#!/usr/bin/env bash\nsleep %s\n' "$MARKER_HELPER_SLEEP_SECONDS" > "$marker_helper"
  chmod +x "$marker_helper"

  local result="$sandbox/marker-result.md"
  local stderr_log="$sandbox/marker.stderr"

  # 프롬프트는 stdin pipe로 전달한다 — argv 전달이면 ps command에 marker 경로가 미리 노출되어
  # 도구 도달을 오판한다.
  # sandbox cwd + 격리 CODEX_HOME(+활성 auth 복사): repo cwd로 실행하면 검토 브랜치의 AGENTS.md가
  # 모델 지시로 로드된다 — 브랜치 제어 지시가 추가 shell 명령을 유도할 수 있는 표면을 scenario-2와
  # 동일한 격리로 차단한다.
  mkdir -p "$sandbox/marker-codex-home"
  _copy_active_codex_auth "$sandbox/marker-codex-home"
  local wrapper_pid rc=0
  ( cd "$sandbox" && printf 'Use the shell tool to run exactly this command now, then wait for it to finish: bash %s\n' "$marker_helper" \
    | env -u CLAUDECODE \
      CODEX_PROGRAMMATIC=1 \
      CODEX_EXEC_TIMEOUT_SECONDS="$MARKER_RESIDUAL_TIMEOUT_SECONDS" \
      CODEX_EXEC_KILL_AFTER_SECONDS="$CODEX_EXEC_KILL_AFTER_SECONDS" \
      CODEX_HOME="$sandbox/marker-codex-home" \
      ${SUPERVISED_ENV[@]+"${SUPERVISED_ENV[@]}"} \
      "$SUPERVISED_BIN" \
        --ephemeral --skip-git-repo-check --sandbox read-only --ignore-user-config --ignore-rules \
        -c model="gpt-5.5" -c model_reasoning_effort="medium" \
        -o "$result" \
        - >/dev/null 2>"$stderr_log" ) &
  wrapper_pid=$!
  _register_live_proc "$wrapper_pid"

  # 실행 중 표본화: wrapper 소유 그룹(timeout이 만든 그룹)을 식별하고, 전체 ps 스냅샷에서
  #   - codex가 timeout 그룹 구성원으로 존재하는지 (그룹 잔존 판정 표면)
  #   - marker helper가 wrapper 후손(PPID 체인)으로 관측되는지 (도구 도달 직접 증거)
  # 를 축적한다.
  # timeout 식별: wrapper는 exec 체인(env→bash→setsid→timeout)이라 background PID($!)가 그대로
  # timeout PID가 된다 (setsid는 비-그룹-리더 호출자에서 fork 없이 in-place exec; fork 경로
  # 방어로 wrapper_pid의 직계 자식도 후보에 넣는다). GNU timeout은 비-foreground 모드에서
  # setpgid로 자기 자신을 그룹 리더로 만들므로 PGID==PID인 표본만 채택한다 — setpgid 전의
  # 짧은 창을 잡으면 fixture 셸 그룹이 wrapper 소유 그룹으로 오인되는 오탐이 실측됐다.
  local deadline=$(( MARKER_RESIDUAL_TIMEOUT_SECONDS + CODEX_EXEC_KILL_AFTER_SECONDS + MARKER_DEADLINE_GRACE_SECONDS ))
  local timeout_pid="" timeout_pgid=""
  local observed_marker=0 observed_descendant=0 observed_group_member=0
  local full_snapshot="$sandbox/marker-full.snapshot"
  local mid_snapshot="$sandbox/marker-mid.snapshot"
  : > "$mid_snapshot"
  local elapsed=0
  while (( elapsed < deadline )); do
    kill -0 "$wrapper_pid" 2>/dev/null || break
    ps -axo pid=,ppid=,pgid=,command= 2>/dev/null > "$full_snapshot" || true
    if [[ -z "$timeout_pid" ]]; then
      local timeout_line
      timeout_line="$(awk -v p="$wrapper_pid" \
        '($1 == p || $2 == p) && $1 == $3 && /--kill-after=/' "$full_snapshot" | head -1 || true)"
      if [[ -n "$timeout_line" ]]; then
        timeout_pid="$(awk '{print $1}' <<<"$timeout_line")"
        timeout_pgid="$(awk '{print $3}' <<<"$timeout_line")"
        # 기동 직후 등록된 wrapper 라인은 exec 체인(env→bash→setsid→timeout)의 중간 argv라
        # 중단 시 identity 불일치로 스킵될 수 있다 — argv가 안정된 timeout 시점에 재등록한다.
        _register_live_proc "$timeout_pid"
      fi
    fi
    if [[ -n "$timeout_pgid" ]]; then
      # timeout 그룹 구성원(timeout 자신 제외 — codex 등) 관측 = 그룹 잔존 판정의 표면 존재.
      if awk -v pg="$timeout_pgid" -v tp="$timeout_pid" '$3 == pg && $1 != tp { found = 1 } END { exit !found }' "$full_snapshot"; then
        observed_group_member=1
      fi
    fi
    local marker_lines
    marker_lines="$(grep -F -- "$marker_helper" "$full_snapshot" | grep -Fv 'grep -F' || true)"
    if [[ -n "$marker_lines" ]]; then
      if (( ! observed_marker )); then
        # 최초 관측 시점에 helper를 중단 경로 정리 대상으로 등록한다 — marker subtree는
        # 자체 PGID로 이탈하므로(§15 ④) wrapper 등록만으로는 Ctrl-C/CI 취소 시 잔존한다.
        _register_live_proc_lines "$marker_lines"
      fi
      observed_marker=1
      printf '%s\n' "$marker_lines" >> "$mid_snapshot"
      if [[ -n "$timeout_pid" ]]; then
        local marker_pid
        marker_pid="$(head -1 <<<"$marker_lines" | awk '{print $1}')"
        if _pid_has_ancestor_in_snapshot "$marker_pid" "$timeout_pid" "$full_snapshot"; then
          observed_descendant=1
        fi
      fi
    fi
    sleep 1
    elapsed=$(( elapsed + 1 ))
  done
  # deadline 내 wrapper 미종료 = supervisor 종료 보장 회귀. 그대로 wait하면 fixture 자체가
  # 무기한 hang하므로(검증 대상 결함이 검증기를 잠근다), 정리 후 즉시 fail한다.
  if kill -0 "$wrapper_pid" 2>/dev/null; then
    local wrapper_line
    wrapper_line="$(ps -o pid=,ppid=,pgid=,command= -p "$wrapper_pid" 2>/dev/null || true)"
    _cleanup_pid_lines_with_children "$wrapper_line" || true
    _marker_fail "$marker_helper" "marker residual: supervisor가 deadline(${deadline}s) 내 미종료 — 종료 보장 회귀 (wrapper pid=$wrapper_pid)"
  fi
  wait "$wrapper_pid" 2>/dev/null || rc=$?

  if (( rc == 127 )); then
    warn "marker residual: supervisor BLOCKED (capability-probe 실패) — skip"
    _cleanup_pid_lines_with_children "$(_collect_marker_and_direct_children_lines "$marker_helper")" || true
    return 0
  fi

  # positive control — 관측 실패는 검증 표면이 없는 것이므로 무효 fail (must-pass 계약).
  # 모든 실패 분기는 _marker_fail이 subtree 정리 후 실패를 보고한다 (정리 누락 방지 단일 계약).
  local stderr_tail
  stderr_tail=$(tail -c 400 "$stderr_log" 2>/dev/null | tr '\n' ' ' || true)
  if (( ! observed_marker )); then
    _marker_fail "$marker_helper" "marker residual: marker helper가 실행 중 표본에서 관측되지 않음 — codex가 shell 도구로 명령을 실행하지 않았거나 timeout budget(${MARKER_RESIDUAL_TIMEOUT_SECONDS}s) 내 미도달 (rc=$rc). stderr_tail: ${stderr_tail:-<empty>}"
  fi
  if (( ! observed_descendant )); then
    _marker_fail "$marker_helper" "marker residual: marker가 wrapper(timeout pid=${timeout_pid:-<미식별>})의 후손으로 확인되지 않음 — 다른 출처의 동명 프로세스이거나 표본화 결함 (무효). 관측 표본 tail: $(tail -3 "$mid_snapshot" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  if (( ! observed_group_member )); then
    _marker_fail "$marker_helper" "marker residual: timeout 소유 PGID(${timeout_pgid:-<미식별>})의 구성원(codex)이 관측되지 않음 — 그룹 잔존 판정의 표면이 없다 (무효). 관측 표본 tail: $(tail -3 "$mid_snapshot" 2>/dev/null | tr '\n' ' ' || true)"
  fi
  case "$rc" in
    0|124|137) : ;;  # 0=codex 자체 정리 후 응답, 124/137=supervisor 정리 — 모두 판정 가능 상태.
    *)
      _marker_fail "$marker_helper" "marker residual: 비정상 exit($rc). stderr_tail: ${stderr_tail:-<empty>}"
      ;;
  esac

  # 종료 후 잔존 판정.
  sleep 1  # SIGKILL grace 후 OS reaper에 시간 부여
  # (a) wrapper 소유 그룹 잔존 — marker 매칭이 아니라 PGID 전수 검사 (codex 등 그룹 구성원이
  #     TERM/KILL을 피해 남으면 marker와 무관하게 회귀다). fail 전에 검출된 그룹 잔존과
  #     marker subtree를 함께 정리한다 — marker subtree만 정리하면 정작 검출한 codex/timeout
  #     프로세스가 호스트에 남는다.
  local group_lingering
  group_lingering="$(ps -axo pid=,ppid=,pgid=,command= 2>/dev/null | awk -v pg="$timeout_pgid" '$3 == pg' || true)"
  if [[ -n "$group_lingering" ]]; then
    _cleanup_pid_lines_with_children "$group_lingering" || true
    _marker_fail "$marker_helper" "marker residual: wrapper 소유 그룹(pgid=$timeout_pgid) 잔존 — process group kill 회귀:
$group_lingering"
  fi
  # (b) 세션 이탈 marker subtree 잔존 — known leak (codex 0.147.0에서 재관측: shell 자식을
  #     자체 그룹으로 분리한다; §15 실증 갱신 ④). 기록 후 child-first 정리, fail 아님.
  #     단 정리 자체가 실패하면(잔존 소멸 미확인) sentinel 계약("검증·정리까지 완료")에 따라
  #     pass mark를 남기지 않고 fail한다.
  local leak_lines
  leak_lines="$(_collect_marker_and_direct_children_lines "$marker_helper")"
  if [[ -n "$leak_lines" ]]; then
    local leak_count
    leak_count="$(awk 'NF' <<<"$leak_lines" | wc -l | tr -d ' ')"
    warn "marker residual: 세션 이탈 잔존 ${leak_count}개 — known leak (known-issues §15 실증 갱신 ④, fail 아님) 기록 후 정리"
    _cleanup_pid_lines_with_children "$leak_lines" \
      || fail "marker residual: known leak 정리 실패 (잔존 PID 소멸 미확인) — 정리 완료 전에는 sentinel을 발행하지 않는다"
  fi

  _live_mark_passed marker_residual
}

# ─── 카테고리 5c-det: supervised 해석 predicate 자체 테스트 (deterministic) ───
# predicate(^SETSID_BIN= 실행 할당문 매칭)의 켜짐/꺼짐 양쪽을 검증한다 — setsid 제거 커밋 후
# 자동으로 꺼져 SETSID_BIN 주입이 중단되는 성질의 회귀 차단. 현재 워크트리 소스의 상태 자체는
# assert하지 않는다 (소스 상태에 결합되면 제거 커밋이 fixture를 죽인다).
test_supervised_setsid_predicate_self() {
  local sandbox
  sandbox=$(new_hook_sandbox)
  printf 'SETSID_BIN="${CODEX_EXEC_SETSID_BIN:-}"\n' > "$sandbox/with-setsid.sh"
  printf '# 역사 각주: SETSID_BIN=... 은 과거 계약\nTIMEOUT_BIN=x\n' > "$sandbox/without-setsid.sh"
  _supervised_source_has_setsid_assignment "$sandbox/with-setsid.sh" \
    || fail "setsid predicate: 실행 할당문이 있는 소스에서 켜져야 함"
  if _supervised_source_has_setsid_assignment "$sandbox/without-setsid.sh"; then
    fail "setsid predicate: 주석/각주뿐인 소스에서 꺼져야 함"
  fi
}

# ─── 카테고리 5c-det: marker 잔존 탐지기 negative control (deterministic) ───
# 의도적으로 process group을 이탈한 marker 자식을 합성으로 만들어, 탐지기가 그 잔존을 실제로
# 관측·out-of-group 분류하는지 확인한다 (탐지기 자체의 실효 검증 — codex 불필요).
# macOS에는 setsid(1)가 없으므로 `set -m`(job control) background job의 자체 process group으로
# 그룹 이탈을 재현한다.
test_marker_residual_detector_negative_control() {
  local sandbox
  sandbox=$(new_hook_sandbox)
  local marker_helper
  marker_helper="$(mktemp "$sandbox/marker-neg-XXXXXX.sh")"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$marker_helper"
  chmod +x "$marker_helper"

  local helper_pid
  # 경로는 bash -c 코드 문자열에 보간하지 않고 위치 인자로 전달한다 — TMPDIR 파생 경로에
  # 따옴표/셸 구문이 섞이면 보간이 인용 종료로 이어진다.
  helper_pid="$(bash -c 'set -m; bash "$1" >/dev/null 2>&1 & printf "%s" "$!"' _ "$marker_helper")"
  if [[ -z "$helper_pid" ]]; then
    fail "negative control: 합성 marker helper 기동 실패"
  fi
  _register_live_proc "$helper_pid"

  sleep 1
  local observed
  observed="$(_ps_lines_matching "$marker_helper")"
  if [[ -z "$observed" ]]; then
    _negative_control_abort "$helper_pid" "negative control: 탐지기가 실행 중 marker를 관측하지 못함 — 탐지기 회귀"
  fi

  # 현재 테스트 프로세스의 PGID를 wrapper 소유 그룹의 대역으로 두면, set -m으로 분리된
  # helper는 out-of-group으로 분류되어야 한다. ($$는 subshell에서도 최상위 PID를 주므로
  # $BASHPID 우선 — 병렬 harness의 subshell 실행에서도 성립한다. fork는 PGID를 보존한다.
  # $BASHPID는 bash 4.0+ 전용이라 macOS 기본 3.2에서는 $$로 폴백한다 — 3.2에서는
  # parallel-harness가 순차 실행을 강제하므로 $$가 곧 현재 실행 셸이다.)
  local self_pgid
  self_pgid="$(ps -o pgid= -p "${BASHPID:-$$}" | tr -d ' ')"
  if [[ -z "$self_pgid" ]]; then
    _negative_control_abort "$helper_pid" "negative control: 자기 PGID 조회 실패"
  fi
  local out_group
  out_group="$(awk -v pg="$self_pgid" '$3 != pg' <<<"$observed")"
  if [[ -z "$out_group" ]]; then
    _negative_control_abort "$helper_pid" "negative control: 그룹 이탈 marker가 out-of-group으로 분류되지 않음 — 분류기 회귀"
  fi

  # 정리 실효 검증까지: helper + 자식 sleep subtree를 정리하고 소멸을 확인한다.
  # cleanup rc(잔존 소멸 미확인=1)와 helper 생존 재확인 둘 다 정리기 회귀로 판정한다.
  if ! _cleanup_pid_lines_with_children "$observed"; then
    _negative_control_abort "$helper_pid" "negative control: cleanup이 잔존 소멸을 확인하지 못함 — 정리기 회귀"
  fi
  if kill -0 "$helper_pid" 2>/dev/null; then
    _negative_control_abort "$helper_pid" "negative control: cleanup 후에도 helper($helper_pid) 잔존 — 정리기 회귀"
  fi
}

# ─── 실행 진입점 ───
# run_test 를 job-pool 병렬 실행으로 제공하는 공유 하네스로 교체한다 (각 테스트는 독립
# new_hook_sandbox 라 병렬 격리 성립). 모든 run_test 등록 후 아래 parallel_barrier 로 수집한다.
# TEST_JOBS=1 이면 순차 폴백. harness 의 run_test 는 $1 을 라벨로 받아 시그니처가 동일하다.
# --live 모드의 세 live fixture(invocation matrix → marker residual → programmatic env
# inheritance)는 순서 계약이 있으므로(#647/#593: issue #593 wrapper/process-group 회귀 신호를
# 먼저 확보한 뒤 잔존 검증 표면과 hook 상속을 본다) 병렬화하지 않고 순차로 강제한다. deterministic(--no-live; lefthook pre-commit + required CI 경로)만 job-pool
# 병렬로 실행한다. LIVE_MODE 판정은 위 CLI 파싱에서 이미 끝났다.
# shellcheck disable=SC2034  # TEST_JOBS 는 바로 아래 source 하는 parallel-harness.sh 가 읽는다.
[ "$LIVE_MODE" = "1" ] && TEST_JOBS=1
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/parallel-harness.sh"

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
run_test "template hook commands match inline shim builder" \
  test_template_hook_commands_match_builder
run_test "inline shim target missing/non-executable policy" \
  test_inline_shim_target_missing_and_non_executable_policy
run_test "inline shim delegates existing targets transparently" \
  test_inline_shim_delegates_existing_targets_transparently

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
run_test "supervised setsid predicate self-test (#1228)" \
  test_supervised_setsid_predicate_self
run_test "marker residual detector negative control (#1228)" \
  test_marker_residual_detector_negative_control

if [[ "$LIVE_MODE" == "1" ]]; then
  # invocation matrix를 먼저 실행한다 (issue #593): wrapper/process-group 회귀 차단 신호를
  # 먼저 확보한 뒤, marker residual(잔존 검증 표면)과 env inheritance를 순서대로 실행한다.
  run_test "codex exec invocation matrix (supervised wrapper, must-pass-only)" \
    test_codex_exec_invocation_live_matrix
  run_test "codex exec marker residual (wrapper 후손 잔존 검증, #1228)" \
    test_codex_exec_marker_residual_live
  run_test "programmatic env inheritance live (codex exec --ephemeral)" \
    test_programmatic_env_inheritance_live
else
  echo "==> codex exec invocation matrix  (skip; --live 또는 CODEX_HOOK_LIVE=1로 활성화)"
  echo "==> codex exec marker residual  (skip; --live 또는 CODEX_HOOK_LIVE=1로 활성화)"
  echo "==> programmatic env inheritance live  (skip; --live 또는 CODEX_HOOK_LIVE=1로 활성화)"
fi

# 병렬 큐잉된 모든 run_test 를 대기·집계한다(TEST_JOBS=1 순차면 no-op). 실패가 하나라도 있으면
# non-zero 로 종료해 아래 성공 메시지 출력과 pre-commit/required CI 통과를 막는다.
parallel_barrier

# aggregate sentinel (issue #1228) — 필수 live 시나리오 전부가 검증·정리까지 완료(=WARN skip
# 없이 pass)된 경우에만 출력한다. 위 parallel_barrier/순차 실행에서 실패가 있으면 여기 도달
# 전에 종료되므로, sentinel은 "exit 0 + 전 시나리오 pass mark"에서만 나온다.
if [[ "$LIVE_MODE" == "1" ]]; then
  _live_missing=""
  for _live_scenario in "${REQUIRED_LIVE_SCENARIOS[@]}"; do
    grep -qx "$_live_scenario" "$LIVE_PASS_FILE" 2>/dev/null \
      || _live_missing="$_live_missing $_live_scenario"
  done
  if [[ -z "$_live_missing" ]]; then
    echo "LIVE_REQUIRED_ALL_PASS"
  else
    # 미완료를 성공처럼 보이게 두지 않는다 — 전체 통과 문구를 억제하고 non-zero로 종결해
    # 판정이 exit code 한 계층에서 닫히게 한다 (sentinel은 성공 경로의 이중 확인 신호).
    warn "live 필수 시나리오 미완(sentinel 미발행):$_live_missing — WARN skip 원인 해소 후 재실행"
    echo "Deterministic tests passed; live REQUIRED scenarios incomplete."
    exit 1
  fi
fi
echo "All codex hook fixture tests passed."
