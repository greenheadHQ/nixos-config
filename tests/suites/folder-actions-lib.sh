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
# - The rar/ffmpeg job e2e fixtures (#1402, #1403) and the upload-immich result
#   fixtures (#1401) are Darwin-only for the same reason.
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
  assert_file_contains "$guide" "> Get-FileHash \"$name.rar\" -Algorithm SHA256"
}

# compress-rar가 실패 격리한 <name>이 하나이고 <content>를 담는지 본다.
_folder_actions_assert_quarantined() {
  local sandbox="$1" name="$2" content="$3"
  local -a found
  found=("$sandbox"/home/FolderActions/.failed/compress-rar/*_"$name")
  [[ "${#found[@]}" -eq 1 && -f "${found[0]}" ]] || fail "expected one quarantined $name: ${found[*]}"
  [[ "$(cat "${found[0]}")" == "$content" ]] || fail "quarantined $name must keep the input bytes"
}

# 작업 스크립트 사본의 /bin/mkdir 호출을 <sandbox>/stubs/mkdir로 돌린다. 대역 내용은 테스트가 쓴다.
_folder_actions_route_mkdir_through_stub() {
  local sandbox="$1"
  local bin="$sandbox/home/.local/bin"
  sed -e "s#/bin/mkdir #$sandbox/stubs/mkdir #g" "$bin/compress-rar.sh" > "$bin/compress-rar.sh.new"
  mv "$bin/compress-rar.sh.new" "$bin/compress-rar.sh"
  chmod 700 "$bin/compress-rar.sh"
  grep -q "$sandbox/stubs/mkdir " "$bin/compress-rar.sh" || fail "fixture copy must route mkdir through the stub"
}

# Pushover 경계 대역: credential을 두고, 보낸 알림의 제목과 본문을 notify.log에 한 줄씩 남긴다.
_folder_actions_install_notify_double() {
  local sandbox="$1"
  mkdir -p "$sandbox/home/.config/pushover" "$sandbox/home/.local/lib"
  printf '%s\n' "test credential" > "$sandbox/home/.config/pushover/folder-actions"
  cat > "$sandbox/home/.local/lib/pushover.sh" <<EOF_NOTIFY
pushover_send() {
  printf '%s\\t%s\\n' "\$2" "\$(printf '%s' "\$3" | tr '\\n' ' ')" >> '$sandbox/notify.log'
}
EOF_NOTIFY
}

# 출력 경로에 부분 결과를 남기고 실패하는 rar. <extra>를 주면 같은 폴더에 그 이름의 파일도 남긴다.
_folder_actions_install_failing_rar() {
  local sandbox="$1" extra="${2:-}"
  cat > "$sandbox/tools/rar" <<EOF_RAR
#!/bin/sh
for arg in "\$@"; do printf 'ARG=%s\n' "\$arg"; done >> '$sandbox/rar.log'
archive=""
input=""
for arg in "\$@"; do archive=\$input; input=\$arg; done
printf '%s\n' partial > "\$archive"
if [ -n '$extra' ]; then printf '%s\n' leftover > "\$(dirname "\$archive")/$extra"; fi
exit 1
EOF_RAR
  chmod 755 "$sandbox/tools/rar"
}

# 작업 스크립트를 <limit>초 안에서만 돌리고 rc를 낸다. 시간을 넘기면 죽이고 124를 낸다.
# 예약 루프가 끝나지 않는 결함이 테스트를 멈추지 않고 실패로 드러나게 한다.
_folder_actions_run_tool_script_bounded() {
  local sandbox="$1" name="$2" limit="$3" out="$4"
  local pid ticks=0 rc=0
  env -i HOME="$sandbox/home" PATH="$sandbox/tools:/usr/bin:/bin" \
    "$sandbox/home/.local/bin/$name.sh" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((limit * 10)) ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      echo 124
      return 0
    fi
    sleep 0.1
    ticks=$((ticks + 1))
  done
  wait "$pid" || rc=$?
  echo "$rc"
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
  local sandbox watch downloads contested
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
  contested="$downloads/sample"

  # 경쟁 실행 흉내: 이 작업이 처음으로 <contested>를 만들려는 mkdir 직전에 다른 실행이 같은 이름을
  # 먼저 차지한다. 비어 있는지 확인하는 단계와 확보하는 단계가 나뉘어 있으면 남의 결과 폴더에 쓰게 된다.
  cat > "$sandbox/stubs/mkdir" <<EOF_STUB
#!/bin/sh
for arg in "\$@"; do
  if [ "\$arg" = '$contested' ] && [ ! -e '$sandbox/contested.flag' ]; then
    : > '$sandbox/contested.flag'
    /bin/mkdir '$contested' && printf '%s\n' 'other run' > '$contested/owner.txt'
  fi
done
exec /bin/mkdir "\$@"
EOF_STUB
  chmod 755 "$sandbox/stubs/mkdir"
  _folder_actions_route_mkdir_through_stub "$sandbox"
  printf '%s\n' "new input" > "$watch/sample.txt"

  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "compress-rar must move on when another run takes the name first"

  [[ -e "$sandbox/contested.flag" ]] || fail "the competing reservation must have fired"
  [[ "$(ls -A "$contested")" == "owner.txt" && "$(cat "$contested/owner.txt")" == "other run" ]] \
    || fail "must not write into a name another run reserved: $(ls -A "$contested")"
  _folder_actions_assert_rar_output "$sandbox" sample_2 "new input"
)

# ~/Downloads가 아예 없으면 예약 전에 만든다(예약 도입 전 mkdir -p가 하던 동작).
test_folder_actions_compress_rar_creates_missing_downloads() (
  local sandbox watch
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_tool_double "$sandbox" rar
  watch="$sandbox/home/FolderActions/compress-rar"
  rmdir "$sandbox/home/Downloads"
  printf '%s\n' "new input" > "$watch/sample.txt"

  _folder_actions_run_tool_script "$sandbox" compress-rar >/dev/null 2>&1 \
    || fail "compress-rar must recreate a missing Downloads"
  _folder_actions_assert_rar_output "$sandbox" sample "new input"
  [[ ! -e "$watch/sample.txt" ]] || fail "input must be removed after success"
)

# ~/Downloads에 새 폴더를 만들 수 없는 것은 입력 결함이 아니라 환경 오류다. 입력을 격리하지 않고
# watch dir에 둔 채 알림 한 번과 함께 run을 멈춘다 (#1402의 도구 부재와 같은 처리).
# rejects는 -w가 참인데도 생성이 거부되는 경우(TCC, 용량 부족 등)를 mkdir 대역으로 흉내 낸다.
test_folder_actions_compress_rar_stops_run_when_downloads_unusable() (
  local kind sandbox watch downloads earlier out rc input
  _folder_actions_tool_scripts_runnable || return 0

  for kind in unwritable file dangling rejects; do
    if [ "$kind" = unwritable ] && [ "$(id -u)" = 0 ]; then
      echo "SKIP: root ignores the read-only Downloads case" >&2
      continue
    fi
    sandbox=$(new_sandbox)
    _folder_actions_install_tool_script "$sandbox" compress-rar
    _folder_actions_install_tool_double "$sandbox" rar
    _folder_actions_install_notify_double "$sandbox"
    watch="$sandbox/home/FolderActions/compress-rar"
    downloads="$sandbox/home/Downloads"
    case "$kind" in
      unwritable)
        mkdir "$downloads/sample"
        printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
        printf '%s\n' "earlier guide" > "$downloads/sample/데이터_무결성_검증방법.txt"
        ;;
      file)
        rmdir "$downloads"
        printf '%s\n' "not a directory" > "$downloads"
        ;;
      dangling)
        rmdir "$downloads"
        ln -s "$sandbox/missing-downloads" "$downloads"
        ;;
      rejects)
        mkdir "$downloads/sample"
        printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
        cat > "$sandbox/stubs/mkdir" <<EOF_STUB
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    '$downloads'/*) echo "mkdir: \$arg: Operation not permitted" >&2; exit 1 ;;
  esac
done
exec /bin/mkdir "\$@"
EOF_STUB
        chmod 755 "$sandbox/stubs/mkdir"
        _folder_actions_route_mkdir_through_stub "$sandbox"
        ;;
    esac
    earlier=$(_folder_actions_tree_digest "$sandbox/home" | grep -E '^[DFL] \./Downloads([ /]|$)')
    printf '%s\n' "new input" > "$watch/sample.txt"
    printf '%s\n' "other input" > "$watch/other.txt"

    [ "$kind" = unwritable ] && chmod 555 "$downloads"
    trap '[ -d "$downloads" ] && [ ! -L "$downloads" ] && chmod 755 "$downloads"' EXIT
    rc=$(_folder_actions_run_tool_script_bounded "$sandbox" compress-rar 60 "$sandbox/out.log")
    [ "$kind" = unwritable ] && chmod 755 "$downloads"
    out=$(cat "$sandbox/out.log")

    [[ "$rc" -eq 1 ]] || fail "$kind: unusable Downloads must stop the run (rc=$rc): $out"
    for input in sample.txt other.txt; do
      [[ -f "$watch/$input" ]] || fail "$kind: $input must stay in the watch dir"
      [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/$input")" == 0 ]] \
        || fail "$kind: must not delete $input: $(cat "$sandbox/calls.log")"
      [[ "$(_folder_actions_count_calls_on "$sandbox" mv "$watch/$input")" == 0 ]] \
        || fail "$kind: must not quarantine $input: $(cat "$sandbox/calls.log")"
    done
    [[ "$(cat "$watch/sample.txt")" == "new input" ]] || fail "$kind: input bytes must stay"
    [[ ! -e "$sandbox/home/FolderActions/.failed" ]] || fail "$kind: must not create the quarantine root"
    [[ ! -e "$sandbox/rar.log" ]] || fail "$kind: rar must not run: $(cat "$sandbox/rar.log")"
    [[ "$(_folder_actions_tree_digest "$sandbox/home" | grep -E '^[DFL] \./Downloads([ /]|$)')" == "$earlier" ]] \
      || fail "$kind: Downloads must stay as it was"
    [[ ! -e "$sandbox/missing-downloads" ]] || fail "$kind: must not create a dangling Downloads target"
    assert_contains "$out" "환경 오류: 결과 폴더 위치에 쓸 수 없음: $downloads"
    [[ "$(wc -l < "$sandbox/notify.log" | tr -d ' ')" == 1 ]] \
      || fail "$kind: expected exactly one notification: $(cat "$sandbox/notify.log")"
    assert_contains "$(cat "$sandbox/notify.log")" "FolderActions 환경 오류"
    [[ ! -e "$sandbox/lock/compress-rar.lock.d" ]] || fail "$kind: lock must be released"
  done
)

# 쓸 수 있는 Downloads에서 이 이름만 만들 수 없으면(이름 길이 초과 등) 그 입력만 격리한다.
# 이름 문제인지는 탐침 폴더를 만들어 보고 가린다. collide는 탐침 이름이 이미 있는 경우,
# unremovable은 탐침을 지우지 못하는 경우다. 어느 쪽이든 남의 항목을 건드리지 않고 격리로 끝나야 한다.
test_folder_actions_compress_rar_quarantines_input_when_name_cannot_be_reserved() (
  local mode sandbox watch downloads earlier out rc entry
  local -a probes
  _folder_actions_tool_scripts_runnable || return 0

  for mode in plain collide unremovable; do
    sandbox=$(new_sandbox)
    _folder_actions_install_tool_script "$sandbox" compress-rar
    _folder_actions_install_tool_double "$sandbox" rar
    _folder_actions_install_notify_double "$sandbox"
    watch="$sandbox/home/FolderActions/compress-rar"
    downloads="$sandbox/home/Downloads"
    mkdir "$downloads/sample"
    printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
    printf '%s\n' "earlier guide" > "$downloads/sample/데이터_무결성_검증방법.txt"
    earlier=$(_folder_actions_tree_digest "$downloads")
    printf '%s\n' "new input" > "$watch/sample.txt"

    # 번호 붙은 이름은 모두 ENAMETOOLONG처럼 만들어지지 않는다. 실패를 곧바로 다음 번호로 넘기는
    # 루프는 끝나지 않으므로 시간 제한으로 실패시킨다.
    cat > "$sandbox/stubs/mkdir" <<EOF_STUB
#!/bin/sh
for arg in "\$@"; do
  case "\$arg" in
    '$downloads'/sample_*) echo "mkdir: \$arg: File name too long" >&2; exit 1 ;;
    '$downloads'/.compress-rar-probe.*)
      if [ '$mode' = collide ] && [ ! -e '$sandbox/probe.flag' ]; then
        : > '$sandbox/probe.flag'
        /bin/mkdir "\$arg" && printf '%s\n' foreign > "\$arg/owner.txt"
      elif [ '$mode' = unremovable ]; then
        /bin/mkdir "\$@" || exit 1
        printf '%s\n' held > "\$arg/held.txt"
        exit 0
      fi
      ;;
  esac
done
exec /bin/mkdir "\$@"
EOF_STUB
    chmod 755 "$sandbox/stubs/mkdir"
    _folder_actions_route_mkdir_through_stub "$sandbox"

    rc=$(_folder_actions_run_tool_script_bounded "$sandbox" compress-rar 60 "$sandbox/out.log")
    out=$(cat "$sandbox/out.log")

    [[ "$rc" -ne 124 ]] || fail "$mode: reservation must stop at a name it cannot create (timed out)"
    [[ "$(_folder_actions_tree_digest "$downloads" | grep -v '^[DF] \./\.compress-rar-probe\.')" == "$earlier" ]] \
      || fail "$mode: existing results must stay untouched: $(_folder_actions_tree_digest "$downloads")"
    [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/sample.txt")" == 0 ]] \
      || fail "$mode: must not delete the input: $(cat "$sandbox/calls.log")"
    _folder_actions_assert_quarantined "$sandbox" sample.txt "new input"
    [[ ! -e "$sandbox/rar.log" ]] || fail "$mode: rar must not run without a reserved output: $(cat "$sandbox/rar.log")"
    [[ "$rc" -eq 0 ]] || fail "$mode: a quarantined name failure must not abort the run (rc=$rc): $out"
    assert_contains "$out" "결과 폴더를 만들 수 없음: $downloads/sample_2"
    assert_contains "$out" "결과 폴더 예약 실패: sample.txt"
    assert_contains "$(cat "$sandbox/notify.log")" "FolderActions 실패"
    assert_not_contains "$(cat "$sandbox/notify.log")" "환경 오류"

    probes=()
    for entry in "$downloads"/.compress-rar-probe.*; do
      if [ -e "$entry" ] || [ -L "$entry" ]; then probes+=("$entry"); fi
    done
    case "$mode" in
      plain)
        [[ "${#probes[@]}" -eq 0 ]] || fail "plain: the probe must be removed: ${probes[*]}"
        ;;
      collide)
        [[ -e "$sandbox/probe.flag" ]] || fail "collide: the probe name collision must have fired"
        [[ "${#probes[@]}" -eq 1 ]] || fail "collide: only the foreign entry may remain: ${probes[*]:-}"
        [[ "$(ls -A "${probes[0]}")" == "owner.txt" && "$(cat "${probes[0]}/owner.txt")" == "foreign" ]] \
          || fail "collide: the foreign entry must stay untouched"
        ;;
      unremovable)
        [[ "${#probes[@]}" -eq 1 ]] || fail "unremovable: the probe that could not be removed must stay: ${probes[*]:-}"
        [[ "$(cat "${probes[0]}/held.txt")" == "held" ]] || fail "unremovable: probe contents must stay"
        assert_contains "$out" "탐침 폴더를 지우지 못함: ${probes[0]}"
        ;;
    esac
  done
)

test_folder_actions_compress_rar_keeps_input_when_rar_fails() (
  local sandbox watch downloads earlier out rc
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  _folder_actions_install_failing_rar "$sandbox"
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
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

test_folder_actions_compress_rar_keeps_reserved_dir_with_other_entries_after_rar_failure() (
  local sandbox watch downloads out
  _folder_actions_tool_scripts_runnable || return 0

  sandbox=$(new_sandbox)
  _folder_actions_install_tool_script "$sandbox" compress-rar
  # rar가 부분 보관본 말고도 다른 파일을 남기면 예약 폴더는 비지 않으므로 지우지 않는다.
  _folder_actions_install_failing_rar "$sandbox" leftover.tmp
  watch="$sandbox/home/FolderActions/compress-rar"
  downloads="$sandbox/home/Downloads"
  printf '%s\n' "new input" > "$watch/sample.txt"

  out=$(_folder_actions_run_tool_script "$sandbox" compress-rar 2>&1) \
    || fail "a quarantined rar failure must not abort the run: $out"

  [[ "$(ls -A "$downloads/sample")" == "leftover.tmp" ]] \
    || fail "reserved dir must keep other entries and lose only the partial archive: $(ls -A "$downloads/sample" 2>&1)"
  [[ "$(cat "$downloads/sample/leftover.tmp")" == "leftover" ]] || fail "other entries must keep their bytes"
  assert_contains "$out" "예약한 결과 폴더를 비우지 못함: $downloads/sample"
  _folder_actions_assert_quarantined "$sandbox" sample.txt "new input"
)

# 압축 도중 신호로 멈추면 예약 폴더는 비어 있을 때만 치우고, 부분 결과가 있으면 남긴다.
# 입력은 지우지도 격리하지도 않고 watch dir에 둔다.
test_folder_actions_compress_rar_signal_removes_only_empty_reserved_dir() (
  local mode sandbox watch downloads earlier pid ticks rc out
  _folder_actions_tool_scripts_runnable || return 0

  for mode in empty partial; do
    sandbox=$(new_sandbox)
    _folder_actions_install_tool_script "$sandbox" compress-rar
    watch="$sandbox/home/FolderActions/compress-rar"
    downloads="$sandbox/home/Downloads"
    # 압축을 시작한 뒤 release 파일이 생길 때까지 머무는 rar. partial이면 부분 결과를 먼저 남긴다.
    cat > "$sandbox/tools/rar" <<EOF_RAR
#!/bin/sh
archive=""
input=""
for arg in "\$@"; do archive=\$input; input=\$arg; done
if [ '$mode' = partial ]; then printf '%s\n' partial > "\$archive"; fi
: > '$sandbox/rar.started'
i=0
while [ ! -e '$sandbox/rar.release' ] && [ "\$i" -lt 300 ]; do sleep 0.1; i=\$((i + 1)); done
exit 1
EOF_RAR
    chmod 755 "$sandbox/tools/rar"
    mkdir "$downloads/sample"
    printf '%s\n' "earlier archive" > "$downloads/sample/sample.rar"
    earlier=$(_folder_actions_tree_digest "$downloads/sample")
    printf '%s\n' "new input" > "$watch/sample.txt"

    env -i HOME="$sandbox/home" PATH="$sandbox/tools:/usr/bin:/bin" \
      "$sandbox/home/.local/bin/compress-rar.sh" > "$sandbox/out.log" 2>&1 &
    pid=$!
    ticks=0
    while [ ! -e "$sandbox/rar.started" ] && [ "$ticks" -lt 300 ]; do
      sleep 0.1
      ticks=$((ticks + 1))
    done
    if [ ! -e "$sandbox/rar.started" ]; then
      kill -KILL "$pid" 2>/dev/null || true
      fail "$mode: rar double never started: $(cat "$sandbox/out.log")"
    fi
    kill -TERM "$pid"
    : > "$sandbox/rar.release"
    rc=0
    wait "$pid" || rc=$?
    out=$(cat "$sandbox/out.log")

    [[ "$rc" -ne 0 ]] || fail "$mode: a signalled run must exit non-zero: $out"
    assert_contains "$out" "received signal TERM"
    [[ "$(cat "$watch/sample.txt")" == "new input" ]] || fail "$mode: input must stay in the watch dir"
    [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/sample.txt")" == 0 ]] \
      || fail "$mode: must not delete the input: $(cat "$sandbox/calls.log")"
    [[ "$(_folder_actions_count_calls_on "$sandbox" mv "$watch/sample.txt")" == 0 ]] \
      || fail "$mode: must not quarantine the input: $(cat "$sandbox/calls.log")"
    [[ "$(_folder_actions_tree_digest "$downloads/sample")" == "$earlier" ]] || fail "$mode: earlier result must stay"
    if [ "$mode" = empty ]; then
      [[ ! -e "$downloads/sample_2" ]] || fail "empty reserved dir must be removed on signal: $(ls -A "$downloads/sample_2")"
    else
      [[ "$(ls -A "$downloads/sample_2")" == "sample_2.rar" && "$(cat "$downloads/sample_2/sample_2.rar")" == "partial" ]] \
        || fail "reserved dir holding a partial result must stay: $(ls -A "$downloads/sample_2" 2>&1)"
    fi
    [[ ! -e "$sandbox/lock/compress-rar.lock.d" ]] || fail "$mode: lock must be released"
  done
)

# ── upload-immich 결과 처리 fixture (#1401) ───────────────────────────────────
# Immich CLI와 서버는 대역이다.
# - bun 대역: `bun x @immich/cli@3 upload ... -- <파일...>` 호출 인자를 기록하고, 넘겨받은 파일 중
#   사례가 업로드 성공으로 지정한 것만 짝 .xmp와 함께 지운다(CLI --delete가 이번 실행에 업로드한
#   파일과 그 사이드카만 지우는 동작). 끝나기 직전 감시 폴더 목록을 남겨 CLI 처리 직후와 스크립트
#   종료 뒤를 나눠 본다.
# - curl 대역: 서버 ping은 성공시키고, stdin config로 온 bulk-upload-check 요청은 파일 SHA1별로
#   사례가 지정한 판정(accept / duplicate / trashed)을 서버 v3 응답 모양으로 돌려준다.
# 락과 스크립트 자신의 삭제는 위 배포 레이아웃 사본으로 격리해 calls.log에 기록한다.

_upload_immich_fixture_runnable() {
  local path

  if [ "$(uname -s)" != "Darwin" ]; then
    echo "N/A: upload-immich result fixture uses a macOS absolute command contract (runner=$(uname -s))" >&2
    return 1
  fi

  for path in /usr/bin/env /usr/bin/id /usr/bin/stat /usr/bin/sed /usr/bin/grep /usr/bin/tr \
    /usr/bin/hexdump /usr/bin/wc /usr/bin/tail /usr/bin/basename /usr/bin/shasum /usr/bin/plutil \
    /usr/bin/awk /bin/date /bin/ps /bin/kill /bin/ls /bin/mkdir /bin/mv /bin/rm /bin/cat /bin/sleep; do
    if [ ! -x "$path" ]; then
      echo "SKIP: upload-immich result fixture requires $path" >&2
      return 1
    fi
  done
}

# <sandbox> <CLI 종료 코드> [CLI가 업로드하고 지울 파일 이름...]
_upload_immich_prepare() {
  local sandbox="$1" cli_rc="$2"
  shift 2
  local home="$sandbox/home"
  local watch="$home/FolderActions/upload-immich"
  local name

  _folder_actions_install_tool_script "$sandbox" upload-immich
  mkdir -p "$home/.config/immich" "$home/.config/pushover" "$home/.local/lib" "$sandbox/verdicts"
  printf '%s\n' "IMMICH_API_KEY=synthetic-key" > "$home/.config/immich/api-key"
  : > "$home/.config/pushover/immich"
  cat > "$home/.local/lib/pushover.sh" <<EOF_HELPER
pushover_send() {
  { printf 'title=%s\n' "\$2"; printf 'priority=%s\n' "\$4"; printf 'message=%s\n' "\$3"; } >> '$sandbox/pushover.log'
}
EOF_HELPER

  : > "$sandbox/cli-uploads"
  for name in "$@"; do
    printf '%s\n' "$name" >> "$sandbox/cli-uploads"
  done
  {
    printf '#!/bin/sh\nsandbox=%s\nwatch=%s\ncli_rc=%s\n' "'$sandbox'" "'$watch'" "$cli_rc"
    cat <<'EOF_BUN'
for arg in "$@"; do printf 'ARG=%s\n' "$arg"; done >> "$sandbox/bun.log"
files=0
for arg in "$@"; do
  if [ "$files" = 1 ]; then
    if /usr/bin/grep -Fqx -- "${arg##*/}" "$sandbox/cli-uploads"; then
      /bin/rm -f "$arg" "${arg%.*}.xmp" "$arg.xmp"
    fi
  elif [ "$arg" = "--" ]; then
    files=1
  fi
done
/bin/ls -A "$watch" > "$sandbox/after-cli.txt"
echo "synthetic CLI output"
exit "$cli_rc"
EOF_BUN
  } > "$sandbox/tools/bun"

  # check-fail이 있으면 HTTP 오류(curl -f의 22), check-response가 있으면 그 본문을 준다.
  # check-mutate에 적힌 파일은 응답 직전에 내용을 바꾼다(확인과 삭제 사이의 변경).
  {
    printf '#!/bin/sh\nsandbox=%s\n' "'$sandbox'"
    cat <<'EOF_CURL'
case " $* " in
  *" --config "*) ;;
  *) printf 'ping argv=%s\n' "$*" >> "$sandbox/curl.log"; exit 0 ;;
