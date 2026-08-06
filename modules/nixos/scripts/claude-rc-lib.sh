# claude-rc-lib.sh: shared lifecycle helpers for claude-rc and claude-rc-maint.
# shellcheck shell=bash
#
# This file is definition-only. It is concatenated before the command-specific
# script by the Nix package expressions, so it must not run command logic.

STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-rc}"
VERSIONS_DIR="${VERSIONS_DIR:-$HOME/.local/share/claude/versions}"
CLAUDE_RC_BRIDGE_PATH="${CLAUDE_RC_BRIDGE_PATH:-$PATH}"
CLAUDE_RC_HEADLESS_SSH_MARKER="${CLAUDE_RC_HEADLESS_SSH_MARKER:-0}"
CLAUDE_RC_ENVIRONMENT_GENERATION="${CLAUDE_RC_ENVIRONMENT_GENERATION:-unmanaged}"
INSTANCES_FILE="$STATE_DIR/instances.json"
INSTANCES_LOCK="$STATE_DIR/instances.json.lock"
LOG_MAX_BYTES=$((5 * 1024 * 1024))
# Candidate discovery must not assume the configured maint launcher basename.
# Include both official subcommand spellings, then verify the CLI command
# position, cwd, executable boundary, and flock lineage below.
BRIDGE_PROCESS_PATTERN='remote-control|[[:space:]]rc([[:space:]]|$)'
# Spawned session argv may be the versioned Claude binary path, so --sdk-url is
# the stable selector. The leading [-] avoids pgrep treating the pattern as an
# option.
BRIDGE_CHILD_PROCESS_PATTERN='[-]-sdk-url'
ORPHAN_REAP_TERM_ATTEMPTS=5
ORPHAN_REAP_TERM_SLEEP_SECONDS=0.2
SERVER_START_SETTLE_SECONDS="${SERVER_START_SETTLE_SECONDS:-2}"
LAUNCH_GUARD_TERM_ATTEMPTS="${LAUNCH_GUARD_TERM_ATTEMPTS:-20}"
LAUNCH_GUARD_TERM_INTERVAL_SECONDS="${LAUNCH_GUARD_TERM_INTERVAL_SECONDS:-0.05}"
# Process-table inspection can be temporarily slow during a concurrent Nix
# activation or test fan-out. Keep every phase bounded while allowing the
# local spawn/identity handshake to survive that expected scheduler pressure.
LAUNCH_GUARD_ACK_ATTEMPTS="${LAUNCH_GUARD_ACK_ATTEMPTS:-200}"
LAUNCH_GUARD_ACK_INTERVAL_SECONDS="${LAUNCH_GUARD_ACK_INTERVAL_SECONDS:-0.05}"
LAUNCH_GUARD_READY_ATTEMPTS="${LAUNCH_GUARD_READY_ATTEMPTS:-500}"
LAUNCH_GUARD_READY_INTERVAL_SECONDS="${LAUNCH_GUARD_READY_INTERVAL_SECONDS:-0.01}"
# 124 means the caller must use its exact-lineage fallback: either the guardian
# reported that cleanup was unconfirmed or the waiter reached its ack deadline.
# 125 is reserved for pre-launch identity setup.
LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS=124
LAUNCH_GUARD_SETUP_FAILED_STATUS=125
# A raw TERM exits with 143. Use a distinct, guardian-controlled status so the
# caller cannot mistake an interrupted cleanup for a completed one.
LAUNCH_GUARD_CLEANED_STATUS=85
STARTED_IDENTITY_POLL_ATTEMPTS="${STARTED_IDENTITY_POLL_ATTEMPTS:-100}"
STARTED_IDENTITY_POLL_INTERVAL_SECONDS="${STARTED_IDENTITY_POLL_INTERVAL_SECONDS:-0.1}"
STOPPED_LOCK_POLL_ATTEMPTS="${STOPPED_LOCK_POLL_ATTEMPTS:-30}"
STOPPED_LOCK_POLL_INTERVAL_SECONDS="${STOPPED_LOCK_POLL_INTERVAL_SECONDS:-0.1}"
STOPPED_SERVER_POLL_ATTEMPTS="${STOPPED_SERVER_POLL_ATTEMPTS:-10}"
STOPPED_SERVER_POLL_INTERVAL_SECONDS="${STOPPED_SERVER_POLL_INTERVAL_SECONDS:-1}"
TSV_NULL='__CLAUDE_RC_NULL__'

iso_timestamp() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    printf '%s:%s\n' "${ts%??}" "${ts: -2}"
}

sha256_hex() {
    local value="$1"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
        return
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha256sum | awk '{print $1}'
        return
    fi
    log_error "required command not found in PATH: shasum or sha256sum"
    return 1
}

canonical_existing_path() {
    local path="$1"
    (cd "$path" 2>/dev/null && pwd -P)
}

slug_for_path() {
    local path="$1" base digest
    base=$(basename "$path")
    digest=$(sha256_hex "$path")
    printf '%s-%s\n' "$base" "${digest:0:8}"
}

instance_dir_for_path() {
    local path="$1" slug
    slug=$(slug_for_path "$path")
    printf '%s/%s\n' "$STATE_DIR" "$slug"
}

lock_path_for_path() {
    local path="$1"
    printf '%s/lock\n' "$(instance_dir_for_path "$path")"
}

log_path_for_path() {
    local path="$1"
    printf '%s/server.log\n' "$(instance_dir_for_path "$path")"
}

environment_attestation_path_for_path() {
    local path="$1"
    printf '%s/environment-attestation.json\n' "$(instance_dir_for_path "$path")"
}

pid_process_start_identity() {
    local pid="$1"
    case "$pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    claude-rc-pid-argv --start-identity "$pid"
}

write_environment_attestation() {
    local path="$1" pid="$2" attestation tmp start
    [ "$CLAUDE_RC_ENVIRONMENT_GENERATION" != "unmanaged" ] || return 0
    start=$(pid_process_start_identity "$pid") || return 1
    attestation=$(environment_attestation_path_for_path "$path") || return 1
    [ ! -L "$attestation" ] || return 1
    tmp=$(mktemp "${attestation}.new.XXXXXX") || return 1
    chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
    if ! jq -n -c \
        --argjson pid "$pid" \
        --arg processStartIdentity "$start" \
        --arg environmentGeneration "$CLAUDE_RC_ENVIRONMENT_GENERATION" \
        '{schemaVersion: 1, pid: $pid, processStartIdentity: $processStartIdentity,
          environmentGeneration: $environmentGeneration}' >"$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$attestation"
}

