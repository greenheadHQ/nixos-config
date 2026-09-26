# tests/suites/rebuild-nrs.sh — 도메인 테스트 정의 (sourced; aggregator가 lib/test-common.sh 후 source)
# shellcheck shell=bash
# SC2154: 공통 변수는 aggregator/test-common이 정의. SC2164: set -euo pipefail 런타임 상속.
# shellcheck disable=SC2154,SC2164
write_mixed_user_codex_hooks() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex"
  # session-init-icons.sh is a known stale Claude-era user hook; Codex should prune it, not run it.
  cat > "$home_dir/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "~/.codex/hooks/session-init-icons.sh"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/tmp/custom-user-hook.sh"
          }
        ]
      }
    ]
  }
}
EOF
  printf '{}\n' > "$home_dir/.codex/hooks.compatibility.json"
}
assert_user_codex_hooks_pruned() {
  local home_dir="$1"
  local hooks_json="$home_dir/.codex/hooks.json"
  [[ ! -e "$home_dir/.codex/hooks.compatibility.json" ]] || fail "expected user-level hooks.compatibility.json to be removed"
  [[ -f "$hooks_json" ]] || fail "expected user-level hooks.json with preserved custom entry"
  local hooks_content
  hooks_content="$(cat "$hooks_json")"
  assert_contains "$hooks_content" "/tmp/custom-user-hook.sh"
  assert_not_contains "$hooks_content" "session-init-icons.sh"
}
install_repo_local_only_codex_cleanup_helper() {
  local home_dir="$1"
  local helper="$home_dir/.local/lib/rebuild/common.sh"
  rm -f "$helper"
  cp "$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh" "$helper"
  cat >> "$helper" <<'EOF'

_clear_retired_codex_hook_artifacts() {
    local hooks_json="$FLAKE_PATH/.codex/hooks.json"
    local hooks_report="$FLAKE_PATH/.codex/hooks.compatibility.json"

    if [[ -e "$hooks_json" || -e "$hooks_report" ]]; then
        rm -f "$hooks_json" "$hooks_report"
        log_info "🧹 Removed retired Codex hook artifacts."
    fi
}
EOF
}

install_partial_deployed_codex_legacy_hooks_helper() {
  local home_dir="$1"
  local helper="$home_dir/.local/lib/rebuild/codex-legacy-hooks.sh"
  mkdir -p "$(dirname "$helper")"
  rm -f "$helper"
  cat > "$helper" <<'EOF'
# Partial old deployed helper fixture: readable, but missing codex_clear_retired_hook_artifacts.
codex_partial_legacy_hooks_helper_loaded() {
    return 0
}
EOF
}

install_repo_fallback_codex_legacy_hooks_helper() {
  local repo_root="$1"
  local helper="$repo_root/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh"
  mkdir -p "$(dirname "$helper")"
  cp "$REPO_ROOT/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh" "$helper"
}

install_codex_managed_artifact_fixture() {
  local home_dir="$1"
  mkdir -p "$home_dir/.codex/hooks" "$home_dir/.codex/lib"

  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/record-prompt-submit.sh" \
    "$home_dir/.codex/hooks/record-prompt-submit.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/_stop-dispatcher.sh" \
    "$home_dir/.codex/hooks/_stop-dispatcher.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/record-last-stop.sh" \
    "$home_dir/.codex/hooks/record-last-stop.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/nrs-session-cleanup.sh" \
    "$home_dir/.codex/hooks/nrs-session-cleanup.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-guard.sh" \
    "$home_dir/.codex/hooks/pinning-guard.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/codex/files/hooks/pinning-alert.sh" \
    "$home_dir/.codex/hooks/pinning-alert.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/claude/files/lib/hook-runtime.sh" \
    "$home_dir/.codex/lib/hook-runtime.sh"
  ln -sf "$REPO_ROOT/modules/shared/programs/claude/files/lib/pinning-patterns.sh" \
    "$home_dir/.codex/lib/pinning-patterns.sh"
}

install_platform_rebuild_entrypoint() {
  local sandbox="$1" platform="$2" command="$3"
  local home_dir="$sandbox/home"
  local generated_dir="$sandbox/generated"

  mkdir -p "$home_dir/.local/bin" "$generated_dir"

  # shellcheck disable=SC2016  # Literal Nix source strings.
  case "$platform" in
    darwin)
      register_copy_exec \
        "$REPO_ROOT/modules/shared/programs/shell/darwin.nix" \
        ".local/bin/$command" \
        '${darwinScriptsDir}/'"$command"'.sh' \
        "modules/darwin/scripts/$command.sh"
      ;;
    nixos)
      register_copy_exec \
        "$REPO_ROOT/modules/shared/programs/shell/nixos.nix" \
        ".local/bin/$command" \
        '${nixosScriptsDir}/'"$command"'.sh' \
        "modules/nixos/scripts/$command.sh"
      ;;
    *) fail "unknown platform for $command entrypoint: $platform" ;;
  esac
}

install_platform_nrs_entrypoint() {
  install_platform_rebuild_entrypoint "$1" "$2" nrs
}

install_platform_nrp_entrypoint() {
  install_platform_rebuild_entrypoint "$1" "$2" nrp
}

