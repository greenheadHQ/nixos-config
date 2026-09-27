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
# - require_commands_or_abort: command -v, basename, log_error, notify_failure,
#   exit 1 when a required command is missing.
#
# Linux/NixOS exclusion list:
# - ensure_failed_dir, move_to_failed, and wait_file_stable are not exercised
#   directly here because the implementation hard-codes macOS absolute command
#   paths that are absent on the Linux/NixOS runner (/bin/mkdir, /bin/chmod,
#   /bin/date, /bin/mv, /usr/bin/stat). drain_queue and quarantine_or_abort are
#   still covered by overriding those callback boundaries after sourcing.
# - upload-immich.sh missing-credential e2e is skipped when those macOS absolute
#   commands are absent before the credential branch.
# - The rar/ffmpeg job e2e fixtures (#1402, #1403) are Darwin-only for the same reason.
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
    /bin/date /bin/ps /bin/kill /bin/ls /bin/mkdir /bin/rmdir /bin/chmod /bin/mv /bin/rm /bin/cat; do
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

# ── compress-rar 결과 이름 예약 (#1403) ──────────────────────────────────────
# 같은 stem의 입력이 다시 들어오면 앞선 결과를 갱신하지 않고 <stem>_2, <stem>_3 … 폴더를 새로 쓴다.
# 대역 rar는 입력을 출력 경로로 통째로 복사하므로, 같은 경로에 다시 쓰면 앞선 보관본이 바뀐다.

# <dir> 아래 항목의 종류·경로·내용 해시 목록. 실행 전후를 비교해 기존 결과가 그대로인지 본다.
_folder_actions_tree_digest() {
  local root="$1" path
  (cd "$root" && find . | LC_ALL=C sort) | while IFS= read -r path; do
    if [ -L "$root/$path" ]; then
      printf 'L %s -> %s\n' "$path" "$(readlink "$root/$path")"
    elif [ -f "$root/$path" ]; then
      printf 'F %s %s\n' "$path" "$(/usr/bin/shasum -a 256 < "$root/$path" | /usr/bin/awk '{print $1}')"
    else
      printf 'D %s\n' "$path"
    fi
  done
}

# Downloads/<name>/<name>.rar가 <content>를 담고, 안내 파일이 그 이름과 체크섬을 가리키는지 본다.
_folder_actions_assert_rar_output() {
  local sandbox="$1" name="$2" content="$3"
  local dir="$sandbox/home/Downloads/$name" guide sum
  guide="$dir/데이터_무결성_검증방법.txt"
  [[ -f "$dir/$name.rar" ]] || fail "expected archive at $dir/$name.rar"
  [[ "$(cat "$dir/$name.rar")" == "$content" ]] || fail "$dir/$name.rar must hold: $content"
  sum=$(/usr/bin/shasum -a 256 "$dir/$name.rar" | /usr/bin/awk '{print $1}')
  assert_file_contains "$guide" "$sum"
  assert_file_contains "$guide" "파일명: $name.rar"
  assert_file_contains "$guide" "\$ shasum -a 256 \"$name.rar\""
}

