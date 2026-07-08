#!/usr/bin/env bash
# claude-rc-maint: Claude Code Remote Control headless multi-instance ensure.
#
# NixOS systemd timer and macOS launchd run `claude-rc-maint ensure`
# periodically. The script seeds declared instances, starts dead servers, and
# restarts version-drifted servers when that will not tombstone active worktree
# sessions.
set -euo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-rc}"
INSTANCES_FILE="$STATE_DIR/instances.json"
INSTANCES_LOCK="$STATE_DIR/instances.json.lock"
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-30}"
MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"
PUSHOVER_CRED_FILE="${PUSHOVER_CRED_FILE:-}"
SERVICE_LIB="${SERVICE_LIB:-}"
CLAUDE_RC_DECLARED_INSTANCES="${CLAUDE_RC_DECLARED_INSTANCES:-}"
CLAUDE_RC_PERMISSION_MODE="${CLAUDE_RC_PERMISSION_MODE:-bypassPermissions}"
CLAUDE_RC_ALERT_HOST="${CLAUDE_RC_ALERT_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo claude-rc)}"

LOG_MAX_BYTES=$((5 * 1024 * 1024))
PROJECTS_DIR="$HOME/.claude/projects"
BRIDGE_PROCESS_PATTERN='claude remote-control'
# Spawned session argv may be the versioned Claude binary path, so --sdk-url is
# the stable selector. The leading [-] avoids pgrep treating the pattern as an
# option.
BRIDGE_CHILD_PROCESS_PATTERN='[-]-sdk-url'
TSV_NULL='__CLAUDE_RC_NULL__'

DESIRED_VERSION=""
GLOBAL_ACTION="none"
RESULTS_FILE=""

log_info() { echo "[claude-rc-maint] $*"; }
log_error() { echo "[claude-rc-maint] ERROR: $*" >&2; }

iso_timestamp() {
    local ts
    ts=$(date '+%Y-%m-%dT%H:%M:%S%z')
    printf '%s:%s\n' "${ts%??}" "${ts: -2}"
}

#───────────────────────────────────────────────────────────────────────────────
# flock 직렬화 (수동 실행과 timer의 동시 실행 방지)
#───────────────────────────────────────────────────────────────────────────────
with_lock() {
    mkdir -p "$STATE_DIR"
    if ! command -v flock >/dev/null 2>&1; then
        GLOBAL_ACTION="flock-missing"
        log_error "required command not found in PATH: flock"
        return 1
    fi
    exec 9>"$STATE_DIR/ensure.lock"
    if ! flock --timeout "$MAINT_LOCK_TIMEOUT_SECONDS" 9; then
        GLOBAL_ACTION="lock-acquire-timeout"
        return 1
    fi
    # fd 9는 이 셸이 락을 유지하는 동안만 살아야 한다. 9>&- 없이 실행하면
    # detach되는 headless bridge가 fd 9를 상속해 락을 영구 점유하고
    # 이후 모든 타이머 실행이 lock-acquire-timeout으로 실패한다
    # (codex-remote-control-maint.sh의 PR #983과 동일 근거).
    "$@" 9>&-
}

with_instances_lock() {
    mkdir -p "$STATE_DIR"
    (
        flock 8
        "$@"
    ) 8>"$INSTANCES_LOCK"
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

upsert_declared_if_absent_unlocked() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
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
        --argjson capacity "$capacity_json" \
        'if (.version == 1 and (.instances | type) == "object") then . else {version: 1, instances: {}} end
         | if (.instances | has($path)) then .
           else .instances[$path] = {
             spawn: $spawn,
             capacity: $capacity,
             permissionMode: $permissionMode,
             registeredAt: $registeredAt,
             source: "declared"
           }
           end' \
        "$INSTANCES_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$INSTANCES_FILE"
}