install_recording_nrs_relink() {
  local home_dir="$1"
  mkdir -p "$home_dir/.local/bin"
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${NRS_RELINK_LOG:?}"
EOF
  chmod +x "$home_dir/.local/bin/nrs-relink"
}

# fake sudo stub. 비TTY nrs는 sudo를 -n(fail-fast)으로 호출하므로 실제 sudo처럼
# 옵션을 소비한 뒤 명령을 exec한다. -l/-ll(darwin nrs 실패 진단 경로가 호출하는
# 조회 모드)은 명령을 실행하지 않고 소비만 한다 — 현재 어떤 테스트도 rebuild 실패
# 진단 경로를 구동하지 않으므로, 실제 `sudo -ll` 출력(!authenticate) emulation은
# 두지 않는다 (소비처 없는 스캐폴딩 회피; production 진단 판정의 정확성은 실측으로
# 확인). 모르는 옵션은 fail-loud로 계약 드리프트를 잡고, FAKE_SUDO_ARGS_LOG가
# 설정되면 호출 인자를 기록한다 (-n 전달 계약 assert용).
install_fake_sudo_stub() {
  local stub_dir="$1"
  cat > "$stub_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${FAKE_SUDO_ARGS_LOG:-}" ]]; then
  printf 'sudo %s\n' "$*" >> "$FAKE_SUDO_ARGS_LOG"
fi
while [[ "${1:-}" == -* ]]; do
  case "$1" in
    -n) shift ;;
    -l|-ll) exit 0 ;;
    --) shift; break ;;
    *) echo "fake sudo: unexpected option $1" >&2; exit 64 ;;
  esac
done
exec "$@"
EOF
  chmod +x "$stub_dir/sudo"
}

test_rebuild_common_exports_public_api() {
  local sandbox output
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"

  output=$(
    HOME="$sandbox/home" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      REBUILD_CMD="nixos-rebuild"
      source "'"$sandbox/home/.local/lib/rebuild-common.sh"'"
      parse_args --offline --force --cores 2
      printf "offline=%s\nforce=%s\ncores=%s\n" "$OFFLINE_FLAG" "$FORCE_FLAG" "$CORES_FLAG"
      declare -F log_info
      declare -F log_warn
      declare -F log_error
      declare -F acquire_nrs_lock
      declare -F release_nrs_lock
      declare -F release_nrs_lock_after_no_changes
      declare -F release_nrs_lock_on_failure
      declare -F mark_nrs_lock_switch_success
      declare -F acquire_rebuild_lock
      declare -F release_rebuild_lock
      declare -F release_rebuild_lock_on_failure
      declare -F preflight_source_build_check
      declare -F preflight_cask_conflict_check
      declare -F rebuild_is_main_flake
      declare -F prepare_worktree_symlinks_for_rebuild
      declare -F preview_changes
      declare -F worktree_symlink_guard
      declare -F maybe_relink_or_restore
      declare -F cleanup_build_artifacts
      declare -F codex_managed_artifacts_missing
      declare -F codex_log_managed_artifacts_missing
      declare -F repair_codex_config_drift_no_changes
    ' 2>&1
  )

  assert_contains "$output" "offline=--offline"
  assert_contains "$output" "force=true"
  assert_contains "$output" "cores=--cores 2"
  assert_contains "$output" "log_info"
  assert_contains "$output" "log_warn"
  assert_contains "$output" "log_error"
  assert_contains "$output" "acquire_nrs_lock"
  assert_contains "$output" "release_nrs_lock"
  assert_contains "$output" "release_nrs_lock_after_no_changes"
  assert_contains "$output" "release_nrs_lock_on_failure"
  assert_contains "$output" "mark_nrs_lock_switch_success"
  assert_contains "$output" "acquire_rebuild_lock"
  assert_contains "$output" "release_rebuild_lock"
  assert_contains "$output" "release_rebuild_lock_on_failure"
  assert_contains "$output" "preflight_source_build_check"
  assert_contains "$output" "preflight_cask_conflict_check"
  assert_contains "$output" "rebuild_is_main_flake"
  assert_contains "$output" "prepare_worktree_symlinks_for_rebuild"
  assert_contains "$output" "preview_changes"
  assert_contains "$output" "worktree_symlink_guard"
  assert_contains "$output" "maybe_relink_or_restore"
  assert_contains "$output" "cleanup_build_artifacts"
  assert_contains "$output" "codex_managed_artifacts_missing"
  assert_contains "$output" "codex_log_managed_artifacts_missing"
  assert_contains "$output" "repair_codex_config_drift_no_changes"
}

# ─────────────────────────────────────────────────────────────────────────
# #1380: release_rebuild_lock 이 fd 200 을 닫으면서 명령 없는 `exec ... 2>/dev/null`
# 로 호출 셸의 표준 오류까지 영구적으로 /dev/null 로 돌려버리던 결함의 회귀 테스트.
# lib/rebuild/common.sh + lib/rebuild/locks.sh 만 REPO_ROOT 에서 직접 source 한다
# (FLAKE_PATH/MAIN_FLAKE_PATH 는 nrs 워크트리 잠금용이고, rebuild critical-section
# 잠금인 acquire/release_rebuild_lock* 는 이 두 변수와 무관).
#
# 두 성질은 서로 다른 결함을 잡으므로 테스트도 분리한다:
#   - stderr 보존: 원래 버그(exec + 무조건 2>/dev/null 병합)만 깨뜨린다. fd 를 안 닫거나
#     서브셸에서만 닫는 변이는 stderr 를 건드리지 않으므로 이 테스트들은 green 을 유지한다.
#   - fd 200 실제 닫힘: "안 닫음"·"서브셸에서만 닫음" 변이를 잡는다. 원래 버그는 fd 는
#     제대로 닫으므로(문제는 stderr 쪽) 이 테스트들에서는 green 이어도 정상이다.
# ─────────────────────────────────────────────────────────────────────────