environment_attestation_snapshot_for_cleanup() {
    local path="$1" pid="$2" attestation current_start
    if [ "$CLAUDE_RC_ENVIRONMENT_GENERATION" = "unmanaged" ]; then
        printf 'unmanaged\n'
        return 0
    fi
    attestation=$(environment_attestation_path_for_path "$path") || return 1
    [ -f "$attestation" ] && [ ! -L "$attestation" ] || return 1
    current_start=$(pid_process_start_identity "$pid") || return 1
    jq -cer \
        --argjson pid "$pid" \
        --arg processStartIdentity "$current_start" '
          if type == "object"
             and (keys | sort) == ["environmentGeneration", "pid", "processStartIdentity", "schemaVersion"]
             and .schemaVersion == 1
             and .pid == $pid
             and .processStartIdentity == $processStartIdentity
             and (.environmentGeneration | type) == "string"
             and (.environmentGeneration | length) > 0
          then .
          else error("invalid environment attestation")
          end
        ' "$attestation"
}

read_environment_attestation() {
    local path="$1" pid="$2" snapshot
    snapshot=$(environment_attestation_snapshot_for_cleanup "$path" "$pid") || return 1
    if [ "$snapshot" = "unmanaged" ]; then
        printf 'unmanaged\n'
        return 0
    fi
    jq -er '.environmentGeneration' <<<"$snapshot"
}

running_environment_generation_for_path() {
    local path="$1" pid="$2" generation
    if generation=$(read_environment_attestation "$path" "$pid" 2>/dev/null); then
        printf '%s\n' "$generation"
    else
        printf 'unknown\n'
    fi
}

clear_environment_attestation() {
    local path="$1" expected_snapshot="$2" attestation current_snapshot
    if [ "$CLAUDE_RC_ENVIRONMENT_GENERATION" = "unmanaged" ]; then
        [ "$expected_snapshot" = "unmanaged" ]
        return
    fi
    [ "$expected_snapshot" != "unmanaged" ] || return 1
    attestation=$(environment_attestation_path_for_path "$path") || return 1
    [ -f "$attestation" ] && [ ! -L "$attestation" ] || return 1
    current_snapshot=$(jq -cer '
      if type == "object"
         and (keys | sort) == ["environmentGeneration", "pid", "processStartIdentity", "schemaVersion"]
         and .schemaVersion == 1
         and (.pid | type) == "number"
         and (.processStartIdentity | type) == "string"
         and (.environmentGeneration | type) == "string"
      then .
      else error("invalid environment attestation")
      end
    ' "$attestation") || return 1
    [ "$current_snapshot" = "$expected_snapshot" ] || return 1
    rm -f "$attestation"
}

ensure_instance_dir() {
    local path="$1"
    mkdir -p "$(instance_dir_for_path "$path")"
}

lock_is_free() {
    local lock_path="$1"
    flock -n "$lock_path" true
}

rotate_log_if_needed() {
    local log_path="$1" size
    if [ ! -f "$log_path" ]; then
        return 0
    fi
    size=$(wc -c <"$log_path" | tr -d '[:space:]')
    if [ "${size:-0}" -gt "$LOG_MAX_BYTES" ]; then
        mv -f "$log_path" "$log_path.1"
    fi
}

init_instances_file() {
    mkdir -p "$STATE_DIR"
    if [ ! -f "$INSTANCES_FILE" ]; then
        printf '{"version":1,"instances":{}}\n' >"$INSTANCES_FILE"
    fi
}

with_instances_lock() {
    mkdir -p "$STATE_DIR" || return 1
    (
        flock 8 || return $?
        "$@"
    ) 8>"$INSTANCES_LOCK"
}

# Serialize wrapper and maint lifecycle mutations on the same lock while keeping
# the lock fd out of detached bridge descendants. Command-specific callers
# provide their own missing/timeout handlers so user-facing errors and maint
# status actions remain distinct without duplicating the fd contract.
with_lifecycle_lock_fd9() {
    local timeout_seconds="$1" lock_path="$2"
    local missing_handler="$3" timeout_handler="$4" setup_handler="$5"
    local callback_rc
    shift 5

    if ! mkdir -p "$(dirname "$lock_path")"; then
        "$setup_handler" "$lock_path"
        return 1
    fi
    if ! command -v flock >/dev/null 2>&1; then
        "$missing_handler" "$lock_path"
        return 1
    fi
    if ! exec 9>"$lock_path"; then
        "$setup_handler" "$lock_path"
        return 1
    fi
    if ! flock --timeout "$timeout_seconds" 9; then
        "$timeout_handler" "$lock_path"
        exec 9>&-
        return 1
    fi

    # The callback is deliberately guarded so this function always unlocks and
    # closes fd 9. Bash suppresses errexit inside a function invoked from an
    # AND-OR list, including every helper it calls, so lifecycle callbacks must
    # return rather than exit and explicitly propagate each critical failure.
    # Cleanup never overwrites the callback's original status.
    callback_rc=0
    "$@" 9>&- || callback_rc=$?
    flock -u 9 || true
    exec 9>&-
    return "$callback_rc"
}

upsert_instance_unlocked() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4" source="$5"
    local tmp capacity_json registered_at
    capacity_json="null"
    if [ -n "$capacity" ]; then
        capacity_json="$capacity"
    fi
    registered_at=$(iso_timestamp)
    init_instances_file
    tmp=$(mktemp "$STATE_DIR/instances.XXXXXX") || return 1
    jq \
        --arg path "$path" \
        --arg spawn "$spawn" \
        --arg permissionMode "$permission_mode" \
        --arg registeredAt "$registered_at" \
        --arg source "$source" \
        --argjson capacity "$capacity_json" \
        'if (.version == 1 and (.instances | type) == "object") then . else {version: 1, instances: {}} end
         | .instances[$path] = {
             spawn: $spawn,
             capacity: $capacity,
             permissionMode: $permissionMode,
             registeredAt: $registeredAt,
             source: $source
           }' \
        "$INSTANCES_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$INSTANCES_FILE"
}

upsert_instance() {
    with_instances_lock upsert_instance_unlocked "$@"
}

remove_instance_unlocked() {
    local path="$1" tmp
    init_instances_file
    tmp=$(mktemp "$STATE_DIR/instances.XXXXXX") || return 1
    jq --arg path "$path" \
        'if (.version == 1 and (.instances | type) == "object") then . else {version: 1, instances: {}} end
         | del(.instances[$path])' \
        "$INSTANCES_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$INSTANCES_FILE"
}

remove_instance() {
    with_instances_lock remove_instance_unlocked "$@"
}