seed_declared_instances() {
    local payload item path spawn capacity permission_mode
    payload="$CLAUDE_RC_DECLARED_INSTANCES"
    if [ -z "${payload//[[:space:]]/}" ]; then
        return 0
    fi
    if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$payload"; then
        GLOBAL_ACTION="declared-instances-invalid"
        log_error "CLAUDE_RC_DECLARED_INSTANCES must be a JSON array"
        return 1
    fi

    while IFS= read -r item; do
        [ -n "$item" ] || continue
        path=$(jq -r '.path // empty' <<<"$item")
        spawn=$(jq -r '.spawn // "worktree"' <<<"$item")
        capacity=$(jq -r 'if (.capacity // null) == null then "" else (.capacity | tostring) end' <<<"$item")
        permission_mode=$(jq -r --arg fallback "$CLAUDE_RC_PERMISSION_MODE" '.permissionMode // $fallback' <<<"$item")

        if [ -z "$path" ] || [[ "$path" != /* ]]; then
            GLOBAL_ACTION="declared-instances-invalid"
            log_error "declared instance path must be absolute: ${path:-<empty>}"
            return 1
        fi
        if [ -d "$path" ]; then
            path=$(canonical_existing_path "$path")
        fi
        if ! validate_spawn "$spawn"; then
            GLOBAL_ACTION="declared-instances-invalid"
            log_error "invalid declared spawn for $path: $spawn"
            return 1
        fi
        if [ -n "$capacity" ] && ! [[ "$capacity" =~ ^[0-9]+$ ]]; then
            GLOBAL_ACTION="declared-instances-invalid"
            log_error "invalid declared capacity for $path: $capacity"
            return 1
        fi
        if ! validate_permission_mode "$permission_mode"; then
            GLOBAL_ACTION="declared-instances-invalid"
            log_error "invalid declared permissionMode for $path: $permission_mode"
            return 1
        fi
        with_instances_lock upsert_declared_if_absent_unlocked "$path" "$spawn" "$capacity" "$permission_mode"
    done < <(jq -c '.[]' <<<"$payload")
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
            (.value.permissionMode // "bypassPermissions"),
            (.value.source // "unknown")
          ]
        | @tsv
    ' "$INSTANCES_FILE"
}

record_instance_result() {
    local path="$1" running_version="$2" desired_version="$3" action="$4"
    jq -n -c \
        --arg path "$path" \
        --arg runningVersion "$running_version" \
        --arg desiredVersion "$desired_version" \
        --arg action "$action" \
        '{path: $path, runningVersion: $runningVersion, desiredVersion: $desiredVersion, action: $action}' \
        >>"$RESULTS_FILE"
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

desired_claude_version() {
    basename "$(readlink -f "$CLAUDE_BIN")"
}

pid_cwd() {
    local pid="$1"
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | awk '/^n/ {print substr($0, 2); exit}'
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

normalized_instance_prefix() {
    local path="$1"
    printf '%s' "$path" | sed 's/[^[:alnum:]]/-/g'
}

worktree_transcript_prefix() {
    local instance_path="$1"
    # Worktree spawn transcripts use the normalized absolute worktree path.
    # Since spawned worktrees live under <instance>/.claude/worktrees/<name>,
    # their project dirs always begin with:
    # <normalized instance path>--claude-worktrees-
    # Matching that prefix excludes the instance root transcript dir, which can
    # be updated by unrelated local/same-dir sessions and must not defer a
    # worktree drift restart.
    printf '%s--claude-worktrees-' "$(normalized_instance_prefix "$instance_path")"
}

count_matching_transcript_dirs() {
    local instance_path="$1" prefix
    [ -d "$PROJECTS_DIR" ] || { echo 0; return; }
    prefix=$(worktree_transcript_prefix "$instance_path")
    find "$PROJECTS_DIR" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null | wc -l
}

count_recent_instance_transcripts() {
    local instance_path="$1" prefix total=0 dir count
    [ -d "$PROJECTS_DIR" ] || { echo 0; return; }
    prefix=$(worktree_transcript_prefix "$instance_path")
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        count=$(find "$dir" -maxdepth 1 -name '*.jsonl' -mmin "-$IDLE_THRESHOLD_MINUTES" 2>/dev/null | wc -l)
        total=$((total + count))
    done < <(find "$PROJECTS_DIR" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null)
    echo "$total"
}

restart_gate() {
    local instance_path="$1" recent_count session_procs transcript_dir_count
    recent_count=$(count_recent_instance_transcripts "$instance_path")
    session_procs=$(count_worktree_session_procs "$instance_path")

    if [ "$recent_count" -gt 0 ]; then
        return 1
    fi
    if [ "$session_procs" -eq 0 ]; then
        return 0
    fi
    transcript_dir_count=$(count_matching_transcript_dirs "$instance_path")
    if [ "$transcript_dir_count" -gt 0 ]; then
        return 0
    fi
    return 2
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

restart_server() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4" pid lock_path
    lock_path=$(lock_path_for_path "$path")
    if pid=$(find_server_pid_for_path "$path"); then
        kill -TERM "$pid" 2>/dev/null || true
        wait_until_server_stops "$pid" || return 1
    elif ! lock_is_free "$lock_path"; then
        return 1
    fi

    if ! lock_is_free "$lock_path"; then
        return 1
    fi
    start_server "$path" "$spawn" "$capacity" "$permission_mode"
    sleep 2
    if lock_is_free "$lock_path"; then
        return 1
    fi
}

capture_started_version() {
    local path="$1" pid
    if pid=$(find_server_pid_for_path "$path"); then
        pid_exe_version "$pid" 2>/dev/null || true
    fi
}

process_instance() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4" source="$5"
    local lock_path pid running_version action gate_rc started_version
    : "$source"

    if [ ! -d "$path" ]; then
        action="path-missing"
        log_info "path missing: $path"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        return 0
    fi

    if ! validate_spawn "$spawn"; then
        action="invalid-spawn"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        return 1
    fi
    if [ -n "$capacity" ] && ! [[ "$capacity" =~ ^[0-9]+$ ]]; then
        action="invalid-capacity"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        return 1
    fi
    if ! validate_permission_mode "$permission_mode"; then
        action="invalid-permission-mode"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        return 1
    fi

    ensure_instance_dir "$path"
    lock_path=$(lock_path_for_path "$path")
    if lock_is_free "$lock_path"; then
        start_server "$path" "$spawn" "$capacity" "$permission_mode"
        sleep 2
        if lock_is_free "$lock_path"; then
            action="start-failed"
            record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
            log_error "start failed: $path"
            return 1
        fi
        started_version=$(capture_started_version "$path")
        action="started"
        record_instance_result "$path" "$started_version" "$DESIRED_VERSION" "$action"
        log_info "started: $path"
        return 0
    fi

    if ! pid=$(find_server_pid_for_path "$path"); then
        action="no-server-process"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        log_error "lock held but server process not found: $path"
        return 1
    fi

    if ! running_version=$(pid_exe_version "$pid"); then
        action="running-version-unresolvable"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        return 1
    fi

    if [ "$running_version" = "$DESIRED_VERSION" ]; then
        action="healthy"
        record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
        return 0
    fi

    case "$spawn" in
        same-dir)
            # Live measurement confirmed same-dir spawned sessions reconnect to
            # the restarted server, so version drift can be corrected eagerly.
            if restart_server "$path" "$spawn" "$capacity" "$permission_mode"; then
                action="restarted-version-drift"
                log_info "restarted same-dir drift: $path (${running_version} -> ${DESIRED_VERSION})"
                record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
                return 0
            fi
            action="restart-failed"
            record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
            return 1
            ;;
        worktree)
            gate_rc=0
            restart_gate "$path" || gate_rc=$?
            case "$gate_rc" in
                0)
                    if restart_server "$path" "$spawn" "$capacity" "$permission_mode"; then
                        action="restarted-version-drift"
                        log_info "restarted worktree drift: $path (${running_version} -> ${DESIRED_VERSION})"
                        record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
                        return 0
                    fi
                    action="restart-failed"
                    record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
                    return 1
                    ;;
                1)
                    action="deferred-active-sessions"
                    record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
                    log_info "deferred active worktree sessions: $path"
                    return 0
                    ;;
                2)
                    action="deferred-unknown-activity"
                    record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
                    log_info "deferred unknown worktree activity: $path"
                    return 0
                    ;;
                *)
                    action="restart-gate-failed"
                    record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
                    return 1
                    ;;
            esac
            ;;
        *)
            action="invalid-spawn"
            record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
            return 1
            ;;
    esac
}

ensure_core() {
    local entries rc path spawn capacity permission_mode source
    GLOBAL_ACTION="running"

    seed_declared_instances || return 1

    if ! DESIRED_VERSION=$(desired_claude_version); then
        GLOBAL_ACTION="desired-version-unresolvable"
        return 1
    fi

    if ! entries=$(with_instances_lock emit_instances_tsv_unlocked); then
        GLOBAL_ACTION="instances-read-failed"
        return 1
    fi
    if [ -z "$entries" ]; then
        GLOBAL_ACTION="no-instances"
        log_info "no registered instances"
        return 0
    fi

    rc=0
    while IFS=$'\t' read -r path spawn capacity permission_mode source; do
        [ -n "$path" ] || continue
        [ "$capacity" = "$TSV_NULL" ] && capacity=""
        process_instance "$path" "$spawn" "$capacity" "$permission_mode" "$source" || rc=1
    done <<<"$entries"

    if [ "$rc" -eq 0 ]; then
        GLOBAL_ACTION="completed"
    else
        GLOBAL_ACTION="failed"
    fi
    return "$rc"
}

write_status() {
    local exit_code="${1:-0}" tmp
    mkdir -p "$STATE_DIR"
    tmp=$(mktemp "$STATE_DIR/status.XXXXXX") || return 1
    jq -s \
        --arg timestamp "$(iso_timestamp)" \
        --arg action "$GLOBAL_ACTION" \
        --argjson exitCode "$exit_code" \
        '{
          timestamp: $timestamp,
          exitCode: $exitCode,
          action: $action,
          instances: .
        }' "$RESULTS_FILE" >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$STATE_DIR/status.json"
}

load_alerting() {
    # shellcheck source=/dev/null
    [ -n "$SERVICE_LIB" ] && [ -f "$SERVICE_LIB" ] && source "$SERVICE_LIB"
    local cred
    cred="$PUSHOVER_CRED_FILE"
    if [ -z "$cred" ] && [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
        cred="$CREDENTIALS_DIRECTORY/pushover-system-monitor"
    fi
    if [ -n "$cred" ] && [ -r "$cred" ]; then
        # shellcheck source=/dev/null
        source "$cred"
    fi
}

failed_instance_summary() {
    if [ ! -s "$RESULTS_FILE" ]; then
        printf 'action=%s' "$GLOBAL_ACTION"
        return
    fi
    local summary
    summary=$(jq -r '
        [
          .[]
          | select(.action as $action
              | ["start-failed", "restart-failed", "no-server-process",
                 "running-version-unresolvable", "invalid-spawn",
                 "invalid-capacity", "invalid-permission-mode",
                 "restart-gate-failed"] | index($action))
          | "\(.path): \(.action)"
        ]
        | if length == 0 then "" else join("; ") end
    ' "$RESULTS_FILE")
    if [ -n "$summary" ]; then
        printf '%s' "$summary"
    else
        printf 'action=%s' "$GLOBAL_ACTION"
    fi
}

send_alerts() {
    local exit_code="$1"
    # graceful fallback: hosts without credentials or service-lib skip
    # notification only; ensure itself still runs and records status.
    if ! command -v send_notification >/dev/null 2>&1 \
        || [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
        log_info "알림 스킵 (Pushover 크리덴셜/서비스 lib 없음)"
        return 0
    fi

    local now state_file last_failure_file previous last summary
    now=$(date +%s)
    state_file="$STATE_DIR/last-health-state"
    last_failure_file="$STATE_DIR/last-failure-alert"
    previous="unknown"
    if [ -f "$state_file" ]; then
        previous=$(cat "$state_file" 2>/dev/null || echo unknown)
    fi

    if [ "$exit_code" -eq 0 ]; then
        if [ "$previous" = "failed" ]; then
            send_notification "Claude RC Recovered" \
                "${CLAUDE_RC_ALERT_HOST} claude-rc ensure is healthy (desired=${DESIRED_VERSION:-unknown})." 0
        fi
        echo "healthy" >"$state_file"
        return 0
    fi

    last=0
    if [ -f "$last_failure_file" ]; then
        last=$(cat "$last_failure_file" 2>/dev/null || echo 0)
    fi
    if [ $((now - last)) -ge "$ALERT_COOLDOWN_SECONDS" ]; then
        summary=$(failed_instance_summary)
        send_notification "Claude RC Ensure Failed" \
            "exit=${exit_code}, action=${GLOBAL_ACTION}, failed=${summary}, desired=${DESIRED_VERSION:-unknown}" 0
        echo "$now" >"$last_failure_file"
    fi
    echo "failed" >"$state_file"
}

cmd_ensure() {
    local rc
    rc=0
    mkdir -p "$STATE_DIR"
    RESULTS_FILE=$(mktemp "$STATE_DIR/results.XXXXXX") || return 1
    with_lock ensure_core || rc=$?
    # 단일 finalizer: 어떤 분기도 이 경로를 우회하지 않는다
    # (recovered/failure 알림 상태 전이가 모든 실행에서 평가되도록).
    write_status "$rc" || true
    # source되는 credential/lib 파일이 malformed여도 (source가 && 리스트의
    # 마지막 명령이라 set -e 발동) finalizer가 send_alerts 전에 죽지 않게 guard.
    load_alerting || true
    send_alerts "$rc" || true
    rm -f "$RESULTS_FILE"
    return "$rc"
}

usage() {
    cat >&2 <<'EOF'
Usage: claude-rc-maint ensure

env:
  CLAUDE_BIN, STATE_DIR, CLAUDE_RC_DECLARED_INSTANCES,
  IDLE_THRESHOLD_MINUTES (default 30), MAINT_LOCK_TIMEOUT_SECONDS (default 120),
  ALERT_COOLDOWN_SECONDS (default 1800), PUSHOVER_CRED_FILE, SERVICE_LIB,
  CLAUDE_RC_PERMISSION_MODE, CLAUDE_RC_ALERT_HOST

CLAUDE_RC_DECLARED_INSTANCES:
  JSON array, for example:
  [{"path":"/path/to/project","spawn":"worktree","capacity":null}]

Status:
  cat $STATE_DIR/status.json (default ~/.local/state/claude-rc/status.json)
EOF
}

main() {
    case "${1:-}" in
        ensure) cmd_ensure ;;
        -h|--help|help) usage ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