test_release_rebuild_lock_preserves_caller_stderr() {
  local sandbox output
  sandbox=$(new_sandbox)

  # shellcheck disable=SC2016  # 내부 bash -c 스크립트의 변수라 여기서 확장되면 안 됨.
  output=$(
    bash -c '
      set -euo pipefail
      GREEN="" YELLOW="" RED="" NC=""
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/common.sh"
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/locks.sh"
      NRS_REBUILD_LOCK="'"$sandbox"'/rebuild.lock"

      echo before-release-marker >&2
      acquire_rebuild_lock
      release_rebuild_lock
      echo "held_after_first_release=$NRS_REBUILD_LOCK_HELD"
      # 이미 해제된 상태에서 재호출해도 stderr 대상이 다시 바뀌지 않아야 함.
      release_rebuild_lock
      acquire_rebuild_lock
      release_rebuild_lock
      echo "held_after_second_release=$NRS_REBUILD_LOCK_HELD"
      echo after-release-marker >&2
    ' 2>&1
  )

  assert_contains "$output" "before-release-marker"
  assert_contains "$output" "held_after_first_release=false"
  assert_contains "$output" "held_after_second_release=false"
  assert_contains "$output" "after-release-marker"
}

test_release_rebuild_lock_on_failure_preserves_caller_stderr() {
  local sandbox output
  sandbox=$(new_sandbox)

  # shellcheck disable=SC2016
  output=$(
    bash -c '
      set -euo pipefail
      GREEN="" YELLOW="" RED="" NC=""
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/common.sh"
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/locks.sh"
      NRS_REBUILD_LOCK="'"$sandbox"'/rebuild.lock"

      echo before-failure-cleanup-marker >&2
      acquire_rebuild_lock
      release_rebuild_lock_on_failure
      echo "held=$NRS_REBUILD_LOCK_HELD"
      echo after-failure-cleanup-marker >&2
    ' 2>&1
  )

  assert_contains "$output" "before-failure-cleanup-marker"
  assert_contains "$output" "held=false"
  assert_contains "$output" "after-failure-cleanup-marker"
}

test_release_rebuild_lock_without_hold_is_noop() {
  local sandbox output
  sandbox=$(new_sandbox)

  # shellcheck disable=SC2016
  output=$(
    bash -c '
      set -euo pipefail
      GREEN="" YELLOW="" RED="" NC=""
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/common.sh"
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/locks.sh"
      NRS_REBUILD_LOCK="'"$sandbox"'/rebuild.lock"

      echo before-marker >&2
      release_rebuild_lock
      echo "release_status=$?"
      echo "held=$NRS_REBUILD_LOCK_HELD"
      echo after-marker >&2
    ' 2>&1
  )

  assert_contains "$output" "before-marker"
  assert_contains "$output" "release_status=0"
  assert_contains "$output" "held=false"
  assert_contains "$output" "after-marker"
}

test_release_rebuild_lock_closes_fd200_in_same_shell() {
  local sandbox output
  sandbox=$(new_sandbox)

  # 교차 프로세스 경쟁 없이, acquire/release 를 부른 바로 그 프로세스에서 fd 200 이
  # 실제로 닫혔는지 직접 검사한다. `{ true >&200; } 2>/dev/null` 는 fd 200 이 열려
  # 있으면 성공, 닫혀 있으면 실패한다(open이면 그 자체가 유효한 명령이 되어 rc=0).
  # 이 검사는 "fd 를 안 닫음"·"서브셸에서만 닫음" 변이를 잡는다 — 원래 버그(#1380)는
  # fd 자체는 제대로 닫으므로 이 테스트에서는 green 이어도 정상이며, 원래 버그는
  # stderr 보존 테스트가 잡는다.
  # shellcheck disable=SC2016
  output=$(
    bash -c '
      set -euo pipefail
      GREEN="" YELLOW="" RED="" NC=""
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/common.sh"
      source "'"$REPO_ROOT"'/modules/shared/scripts/lib/rebuild/locks.sh"
      NRS_REBUILD_LOCK="'"$sandbox"'/rebuild.lock"

      acquire_rebuild_lock
      release_rebuild_lock
      if { true >&200; } 2>/dev/null; then
        echo "fd200=open"
      else
        echo "fd200=closed"
      fi
      echo "held=$NRS_REBUILD_LOCK_HELD"
    ' 2>&1
  )

  assert_contains "$output" "fd200=closed"
  assert_contains "$output" "held=false"
}

