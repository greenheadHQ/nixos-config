# tests/suites/folder-actions-lib.sh — Folder Actions shared lib characterization (sourced)
# shellcheck shell=bash
# SC2154: REPO_ROOT/new_sandbox/run_test/assert_* are provided by tests/lib/test-common.sh.
# shellcheck disable=SC2154

# Source-safety/dependency audit, current as of this characterization:
# - source side effects: variable assignments only
#   (PUSHOVER_CREDENTIALS, PUSHOVER_HELPER, _FA_LIB_FAILED_ROOT) plus function
#   definitions. No file, process, or network side effect was observed.
# - notify_failure: sources $HOME/.local/lib/pushover.sh and calls pushover_send
#   only when $HOME/.config/pushover/folder-actions exists.
# - ensure_failed_dir: basename, /bin/mkdir, /bin/chmod, caller-provided
#   verify_path_security.
# - move_to_failed: ensure_failed_dir, basename, /bin/date, /bin/mv,
#   notify_failure.
# - wait_file_stable: /usr/bin/stat -f '%z:%m', sleep.
# - drain_queue: find_candidates/process_one callbacks, wait_file_stable,
#   basename in the deferred warning path.
# - quarantine_or_abort: move_to_failed, log_error, exit 1 on quarantine failure.
#
# Linux/NixOS exclusion list:
# - ensure_failed_dir, move_to_failed, and wait_file_stable are not exercised
#   directly here because the implementation hard-codes macOS absolute command
#   paths that are absent on the Linux/NixOS runner (/bin/mkdir, /bin/chmod,
#   /bin/date, /bin/mv, /usr/bin/stat). drain_queue and quarantine_or_abort are
#   still covered by overriding those callback boundaries after sourcing.
# - upload-immich.sh missing-credential e2e is skipped when those macOS absolute
#   commands are absent before the credential branch.
#
# This suite is definition-only; tests/shell-script-tests.sh owns run_test registration.

_folder_actions_lib_path() {
  printf '%s\n' "$REPO_ROOT/modules/darwin/programs/folder-actions/files/scripts/_folder-actions-lib.sh"
}

_upload_immich_script_path() {
  printf '%s\n' "$REPO_ROOT/modules/darwin/programs/folder-actions/files/scripts/upload-immich.sh"
}

_folder_actions_define_logger_stubs() {
  _FOLDER_ACTIONS_TEST_LOG_FILE="$1"

  log_info() { printf 'INFO:%s\n' "$*" >> "$_FOLDER_ACTIONS_TEST_LOG_FILE"; }
  log_warn() { printf 'WARN:%s\n' "$*" >> "$_FOLDER_ACTIONS_TEST_LOG_FILE"; }
  log_error() { printf 'ERROR:%s\n' "$*" >> "$_FOLDER_ACTIONS_TEST_LOG_FILE"; }
  verify_path_security() { return 0; }
}

test_folder_actions_lib_source_is_side_effect_free() (
  local sandbox home out
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  mkdir -p "$home"

  out=$(
    HOME="$home" bash -c '
      set -euo pipefail
      WATCH_DIR="$HOME/FolderActions/compress-video"
      CURRENT_PID="12345"
      log_info() { :; }
      log_warn() { :; }
      log_error() { :; }
      verify_path_security() { :; }
      # shellcheck source=/dev/null
      source "$1"
    ' _ "$(_folder_actions_lib_path)" 2>&1
  )

  [[ -z "$out" ]] || fail "source must not emit output, got: $out"
  [[ ! -e "$home/FolderActions" ]] || fail "source must not create FolderActions paths"
  [[ ! -e "$home/.config" ]] || fail "source must not create credential paths"
  [[ ! -e "$home/.local" ]] || fail "source must not create helper paths"
)

test_folder_actions_notify_failure_uses_pushover_helper_boundary() (
  local sandbox home helper cred log_file
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  helper="$home/.local/lib/pushover.sh"
  cred="$home/.config/pushover/folder-actions"
  log_file="$sandbox/pushover-send.log"

  mkdir -p "$(dirname "$helper")" "$(dirname "$cred")"
  : > "$cred"
  cat > "$helper" <<'EOF_HELPER'
pushover_send() {
  : "${PUSHOVER_SEND_LOG:?}"
  printf '%s\n' "$@" > "$PUSHOVER_SEND_LOG"
}
EOF_HELPER

  export HOME="$home"
  export WATCH_DIR="$home/FolderActions/compress-video"
  export CURRENT_PID="12345"
  export PUSHOVER_SEND_LOG="$log_file"
  _folder_actions_define_logger_stubs "$sandbox/events.log"
  # shellcheck source=/dev/null
  source "$(_folder_actions_lib_path)"

  notify_failure "FolderActions 실패" "처리 실패 격리: input.mov" 1

  assert_file_contains "$log_file" "$cred"
  assert_file_contains "$log_file" "FolderActions 실패"
  assert_file_contains "$log_file" "처리 실패 격리: input.mov"
  assert_file_contains "$log_file" "1"
)