esac
printf 'check argv=%s\n' "$*" >> "$sandbox/curl.log"
/bin/cat > "$sandbox/check-request.cfg"
[ -e "$sandbox/check-fail" ] && exit 22
if [ -e "$sandbox/check-mutate" ]; then
  while IFS= read -r target; do printf '%s\n' changed >> "$target"; done < "$sandbox/check-mutate"
fi
if [ -e "$sandbox/check-response" ]; then /bin/cat "$sandbox/check-response"; exit 0; fi
/usr/bin/sed -n 's/^data-binary = "\(.*\)"$/\1/p' "$sandbox/check-request.cfg" | /usr/bin/sed 's/\\"/"/g' \
  | /usr/bin/grep -oE '"id":"[0-9]+","checksum":"[0-9a-f]{40}"' \
  | /usr/bin/awk -F'"' -v dir="$sandbox/verdicts" '
      {
        v = "accept"; f = dir "/" $8
        if ((getline line < f) > 0) v = line
        close(f)
        if (v == "duplicate" || v == "trashed")
          r = "{\"id\":\"" $4 "\",\"action\":\"reject\",\"reason\":\"duplicate\",\"assetId\":\"00000000-0000-4000-8000-000000000000\",\"isTrashed\":" (v == "trashed" ? "true" : "false") "}"
        else
          r = "{\"id\":\"" $4 "\",\"action\":\"accept\"}"
        out = out (NR > 1 ? "," : "") r
      }
      END { printf "{\"results\":[%s]}", out }'