test_release_rebuild_lock_frees_lock_for_other_process() (
  local sandbox holder_script attempt_script holder_log holder_pid=""

  # 실패 경로(fail() 의 exit 1 포함)에서도 holder 백그라운드 프로세스를 반드시 정리한다.
  # 정리하지 않으면 sandbox 가 지워진 뒤 holder 의 대기 루프가 PPID 1 로 영구히 돈다.
  # 선례: tests/suites/claude-remote-control-guardian.sh 의
  # test_claude_remote_control_launch_guard_reaps_early_exit_descendant.
  # shellcheck disable=SC2329  # EXIT trap에서만 호출
  _cleanup_frees_lock_fixture() {
    [[ -z "$holder_pid" ]] || kill "$holder_pid" 2>/dev/null || true
    [[ -z "$holder_pid" ]] || wait "$holder_pid" 2>/dev/null || true
  }
  trap _cleanup_frees_lock_fixture EXIT

  sandbox=$(new_sandbox)
  holder_script="$sandbox/holder.sh"
  attempt_script="$sandbox/attempt.sh"
  holder_log="$sandbox/holder.log"

  # holder: 잠금을 잡고, 신호 파일이 나타날 때까지 기다렸다가 release_rebuild_lock 을
  # 호출한다. 해제 뒤에도 곧바로 종료하지 않고 이 테스트가 다른 프로세스의 재획득
  # 시도를 끝내고 attempt-done 을 남길 때까지 살아있는다 — "fd 를 닫아서 풀렸다"와
  # "holder 프로세스가 죽어서 풀렸다"를 구분하기 위함(고정 sleep 이면 그 사이 holder가
  # 먼저 죽어 시도가 지연 성공하는 것과 fd 닫힘을 구분할 수 없다).
  cat > "$holder_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
GREEN="" YELLOW="" RED="" NC=""
source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh"
source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/locks.sh"
NRS_REBUILD_LOCK="$sandbox/rebuild.lock"
NRS_REBUILD_LOCK_TIMEOUT=5
acquire_rebuild_lock
echo "holder-acquired"
until [[ -f "$sandbox/release-now" ]]; do sleep 0.05; done
release_rebuild_lock
echo "holder-released"
touch "$sandbox/holder-alive-after-release"
_holder_waited=0
until [[ -f "$sandbox/attempt-done" ]]; do
  sleep 0.05
  _holder_waited=\$((_holder_waited + 1))
  (( _holder_waited > 200 )) && break
done
EOF
  chmod +x "$holder_script"

  # attempt: 짧은 타임아웃으로 잠금 획득을 시도하는 별도 프로세스. \$1 은 런타임에
  # attempt_script 자신에게 전달되는 타임아웃(초)이라 생성 시점에 확장하면 안 된다.
  # discoteq flock 0.4.0 은 --timeout 0 을 rc=64 로 거부하므로 최소값 1 을 쓴다.
  cat > "$attempt_script" <<EOF
#!/usr/bin/env bash
set -euo pipefail
GREEN="" YELLOW="" RED="" NC=""
source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/common.sh"
source "$REPO_ROOT/modules/shared/scripts/lib/rebuild/locks.sh"
NRS_REBUILD_LOCK="$sandbox/rebuild.lock"
NRS_REBUILD_LOCK_TIMEOUT="\$1"
if acquire_rebuild_lock; then
  echo "attempt-acquired"
  release_rebuild_lock
else
  echo "attempt-timeout"
fi
EOF
  chmod +x "$attempt_script"

  "$holder_script" > "$holder_log" 2>&1 &
  holder_pid=$!

  local waited=0
  until grep -q "holder-acquired" "$holder_log" 2>/dev/null; do
    sleep 0.05
    waited=$((waited + 1))
    (( waited > 60 )) && break
  done
  assert_contains "$(cat "$holder_log")" "holder-acquired"

  # holder 가 잠금을 쥔 동안에는 다른 프로세스가 짧은 타임아웃 안에 획득하지 못해야 함.
  local blocked_output
  blocked_output=$("$attempt_script" 1 2>&1)
  assert_contains "$blocked_output" "attempt-timeout"

  touch "$sandbox/release-now"
  waited=0
  until [[ -f "$sandbox/holder-alive-after-release" ]]; do
    sleep 0.05
    waited=$((waited + 1))
    (( waited > 60 )) && break
  done
  [[ -f "$sandbox/holder-alive-after-release" ]] \
    || fail "holder released 이후 상태를 확인하지 못함 (release_rebuild_lock 이 반환하지 않은 것으로 보임)"
  kill -0 "$holder_pid" 2>/dev/null \
    || fail "holder 프로세스가 release 증거 기록 직후 이미 종료됨 — fd 닫힘과 프로세스 종료를 구분할 수 없음"

  # holder 프로세스는 여전히 살아있고(attempt-done 을 기다리는 중), 이 시점에는 아직
  # 그 신호를 주지 않았다. 그런데도 다른 프로세스가 짧은 타임아웃 안에 잠금을 얻을 수
  # 있다면, release_rebuild_lock 이 실제로 fd 200 을 닫아 OS 잠금을 풀었다는 증거다.
  local freed_output
  freed_output=$("$attempt_script" 1 2>&1)

  # 재획득 시도가 끝난 뒤에도 holder 가 살아있었는지 다시 단정한다 — "그 사이 holder가
  # 죽어서 풀렸다"는 대안 설명을 배제한다.
  kill -0 "$holder_pid" 2>/dev/null \
    || fail "holder 프로세스가 재획득 시도 도중 종료됨 — fd 닫힘과 프로세스 종료를 구분할 수 없음"

  touch "$sandbox/attempt-done"
  wait "$holder_pid" 2>/dev/null || true
  holder_pid=""

  assert_contains "$freed_output" "attempt-acquired"
)