# compress-rar가 실패 격리한 <name>이 하나이고 <content>를 담는지 본다.
_folder_actions_assert_quarantined() {
  local sandbox="$1" name="$2" content="$3"
  local -a found
  found=("$sandbox"/home/FolderActions/.failed/compress-rar/*_"$name")
  [[ "${#found[@]}" -eq 1 && -f "${found[0]}" ]] || fail "expected one quarantined $name: ${found[*]}"
  [[ "$(cat "${found[0]}")" == "$content" ]] || fail "quarantined $name must keep the input bytes"
}

test_folder_actions_compress_rar_keeps_earlier_archive_for_same_name() (
  local sandbox watch downloads first_result
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"

  printf '%s\n' "first version" > "$watch/sample.txt"
  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "first compress-rar run must succeed"
  _folder_actions_assert_rar_output "$sandbox" sample "first version"
  first_result=$(_folder_actions_tree_digest "$downloads/sample")

  printf '%s\n' "second version" > "$watch/sample.txt"
  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "second compress-rar run must succeed"

  # 같은 보관본에 다시 rar a를 하면 앞선 버전을 복원할 수 없다.
  assert_line_count "$sandbox/rar.log" "ARG=$downloads/sample/sample.rar" 1
  [[ "$(_folder_actions_tree_digest "$downloads/sample")" == "$first_result" ]] \
    || fail "second run must leave the first result untouched"
  _folder_actions_assert_rar_output "$sandbox" sample_2 "second version"
  [[ ! -e "$watch/sample.txt" ]] || fail "second input must be removed once its own archive exists"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/sample.txt")" == 2 ]] \
    || fail "each run must delete its own input exactly once: $(cat "$sandbox/calls.log")"
)

test_folder_actions_compress_rar_separates_same_stem_inputs() (
  local sandbox watch downloads first second
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
  printf '%s\n' "text input" > "$watch/sample.txt"
  printf '%s\n' "csv input" > "$watch/sample.csv"

  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "compress-rar must succeed for inputs sharing a stem"

  # 처리 순서는 find 순서를 따르므로 고정하지 않는다. 두 보관본이 입력을 하나씩 담으면 된다.
  [[ -f "$downloads/sample/sample.rar" && -f "$downloads/sample_2/sample_2.rar" ]] \
    || fail "each same-stem input needs its own archive: $(cat "$sandbox/rar.log")"
  first=$(cat "$downloads/sample/sample.rar")
  second=$(cat "$downloads/sample_2/sample_2.rar")
  [[ "$(printf '%s\n' "$first" "$second" | LC_ALL=C sort)" == "$(printf '%s\n' "csv input" "text input")" ]] \
    || fail "archives must hold one input each (got: $first / $second)"
  _folder_actions_assert_rar_output "$sandbox" sample "$first"
  _folder_actions_assert_rar_output "$sandbox" sample_2 "$second"
  assert_line_count "$sandbox/rar.log" "ARG=$downloads/sample/sample.rar" 1
  assert_line_count "$sandbox/rar.log" "ARG=$downloads/sample_2/sample_2.rar" 1
  [[ ! -e "$watch/sample.txt" && ! -e "$watch/sample.csv" ]] || fail "both inputs must be removed after success"
)

test_folder_actions_compress_rar_skips_existing_output_entries() (
  local sandbox watch downloads earlier
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"

  # 앞선 결과 폴더, 같은 이름의 일반 파일, 끊어진 심볼릭 링크가 이미 이름을 차지하고 있다.
  mkdir "$downloads/sample"
  printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
  printf '%s\n' "earlier guide" > "$downloads/sample/데이터_무결성_검증방법.txt"
  printf '%s\n' "user note" > "$downloads/sample/note.txt"
  printf '%s\n' "user file" > "$downloads/sample_2"
  ln -s "$sandbox/missing" "$downloads/sample_3"
  earlier=$(_folder_actions_tree_digest "$downloads")
  printf '%s\n' "new input" > "$watch/sample.txt"

  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "compress-rar must succeed when earlier names are taken"

  _folder_actions_assert_rar_output "$sandbox" sample_4 "new input"
  [[ "$(_folder_actions_tree_digest "$downloads" | grep -v '^[DF] \./sample_4')" == "$earlier" ]] \
    || fail "existing Downloads entries must stay untouched: $(cat "$sandbox/rar.log")"
  [[ ! -e "$sandbox/missing" ]] || fail "must not create anything through a dangling symlink"
  [[ ! -e "$watch/sample.txt" ]] || fail "input must be removed after success"
)

test_folder_actions_compress_rar_reserves_output_name_atomically() (
  local sandbox bin stubs watch downloads contested
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  bin="$sandbox/home/.local/bin"
  stubs="$sandbox/stubs"
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
  contested="$downloads/sample"

  # 경쟁 실행 흉내: 이 작업이 처음으로 <contested>를 만들려는 mkdir 직전에 다른 실행이 같은 이름을
  # 먼저 차지한다. 비어 있는지 확인하는 단계와 확보하는 단계가 나뉘어 있으면 남의 결과 폴더에 쓰게 된다.
  cat > "$stubs/mkdir" <<EOF_STUB
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = '$contested' ] && [ ! -e '$sandbox/contested.flag' ]; then
    : > '$sandbox/contested.flag'
    /bin/mkdir '$contested' && printf '%s\n' 'other run' > '$contested/owner.txt'
  fi
done
exec /bin/mkdir "\$@"
EOF_STUB
  chmod 755 "$stubs/mkdir"
  sed -e "s#/bin/mkdir #$stubs/mkdir #g" "$bin/compress-rar.sh" > "$bin/compress-rar.sh.new"
  mv "$bin/compress-rar.sh.new" "$bin/compress-rar.sh"
  chmod 700 "$bin/compress-rar.sh"
  printf '%s\n' "new input" > "$watch/sample.txt"

  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "compress-rar must move on when another run takes the name first"

  [[ -e "$sandbox/contested.flag" ]] || fail "the competing reservation must have fired"
  [[ "$(ls -A "$contested")" == "owner.txt" && "$(cat "$contested/owner.txt")" == "other run" ]] \
    || fail "must not write into a name another run reserved: $(ls -A "$contested")"
  _folder_actions_assert_rar_output "$sandbox" sample_2 "new input"
)

test_folder_actions_compress_rar_keeps_input_when_output_reservation_fails() (
  local sandbox watch downloads earlier out rc
  _folder_actions_tool_scripts_runnable || return 0
  if [ "$(id -u)" = 0 ]; then
    echo "SKIP: root ignores the read-only Downloads used to fail the reservation" >&2
    return 0
  fi

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
  mkdir "$downloads/sample"
  printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
  printf '%s\n' "earlier guide" > "$downloads/sample/데이터_무결성_검증방법.txt"
  earlier=$(_folder_actions_tree_digest "$downloads")
  printf '%s\n' "new input" > "$watch/sample.txt"

  # Downloads에 새 항목을 만들 수 없으면 다음 번호도 확보할 수 없다. 앞선 결과 폴더 자체는 쓸 수 있다.
  chmod 555 "$downloads"
  trap 'chmod 755 "$downloads"' EXIT
  set +e
  out=$(_folder_actions_run_tool_script "$sandbox" compress-rar 2>&1)
  rc=$?
  set -e
  chmod 755 "$downloads"

  # 앞선 결과와 새 입력이 모두 남아야 한다.
  [[ "$(_folder_actions_tree_digest "$downloads")" == "$earlier" ]] \
    || fail "existing results must stay untouched: $(_folder_actions_tree_digest "$downloads")"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/sample.txt")" == 0 ]] \
    || fail "must not delete the input: $(cat "$sandbox/calls.log")"
  _folder_actions_assert_quarantined "$sandbox" sample.txt "new input"
  [[ ! -e "$sandbox/rar.log" ]] || fail "rar must not run without a reserved output: $(cat "$sandbox/rar.log")"
  [[ "$rc" -eq 0 ]] || fail "a quarantined reservation failure must not abort the run (rc=$rc): $out"
  assert_contains "$out" "결과 폴더 예약 실패: sample.txt"
)

test_folder_actions_compress_rar_keeps_input_when_rar_fails() (
  local sandbox watch downloads earlier out rc
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
  # 출력 경로에 부분 결과를 남기고 실패하는 rar
  cat > "$sandbox/tools/rar" <<EOF_RAR
#!/bin/sh
for arg in "\$@"; do printf 'ARG=%s\n' "\$arg"; done >> '$sandbox/rar.log'
archive=""
input=""
for arg in "\$@"; do archive=\$input; input=\$arg; done
printf '%s\n' partial > "\$archive"
exit 1
EOF_RAR
  chmod 755 "$sandbox/tools/rar"
  mkdir "$downloads/sample"
  printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
  printf '%s\n' "earlier guide" > "$downloads/sample/데이터_무결성_검증방법.txt"
  earlier=$(_folder_actions_tree_digest "$downloads")
  printf '%s\n' "new input" > "$watch/sample.txt"

  set +e
  out=$(_folder_actions_run_tool_script "$sandbox" compress-rar 2>&1)
  rc=$?
  set -e

  # 새로 예약한 경로에만 썼고, 그 폴더는 부분 결과와 함께 치워 앞선 결과만 남는다.
  [[ "$(_folder_actions_tree_digest "$downloads")" == "$earlier" ]] \
    || fail "failed run must leave only the earlier results: $(_folder_actions_tree_digest "$downloads")"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/sample.txt")" == 0 ]] \
    || fail "must not delete the input: $(cat "$sandbox/calls.log")"
  _folder_actions_assert_quarantined "$sandbox" sample.txt "new input"
  assert_line_count "$sandbox/rar.log" "ARG=$downloads/sample_2/sample_2.rar" 1
  [[ "$rc" -eq 0 ]] || fail "a quarantined rar failure must not abort the run (rc=$rc): $out"
  assert_contains "$out" "압축 실패: sample.txt"
)