EOF_CURL
  } > "$sandbox/tools/curl"
  chmod 755 "$sandbox/tools/curl" "$sandbox/tools/bun"
}

# <sandbox> <파일>: 스크립트 사본의 /bin/rm 대역이 이 파일에서만 실패하게 한다.
_upload_immich_fail_rm_on() {
  local sandbox="$1" target="$2"
  {
    printf '#!/bin/sh\nsandbox=%s\ntarget=%s\n' "'$sandbox'" "'$target'"
    cat <<'EOF_RM'
{ printf '%s' rm; for arg in "$@"; do printf '\t%s' "$arg"; done; printf '\n'; } >> "$sandbox/calls.log"
for arg in "$@"; do [ "$arg" = "$target" ] && exit 1; done
exec /bin/rm "$@"
EOF_RM
  } > "$sandbox/stubs/rm"
}

# <sandbox> <파일> <duplicate|trashed>: 서버에 같은 SHA1 자산이 있다고 답하게 한다.
_upload_immich_server_has() {
  local sandbox="$1" file="$2" verdict="$3" sum
  sum=$(/usr/bin/shasum -a 1 < "$file")
  printf '%s\n' "$verdict" > "$sandbox/verdicts/${sum%% *}"
}

# launchd PATH의 ~/.bun/bin 자리에 대역 디렉터리를 둔다.
_upload_immich_run_script() {
  local sandbox="$1"
  env -i HOME="$sandbox/home" PATH="$sandbox/tools:/usr/bin:/bin" \
    WATCH_DIR="$sandbox/home/FolderActions/upload-immich" \
    IMMICH_INSTANCE_URL="http://127.0.0.1:9" \
    "$sandbox/home/.local/bin/upload-immich.sh"
}