test_parse_args_unknown_argument_shows_usage_and_fails() {
  local sandbox stdout_file stderr_file rc
  sandbox=$(new_sandbox)
  install_deployed_layout "$sandbox"
  stdout_file="$sandbox/parse-args.out"
  stderr_file="$sandbox/parse-args.err"

  # 오류 메시지와 usage는 stderr 계약이다 — stdout/stderr를 분리 캡처해 스트림 회귀를 감지한다.
  rc=0
  HOME="$sandbox/home" \
  PATH="$FIXTURE_DIR/bin:$PATH" \
  bash -c '
    set -euo pipefail
    REBUILD_CMD="nixos-rebuild"
    source "'"$sandbox/home/.local/lib/rebuild-common.sh"'"
    parse_args --bogus
  ' > "$stdout_file" 2> "$stderr_file" || rc=$?

  [[ "$rc" -eq 1 ]] || fail "expected parse_args --bogus to exit 1 (actual: $rc)"
  assert_contains "$(cat "$stderr_file")" "Unknown argument: --bogus"
  assert_contains "$(cat "$stderr_file")" "Usage:"
  [[ -s "$stdout_file" ]] && fail "expected empty stdout for unknown argument (got: $(cat "$stdout_file"))"
  return 0
}

# usage/도움말 계열 테스트 공용 fixture — sandbox를 만들고 배포 진입점을 설치한 뒤
# ENTRYPOINT_FIXTURE_HOME / ENTRYPOINT_FIXTURE_REPO 전역을 설정한다.
# 이 계열은 parse_args 단계에서 종료되므로 rebuild/sudo stub 없이 안전하게 실행된다.
prepare_rebuild_entrypoint_fixture() {
  local platform="$1" command="$2"
  local sandbox
  sandbox=$(new_sandbox)
  ENTRYPOINT_FIXTURE_HOME="$sandbox/home"
  ENTRYPOINT_FIXTURE_REPO="$sandbox/repo"
  create_git_fixture_repo "$ENTRYPOINT_FIXTURE_REPO"
  ENTRYPOINT_FIXTURE_REPO="$(cd "$ENTRYPOINT_FIXTURE_REPO" && pwd -P)"
  install_deployed_layout "$sandbox" "$ENTRYPOINT_FIXTURE_REPO"
  install_platform_rebuild_entrypoint "$sandbox" "$platform" "$command"
}

# 준비된 fixture에서 배포 진입점을 실행한다 (stdout+stderr 병합 반환).
# 시나리오별 환경변수는 호출 앞에 붙인다: REBUILD_MODE=preview run_deployed_rebuild_entrypoint nrs --help
run_deployed_rebuild_entrypoint() {
  local command="$1"; shift
  HOME="$ENTRYPOINT_FIXTURE_HOME" \
  PATH="$FIXTURE_DIR/bin:$PATH" \
  bash -c '
    set -euo pipefail
    cd "'"$ENTRYPOINT_FIXTURE_REPO"'"
    "'"$ENTRYPOINT_FIXTURE_HOME/.local/bin/$command"'" "$@"
  ' _ "$@" 2>&1
}

test_nixos_nrs_help_flag_prints_usage() {
  local output
  prepare_rebuild_entrypoint_fixture nixos nrs
  output=$(run_deployed_rebuild_entrypoint nrs --help)

  assert_contains "$output" "Usage: nrs"
  assert_contains "$output" "--offline"
  assert_contains "$output" "--cores N"
  assert_not_contains "$output" "Applying changes"
  assert_not_contains "$output" "Unknown argument"
}

test_darwin_nrs_h_alias_prints_usage() {
  local output
  prepare_rebuild_entrypoint_fixture darwin nrs
  # darwin 진입점 + 짧은 alias -h도 동일 usage 계약을 따른다.
  output=$(run_deployed_rebuild_entrypoint nrs -h)

  assert_contains "$output" "Usage: nrs"
  assert_contains "$output" "--force"
  assert_contains "$output" "--cores N"
  assert_not_contains "$output" "Unknown argument"
}

test_nrs_help_ignores_inherited_rebuild_mode() {
  local output
  prepare_rebuild_entrypoint_fixture nixos nrs
  # 진입점의 REBUILD_MODE=switch 명시 선언이 호출 환경에서 상속된 값을 덮는다.
  output=$(REBUILD_MODE="preview" run_deployed_rebuild_entrypoint nrs --help)

  assert_contains "$output" "Usage: nrs"
  assert_contains "$output" "--force"
  assert_not_contains "$output" "preview wrapper"
}

test_nrp_help_usage_omits_force_flag() {
  local output
  prepare_rebuild_entrypoint_fixture nixos nrp
  # 실제 nrp 진입점 실행 — REBUILD_MODE=preview 선언이 usage에서 무효 --force를 제외한다.
  output=$(run_deployed_rebuild_entrypoint nrp --help)

  assert_contains "$output" "Usage: nrp"
  assert_contains "$output" "--cores N"
  assert_not_contains "$output" "--force"
}