emit_instances_tsv_unlocked() {
    init_instances_file
    jq -r --arg tsv_null "$TSV_NULL" '
        if (.version == 1 and (.instances | type) == "object") then .instances else {} end
        | to_entries[]
        | [
            .key,
            (.value.spawn // "worktree"),
            (if (.value.capacity // null) == null then $tsv_null else (.value.capacity | tostring) end),
            (.value.permissionMode // "bypassPermissions")
          ]
        | @tsv
    ' "$INSTANCES_FILE"
}

validate_permission_mode() {
    case "$1" in
        acceptEdits|bypassPermissions|default|dontAsk|plan) return 0 ;;
        *) return 1 ;;
    esac
}

validate_spawn() {
    case "$1" in
        worktree|same-dir) return 0 ;;
        *) return 1 ;;
    esac
}

pid_cwd() {
    local pid="$1"
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ {print substr($0, 2); exit}'
}

# 플랫폼별 실행 바이너리 경로 조회.
# - Linux: /proc/PID/exe. 삭제된 바이너리는 " (deleted)" suffix가 붙는다.
# - Darwin: /proc이 없어 lsof의 첫 txt(code segment) 항목을 쓴다. 실행 파일이
#   항상 첫 txt로 나열되고(-F 필드 출력은 경로 공백 안전; 실측), ps -o comm=은
#   argv[0] 기반이라 symlink 경유 실행 시 실경로를 잃는다.
#   삭제된 바이너리도 suffix 없이 원경로가 그대로 나오지만, 버전이 파일명이라
#   desired와의 문자열 비교로 drift가 감지되므로 (deleted) 표식 없이도 충분하다.
pid_exe_path() {
    local pid="$1"
    case "$(uname -s)" in
        Darwin) lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ {print substr($0, 2); exit}' ;;
        *) readlink "/proc/$pid/exe" 2>/dev/null ;;
    esac
}

# pid_exe_path 기준 실행 중 버전. 바이너리가 삭제된 구버전이면 "deleted"를 붙여
# 호출측이 drift로 취급하게 한다 (Linux 전용 신호 — Darwin 주석은 pid_exe_path 참조).
pid_exe_version() {
    local pid="$1" exe
    exe=$(pid_exe_path "$pid") || return 1
    [ -n "$exe" ] || return 1
    case "$exe" in
        *" (deleted)") echo "$(basename "${exe% (deleted)}") (deleted)" ;;
        *) basename "$exe" ;;
    esac
}

PID_ARGV=()

load_pid_argv() {
    local pid="$1" arg
    PID_ARGV=()
    while IFS= read -r -d '' arg; do
        PID_ARGV+=("$arg")
    done < <(claude-rc-pid-argv "$pid" 2>/dev/null)
    [ "${#PID_ARGV[@]}" -gt 0 ]
}

pid_spawn_mode() {
    local pid="$1" mode i
    local -a argv
    load_pid_argv "$pid" || return 1
    argv=("${PID_ARGV[@]}")
    for ((i = 0; i < ${#argv[@]}; i++)); do
        case "${argv[$i]}" in
            --spawn)
                if [ $((i + 1)) -lt "${#argv[@]}" ]; then
                    mode="${argv[$((i + 1))]}"
                    validate_spawn "$mode" || return 1
                    printf '%s\n' "$mode"
                    return 0
                fi
                return 1
                ;;
            --spawn=*)
                mode="${argv[$i]#--spawn=}"
                validate_spawn "$mode" || return 1
                printf '%s\n' "$mode"
                return 0
                ;;
        esac
    done
    return 1
}

pid_has_exact_argv_tokens() {
    local pid="$1" expected arg found
    local -a argv
    shift
    load_pid_argv "$pid" || return 1
    argv=("${PID_ARGV[@]}")
    for expected in "$@"; do
        found=false
        for arg in "${argv[@]}"; do
            if [ "$arg" = "$expected" ]; then
                found=true
                break
            fi
        done
        [ "$found" = true ] || return 1
    done
    return 0
}

pid_is_bridge_candidate_process() {
    local pid="$1" arg
    local -a argv
    load_pid_argv "$pid" || return 1
    argv=("${PID_ARGV[@]}")

    # The unmanaged duplicate guard never signals a candidate; it only blocks
    # a second launch while the instance lock is free. Avoid mirroring the
    # self-updating Claude CLI's global-option grammar here. An exact command
    # token is enough to fail closed, including joined valued options such as
    # `--model=sonnet remote-control`. Only explicit prompt/argument boundaries
    # prove that a later token is data rather than a bridge command.
    for arg in "${argv[@]:1}"; do
        case "$arg" in
            -p | --print | --print=* | --) return 1 ;;
            remote-control | rc) return 0 ;;
        esac
    done
    return 1
}

pid_is_managed_bridge_process() {
    # The managed path is bound separately to the exact flock argv suffix,
    # parent/child lineage, lock inode, cwd, and versioned executable. It does
    # not need the upstream CLI grammar parser used by unmanaged discovery.
    pid_has_exact_argv_tokens "$1" remote-control --no-create-session-in-dir
}

same_cwd_as_path() {
    local pid="$1" path="$2" cwd target
    cwd=$(pid_cwd "$pid") || return 1
    [ -n "$cwd" ] || return 1
    target=$(canonical_existing_path "$path") || return 1
    [ "$cwd" = "$target" ]
}

is_flock_process() {
    local pid="$1" exe
    exe=$(pid_exe_path "$pid") || return 1
    [ -n "$exe" ] || return 1
    # Both platform packages are immutable Nix-store executables. Accept old
    # store generations as well as the current PATH target so an `nrs` update
    # can still identify and replace a bridge launched by the previous closure.
    case "${exe% (deleted)}" in
        /nix/store/*-flock-*/bin/flock | /nix/store/*-util-linux-*/bin/flock) return 0 ;;
    esac
    return 1
}