test_folder_actions_drain_queue_processes_rescanned_files_in_order() (
  local sandbox home watch processed
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  watch="$home/FolderActions/compress-video"
  processed="$sandbox/processed.log"
  mkdir -p "$watch"
  printf '%s\n' "first" > "$watch/first.txt"

  export HOME="$home"
  export WATCH_DIR="$watch"
  export CURRENT_PID="12345"
  _folder_actions_define_logger_stubs "$sandbox/events.log"
  # shellcheck source=/dev/null
  source "$(_folder_actions_lib_path)"

  wait_file_stable() { return 0; }
  find_candidates() { find "$watch" -maxdepth 1 -type f | sort; }
  process_one() {
    local file="$1"
    local name
    name=$(basename "$file")
    printf '%s\n' "$name" >> "$processed"
    rm -f "$file"
    if [ "$name" = "first.txt" ]; then
      printf '%s\n' "second" > "$watch/second.txt"
    fi
  }

  drain_queue process_one

  assert_file_contains "$processed" "first.txt"
  assert_file_contains "$processed" "second.txt"
  [[ "$(cat "$processed")" = $'first.txt\nsecond.txt' ]] \
    || fail "expected FIFO processing with rescan, got: $(cat "$processed")"
  [[ -z "$(find "$watch" -maxdepth 1 -type f -print)" ]] \
    || fail "expected queue to be empty after stable processing"
)

test_folder_actions_drain_queue_defers_unstable_files() (
  local sandbox home watch processed events
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  watch="$home/FolderActions/rename-asset"
  processed="$sandbox/processed.log"
  events="$sandbox/events.log"
  mkdir -p "$watch"
  printf '%s\n' "stable" > "$watch/stable.txt"
  printf '%s\n' "unstable" > "$watch/unstable.txt"

  export HOME="$home"
  export WATCH_DIR="$watch"
  export CURRENT_PID="12345"
  _folder_actions_define_logger_stubs "$events"
  # shellcheck source=/dev/null
  source "$(_folder_actions_lib_path)"

  wait_file_stable() {
    [ "$(basename "$1")" != "unstable.txt" ]
  }
  find_candidates() { find "$watch" -maxdepth 1 -type f | sort; }
  process_one() {
    printf '%s\n' "$(basename "$1")" >> "$processed"
    rm -f "$1"
  }

  drain_queue process_one

  assert_file_contains "$processed" "stable.txt"
  [[ ! -e "$watch/stable.txt" ]] || fail "stable file must be processed"
  [[ -e "$watch/unstable.txt" ]] || fail "unstable file must remain for a later wakeup"
  assert_contains "$(cat "$events")" "WARN:unstable; deferred to next wakeup: unstable.txt"
  assert_contains "$(cat "$events")" "INFO:unstable 파일 1개 잔존; run 종료"
)

test_folder_actions_quarantine_or_abort_branches() (
  local sandbox home success_log fail_log rc
  sandbox=$(new_sandbox)
  home="$sandbox/home"
  success_log="$sandbox/quarantine-success.log"
  fail_log="$sandbox/quarantine-fail.log"

  export HOME="$home"
  export WATCH_DIR="$home/FolderActions/compress-rar"
  export CURRENT_PID="12345"
  _folder_actions_define_logger_stubs "$sandbox/events.log"
  # shellcheck source=/dev/null
  source "$(_folder_actions_lib_path)"

  move_to_failed() {
    printf '%s\n' "$1" >> "$success_log"
    return 0
  }
  quarantine_or_abort "$sandbox/input.rar"
  assert_file_contains "$success_log" "$sandbox/input.rar"

  set +e
  (
    set -euo pipefail
    export HOME="$home"
    export WATCH_DIR="$home/FolderActions/compress-rar"
    export CURRENT_PID="12345"
    log_info() { :; }
    log_warn() { :; }
    log_error() { printf 'ERROR:%s\n' "$*" >> "$fail_log"; }
    verify_path_security() { return 0; }
    # shellcheck source=/dev/null
    source "$(_folder_actions_lib_path)"
    move_to_failed() { return 1; }
    quarantine_or_abort "$sandbox/input.rar"
  )
  rc=$?
  set -e

  [[ "$rc" -eq 1 ]] || fail "quarantine_or_abort must exit 1 when move_to_failed fails (got $rc)"
  assert_contains "$(cat "$fail_log")" "ERROR:quarantine 실패; run 중단"
)

test_upload_immich_missing_credential_branch_is_quiet_or_skipped() (
  local required path sandbox home watch out rc
  required=(
    /usr/bin/id
    /usr/bin/stat
    /usr/bin/sed
    /usr/bin/grep
    /usr/bin/tr
    /bin/date
    /bin/ps
    /bin/mkdir
    /bin/rm
  )

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "==> upload-immich missing credentials: SKIPPED (macOS absolute command contract; runner=$(uname -s))" >&2
    return 0
  fi

  for path in "${required[@]}"; do
    if [ ! -x "$path" ]; then
      echo "==> upload-immich missing credentials: SKIPPED (missing $path before credential branch)" >&2
      return 0
    fi
  done

  if [ -e /tmp/upload-immich.lock.d ] || [ -e /tmp/upload-immich.lock ]; then
    echo "==> upload-immich missing credentials: SKIPPED (real lock path already exists)" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  home="$sandbox/home"
  watch="$home/FolderActions/upload-immich"
  mkdir -p "$watch"
  printf '%s\n' "image" > "$watch/photo.jpg"

  set +e
  out=$(HOME="$home" WATCH_DIR="$watch" bash "$(_upload_immich_script_path)" 2>&1)
  rc=$?
  set -e

  [[ "$rc" -eq 0 ]] || fail "upload-immich missing credential branch must exit 0 (got $rc): $out"
  assert_contains "$out" "자격증명 없음: $home/.config/immich/api-key"
  [[ -e "$watch/photo.jpg" ]] || fail "missing credentials must not delete media"
)
