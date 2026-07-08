#!/usr/bin/env bash
# claude-rc: Claude Code Remote Control headless multi-instance wrapper.
#
# Runtime dependencies are resolved from the user's PATH: claude, flock, git,
# jq, lsof, pgrep, shasum or sha256sum. The wrapper intentionally has no Nix
# runtimeInputs yet; the packaging changes are handled in the next phase.

set -euo pipefail

STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-rc}"
INSTANCES_FILE="$STATE_DIR/instances.json"
INSTANCES_LOCK="$STATE_DIR/instances.json.lock"
LOG_MAX_BYTES=$((5 * 1024 * 1024))
BRIDGE_PROCESS_PATTERN='claude remote-control'
# Spawned session argv may be the versioned Claude binary path, so --sdk-url is
# the stable selector. The leading [-] avoids pgrep treating the pattern as an
# option.
BRIDGE_CHILD_PROCESS_PATTERN='[-]-sdk-url'
TSV_NULL='__CLAUDE_RC_NULL__'

ACTION="start"
RC_SPAWN="worktree"
RC_CAPACITY=""
RC_PERMISSION_MODE="bypassPermissions"
RC_SPAWN_SET=false
RC_CAPACITY_SET=false
RC_PERMISSION_MODE_SET=false
FORCE=false

log_info() { echo "[claude-rc] $*"; }
log_warn() { echo "[claude-rc] WARN: $*" >&2; }
log_error() { echo "[claude-rc] ERROR: $*" >&2; }

iso_timestamp() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    printf '%s:%s\n' "${ts%??}" "${ts: -2}"
}

usage() {
    cat <<'EOF'
claude-rc: Claude Code Remote Control headless multi-instance wrapper

Usage:
  claude-rc [start] [--spawn worktree|same-dir] [--capacity N] [--permission-mode MODE]
  claude-rc stop [--force]
  claude-rc ls
  claude-rc cleanup
  claude-rc --help

Options:
  --spawn <mode>             worktree|same-dir (default: worktree)
  --capacity <N>             Optional capacity. Omitted by default, so upstream uses its default.
  --permission-mode <mode>   acceptEdits|bypassPermissions|default|dontAsk|plan
                             (default: bypassPermissions)
  --force                    Allow stop while worktree sessions exist.
EOF
    printf '\nState:\n'
    printf '  %s/instances.json records managed instances.\n' "$STATE_DIR"
    printf '  %s/<slug>/server.log stores each server'\''s stdout/stderr.\n' "$STATE_DIR"
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_error "required command not found in PATH: $cmd"
        exit 1
    fi
}

require_common_cmds() {
    require_cmd flock
    require_cmd git
    require_cmd jq
    require_cmd lsof
    require_cmd pgrep
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
    exit 1
}

