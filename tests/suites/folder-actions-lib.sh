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
# - The rar/ffmpeg job e2e fixtures (#1402) are Darwin-only for the same reason.
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
    echo "N/A: upload-immich missing credentials uses a macOS absolute command contract (runner=$(uname -s))" >&2
    return 0
  fi

  for path in "${required[@]}"; do
    if [ ! -x "$path" ]; then
      echo "SKIP: upload-immich missing credentials requires $path before credential branch" >&2
      return 0
    fi
  done

  if [ -e /tmp/upload-immich.lock.d ] || [ -e /tmp/upload-immich.lock ]; then
    echo "SKIP: upload-immich missing credentials cannot run while the real lock path exists" >&2
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

# ── rar/ffmpeg 작업의 launchd 최소 환경 fixture (#1402) ──────────────────────
# launchd는 로그인 셸 PATH를 물려받지 않으므로 default.nix가 각 작업에 Nix 도구 bin과
# /usr/bin:/bin만 준다. 아래 fixture는 같은 모양의 PATH(도구 대역 디렉터리가 Nix bin 역할)로
# env -i 실행해 Homebrew 경로와 셸 초기화 없이 스크립트가 동작하는지 본다.

_folder_actions_tool_scripts_runnable() {
  local path

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "N/A: folder-actions rar/ffmpeg jobs use a macOS absolute command contract (runner=$(uname -s))" >&2
    return 1
  fi

  for path in /usr/bin/env /usr/bin/id /usr/bin/stat /usr/bin/sed /usr/bin/grep /usr/bin/tr \
    /usr/bin/hexdump /usr/bin/dirname /usr/bin/shasum /usr/bin/awk /usr/bin/wc \
    /bin/date /bin/ps /bin/kill /bin/ls /bin/mkdir /bin/chmod /bin/mv /bin/rm /bin/cat; do
    if [ ! -x "$path" ]; then
      echo "SKIP: folder-actions rar/ffmpeg fixture requires $path" >&2
      return 1
    fi
  done

  # 시스템 경로에 도구가 있으면 PATH에서 Nix bin을 빼도 부재를 재현할 수 없다.
  for path in /usr/bin/rar /bin/rar /usr/bin/ffmpeg /bin/ffmpeg; do
    if [ -e "$path" ]; then
      echo "SKIP: $path makes the missing-tool fixture unreachable" >&2
      return 1
    fi
  done
}

# 배포 레이아웃(~/.local/bin)에 작업 스크립트와 lib 사본을 둔다. 사본은 실제 /tmp 락 경로를
# sandbox로 옮기고, 입력 파일을 지우거나 격리하는 /bin/rm·/bin/mv를 호출을 기록한 뒤 원래
# 명령에 위임하는 대역으로 바꾼다. 나머지 절대경로 명령은 그대로 실행된다.
_folder_actions_install_tool_script() {
  local sandbox="$1" name="$2"
  local src bin stubs file cmd
  src="$REPO_ROOT/modules/darwin/programs/folder-actions/files/scripts"
  bin="$sandbox/home/.local/bin"
  stubs="$sandbox/stubs"
  mkdir -p "$bin" "$stubs" "$sandbox/tools" "$sandbox/lock" "$sandbox/home/Downloads" \
    "$sandbox/home/FolderActions/$name"

  for cmd in mv rm; do
    cat > "$stubs/$cmd" <<EOF_STUB
#!/bin/sh
{ printf '%s' '$cmd'; for arg in "\$@"; do printf '\t%s' "\$arg"; done; printf '\n'; } >> '$sandbox/calls.log'
exec /bin/$cmd "\$@"
EOF_STUB
    chmod 755 "$stubs/$cmd"
  done

  for file in "$name.sh" _folder-actions-lib.sh; do
    sed -e "s#/tmp/$name\\.lock#$sandbox/lock/$name.lock#g" \
      -e "s#/bin/mv #$stubs/mv #g" \
      -e "s#/bin/rm #$stubs/rm #g" \
      "$src/$file" > "$bin/$file"
    if grep -nE "/tmp/$name\\.lock|/bin/(mv|rm) " "$bin/$file" >&2; then
      fail "fixture copy of $file still reaches the real lock path or an unrecorded mv/rm"
    fi
  done
  chmod 700 "$bin/$name.sh"
}