is_claude_versions_exe_process() {
    local pid="$1" exe versions_dir
    exe=$(pid_exe_path "$pid") || return 1
    [ -n "$exe" ] || return 1
    versions_dir="${VERSIONS_DIR%/}"
    [ -n "$versions_dir" ] || return 1
    case "${exe% (deleted)}" in
        "$versions_dir"/*) return 0 ;;
    esac
    return 1
}

find_bridge_pids_for_path() {
    local path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        same_cwd_as_path "$pid" "$path" || continue
        pid_is_bridge_candidate_process "$pid" || continue
        if is_flock_process "$pid"; then
            continue
        fi
        # pgrep -f is only argv substring matching. A long-lived unrelated
        # script can contain "claude remote-control" in argv and share the cwd,
        # so require the actual executable to be the versioned Claude binary.
        is_claude_versions_exe_process "$pid" || continue
        echo "$pid"
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_PROCESS_PATTERN" 2>/dev/null || true)
}

find_bridge_pid_for_path() {
    local path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        echo "$pid"
        return 0
    done < <(find_bridge_pids_for_path "$path")
    return 1
}

pid_has_open_file() {
    local pid="$1" path="$2"
    lsof -a -p "$pid" -Fn -- "$path" 2>/dev/null \
        | awk -v expected="n$path" '$0 == expected { found = 1 } END { exit !found }'
}

pid_is_instance_flock_launcher() {
    local parent_pid="$1" child_pid="$2" lock_path="$3"
    local child_start=-1 i offset
    local -a parent_argv child_argv launched_suffix child_suffix
    load_pid_argv "$parent_pid" || return 1
    parent_argv=("${PID_ARGV[@]}")
    load_pid_argv "$child_pid" || return 1
    child_argv=("${PID_ARGV[@]}")
    [ "${#parent_argv[@]}" -ge 5 ] || return 1
    [ "$(basename "${parent_argv[0]}")" = "flock" ] || return 1
    [ "${parent_argv[1]}" = "-n" ] || return 1
    [ "${parent_argv[2]}" = "$lock_path" ] || return 1
    [ -n "${parent_argv[3]}" ] || return 1
    [ "${parent_argv[4]}" = "remote-control" ] || return 1
    launched_suffix=("${parent_argv[@]:4}")
    for ((i = 0; i < ${#child_argv[@]}; i++)); do
        if [ "${child_argv[$i]}" = "remote-control" ]; then
            child_start="$i"
            break
        fi
    done
    [ "$child_start" -ge 0 ] || return 1
    child_suffix=("${child_argv[@]:child_start}")
    # `flock -n FILE COMMAND...` starts COMMAND only after it owns FILE. Match
    # its actual argv boundaries, exact lock path, and bridge argv suffix against
    # the live child. The
    # maint launcher is configurable and need not be named `claude`; the child
    # executable boundary is enforced separately by VERSIONS_DIR. Native Claude
    # keeps the whole command identical; script-based test doubles gain a
    # shebang interpreter prefix after exec, so the stable suffix is the
    # portable boundary.
    [ "${#launched_suffix[@]}" -eq "${#child_suffix[@]}" ] || return 1
    for ((offset = 0; offset < ${#launched_suffix[@]}; offset++)); do
        [ "${launched_suffix[$offset]}" = "${child_suffix[$offset]}" ] || return 1
    done
}

pid_is_managed_server_for_path() {
    local pid="$1" path="$2" parent_pid lock_path
    same_cwd_as_path "$pid" "$path" || return 1
    is_flock_process "$pid" && return 1
    is_claude_versions_exe_process "$pid" || return 1
    pid_is_managed_bridge_process "$pid" || return 1
    parent_pid=$(pid_parent_pid "$pid") || return 1
    case "$parent_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    lock_path=$(lock_path_for_path "$path")
    # spawn_guarded_server_launch launches the Claude binary as flock's direct child.
    # Bind the server PID to that exact launcher and lock inode before any
    # lifecycle signal: a separate same-cwd/versioned Claude process must never
    # become the stop target merely because another process holds the lock.
    is_flock_process "$parent_pid" || return 1
    pid_is_instance_flock_launcher "$parent_pid" "$pid" "$lock_path" || return 1
    pid_has_open_file "$parent_pid" "$lock_path" || return 1
    pid_has_open_file "$pid" "$lock_path" || return 1
    if lock_is_free "$lock_path"; then
        return 1
    fi
    return 0
}

find_server_pid_for_path() {
    local path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        pid_is_managed_server_for_path "$pid" "$path" || continue
        echo "$pid"
        return 0
    done < <(find_bridge_pids_for_path "$path")
    return 1
}

has_unmanaged_server_for_path() {
    # Callers use this only after proving the instance lock is free. At that
    # point every matching bridge is necessarily outside the managed launcher.
    find_bridge_pid_for_path "$1" >/dev/null
}

count_worktree_session_procs() {
    local instance_path="$1" wt_root pid cwd count=0
    wt_root="$instance_path/.claude/worktrees/"
    # pgrep -c is not portable to macOS BSD pgrep, so count PID lines manually.
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        cwd=$(pid_cwd "$pid") || continue
        case "$cwd" in
            "$wt_root"*) count=$((count + 1)) ;;
        esac
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_CHILD_PROCESS_PATTERN" 2>/dev/null || true)
    echo "$count"
}

pid_parent_pid() {
    local pid="$1"
    ps -o ppid= -p "$pid" 2>/dev/null | awk '{print $1; exit}'
}

session_cwd_is_in_instance_scope() {
    local pid="$1" instance_path="$2" cwd target wt_root
    cwd=$(pid_cwd "$pid") || return 1
    [ -n "$cwd" ] || return 1
    target=$(canonical_existing_path "$instance_path") || return 1
    wt_root="$target/.claude/worktrees/"
    # The instance root itself is in scope because same-dir spawned sessions
    # run at the instance root; only worktree sessions live under wt_root.
    [ "$cwd" = "$target" ] && return 0
    case "$cwd" in
        "$wt_root"*) return 0 ;;
    esac
    return 1
}

pid_is_session_proc() {
    local pid="$1" arg i saw_print saw_sdk_url
    local -a argv
    load_pid_argv "$pid" || return 1
    argv=("${PID_ARGV[@]}")
    saw_print=false
    saw_sdk_url=false
    i=1
    while [ "$i" -lt "${#argv[@]}" ]; do
        arg="${argv[$i]}"
        case "$arg" in
            --) break ;;
            -p | --print | --print=*) saw_print=true ;;
            --sdk-url)
                [ $((i + 1)) -lt "${#argv[@]}" ] || return 1
                case "${argv[$((i + 1))]}" in
                    '' | -*) return 1 ;;
                esac
                saw_sdk_url=true
                i=$((i + 1))
                ;;
            --sdk-url=?*) saw_sdk_url=true ;;
        esac
        i=$((i + 1))
    done
    [ "$saw_print" = true ] && [ "$saw_sdk_url" = true ]
}

is_orphan_session_proc_for_path() {
    local pid="$1" instance_path="$2" ppid
    # The --sdk-url argv selector is rechecked here (not only at pgrep
    # discovery) so a recycled PID that is no longer a session process fails
    # this predicate before any signal is sent.
    pid_is_session_proc "$pid" || return 1
    # Spawned session processes run as the versioned Claude binary. Keep the
    # same executable boundary as server PID detection so an unrelated
    # --sdk-url argv match is never a reap target.
    is_claude_versions_exe_process "$pid" || return 1
    session_cwd_is_in_instance_scope "$pid" "$instance_path" || return 1
    ppid=$(pid_parent_pid "$pid") || return 1
    case "$ppid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # The confirmed orphan shape is SIGKILL re-parenting to init. A ppid > 1
    # non-server parent is not proven orphaned, so do not broaden this helper
    # beyond the case its name describes.
    [ "$ppid" -le 1 ] && return 0
    return 1
}

find_orphan_session_pids_for_path() {
    local instance_path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        if is_orphan_session_proc_for_path "$pid" "$instance_path"; then
            echo "$pid"
        fi
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_CHILD_PROCESS_PATTERN" 2>/dev/null || true)
}

reap_orphan_session_procs_for_path() {
    local instance_path="$1" pid initial_count attempt
    local -a pids term_pids remaining
    pids=()
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        pids+=("$pid")
    done < <(find_orphan_session_pids_for_path "$instance_path")

    if [ "${#pids[@]}" -eq 0 ]; then
        echo 0
        return 0
    fi

    term_pids=()
    for pid in "${pids[@]}"; do
        # PIDs can exit and be reused between discovery and signal delivery;
        # kill -0 only proves existence, not that this is still the same
        # orphan session, so re-run the full predicate before signaling.
        is_orphan_session_proc_for_path "$pid" "$instance_path" || continue
        kill -TERM "$pid" 2>/dev/null || true
        term_pids+=("$pid")
    done

    if [ "${#term_pids[@]}" -eq 0 ]; then
        echo 0
        return 0
    fi

    initial_count="${#term_pids[@]}"
    remaining=("${term_pids[@]}")
    # Give cooperative session processes about 1s to handle SIGTERM before
    # escalating to SIGKILL.
    for ((attempt = 0; attempt < ORPHAN_REAP_TERM_ATTEMPTS; attempt++)); do
        remaining=()
        for pid in "${term_pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                remaining+=("$pid")
            fi
        done
        [ "${#remaining[@]}" -gt 0 ] || break
        term_pids=("${remaining[@]}")
        sleep "$ORPHAN_REAP_TERM_SLEEP_SECONDS"
    done

    if [ "${#remaining[@]}" -gt 0 ]; then
        for pid in "${remaining[@]}"; do
            # Revalidate again after the grace window; a recycled PID must not
            # receive the terminal SIGKILL.
            is_orphan_session_proc_for_path "$pid" "$instance_path" || continue
            kill -KILL "$pid" 2>/dev/null || true
        done
    fi

    echo "$initial_count"
}

spawn_guarded_server_launch() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4" claude_bin="$5"
    local result_guard_pid_var="$6" result_launcher_pid_var="$7" result_group_pid_var="$8"
    local instance_dir lock_path log_path launch_pid_file launch_group_file guard_identity_file
    local spawned_guard_pid spawned_launcher_pid spawned_group_pid attempt
    local guardian_parent_pid
    local launch_group_bin flock_bin
    local -a args
    printf -v "$result_guard_pid_var" '%s' ""
    printf -v "$result_launcher_pid_var" '%s' ""
    printf -v "$result_group_pid_var" '%s' ""
    instance_dir=$(instance_dir_for_path "$path") || return 1
    lock_path="$instance_dir/lock"
    log_path="$instance_dir/server.log"
    mkdir -p "$instance_dir" || return 1
    rotate_log_if_needed "$log_path" || return 1
    # Callers make the launcher contract explicit: maint passes its exact
    # managed entrypoint, while the interactive wrapper resolves an absolute
    # `claude` entrypoint from CLAUDE_RC_BRIDGE_PATH. The stable symlink still
    # preserves self-update behavior without trusting ambient PATH.
    [ -n "$claude_bin" ] || return 1
    [ -n "$CLAUDE_RC_BRIDGE_PATH" ] || return 1
    case "$CLAUDE_RC_HEADLESS_SSH_MARKER" in
        0 | 1) ;;
        *) return 1 ;;
    esac
    [ -n "$CLAUDE_RC_ENVIRONMENT_GENERATION" ] || return 1
    launch_group_bin=$(command -v claude-rc-launch-group) || return 1
    flock_bin=$(command -v flock) || return 1
    args=("$claude_bin" remote-control --spawn "$spawn" --permission-mode "$permission_mode")
    if [ -n "$capacity" ]; then
        args+=(--capacity "$capacity")
    fi
    args+=(--no-create-session-in-dir)

    launch_pid_file=$(mktemp "$instance_dir/launch-pid.XXXXXX") || return 1
    launch_group_file=$(mktemp "$instance_dir/launch-group.XXXXXX") || {
        rm -f "$launch_pid_file"
        return 1
    }
    guard_identity_file=$(mktemp "$instance_dir/launch-guard.XXXXXX") || {
        rm -f "$launch_pid_file" "$launch_group_file"
        return 1
    }

    # A native supervisor remains the process-group leader until the caller
    # chooses cancellation or verified handoff. The stable group survives an
    # early flock exit, so descendants that inherited the lock cannot escape by
    # being re-parented before the startup deadline.
    (
        owned_launcher_pid=""
        owned_group_pid=""
        guardian_self_pid=""
        guardian_parent_pid=""
        # No process group exists yet. This early trap only bounds the identity
        # handshake; the exact-group cleanup trap replaces it before launch.
        trap 'rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"; exit 143' HUP TERM INT
        cd "$path" || {
            rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
            exit 1
        }

        # shellcheck disable=SC2329 # used by the signal-driven guardian cleanup
        launch_group_is_current_job() {
            local job_pid
            while IFS= read -r job_pid; do
                [ "$job_pid" = "$owned_group_pid" ] && return 0
            done < <(jobs -p)
            return 1
        }

        # shellcheck disable=SC2329 # invoked indirectly by signal traps
        cancel_pending_launcher() {
            # Cleanup is a critical section: a repeated signal after the group
            # has been stopped must not kill the guardian and strand the lock
            # holder in T state. Ignore further lifecycle signals until this
            # path either kills or resumes the exact group.
            trap '' HUP TERM INT USR1
            if [ -z "$owned_group_pid" ] || ! launch_group_is_current_job; then
                [ -z "$owned_group_pid" ] || wait "$owned_group_pid" 2>/dev/null || true
                rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
                exit "$LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS"
            fi
            if ! terminate_owned_process_group "$owned_group_pid" "$guardian_self_pid"; then
                resume_owned_process_group "$owned_group_pid" "$guardian_self_pid" || true
                rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
                exit "$LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS"
            fi
            wait "$owned_group_pid" 2>/dev/null || true
            rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
            exit "$LAUNCH_GUARD_CLEANED_STATUS"
        }

        # shellcheck disable=SC2329 # invoked indirectly by the USR1 trap
        handoff_running_launcher() {
            local group_status=0 launcher_group=""
            # Do not let a repeated lifecycle signal interrupt the verified
            # handoff or its fail-closed cleanup path halfway through.
            trap '' HUP TERM INT USR1
            [ -z "$owned_launcher_pid" ] \
                || launcher_group=$(pid_process_group "$owned_launcher_pid" 2>/dev/null) \
                || launcher_group=""
            if [ -z "$owned_group_pid" ] \
                || [ -z "$owned_launcher_pid" ] \
                || ! launch_group_is_current_job \
                || ! pid_is_process_group_leader_child_of "$owned_group_pid" "$guardian_self_pid" \
                || ! pid_is_live_child_of "$owned_launcher_pid" "$owned_group_pid" \
                || [ "$launcher_group" != "$owned_group_pid" ]; then
                cancel_pending_launcher
            fi
            kill -USR1 "$owned_group_pid" 2>/dev/null || cancel_pending_launcher
            wait "$owned_group_pid" 2>/dev/null || group_status=$?
            rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
            [ "$group_status" -eq 0 ] || exit 1
            exit 0
        }

        # Install the cancellation contract before publishing readiness. Once
        # the PID file is visible, the guardian deliberately remains alive
        # until the parent chooses cancel or handoff, even if the launcher has
        # already exited. This prevents a stale guardian PID from becoming a
        # signal target after PID reuse.
        trap cancel_pending_launcher HUP TERM INT
        trap handoff_running_launcher USR1

        for ((attempt = 0; attempt < LAUNCH_GUARD_READY_ATTEMPTS; attempt++)); do
            if IFS=$'\t' read -r guardian_self_pid guardian_parent_pid < "$guard_identity_file"; then
                case "$guardian_self_pid:$guardian_parent_pid" in
                    *[!0-9:]*|:*|*:) ;;
                    *)
                        current_guardian_parent=$(pid_parent_pid "$guardian_self_pid" 2>/dev/null) \
                            || current_guardian_parent=""
                        [ "$current_guardian_parent" = "$guardian_parent_pid" ] && break
                        ;;
                esac
            fi
            guardian_self_pid=""
            guardian_parent_pid=""
            sleep "$LAUNCH_GUARD_READY_INTERVAL_SECONDS"
        done
        case "$guardian_self_pid:$guardian_parent_pid" in
            *[!0-9:]*|:*|*:)
                rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
                exit "$LAUNCH_GUARD_SETUP_FAILED_STATUS"
                ;;
        esac
        rm -f "$guard_identity_file"

        (
            trap '' HUP
            exec </dev/null >>"$log_path" 2>&1
            exec env -u CREDENTIALS_DIRECTORY -u PUSHOVER_CRED_FILE -u PUSHOVER_TOKEN -u PUSHOVER_USER -u SERVICE_LIB \
                -u CLAUDE_RC_DRIFT_POLICY -u CLAUDE_RC_DRIFT_APPROVAL_JSON \
                -u CLAUDE_RC_BRIDGE_PATH -u CLAUDE_RC_HEADLESS_SSH_MARKER -u CLAUDE_RC_ENVIRONMENT_GENERATION \
                PATH="$CLAUDE_RC_BRIDGE_PATH" \
                NIXOS_CONFIG_HEADLESS_SSH="$CLAUDE_RC_HEADLESS_SSH_MARKER" \
                NIXOS_CONFIG_HEADLESS_SSH_GENERATION="$CLAUDE_RC_ENVIRONMENT_GENERATION" \
                "$launch_group_bin" "$launch_pid_file" "$flock_bin" -n "$lock_path" "${args[@]}"
        ) &
        owned_group_pid=$!
        printf '%s\n' "$owned_group_pid" > "$launch_group_file"

        for ((attempt = 0; attempt < LAUNCH_GUARD_READY_ATTEMPTS; attempt++)); do
            if [ -f "$launch_pid_file" ] \
                && IFS= read -r owned_launcher_pid < "$launch_pid_file" \
                && [ -n "$owned_launcher_pid" ]; then
                break
            fi
            launch_group_is_current_job || break
            sleep "$LAUNCH_GUARD_READY_INTERVAL_SECONDS"
        done
        case "$owned_launcher_pid" in
            ''|*[!0-9]*) cancel_pending_launcher ;;
        esac

        while :; do
            current_guardian_parent=$(pid_parent_pid "$guardian_self_pid" 2>/dev/null) \
                || cancel_pending_launcher
            [ "$current_guardian_parent" = "$guardian_parent_pid" ] \
                || cancel_pending_launcher
            sleep "$LAUNCH_GUARD_READY_INTERVAL_SECONDS"
        done
    ) &
    spawned_guard_pid=$!
    guardian_parent_pid=$(pid_parent_pid "$spawned_guard_pid" 2>/dev/null) || guardian_parent_pid=""
    case "$guardian_parent_pid" in
        ''|*[!0-9]*)
            cancel_unlaunched_guard "$spawned_guard_pid" || true
            rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
            return 1
            ;;
    esac
    if ! printf '%s\t%s\n' "$spawned_guard_pid" "$guardian_parent_pid" > "$guard_identity_file"; then
        cancel_unlaunched_guard "$spawned_guard_pid" || true
        rm -f "$guard_identity_file" "$launch_pid_file" "$launch_group_file"
        return 1
    fi
    spawned_launcher_pid=""
    spawned_group_pid=""
    for ((attempt = 0; attempt < LAUNCH_GUARD_READY_ATTEMPTS; attempt++)); do
        if IFS= read -r spawned_launcher_pid < "$launch_pid_file" \
            && IFS= read -r spawned_group_pid < "$launch_group_file" \
            && [ -n "$spawned_launcher_pid" ] \
            && [ -n "$spawned_group_pid" ]; then
            break
        fi
        kill -0 "$spawned_guard_pid" 2>/dev/null || break
        sleep "$LAUNCH_GUARD_READY_INTERVAL_SECONDS"
    done
    # The guardian still needs the private PID files to bind its in-process
    # ownership state. It removes them after cancel or handoff; deleting them
    # here would race that read after the outer caller observed the same bytes.
    rm -f "$guard_identity_file"
    case "$spawned_launcher_pid:$spawned_group_pid" in
        *[!0-9:]*|:*|*:)
            cancel_launch_guard "$spawned_guard_pid" "$spawned_group_pid" || true
            return 1
            ;;
    esac
    printf -v "$result_guard_pid_var" '%s' "$spawned_guard_pid"
    printf -v "$result_launcher_pid_var" '%s' "$spawned_launcher_pid"
    printf -v "$result_group_pid_var" '%s' "$spawned_group_pid"
}

launch_guard_is_current_job() {
    local guard_pid="$1" job_pid
    while IFS= read -r job_pid; do
        [ "$job_pid" = "$guard_pid" ] && return 0
    done < <(jobs -p)
    return 1
}

pid_is_zombie_process() {
    local state
    state=$(ps -o state= -p "$1" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$state" in
        Z*) return 0 ;;
        *) return 1 ;;
    esac
}

wait_for_launch_guard_exit() {
    local guard_pid="$1" attempt wait_status=0
    for ((attempt = 0; ; attempt++)); do
        if ! launch_guard_is_current_job "$guard_pid" \
            || ! kill -0 "$guard_pid" 2>/dev/null \
            || pid_is_zombie_process "$guard_pid"; then
            wait "$guard_pid" 2>/dev/null || wait_status=$?
            return "$wait_status"
        fi
        [ "$attempt" -lt "$LAUNCH_GUARD_ACK_ATTEMPTS" ] || break
        sleep "$LAUNCH_GUARD_ACK_INTERVAL_SECONDS"
    done
    return "$LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS"
}

pid_is_live_child_of() {
    local pid="$1" expected_parent="$2" current_parent
    current_parent=$(pid_parent_pid "$pid" 2>/dev/null) || return 1
    [ "$current_parent" = "$expected_parent" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    pid_is_zombie_process "$pid" && return 1
    return 0
}

pid_process_group() {
    local pid="$1"
    ps -o pgid= -p "$pid" 2>/dev/null | awk '{print $1; exit}'
}

pid_is_process_group_leader_child_of() {
    local group_pid="$1" expected_parent="$2" current_group
    pid_is_live_child_of "$group_pid" "$expected_parent" || return 1
    current_group=$(pid_process_group "$group_pid") || return 1
    [ "$current_group" = "$group_pid" ]
}

process_group_members_are_stopped() {
    local group_pid="$1" pid member_group state snapshot found=false
    snapshot=$(ps -axo pid=,pgid=,state= 2>/dev/null) || return 1
    while read -r pid member_group state; do
        [ "$member_group" = "$group_pid" ] || continue
        found=true
        case "$state" in
            T*|Z*) ;;
            *) return 1 ;;
        esac
    done <<< "$snapshot"
    "$found"
}

process_group_has_active_members() {
    local group_pid="$1" pid member_group state snapshot
    snapshot=$(ps -axo pid=,pgid=,state= 2>/dev/null) || return 0
    while read -r pid member_group state; do
        [ "$member_group" = "$group_pid" ] || continue
        case "$state" in
            Z*) ;;
            *) return 0 ;;
        esac
    done <<< "$snapshot"
    return 1
}

# Set only after an exact live leader->guardian and PGID boundary was validated
# and group-wide SIGSTOP succeeded. If a later ps/revalidation probe fails, the
# same shell can still issue best-effort SIGCONT without risking a recycled PGID:
# the stopped leader keeps that process group allocated until resume or kill.
STOPPED_OWNED_PROCESS_GROUP=""

stop_owned_process_group() {
    local group_pid="$1" expected_parent="$2" attempt
    pid_is_process_group_leader_child_of "$group_pid" "$expected_parent" || return 1
    for ((attempt = 0; attempt < LAUNCH_GUARD_TERM_ATTEMPTS; attempt++)); do
        kill -STOP -- "-$group_pid" 2>/dev/null || return 1
        STOPPED_OWNED_PROCESS_GROUP="$group_pid"
        pid_is_process_group_leader_child_of "$group_pid" "$expected_parent" || return 1
        process_group_members_are_stopped "$group_pid" && return 0
        sleep "$LAUNCH_GUARD_TERM_INTERVAL_SECONDS"
    done
    return 1
}

resume_owned_process_group() {
    local group_pid="$1" expected_parent="$2"
    if [ "$STOPPED_OWNED_PROCESS_GROUP" = "$group_pid" ]; then
        kill -CONT -- "-$group_pid" 2>/dev/null || return 1
        STOPPED_OWNED_PROCESS_GROUP=""
        return 0
    fi
    pid_is_process_group_leader_child_of "$group_pid" "$expected_parent" || return 1
    kill -CONT -- "-$group_pid" 2>/dev/null
}

terminate_owned_process_group() {
    local group_pid="$1" expected_parent="$2" attempt
    stop_owned_process_group "$group_pid" "$expected_parent" || return 1
    pid_is_process_group_leader_child_of "$group_pid" "$expected_parent" || return 1
    kill -KILL -- "-$group_pid" 2>/dev/null || return 1
    STOPPED_OWNED_PROCESS_GROUP=""
    for ((attempt = 0; attempt < LAUNCH_GUARD_TERM_ATTEMPTS; attempt++)); do
        process_group_has_active_members "$group_pid" || return 0
        sleep "$LAUNCH_GUARD_TERM_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_killed_guard_exit() {
    local guard_pid="$1" attempt
    for ((attempt = 0; attempt < LAUNCH_GUARD_TERM_ATTEMPTS; attempt++)); do
        if ! kill -0 "$guard_pid" 2>/dev/null || pid_is_zombie_process "$guard_pid"; then
            wait "$guard_pid" 2>/dev/null || true
            return 0
        fi
        sleep "$LAUNCH_GUARD_TERM_INTERVAL_SECONDS"
    done
    return 1
}

cancel_unlaunched_guard() {
    local guard_pid="$1" wait_status=0
    case "$guard_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    launch_guard_is_current_job "$guard_pid" || {
        wait "$guard_pid" 2>/dev/null || true
        return 0
    }
    kill -TERM "$guard_pid" 2>/dev/null || return 1
    wait_for_launch_guard_exit "$guard_pid" || wait_status=$?
    if [ "$wait_status" -eq "$LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS" ]; then
        launch_guard_is_current_job "$guard_pid" || return 1
        kill -KILL "$guard_pid" 2>/dev/null || return 1
        wait_for_killed_guard_exit "$guard_pid"
        return
    fi
    return 0
}

force_cancel_launch_guard_group() {
    local guard_pid="$1" group_pid="$2"
    case "$group_pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    launch_guard_is_current_job "$guard_pid" || return 1
    if ! terminate_owned_process_group "$group_pid" "$guard_pid"; then
        resume_owned_process_group "$group_pid" "$guard_pid" || true
        return 1
    fi
    launch_guard_is_current_job "$guard_pid" || return 1
    kill -KILL "$guard_pid" 2>/dev/null || return 1
    wait_for_killed_guard_exit "$guard_pid"
}

cancel_launch_guard() {
    local guard_pid="$1" group_pid="${2:-}" wait_status=0
    case "$guard_pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    launch_guard_is_current_job "$guard_pid" || {
        wait "$guard_pid" 2>/dev/null || true
        return 1
    }
    kill -TERM "$guard_pid" 2>/dev/null || return 1
    wait_for_launch_guard_exit "$guard_pid" || wait_status=$?
    if [ "$wait_status" -eq "$LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS" ]; then
        force_cancel_launch_guard_group "$guard_pid" "$group_pid"
        return
    fi
    [ "$wait_status" -eq "$LAUNCH_GUARD_CLEANED_STATUS" ]
}

handoff_launch_guard() {
    local guard_pid="$1" group_pid="${2:-}" wait_status=0 late_wait_status=0
    case "$guard_pid" in
        '' | *[!0-9]*) return 1 ;;
    esac
    launch_guard_is_current_job "$guard_pid" || {
        wait "$guard_pid" 2>/dev/null || true
        return 1
    }
    kill -USR1 "$guard_pid" 2>/dev/null || return 1
    wait_for_launch_guard_exit "$guard_pid" || wait_status=$?
    if [ "$wait_status" -eq "$LAUNCH_GUARD_FALLBACK_REQUIRED_STATUS" ]; then
        # A guardian that did not acknowledge handoff cannot be trusted to
        # remain the ownership boundary. Request normal cleanup, then use the
        # exact guard→process-group lineage as the bounded fallback.
        kill -TERM "$guard_pid" 2>/dev/null || true
        wait_for_launch_guard_exit "$guard_pid" >/dev/null 2>&1 \
            || late_wait_status=$?
        # The USR1 trap ignores TERM after entering its handoff critical
        # section. A scheduler-delayed but otherwise verified handoff can
        # therefore finish successfully during this second bounded wait.
        [ "$late_wait_status" -eq 0 ] && return 0
        force_cancel_launch_guard_group "$guard_pid" "$group_pid" || true
        return 1
    fi
    [ "$wait_status" -eq 0 ]
}

wait_until_server_stops() {
    local pid="$1" _
    for ((_ = 0; _ < STOPPED_SERVER_POLL_ATTEMPTS; _++)); do
        if ! kill -0 "$pid" 2>/dev/null || pid_is_zombie_process "$pid"; then
            return 0
        fi
        sleep "$STOPPED_SERVER_POLL_INTERVAL_SECONDS"
    done
    return 1
}

wait_for_started_identity() {
    local path="$1" expected_launcher_pid="${2:-}" attempt pid parent_pid version
    for ((attempt = 0; attempt < STARTED_IDENTITY_POLL_ATTEMPTS; attempt++)); do
        if pid=$(find_server_pid_for_path "$path"); then
            if [ -n "$expected_launcher_pid" ]; then
                parent_pid=$(pid_parent_pid "$pid" 2>/dev/null) || parent_pid=""
                [ "$parent_pid" = "$expected_launcher_pid" ] || {
                    sleep "$STARTED_IDENTITY_POLL_INTERVAL_SECONDS"
                    continue
                }
            fi
            version=$(pid_exe_version "$pid" 2>/dev/null) || version=""
            if [ -n "$version" ]; then
                printf '%s\t%s\n' "$pid" "$version"
                return 0
            fi
        fi
        sleep "$STARTED_IDENTITY_POLL_INTERVAL_SECONDS"
    done
    return 1
}

wait_until_instance_lock_free() {
    local lock_path="$1" attempt
    for ((attempt = 0; attempt < STOPPED_LOCK_POLL_ATTEMPTS; attempt++)); do
        lock_is_free "$lock_path" && return 0
        sleep "$STOPPED_LOCK_POLL_INTERVAL_SECONDS"
    done
    return 1
}

stop_verified_started_server() {
    local path="$1" pid="$2" expected_version="$3" current_version lock_path attestation_snapshot
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    pid_is_managed_server_for_path "$pid" "$path" || return 1
    current_version=$(pid_exe_version "$pid" 2>/dev/null) || return 1
    [ "$current_version" = "$expected_version" ] || return 1
    attestation_snapshot=$(environment_attestation_snapshot_for_cleanup "$path" "$pid") || return 1
    # Re-run the full launcher/lock predicate immediately before signaling so a
    # recycled PID or a same-cwd decoy cannot inherit an earlier verification.
    pid_is_managed_server_for_path "$pid" "$path" || return 1
    kill -TERM "$pid" 2>/dev/null || return 1
    wait_until_server_stops "$pid" || return 1
    lock_path=$(lock_path_for_path "$path") || return 1
    wait_until_instance_lock_free "$lock_path" || return 1
    clear_environment_attestation "$path" "$attestation_snapshot"
}

launch_and_verify_server() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4" launcher="$5"
    local result_status_var="$6" result_pid_var="$7" result_version_var="$8"
    local lock_path launch_guard_pid launcher_pid launch_group_pid started_identity resolved_pid resolved_version
    local attestation_snapshot
    printf -v "$result_status_var" '%s' "launch-failed"
    printf -v "$result_pid_var" '%s' ""
    printf -v "$result_version_var" '%s' ""
    lock_path=$(lock_path_for_path "$path") || return 1

    if ! spawn_guarded_server_launch \
        "$path" "$spawn" "$capacity" "$permission_mode" "$launcher" \
        launch_guard_pid launcher_pid launch_group_pid; then
        return 0
    fi
    sleep "$SERVER_START_SETTLE_SECONDS"
    started_identity=$(wait_for_started_identity "$path" "$launcher_pid") || started_identity=""
    if [ -n "$started_identity" ]; then
        IFS=$'\t' read -r resolved_pid resolved_version <<<"$started_identity"
        if ! write_environment_attestation "$path" "$resolved_pid"; then
            printf -v "$result_status_var" '%s' "environment-attestation-failed"
            if cancel_launch_guard "$launch_guard_pid" "$launch_group_pid" \
                && wait_until_instance_lock_free "$lock_path"; then
                printf -v "$result_status_var" '%s' "environment-attestation-failed-cleaned"
            fi
            return 0
        fi
        if ! attestation_snapshot=$(environment_attestation_snapshot_for_cleanup "$path" "$resolved_pid"); then
            printf -v "$result_status_var" '%s' "environment-attestation-failed"
            if cancel_launch_guard "$launch_guard_pid" "$launch_group_pid" \
                && wait_until_instance_lock_free "$lock_path"; then
                printf -v "$result_status_var" '%s' "environment-attestation-failed-cleaned"
            fi
            return 0
        fi
        if ! handoff_launch_guard "$launch_guard_pid" "$launch_group_pid"; then
            clear_environment_attestation "$path" "$attestation_snapshot" || true
            return 0
        fi
        printf -v "$result_status_var" '%s' "started"
        printf -v "$result_pid_var" '%s' "$resolved_pid"
        printf -v "$result_version_var" '%s' "$resolved_version"
        return 0
    fi

    # A live exact flock launcher with the instance lock open proves that this
    # attempt reached server startup but its child identity was not resolvable.
    # Otherwise report an ordinary launch failure. Either way, cancel only the
    # exact guardian-owned process group before returning.
    if pid_has_open_file "$launcher_pid" "$lock_path"; then
        printf -v "$result_status_var" '%s' "identity-unresolvable"
    fi
    if cancel_launch_guard "$launch_guard_pid" "$launch_group_pid" \
        && wait_until_instance_lock_free "$lock_path" \
        && [ "${!result_status_var}" = "identity-unresolvable" ]; then
        printf -v "$result_status_var" '%s' "identity-unresolvable-cleaned"
    fi
}