test_nrp_rejects_force_flag() {
  local output rc
  prepare_rebuild_entrypoint_fixture nixos nrp
  # preview 진입점에서 --force는 usage뿐 아니라 parser에서도 거부된다.
  rc=0
  output=$(run_deployed_rebuild_entrypoint nrp --force) || rc=$?

  [[ "$rc" -eq 1 ]] || fail "expected nrp --force to exit 1 (actual: $rc)"
  assert_contains "$output" "--force is not supported"
  assert_contains "$output" "Usage: nrp"
}

test_detect_worktree_uses_current_worktree_path() {
  local sandbox home_dir repo_root worktree_root output
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      printf "flake=%s\nis_main=%s\n" \
        "$FLAKE_PATH" \
        "$(rebuild_is_main_flake && echo true || echo false)"
    ' 2>&1
  )

  assert_contains "$output" "flake=$worktree_root"
  assert_contains "$output" "is_main=false"
}

test_worktree_relink_skips_non_tty_without_opt_in() {
  local sandbox home_dir repo_root worktree_root output relink_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  relink_log="$sandbox/nrs-relink.log"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_recording_nrs_relink "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    NRS_RELINK_LOG="$relink_log" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      maybe_relink_or_restore
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Skipping worktree relink in non-interactive/agent context"
  assert_not_contains "$output" "Relinking symlinks to worktree"
  [[ ! -s "$relink_log" ]] || fail "expected non-TTY worktree relink to skip nrs-relink"
}

test_worktree_relink_opt_in_allows_non_tty() {
  local sandbox home_dir repo_root worktree_root output relink_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  relink_log="$sandbox/nrs-relink.log"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_recording_nrs_relink "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    NRS_RELINK_LOG="$relink_log" \
    NRS_ALLOW_WORKTREE_RELINK=1 \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      maybe_relink_or_restore
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Relinking symlinks to worktree"
  assert_not_contains "$output" "Skipping worktree relink"
  assert_file_contains "$relink_log" "relink"
}

test_main_relink_restore_ignores_non_tty_guard() {
  local sandbox home_dir repo_root worktree_root output relink_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  relink_log="$sandbox/nrs-relink.log"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_recording_nrs_relink "$home_dir"

  mkdir -p "$home_dir/.claude" "$worktree_root"
  ln -sf "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"

  output=$(
    HOME="$home_dir" \
    PATH="$FIXTURE_DIR/bin:$PATH" \
    NRS_RELINK_LOG="$relink_log" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      REBUILD_CMD="nixos-rebuild"
      source "'"$home_dir/.local/lib/rebuild-common.sh"'"
      maybe_relink_or_restore
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Restoring symlinks to nix store chain"
  assert_not_contains "$output" "Skipping worktree relink"
  assert_file_contains "$relink_log" "restore"
}

test_nixos_nrs_offline_force_smoke() {
  local sandbox home_dir repo_root stub_dir output result_target
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos
  install_repo_local_only_codex_cleanup_helper "$home_dir"
  install_partial_deployed_codex_legacy_hooks_helper "$home_dir"
  install_repo_fallback_codex_legacy_hooks_helper "$repo_root"

  mkdir -p "$stub_dir" "$home_dir/.local/bin"
  install_fake_sudo_stub "$stub_dir"
  cat > "$stub_dir/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${NRS_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected nixos-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/nixos-rebuild" "$stub_dir/nvd" "$home_dir/.local/bin/nrs-relink"

  result_target="$sandbox/current-system"
  mkdir -p "$result_target"
  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    NRS_RESULT_TARGET="$result_target" \
    FAKE_SUDO_ARGS_LOG="$sandbox/sudo-args.log" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline --force
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Applying changes (offline)"
  assert_contains "$output" "Done!"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  # 비TTY 계약: nrs는 sudo를 -n(fail-fast)으로 호출해야 한다
  assert_contains "$(cat "$sandbox/sudo-args.log")" "sudo -n nixos-rebuild switch"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected nixos nrs to remove retired hooks.json"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected nixos nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

test_nixos_nrs_no_changes_activates_when_codex_artifact_missing() {
  local sandbox home_dir repo_root stub_dir output current_target switch_log
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  current_target="$sandbox/current-system"
  switch_log="$sandbox/nixos-switch.log"

  mkdir -p "$repo_root" "$stub_dir" "$home_dir/.local/bin" "$current_target"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" nixos
  install_codex_managed_artifact_fixture "$home_dir"
  rm -f "$home_dir/.codex/hooks/pinning-alert.sh"

  install_fake_sudo_stub "$stub_dir"
  cat > "$stub_dir/nixos-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${NIXOS_CURRENT_SYSTEM:?}" ./result
    ;;
  switch)
    printf 'switch\n' >> "${NIXOS_SWITCH_LOG:?}"
    ;;
  *)
    echo "unexpected nixos-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${NIXOS_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/nixos-rebuild" "$stub_dir/nvd" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    NIXOS_CURRENT_SYSTEM="$current_target" \
    NIXOS_SWITCH_LOG="$switch_log" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline
    ' 2>&1
  )

  assert_contains "$output" "Codex hook/lib artifact missing"
  assert_contains "$output" '$HOME/.codex/hooks/pinning-alert.sh'
  assert_contains "$output" "Applying changes (offline)"
  assert_not_contains "$output" "Skipping rebuild"
  [[ -s "$switch_log" ]] || fail "expected no-change nrs to run nixos-rebuild switch when Codex artifact is missing"
}

