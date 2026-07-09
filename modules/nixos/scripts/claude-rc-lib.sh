# claude-rc-lib.sh: shared lifecycle helpers for claude-rc and claude-rc-maint.
# shellcheck shell=bash
#
# This file is definition-only. It is concatenated before the command-specific
# script by the Nix package expressions, so it must not run command logic.

STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-rc}"
VERSIONS_DIR="${VERSIONS_DIR:-$HOME/.local/share/claude/versions}"
INSTANCES_FILE="$STATE_DIR/instances.json"
INSTANCES_LOCK="$STATE_DIR/instances.json.lock"
LOG_MAX_BYTES=$((5 * 1024 * 1024))
BRIDGE_PROCESS_PATTERN='claude remote-control'
# Spawned session argv may be the versioned Claude binary path, so --sdk-url is
# the stable selector. The leading [-] avoids pgrep treating the pattern as an
# option.
BRIDGE_CHILD_PROCESS_PATTERN='[-]-sdk-url'
ORPHAN_REAP_TERM_ATTEMPTS=5
ORPHAN_REAP_TERM_SLEEP_SECONDS=0.2
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
    mkdir -p "$STATE_DIR"
    (
        flock 8
        "$@"
    ) 8>"$INSTANCES_LOCK"
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

pid_spawn_mode() {
    local pid="$1" command mode i
    local -a argv
    command=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
    [ -n "$command" ] || return 1
    read -r -a argv <<<"$command"
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

same_cwd_as_path() {
    local pid="$1" path="$2" cwd target
    cwd=$(pid_cwd "$pid") || return 1
    [ -n "$cwd" ] || return 1
    target=$(canonical_existing_path "$path") || return 1
    [ "$cwd" = "$target" ]
}

is_flock_process() {
    local pid="$1" exe base
    exe=$(pid_exe_path "$pid") || return 1
    [ -n "$exe" ] || return 1
    base=$(basename "${exe% (deleted)}")
    [ "$base" = "flock" ]
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

find_server_pid_for_path() {
    local path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        same_cwd_as_path "$pid" "$path" || continue
        if is_flock_process "$pid"; then
            continue
        fi
        # pgrep -f is only argv substring matching. A long-lived unrelated
        # script can contain "claude remote-control" in argv and share the cwd,
        # so require the actual executable to be the versioned Claude binary.
        is_claude_versions_exe_process "$pid" || continue
        echo "$pid"
        return 0
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_PROCESS_PATTERN" 2>/dev/null || true)
    return 1
}

has_unmanaged_server_for_path() {
    find_server_pid_for_path "$1" >/dev/null
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
    local pid="$1" command
    command=$(ps -o command= -p "$pid" 2>/dev/null) || return 1
    case "$command" in
        *--sdk-url*) return 0 ;;
    esac
    return 1
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

    for pid in "${remaining[@]}"; do
        # Revalidate again after the grace window; a recycled PID must not
        # receive the terminal SIGKILL.
        is_orphan_session_proc_for_path "$pid" "$instance_path" || continue
        kill -KILL "$pid" 2>/dev/null || true
    done

    echo "$initial_count"
}

start_server() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local instance_dir lock_path log_path
    local -a args
    instance_dir=$(instance_dir_for_path "$path")
    lock_path="$instance_dir/lock"
    log_path="$instance_dir/server.log"
    mkdir -p "$instance_dir"
    rotate_log_if_needed "$log_path"
    args=(claude remote-control --spawn "$spawn" --permission-mode "$permission_mode")
    if [ -n "$capacity" ]; then
        args+=(--capacity "$capacity")
    fi
    args+=(--no-create-session-in-dir)

    # macOS does not ship setsid. The outer background subshell exits after
    # spawning the inner one, so the server is re-parented and survives terminal,
    # systemd oneshot (KillMode=process), and launchd agent exit. stdin/logs are
    # detached, and SIGHUP is ignored before exec for terminal-close survival.
    (
        cd "$path" || exit 1
        (
            trap '' HUP
            exec </dev/null >>"$log_path" 2>&1
            exec env -u CREDENTIALS_DIRECTORY -u PUSHOVER_CRED_FILE -u PUSHOVER_TOKEN -u PUSHOVER_USER -u SERVICE_LIB \
                flock -n "$lock_path" "${args[@]}"
        ) &
    ) &
}

wait_until_server_stops() {
    local pid="$1"
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}