test_upload_immich_keeps_originals_the_cli_did_not_upload() (
  local sandbox watch out expected actual
  _upload_immich_fixture_runnable || return 0

  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  # 성공 1개 + 실패 1개인데 CLI 종료 코드는 0이다. 실패 파일은 서버에도 없다(accept).
  _upload_immich_prepare "$sandbox" 0 uploaded.jpg
  printf '%s\n' "synthetic uploaded" > "$watch/uploaded.jpg"
  printf '%s\n' "synthetic failed" > "$watch/failed.jpg"

  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "upload-immich must exit 0: $out"

  assert_file_contains "$sandbox/after-cli.txt" "failed.jpg"
  [[ "$(cat "$watch/failed.jpg" 2>/dev/null)" == "synthetic failed" ]] \
    || fail "an original the CLI did not upload must survive post-processing: $out"
  [[ ! -e "$watch/uploaded.jpg" ]] || fail "the fixture CLI must have removed uploaded.jpg"
  ! grep -Fq "$watch" "$sandbox/calls.log" \
    || fail "the script must not delete an original the server does not have: $(cat "$sandbox/calls.log")"

  assert_line_count "$sandbox/pushover.log" "title=Immich [⚠️ 일부 미업로드]" 1
  assert_file_contains "$sandbox/pushover.log" "priority=0"
  assert_file_contains "$sandbox/pushover.log" "message=📸 1/2개 업로드 → Desktop Upload"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 업로드 안 된 1개 원본 보존"
  assert_not_contains "$(cat "$sandbox/pushover.log")" "업로드 완료"

  # CLI에는 확정한 미디어 목록만 넘기고, 서버 중복 삭제는 CLI에 맡기지 않는다.
  expected=$(printf 'ARG=%s\n' x @immich/cli@3 upload --album-name "Desktop Upload" \
    --delete --concurrency 2 -- "$watch/failed.jpg" "$watch/uploaded.jpg")
  actual=$(cat "$sandbox/bun.log")
  [[ "$actual" == "$expected" ]] || fail "Immich CLI invocation changed: $actual"

  # 남은 원본은 서버에 확인하되, API 키는 명령줄이 아니라 stdin config로 넘긴다.
  assert_line_count "$sandbox/curl.log" "check argv=-q -sf --max-time 30 --config -" 1
  assert_not_contains "$(cat "$sandbox/curl.log")" "synthetic-key"
  assert_not_contains "$out" "synthetic-key"
  assert_file_contains "$sandbox/check-request.cfg" 'header = "x-api-key: synthetic-key"'
  assert_file_contains "$sandbox/check-request.cfg" \
    'url = "http://127.0.0.1:9/api/assets/bulk-upload-check"'
)