# 도구 대역: 받은 PATH와 인자를 기록하고 입력을 출력 경로로 복사한다.
# rar a <옵션...> <archive> <input> / ffmpeg ... -i <input> ... <output>
_folder_actions_install_tool_double() {
  local sandbox="$1" tool="$2"
  local target="$sandbox/tools/$tool"

  cat > "$target" <<EOF_HEAD
#!/bin/sh
{ printf 'PATH=%s\n' "\$PATH"; for arg in "\$@"; do printf 'ARG=%s\n' "\$arg"; done; } >> '$sandbox/$tool.log'
EOF_HEAD
  case "$tool" in
    rar)
      cat >> "$target" <<'EOF_RAR'
archive=""
input=""
for arg in "$@"; do archive=$input; input=$arg; done
/bin/cat "$input" > "$archive"
EOF_RAR
      ;;
    ffmpeg)
      cat >> "$target" <<'EOF_FFMPEG'
input=""
output=""
next_is_input=0
for arg in "$@"; do
  if [ "$next_is_input" = 1 ]; then input=$arg; fi
  next_is_input=0
  if [ "$arg" = "-i" ]; then next_is_input=1; fi
  output=$arg
done
/bin/cat "$input" > "$output"
EOF_FFMPEG
      ;;
    *) fail "unknown folder-actions tool double: $tool" ;;
  esac
  chmod 755 "$target"
}

_folder_actions_run_tool_script() {
  local sandbox="$1" name="$2"
  env -i HOME="$sandbox/home" PATH="$sandbox/tools:/usr/bin:/bin" \
    "$sandbox/home/.local/bin/$name.sh"
}

# calls.log에서 <cmd> 호출 중 인자 하나가 정확히 <path>인 횟수
_folder_actions_count_calls_on() {
  local sandbox="$1" cmd="$2" path="$3"
  [ -f "$sandbox/calls.log" ] || { echo 0; return 0; }
  awk -F '\t' -v cmd="$cmd" -v path="$path" '
    $1 == cmd { for (i = 2; i <= NF; i++) if ($i == path) { n++; break } }
    END { print n + 0 }
  ' "$sandbox/calls.log"
}

test_folder_actions_tool_jobs_keep_input_when_required_tool_missing() (
  local entry name tool sandbox input out rc
  _folder_actions_tool_scripts_runnable || return 0

  for entry in compress-rar:rar compress-video:ffmpeg convert-video-to-gif:ffmpeg; do
    name="${entry%%:*}"
    tool="${entry##*:}"
    sandbox=$(new_sandbox)
    _folder_actions_install_tool_script "$sandbox" "$name"
    input="$sandbox/home/FolderActions/$name/sample.mov"
    printf '%s\n' "synthetic input" > "$input"

    # 도구 bin이 비어 있다 = launchd PATH에서 Nix 도구 경로가 빠진 상태
    set +e
    out=$(_folder_actions_run_tool_script "$sandbox" "$name" 2>&1)
    rc=$?
    set -e

    [[ "$rc" -eq 1 ]] || fail "$name must fail as an environment error without $tool (rc=$rc): $out"
    assert_contains "$out" "필수 실행파일 없음: $tool"
    assert_not_contains "$out" "압축 실패"
    assert_not_contains "$out" "변환 실패"
    assert_not_contains "$out" "격리"
    [[ "$(cat "$input")" == "synthetic input" ]] || fail "$name must leave the input untouched"
    [[ "$(_folder_actions_count_calls_on "$sandbox" mv "$input")" == 0 ]] \
      || fail "$name must not move the input: $(cat "$sandbox/calls.log")"
    [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$input")" == 0 ]] \
      || fail "$name must not delete the input: $(cat "$sandbox/calls.log")"
    [[ ! -e "$sandbox/home/FolderActions/.failed" ]] || fail "$name must not create the quarantine root"
    [[ -z "$(ls -A "$sandbox/home/Downloads")" ]] || fail "$name must not create outputs"
    [[ ! -e "$sandbox/lock/$name.lock.d" ]] || fail "$name must release its lock"
  done
)