test_darwin_nrs_offline_force_smoke() {
  local sandbox home_dir repo_root stub_dir output result_target current_target
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin

  mkdir -p "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents" "$sandbox/current-system"
  current_target="$sandbox/current-system"

  install_fake_sudo_stub "$stub_dir"
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    printf '%s\n' '-\t0\tcom.greenhead.test-agent'
    exit 0
    ;;
  bootout) exit 0 ;;
esac
exit 0
EOF
  cat > "$stub_dir/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  cat > "$stub_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  cat > "$stub_dir/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/launchctl" "$stub_dir/open" "$stub_dir/pgrep" "$stub_dir/killall" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  result_target="$sandbox/darwin-result"
  mkdir -p "$result_target"
  mkdir -p "$repo_root/.codex"
  printf '{}\n' > "$repo_root/.codex/hooks.json"
  printf '{}\n' > "$repo_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_RESULT_TARGET="$result_target" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    FAKE_SUDO_ARGS_LOG="$sandbox/sudo-args.log" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'" --offline --force
    ' </dev/null 2>&1
  )

  assert_contains "$output" "Applying changes (offline)"
  assert_contains "$output" "Done!"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  # 비TTY 계약: nrs는 sudo를 -n(fail-fast)으로 호출해야 한다
  assert_contains "$(cat "$sandbox/sudo-args.log")" "sudo -n darwin-rebuild switch"
  [[ ! -e "$repo_root/.codex/hooks.json" ]] || fail "expected darwin nrs to remove retired hooks.json"
  [[ ! -e "$repo_root/.codex/hooks.compatibility.json" ]] || fail "expected darwin nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

test_darwin_nrs_no_changes_releases_worktree_lock() {
  local sandbox home_dir repo_root worktree_root stub_dir output result_target current_target lock_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_repo_local_only_codex_cleanup_helper "$home_dir"
  install_partial_deployed_codex_legacy_hooks_helper "$home_dir"
  install_repo_fallback_codex_legacy_hooks_helper "$worktree_root"

  mkdir -p "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents"
  current_target="$sandbox/current-system"
  mkdir -p "$current_target"
  lock_file="$sandbox/nrs-state"
  rm -f "$lock_file"
  mkdir -p "$worktree_root/.codex"
  printf '{}\n' > "$worktree_root/.codex/hooks.json"
  printf '{}\n' > "$worktree_root/.codex/hooks.compatibility.json"
  write_mixed_user_codex_hooks "$home_dir"
  install_codex_managed_artifact_fixture "$home_dir"

  install_fake_sudo_stub "$stub_dir"
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_RESULT_TARGET:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  result_target="$current_target"
  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_RESULT_TARGET="$result_target" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    NRS_LOCK_FILE="$lock_file" \
    bash -c '
      set -euo pipefail
      cd "'"$worktree_root"'"
      "'"$home_dir/.local/bin/nrs"'"
    ' 2>&1
  )

  assert_contains "$output" "Lock acquired"
  assert_contains "$output" "No changes to apply"
  assert_contains "$output" "Lock released"
  assert_contains "$output" "Removed retired user-level Codex hooks.compatibility.json"
  assert_contains "$output" "Pruned 1 stale Codex hook entry"
  [[ ! -e "$lock_file" ]] || fail "expected sandbox nrs lock file to be removed after no-change early return"
  [[ ! -e "$worktree_root/.codex/hooks.json" ]] || fail "expected no-change darwin nrs to remove retired hooks.json"
  [[ ! -e "$worktree_root/.codex/hooks.compatibility.json" ]] || fail "expected no-change darwin nrs to remove retired hooks.compatibility.json"
  assert_user_codex_hooks_pruned "$home_dir"
}

# darwin no-change gcroot guard fixture — caller의 local 변수(sandbox/home_dir/repo_root/
# worktree_root/stub_dir/current_target/relink_log/lock_file)를 bash dynamic scoping으로 채운다.
# main repo에서 no-change nrs를 돌리되, stale worktree 심링크 probe를 심어 guard가 없으면
# maybe_relink_or_restore의 Phase 1(rm) + restore가 반드시 실행되는 상태를 만든다.
setup_darwin_no_change_gcroot_fixture() {
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  current_target="$sandbox/current-system"
  relink_log="$sandbox/nrs-relink.log"
  lock_file="$sandbox/nrs-state"

  create_git_fixture_repo "$repo_root"
  repo_root="$(cd "$repo_root" && pwd -P)"
  worktree_root="$repo_root/.claude/worktrees/feature_one"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_codex_managed_artifact_fixture "$home_dir"
  install_recording_nrs_relink "$home_dir"

  mkdir -p "$stub_dir" "$current_target" "$home_dir/.claude"
  rm -f "$lock_file"

  # stale worktree probe: main 경로 _remove_worktree_symlinks가 매칭하는 심링크
  ln -sf "$worktree_root/CLAUDE.md" "$home_dir/.claude/CLAUDE.md"

  install_fake_sudo_stub "$stub_dir"
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_CURRENT_SYSTEM:?}" ./result
    ;;
  switch)
    :
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/readlink"
}