test_upload_immich_notification_counts_remaining_originals() (
  local sandbox watch out
  _upload_immich_fixture_runnable || return 0

  # 전체 업로드: 남은 원본이 없을 때만 완료로 알린다. RAW(.dng)도 업로드 대상이고,
  # 비미디어는 CLI에 넘기지 않는다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 0 a.jpg b.dng
  printf '%s\n' a > "$watch/a.jpg"
  printf '%s\n' '<xmp/>' > "$watch/a.xmp"
  printf '%s\n' b > "$watch/b.dng"
  printf '%s\n' note > "$watch/note.txt"
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "all-uploaded run must exit 0: $out"
  assert_line_count "$sandbox/pushover.log" "title=Immich [✅ 업로드 완료]" 1
  assert_file_contains "$sandbox/pushover.log" "message=📸 2개 파일 (4B) → Desktop Upload"
  # 시작 전 비미디어 2개 중 a.xmp는 CLI가 사이드카로 올리고 지웠다.
  assert_file_contains "$sandbox/pushover.log" "⚠️ 비미디어 1개 무시됨"
  [[ -e "$watch/note.txt" ]] || fail "non-media files must stay"
  assert_not_contains "$(cat "$sandbox/bun.log")" "note.txt"
  assert_not_contains "$(cat "$sandbox/curl.log")" "check argv="

  # 전체 실패인데 종료 코드 0: 업로드된 파일이 없다고 알리고 두 원본을 남긴다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 0
  printf '%s\n' a > "$watch/a.jpg"
  printf '%s\n' b > "$watch/b.mov"
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "all-failed run must exit 0: $out"
  [[ -e "$watch/a.jpg" && -e "$watch/b.mov" ]] || fail "all originals must stay when nothing was uploaded: $out"
  ! grep -Fq "$watch" "$sandbox/calls.log" || fail "all-failed run must not delete: $(cat "$sandbox/calls.log")"
  assert_line_count "$sandbox/pushover.log" "title=Immich [❌ 업로드된 파일 없음]" 1
  assert_file_contains "$sandbox/pushover.log" "message=📸 0/2개 업로드 → Desktop Upload"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 업로드 안 된 2개 원본 보존"

  # 명령 비정상 종료: CLI가 한 개를 지운 뒤 실패해도 실제로 남은 수를 알리고, 서버 확인은
  # 하지 않는다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 1 a.jpg
  printf '%s\n' a > "$watch/a.jpg"
  printf '%s\n' b > "$watch/b.mov"
  _upload_immich_server_has "$sandbox" "$watch/b.mov" duplicate
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "cli-error run must exit 0: $out"
  [[ "$(cat "$watch/b.mov" 2>/dev/null)" == "b" ]] || fail "the original left by a failed CLI must stay: $out"
  ! grep -Fq "$watch" "$sandbox/calls.log" || fail "cli-error run must not delete: $(cat "$sandbox/calls.log")"
  assert_not_contains "$(cat "$sandbox/curl.log")" "check argv="
  assert_line_count "$sandbox/pushover.log" "title=Immich [❌ 업로드 실패]" 1
  assert_file_contains "$sandbox/pushover.log" "message=CLI 오류: synthetic CLI output"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 남은 파일 1/2개 원본 보존"
)