current_git_root() {
    local root
    if ! root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
        log_error "git repo가 아님"
        exit 1
    fi
    printf '%s\n' "$root"
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
    exec 8>"$INSTANCES_LOCK"
    flock 8
    "$@"
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

warn_if_start_options_ignored() {
    local path="$1" registered reg_spawn reg_capacity reg_permission_mode
    local -a diffs=()
    if [ "$RC_SPAWN_SET" != true ] && [ "$RC_CAPACITY_SET" != true ] && [ "$RC_PERMISSION_MODE_SET" != true ]; then
        return 0
    fi
    [ -f "$INSTANCES_FILE" ] || return 0

    registered=$(jq -r --arg path "$path" --arg tsv_null "$TSV_NULL" '
        if (.version == 1 and (.instances | type) == "object" and (.instances | has($path))) then
          .instances[$path]
          | [
              (.spawn // ""),
              (if (.capacity // null) == null then $tsv_null else (.capacity | tostring) end),
              (.permissionMode // "")
            ]
          | @tsv
        else
          empty
        end
    ' "$INSTANCES_FILE")
    [ -n "$registered" ] || return 0

    IFS=$'\t' read -r reg_spawn reg_capacity reg_permission_mode <<<"$registered"
    [ "$reg_capacity" = "$TSV_NULL" ] && reg_capacity=""
    if [ "$RC_SPAWN_SET" = true ] && [ "$RC_SPAWN" != "$reg_spawn" ]; then
        diffs+=("spawn: running=${reg_spawn:-<unset>}, requested=$RC_SPAWN")
    fi
    if [ "$RC_CAPACITY_SET" = true ] && [ "$RC_CAPACITY" != "$reg_capacity" ]; then
        diffs+=("capacity: running=${reg_capacity:-<omitted>}, requested=$RC_CAPACITY")
    fi
    if [ "$RC_PERMISSION_MODE_SET" = true ] && [ "$RC_PERMISSION_MODE" != "$reg_permission_mode" ]; then
        diffs+=("permission-mode: running=${reg_permission_mode:-<unset>}, requested=$RC_PERMISSION_MODE")
    fi

    if [ "${#diffs[@]}" -gt 0 ]; then
        log_warn "실행 중인 서버에는 반영되지 않음 — 변경하려면 claude-rc stop 후 재기동"
        printf '[claude-rc] WARN: %s\n' "${diffs[@]}" >&2
    fi
}

pid_cwd() {
    local pid="$1"
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ {print substr($0, 2); exit}'
}

pid_exe_path() {
    local pid="$1"
    case "$(uname -s)" in
        Darwin) lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ {print substr($0, 2); exit}' ;;
        *) readlink "/proc/$pid/exe" 2>/dev/null ;;
    esac
}

pid_exe_version() {
    local pid="$1" exe
    exe=$(pid_exe_path "$pid") || return 1
    [ -n "$exe" ] || return 1
    case "$exe" in
        *" (deleted)") echo "$(basename "${exe% (deleted)}") (deleted)" ;;
        *) basename "$exe" ;;
    esac
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

find_server_pid_for_path() {
    local path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        same_cwd_as_path "$pid" "$path" || continue
        if is_flock_process "$pid"; then
            continue
        fi
        echo "$pid"
        return 0
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_PROCESS_PATTERN" 2>/dev/null || true)
    return 1
}

has_unmanaged_server_for_path() {
    local path="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        same_cwd_as_path "$pid" "$path" || continue
        if is_flock_process "$pid"; then
            continue
        fi
        return 0
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_PROCESS_PATTERN" 2>/dev/null || true)
    return 1
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

start_server() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local instance_dir lock_path log_path
    instance_dir=$(instance_dir_for_path "$path")
    lock_path="$instance_dir/lock"
    log_path="$instance_dir/server.log"
    mkdir -p "$instance_dir"
    rotate_log_if_needed "$log_path"

    # macOS does not ship setsid. The outer background subshell exits after
    # spawning the inner one, so the server is re-parented and survives terminal,
    # systemd oneshot (KillMode=process), and launchd agent exit. stdin/logs are
    # detached, and SIGHUP is ignored before exec for terminal-close survival.
    (
        cd "$path" || exit 1
        (
            trap '' HUP
            exec </dev/null >>"$log_path" 2>&1
            if [ -n "$capacity" ]; then
                exec env -u CREDENTIALS_DIRECTORY -u PUSHOVER_CRED_FILE -u PUSHOVER_TOKEN -u PUSHOVER_USER -u SERVICE_LIB \
                    flock -n "$lock_path" claude remote-control \
                    --spawn "$spawn" \
                    --permission-mode "$permission_mode" \
                    --capacity "$capacity" \
                    --no-create-session-in-dir
            else
                exec env -u CREDENTIALS_DIRECTORY -u PUSHOVER_CRED_FILE -u PUSHOVER_TOKEN -u PUSHOVER_USER -u SERVICE_LIB \
                    flock -n "$lock_path" claude remote-control \
                    --spawn "$spawn" \
                    --permission-mode "$permission_mode" \
                    --no-create-session-in-dir
            fi
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

parse_args() {
    if [ $# -gt 0 ]; then
        case "$1" in
            start|stop|ls|cleanup)
                ACTION="$1"
                shift
                ;;
            --stop)
                ACTION="stop"
                shift
                ;;
            --cleanup)
                ACTION="cleanup"
                shift
                ;;
            --help|-h|help)
                usage
                exit 0
                ;;
        esac
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --spawn)
                [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 1; }
                case "$2" in
                    worktree|same-dir) ;;
                    *) log_error "Invalid spawn mode: $2"; exit 1 ;;
                esac
                RC_SPAWN="$2"
                RC_SPAWN_SET=true
                shift 2
                ;;
            --capacity)
                [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 1; }
                [[ "$2" =~ ^[0-9]+$ ]] || { log_error "capacity must be a number: $2"; exit 1; }
                RC_CAPACITY="$2"
                RC_CAPACITY_SET=true
                shift 2
                ;;
            --permission-mode)
                [ $# -ge 2 ] || { log_error "$1 requires an argument"; exit 1; }
                case "$2" in
                    acceptEdits|bypassPermissions|default|dontAsk|plan) ;;
                    *) log_error "Invalid permission mode: $2"; exit 1 ;;
                esac
                RC_PERMISSION_MODE="$2"
                RC_PERMISSION_MODE_SET=true
                shift 2
                ;;
            --force)
                FORCE=true
                shift
                ;;
            --help|-h|help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

do_start() {
    require_common_cmds
    require_cmd claude
    local instance_path lock_path log_path env_line
    instance_path=$(current_git_root)
    ensure_instance_dir "$instance_path"
    lock_path=$(lock_path_for_path "$instance_path")
    log_path=$(log_path_for_path "$instance_path")

    if ! lock_is_free "$lock_path"; then
        log_info "이미 실행 중: $instance_path"
        warn_if_start_options_ignored "$instance_path"
        log_info "log: $log_path"
        exit 0
    fi

    # Wrapper-bypassed plain CLI servers do not hold this flock. Starting a
    # second server in the same cwd permanently creates an undeletable ghost
    # environment, so cwd-based process detection is a hard safety gate.
    if has_unmanaged_server_for_path "$instance_path"; then
        log_error "same-dir claude remote-control process already exists outside claude-rc"
        log_error "refusing duplicate start for: $instance_path"
        exit 1
    fi

    start_server "$instance_path" "$RC_SPAWN" "$RC_CAPACITY" "$RC_PERMISSION_MODE"
    sleep 2

    if lock_is_free "$lock_path"; then
        log_error "server failed to start: $instance_path"
        if [ -f "$log_path" ]; then
            tail -n 30 "$log_path" >&2 || true
        fi
        exit 1
    fi

    upsert_instance "$instance_path" "$RC_SPAWN" "$RC_CAPACITY" "$RC_PERMISSION_MODE" "manual"
    log_info "서버 시작됨: $instance_path"
    log_info "log: $log_path"
    env_line=$(grep 'environment=' "$log_path" 2>/dev/null | tail -n 1 || true)
    if [ -n "$env_line" ]; then
        log_info "$env_line"
    else
        log_info "접속 URL은 server.log의 environment= 라인을 확인하세요."
    fi
}