test_folder_actions_compress_rar_runs_with_launchd_minimal_path() (
  local sandbox input archive guide expected actual sum
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  input="$sandbox/home/FolderActions/compress-rar/sample.txt"
  archive="$sandbox/home/Downloads/sample/sample.rar"
  guide="$sandbox/home/Downloads/sample/데이터_무결성_검증방법.txt"
  printf '%s\n' "synthetic archive input" > "$input"

  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "compress-rar must succeed with rar on the launchd PATH"

  # 스크립트가 PATH 앞에 다른 경로를 끼우면 선언한 도구가 가려진다.
  assert_file_contains "$sandbox/rar.log" "PATH=$sandbox/tools:/usr/bin:/bin"
  expected=$(printf 'ARG=%s\n' a -rr10% -ma5 -ep1 -idq "$archive" "$input")
  actual=$(grep '^ARG=' "$sandbox/rar.log")
  [[ "$actual" == "$expected" ]] || fail "rar arguments changed: $actual"
  [[ "$(cat "$archive")" == "synthetic archive input" ]] || fail "expected archive at $archive"
  sum=$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')
  assert_file_contains "$guide" "$sum"
  [[ ! -e "$input" ]] || fail "compress-rar must remove the original after success"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$input")" == 1 ]] \
    || fail "compress-rar must delete the original exactly once: $(cat "$sandbox/calls.log")"
  [[ "$(_folder_actions_count_calls_on "$sandbox" mv "$input")" == 0 ]] \
    || fail "compress-rar must not quarantine a successful input"
)

test_folder_actions_video_jobs_run_with_launchd_minimal_path() (
  local name sandbox input output outputs expected actual
  _folder_actions_tool_scripts_runnable || return 0

  for name in compress-video convert-video-to-gif; do
    sandbox=$(new_sandbox)
    _folder_actions_install_tool_script "$sandbox" "$name"
    _folder_actions_install_tool_double "$sandbox" ffmpeg
    input="$sandbox/home/FolderActions/$name/sample.mov"
    printf '%s\n' "synthetic video input" > "$input"

    _folder_actions_run_tool_script "$sandbox" "$name" >/dev/null 2>&1 \
      || fail "$name must succeed with ffmpeg on the launchd PATH"

    outputs=("$sandbox"/home/Downloads/*)
    [[ "${#outputs[@]}" -eq 1 && -f "${outputs[0]}" ]] \
      || fail "$name must create exactly one output: ${outputs[*]}"
    output="${outputs[0]}"
    assert_file_contains "$sandbox/ffmpeg.log" "PATH=$sandbox/tools:/usr/bin:/bin"
    if [ "$name" = compress-video ]; then
      [[ "$output" == *.mp4 ]] || fail "compress-video output must be mp4: $output"
      expected=$(printf 'ARG=%s\n' -nostdin -hide_banner -loglevel error -i "$input" \
        -c:v hevc_videotoolbox -q:v 1 -tag:v hvc1 -c:a eac3 -b:a 224k -y "$output")
    else
      [[ "$output" == *.gif ]] || fail "convert-video-to-gif output must be gif: $output"
      expected=$(printf 'ARG=%s\n' -nostdin -hide_banner -loglevel error -y -i "$input" \
        -vf "fps=15,scale=480:-1:flags=lanczos" -c:v gif -f gif "$output")
    fi
    actual=$(grep '^ARG=' "$sandbox/ffmpeg.log")
    [[ "$actual" == "$expected" ]] || fail "$name ffmpeg arguments changed: $actual"
    [[ "$(cat "$output")" == "synthetic video input" ]] || fail "$name output must come from ffmpeg"
    [[ ! -e "$input" ]] || fail "$name must remove the original after success"
    [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$input")" == 1 ]] \
      || fail "$name must delete the original exactly once: $(cat "$sandbox/calls.log")"
    [[ "$(_folder_actions_count_calls_on "$sandbox" mv "$input")" == 0 ]] \
      || fail "$name must not quarantine a successful input"
  done
)