test_upload_immich_deletes_only_live_server_duplicates() (
  local sandbox watch out
  _upload_immich_fixture_runnable || return 0

  # 서버에 이미 있는 원본(휴지통 아님)은 원본만 지우고, 올리지 않은 .xmp 사이드카는 남긴다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 0 new.jpg
  printf '%s\n' dup > "$watch/dup.jpg"
  printf '%s\n' '<xmp>local edits</xmp>' > "$watch/dup.xmp"
  printf '%s\n' new > "$watch/new.jpg"
  _upload_immich_server_has "$sandbox" "$watch/dup.jpg" duplicate
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "duplicate run must exit 0: $out"
  assert_file_contains "$sandbox/after-cli.txt" "dup.jpg"
  [[ ! -e "$watch/dup.jpg" ]] || fail "a live server duplicate must be removed: $out"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/dup.jpg")" == 1 ]] \
    || fail "the script must delete the duplicate original exactly once: $(cat "$sandbox/calls.log")"
  [[ "$(cat "$watch/dup.xmp" 2>/dev/null)" == "<xmp>local edits</xmp>" ]] \
    || fail "the sidecar of a duplicate was never uploaded and must stay"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/dup.xmp")" == 0 ]] \
    || fail "the script must not delete sidecars: $(cat "$sandbox/calls.log")"
  assert_line_count "$sandbox/pushover.log" "title=Immich [✅ 업로드 완료]" 1
  assert_file_contains "$sandbox/pushover.log" "message=📸 2개 파일 (8B) → Desktop Upload"
  assert_file_contains "$sandbox/pushover.log" "♻️ 서버에 이미 있던 1개 원본 정리"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 비미디어 1개 무시됨"

  # 서버 휴지통에만 있는 자산과 같은 원본은 남긴다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 0 new.jpg
  printf '%s\n' trashed > "$watch/trashed.jpg"
  printf '%s\n' new > "$watch/new.jpg"
  _upload_immich_server_has "$sandbox" "$watch/trashed.jpg" trashed
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "trashed run must exit 0: $out"
  [[ "$(cat "$watch/trashed.jpg" 2>/dev/null)" == "trashed" ]] \
    || fail "an original whose server copy is in the trash must stay: $out"
  ! grep -Fq "$watch" "$sandbox/calls.log" || fail "trashed run must not delete: $(cat "$sandbox/calls.log")"
  assert_line_count "$sandbox/pushover.log" "title=Immich [⚠️ 일부 미업로드]" 1
  assert_file_contains "$sandbox/pushover.log" "message=📸 1/2개 업로드 → Desktop Upload"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 서버 휴지통에 있는 1개 원본 보존"
)