do_stop() {
    require_common_cmds
    local instance_path session_count pid
    instance_path=$(current_git_root)
    ensure_instance_dir "$instance_path"

    session_count=$(count_worktree_session_procs "$instance_path")
    if [ "$session_count" -gt 0 ] && [ "$FORCE" != true ]; then
        log_error "재시작 불가(tombstone) 세션 ${session_count}개 존재"
        log_error "정말 종료하려면: claude-rc stop --force"
        exit 1
    fi

    if pid=$(find_server_pid_for_path "$instance_path"); then
        log_info "SIGTERM: pid=$pid"
        kill -TERM "$pid" 2>/dev/null || true
        if ! wait_until_server_stops "$pid"; then
            log_error "server did not exit within 10s: pid=$pid"
            exit 1
        fi
        log_info "서버 종료됨"
    else
        log_info "서버가 이미 죽어 있음 — 등록만 해제"
    fi

    remove_instance "$instance_path"
}

do_ls() {
    require_common_cmds
    init_instances_file
    printf '%-7s %-8s %-10s %-8s %-12s %-16s %s\n' "RUNNING" "PID" "VERSION" "SPAWN" "SOURCE" "LOG" "PATH"
    jq -r '
        if (.version == 1 and (.instances | type) == "object") then .instances else {} end
        | to_entries[]
        | [.key, .value.spawn, (.value.source // "unknown")]
        | @tsv
    ' "$INSTANCES_FILE" | while IFS=$'\t' read -r path spawn source; do
        [ -n "$path" ] || continue
        local lock_path log_path running pid version
        ensure_instance_dir "$path"
        lock_path=$(lock_path_for_path "$path")
        log_path=$(log_path_for_path "$path")
        running="no"
        pid="-"
        version="-"
        if ! lock_is_free "$lock_path"; then
            running="yes"
            if pid=$(find_server_pid_for_path "$path"); then
                version=$(pid_exe_version "$pid" 2>/dev/null || echo unknown)
            else
                pid="?"
                version="unknown"
            fi
        fi
        printf '%-7s %-8s %-10s %-8s %-12s %-16s %s\n' "$running" "$pid" "$version" "$spawn" "$source" "$log_path" "$path"
    done
}

do_cleanup() {
    require_common_cmds
    local instance_path wt_dir prune_output porcelain_output dir canonical
    local -a live_worktrees=()
    instance_path=$(current_git_root)

    if ! prune_output=$(git -C "$instance_path" worktree prune --expire=now --verbose 2>&1); then
        log_error "git worktree prune 실패"
        echo "$prune_output" >&2
        exit 1
    fi
    if [ -n "$prune_output" ]; then
        log_info "worktree prune:"
        echo "$prune_output"
    fi

    wt_dir="$instance_path/.claude/worktrees"
    if [ ! -d "$wt_dir" ]; then
        log_info "정리할 worktree 디렉토리 없음"
        return 0
    fi

    if ! porcelain_output=$(git -C "$instance_path" worktree list --porcelain 2>&1); then
        log_error "git worktree list 실패 — orphan sweep 건너뜀"
        echo "$porcelain_output" >&2
        exit 1
    fi

    while IFS= read -r line; do
        if [[ "$line" == worktree\ * ]]; then
            live_worktrees+=("${line#worktree }")
        fi
    done <<<"$porcelain_output"

    for dir in "$wt_dir"/*/; do
        [ -d "$dir" ] || continue
        canonical=$(canonical_existing_path "$dir") || continue
        local is_live=false live canonical_live
        for live in "${live_worktrees[@]}"; do
            canonical_live=$(canonical_existing_path "$live" 2>/dev/null || true)
            if [ -n "$canonical_live" ] && [ "$canonical_live" = "$canonical" ]; then
                is_live=true
                break
            fi
        done
        if [ "$is_live" = false ]; then
            log_info "orphan 디렉토리 삭제: $(basename "$dir")"
            rm -rf "$dir"
        fi
    done
    log_info "정리 완료"
}

main() {
    parse_args "$@"
    case "$ACTION" in
        start) do_start ;;
        stop) do_stop ;;
        ls) do_ls ;;
        cleanup) do_cleanup ;;
        *) usage; exit 2 ;;
    esac
}

main "$@"