run_darwin_no_change_gcroot_nrs() {
  HOME="$home_dir" \
  PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
  DARWIN_CURRENT_SYSTEM="$current_target" \
  NRS_LOCK_FILE="$lock_file" \
  NRS_RELINK_LOG="$relink_log" \
  bash -c '
    set -euo pipefail
    cd "'"$repo_root"'"
    "'"$home_dir/.local/bin/nrs"'"
  ' 2>&1
}

test_darwin_nrs_no_changes_skips_relink_without_hm_gcroot() {
  local sandbox home_dir repo_root worktree_root stub_dir current_target relink_log lock_file output
  setup_darwin_no_change_gcroot_fixture

  output=$(run_darwin_no_change_gcroot_nrs)

  assert_contains "$output" "No changes to apply"
  assert_not_contains "$output" "Restoring symlinks to nix store chain"
  [[ ! -s "$relink_log" ]] || fail "expected no-change nrs without HM gcroot to skip nrs-relink"
  [[ -L "$home_dir/.claude/CLAUDE.md" ]] || fail "expected stale worktree symlink to be left untouched without HM gcroot"
  [[ ! -e "$lock_file" ]] || fail "expected nrs lock file to be removed after no-change early return"
}

test_darwin_nrs_no_changes_restores_when_hm_gcroot_present() {
  local sandbox home_dir repo_root worktree_root stub_dir current_target relink_log lock_file output
  setup_darwin_no_change_gcroot_fixture
  mkdir -p "$home_dir/.local/state/home-manager/gcroots"
  touch "$home_dir/.local/state/home-manager/gcroots/current-home"

  output=$(run_darwin_no_change_gcroot_nrs)

  assert_contains "$output" "No changes to apply"
  assert_contains "$output" "Restoring symlinks to nix store chain"
  assert_file_contains "$relink_log" "restore"
  [[ ! -L "$home_dir/.claude/CLAUDE.md" ]] || fail "expected stale worktree symlink to be removed when HM gcroot is present"
}

test_darwin_nrs_no_changes_activates_when_codex_artifact_missing() {
  local sandbox home_dir repo_root stub_dir output current_target switch_log lock_file
  sandbox=$(new_sandbox)
  home_dir="$sandbox/home"
  repo_root="$sandbox/repo"
  stub_dir="$sandbox/stub-bin"
  current_target="$sandbox/current-system"
  switch_log="$sandbox/darwin-switch.log"
  lock_file="$sandbox/nrs-state"

  mkdir -p "$repo_root" "$stub_dir" "$home_dir/.local/bin" "$home_dir/Library/LaunchAgents" "$current_target"
  install_deployed_layout "$sandbox" "$repo_root"
  install_platform_nrs_entrypoint "$sandbox" darwin
  install_codex_managed_artifact_fixture "$home_dir"
  rm -f "$home_dir/.codex/hooks/pinning-alert.sh"

  install_fake_sudo_stub "$stub_dir"
  cat > "$stub_dir/darwin-rebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  build)
    ln -sfn "${DARWIN_CURRENT_SYSTEM:?}" ./result
    ;;
  switch)
    printf 'switch\n' >> "${DARWIN_SWITCH_LOG:?}"
    ;;
  *)
    echo "unexpected darwin-rebuild subcommand: $1" >&2
    exit 1
    ;;
esac
EOF
  cat > "$stub_dir/nvd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "stub nvd diff"
EOF
  cat > "$stub_dir/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list) exit 0 ;;
  bootout) exit 0 ;;
esac
exit 0
EOF
  cat > "$stub_dir/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  cat > "$stub_dir/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 1
EOF
  cat > "$stub_dir/killall" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  local real_readlink
  real_readlink="$(command -v readlink)"
  cat > "$stub_dir/readlink" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "/run/current-system" ]]; then
  printf '%s\n' "\${DARWIN_CURRENT_SYSTEM:?}"
else
  "$real_readlink" "\$@"
fi
EOF
  cat > "$home_dir/.local/bin/nrs-relink" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$stub_dir/sudo" "$stub_dir/darwin-rebuild" "$stub_dir/nvd" "$stub_dir/launchctl" "$stub_dir/open" "$stub_dir/pgrep" "$stub_dir/killall" "$stub_dir/readlink" "$home_dir/.local/bin/nrs-relink"

  output=$(
    HOME="$home_dir" \
    PATH="$stub_dir:$FIXTURE_DIR/bin:$PATH" \
    DARWIN_CURRENT_SYSTEM="$current_target" \
    DARWIN_SWITCH_LOG="$switch_log" \
    NRS_LOCK_FILE="$lock_file" \
    bash -c '
      set -euo pipefail
      cd "'"$repo_root"'"
      "'"$home_dir/.local/bin/nrs"'"
    ' 2>&1
  )

  assert_contains "$output" "Codex hook/lib artifact missing"
  assert_contains "$output" '$HOME/.codex/hooks/pinning-alert.sh'
  assert_contains "$output" "Applying changes"
  assert_not_contains "$output" "Skipping rebuild"
  [[ -s "$switch_log" ]] || fail "expected no-change nrs to run darwin-rebuild switch when Codex artifact is missing"
}