test_upload_immich_keeps_originals_when_server_check_fails() (
  local entry sandbox watch out
  _upload_immich_fixture_runnable || return 0

  # 서버가 중복이라고 답할 파일이라도 확인 요청이 실패하거나 응답을 해석할 수 없으면 지우지 않는다.
  for entry in http-error results-count-mismatch missing-is-trashed not-json unknown-action \
    sha1-unreadable; do
    sandbox=$(new_sandbox)
    watch="$sandbox/home/FolderActions/upload-immich"
    _upload_immich_prepare "$sandbox" 0 new.jpg
    printf '%s\n' dup > "$watch/dup.jpg"
    printf '%s\n' new > "$watch/new.jpg"
    _upload_immich_server_has "$sandbox" "$watch/dup.jpg" duplicate
    case "$entry" in
      http-error) : > "$sandbox/check-fail" ;;
      results-count-mismatch) printf '%s' '{"results":[]}' > "$sandbox/check-response" ;;
      missing-is-trashed)
        printf '%s' '{"results":[{"id":"0","action":"reject","reason":"duplicate"}]}' > "$sandbox/check-response"
        ;;
      not-json) printf '%s' '<html>proxy error</html>' > "$sandbox/check-response" ;;
      unknown-action) printf '%s' '{"results":[{"id":"0","action":"skip"}]}' > "$sandbox/check-response" ;;
      sha1-unreadable) chmod 000 "$watch/dup.jpg" ;;
    esac
    out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "$entry run must exit 0: $out"
    chmod 600 "$watch/dup.jpg" 2>/dev/null || true
    if [ "$entry" = sha1-unreadable ]; then
      # SHA1을 못 구하면 요청 자체를 보내지 않는다.
      assert_not_contains "$(cat "$sandbox/curl.log")" "check argv="
    else
      assert_line_count "$sandbox/curl.log" "check argv=-q -sf --max-time 30 --config -" 1
    fi
    [[ "$(cat "$watch/dup.jpg" 2>/dev/null)" == "dup" ]] || fail "$entry must keep the original: $out"
    ! grep -Fq "$watch" "$sandbox/calls.log" || fail "$entry must not delete: $(cat "$sandbox/calls.log")"
    assert_line_count "$sandbox/pushover.log" "title=Immich [⚠️ 일부 미업로드]" 1
    assert_file_contains "$sandbox/pushover.log" "message=📸 1/2개 업로드 → Desktop Upload"
    assert_file_contains "$sandbox/pushover.log" "⚠️ 서버 확인 실패로 1개 원본 보존"
  done
)

test_upload_immich_cli_major_matches_server_image() (
  local cli server

  cli=$(grep -oE '@immich/cli@[0-9]+' "$(_upload_immich_script_path)" | sort -u)
  server=$(grep -oE 'immich-server:v[0-9]+' "$REPO_ROOT/modules/nixos/programs/docker/immich.nix" | sort -u)
  [[ "$cli" =~ ^@immich/cli@[0-9]+$ ]] || fail "upload-immich.sh must pin exactly one CLI major: $cli"
  [[ "$server" =~ ^immich-server:v[0-9]+$ ]] || fail "immich.nix must declare exactly one server major: $server"
  [[ "${cli##*@}" == "${server##*:v}" ]] || fail "CLI major ($cli) must match the server image ($server)"
)

# 응답 id는 요청 때 보낸 10진 순번과 정확히 같아야 한다. 앞자리 0은 bash 배열 첨자에서 8진수로
# 읽혀(08은 산술 오류, 010은 8번) 판정이 다른 파일에 붙을 수 있다.
_upload_immich_check_response() {
  local sandbox="$1" entry item result=""
  shift
  for entry in "$@"; do
    case "${entry#*=}" in
      accept) item='"action":"accept"' ;;
      duplicate)
        item='"action":"reject","reason":"duplicate","assetId":"00000000-0000-4000-8000-000000000000","isTrashed":false'
        ;;
      *) fail "unknown check verdict: $entry" ;;
    esac
    result="${result:+$result,}{${entry%%=*},$item}"
  done
  printf '{"results":[%s]}' "$result" > "$sandbox/check-response"
}

test_upload_immich_rejects_malformed_check_ids() (
  local entry count i sandbox watch out
  _upload_immich_fixture_runnable || return 0

  for entry in leading-zero-08:9 leading-zero-010:11 numeric-id:1 out-of-range:1 duplicate-id:2; do
    count="${entry##*:}"
    sandbox=$(new_sandbox)
    watch="$sandbox/home/FolderActions/upload-immich"
    _upload_immich_prepare "$sandbox" 0
    for ((i = 0; i < count; i++)); do
      printf 'f%02d\n' "$i" > "$watch/f$(printf '%02d' "$i").jpg"
    done
    case "${entry%%:*}" in
      leading-zero-08)
        _upload_immich_check_response "$sandbox" '"id":"0"=accept' '"id":"1"=accept' '"id":"2"=accept' \
          '"id":"3"=accept' '"id":"4"=accept' '"id":"5"=accept' '"id":"6"=accept' '"id":"7"=accept' \
          '"id":"08"=duplicate'
        ;;
      leading-zero-010)
        _upload_immich_check_response "$sandbox" '"id":"0"=accept' '"id":"1"=accept' '"id":"2"=accept' \
          '"id":"3"=accept' '"id":"4"=accept' '"id":"5"=accept' '"id":"6"=accept' '"id":"7"=accept' \
          '"id":"010"=duplicate' '"id":"9"=accept' '"id":"10"=accept'
        ;;
      numeric-id) _upload_immich_check_response "$sandbox" '"id":0=duplicate' ;;
      out-of-range) _upload_immich_check_response "$sandbox" '"id":"1"=duplicate' ;;
      duplicate-id) _upload_immich_check_response "$sandbox" '"id":"0"=duplicate' '"id":"0"=accept' ;;
    esac
    out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "$entry run must exit 0: $out"
    [[ "$(find "$watch" -name 'f*.jpg' | wc -l | tr -d ' ')" == "$count" ]] \
      || fail "$entry must keep every original: $(ls "$watch")"
    ! grep -Fq "$watch" "$sandbox/calls.log" || fail "$entry must not delete: $(cat "$sandbox/calls.log")"
    assert_line_count "$sandbox/pushover.log" "title=Immich [❌ 업로드된 파일 없음]" 1
    assert_file_contains "$sandbox/pushover.log" "⚠️ 서버 확인 실패로 ${count}개 원본 보존"
  done
)

test_upload_immich_rechecks_before_deleting_duplicates() (
  local sandbox watch out
  _upload_immich_fixture_runnable || return 0

  # 서버에 있는 원본인데 삭제가 실패하면 따로 세어 알린다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 0 new.jpg
  printf '%s\n' dup > "$watch/dup.jpg"
  printf '%s\n' new > "$watch/new.jpg"
  _upload_immich_server_has "$sandbox" "$watch/dup.jpg" duplicate
  _upload_immich_fail_rm_on "$sandbox" "$watch/dup.jpg"
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "rm-failure run must exit 0: $out"
  [[ "$(_folder_actions_count_calls_on "$sandbox" rm "$watch/dup.jpg")" == 1 ]] \
    || fail "the script must try to delete the duplicate once: $(cat "$sandbox/calls.log")"
  [[ -e "$watch/dup.jpg" ]] || fail "the fixture rm must have failed"
  assert_line_count "$sandbox/pushover.log" "title=Immich [⚠️ 원본 정리 실패]" 1
  assert_file_contains "$sandbox/pushover.log" "message=📸 2/2개 업로드 → Desktop Upload"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 서버에 있으나 삭제 실패 1개 원본 보존"
  assert_not_contains "$(cat "$sandbox/pushover.log")" "♻️"

  # 서버 확인 뒤 삭제 전에 내용이 바뀐 원본은 확인 실패로 남긴다.
  sandbox=$(new_sandbox)
  watch="$sandbox/home/FolderActions/upload-immich"
  _upload_immich_prepare "$sandbox" 0 new.jpg
  printf '%s\n' dup > "$watch/dup.jpg"
  printf '%s\n' new > "$watch/new.jpg"
  _upload_immich_server_has "$sandbox" "$watch/dup.jpg" duplicate
  printf '%s\n' "$watch/dup.jpg" > "$sandbox/check-mutate"
  out=$(_upload_immich_run_script "$sandbox" 2>&1) || fail "changed-file run must exit 0: $out"
  [[ "$(cat "$watch/dup.jpg")" == $'dup\nchanged' ]] || fail "a file changed after the check must stay: $out"
  ! grep -Fq "$watch" "$sandbox/calls.log" || fail "changed-file run must not delete: $(cat "$sandbox/calls.log")"
  assert_line_count "$sandbox/pushover.log" "title=Immich [⚠️ 일부 미업로드]" 1
  assert_file_contains "$sandbox/pushover.log" "message=📸 1/2개 업로드 → Desktop Upload"
  assert_file_contains "$sandbox/pushover.log" "⚠️ 서버 확인 실패로 1개 원본 보존"
)
