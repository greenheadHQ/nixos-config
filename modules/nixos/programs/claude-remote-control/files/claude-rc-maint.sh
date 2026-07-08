#!/usr/bin/env bash
# claude-rc-maint: Claude Code Remote Control headless multi-instance ensure.
#
# This file is packaged by concatenating modules/nixos/scripts/claude-rc-lib.sh
# before it.
#
# NixOS systemd timer and macOS launchd run `claude-rc-maint ensure`
# periodically. The script seeds declared instances, starts dead servers, and
# restarts version-drifted servers when that will not tombstone active worktree
# sessions.
set -euo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-30}"
MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"
PUSHOVER_CRED_FILE="${PUSHOVER_CRED_FILE:-}"
SERVICE_LIB="${SERVICE_LIB:-}"
CLAUDE_RC_DECLARED_INSTANCES="${CLAUDE_RC_DECLARED_INSTANCES:-}"
CLAUDE_RC_PERMISSION_MODE="${CLAUDE_RC_PERMISSION_MODE:-bypassPermissions}"
CLAUDE_RC_ALERT_HOST="${CLAUDE_RC_ALERT_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo claude-rc)}"

PROJECTS_DIR="$HOME/.claude/projects"

DESIRED_VERSION=""
GLOBAL_ACTION="none"
RESULTS_FILE=""

log_info() { echo "[claude-rc-maint] $*"; }
log_error() { echo "[claude-rc-maint] ERROR: $*" >&2; }

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

reconcile_declared_instance_unlocked() {
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
         | if (.instances | has($path)) then
             .instances[$path] = (.instances[$path] + {
               spawn: $spawn,
               capacity: $capacity,
               permissionMode: $permissionMode,
               registeredAt: (.instances[$path].registeredAt // $registeredAt),
               source: "declared"
             })
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
        # Declared paths are authoritative desired state. If a manual start
        # temporarily uses different options, the next ensure reconciles the
        # registry back to the declaration and treats the manual change as an
        # experiment.
        with_instances_lock reconcile_declared_instance_unlocked "$path" "$spawn" "$capacity" "$permission_mode"
    done < <(jq -c '.[]' <<<"$payload")
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

desired_claude_version() {
    basename "$(readlink -f "$CLAUDE_BIN")"
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
    if has_unmanaged_server_for_path "$path"; then
        return 2
    fi
    start_server "$path" "$spawn" "$capacity" "$permission_mode"
    sleep 2
    if lock_is_free "$lock_path"; then
        return 1
    fi
}

handle_restart_result() {
    local path="$1" mode="$2" running_version="$3" restart_rc="$4" action
    if [ "$restart_rc" -eq 0 ]; then
        action="restarted-version-drift"
        log_info "restarted ${mode} drift: $path (${running_version} -> ${DESIRED_VERSION})"
        record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
        return 0
    fi
    if [ "$restart_rc" -eq 2 ]; then
        action="unmanaged-server-present"
        record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
        log_error "unmanaged same-cwd server present after stop: $path"
        return 1
    fi
    action="restart-failed"
    record_instance_result "$path" "$running_version" "$DESIRED_VERSION" "$action"
    return 1
}

capture_started_version() {
    local path="$1" pid
    if pid=$(find_server_pid_for_path "$path"); then
        pid_exe_version "$pid" 2>/dev/null || true
    fi
}

validate_instance_config() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local action

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
}

start_missing_instance() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local action lock_path started_version
    lock_path=$(lock_path_for_path "$path")
    # A wrapper-bypassed plain CLI server in the same cwd does not hold our
    # lock. Starting another server here permanently creates an undeletable
    # ghost environment, so ensure must share the wrapper's cwd guard.
    if has_unmanaged_server_for_path "$path"; then
        action="unmanaged-server-present"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        log_error "unmanaged same-cwd server present: $path"
        return 1
    fi
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
}

handle_running_instance() {
    local path="$1" desired_spawn="$2" capacity="$3" permission_mode="$4"
    local pid running_version action
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

    handle_drift "$path" "$desired_spawn" "$capacity" "$permission_mode" "$pid" "$running_version"
}

handle_drift() {
    local path="$1" desired_spawn="$2" capacity="$3" permission_mode="$4" pid="$5" running_version="$6"
    local effective_spawn gate_rc restart_rc action
    # Registry spawn is desired state and may differ from the already-running
    # server after declaration changes or temporary manual override starts.
    # Restart safety depends on the effective mode of the running process. If
    # argv parsing fails, apply the conservative worktree gate.
    if ! effective_spawn=$(pid_spawn_mode "$pid"); then
        effective_spawn="worktree"
        log_info "running spawn unknown; applying worktree drift gate: $path"
    fi

    case "$effective_spawn" in
        same-dir)
            # Live measurement confirmed same-dir spawned sessions reconnect to
            # the restarted server, so version drift can be corrected eagerly.
            restart_rc=0
            restart_server "$path" "$desired_spawn" "$capacity" "$permission_mode" || restart_rc=$?
            handle_restart_result "$path" "same-dir" "$running_version" "$restart_rc"
            ;;
        worktree)
            gate_rc=0
            restart_gate "$path" || gate_rc=$?
            case "$gate_rc" in
                0)
                    restart_rc=0
                    restart_server "$path" "$desired_spawn" "$capacity" "$permission_mode" || restart_rc=$?
                    handle_restart_result "$path" "worktree" "$running_version" "$restart_rc"
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

process_instance() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local lock_path action

    if [ ! -d "$path" ]; then
        action="path-missing"
        log_info "path missing: $path"
        record_instance_result "$path" "" "$DESIRED_VERSION" "$action"
        return 0
    fi

    validate_instance_config "$path" "$spawn" "$capacity" "$permission_mode" || return 1

    ensure_instance_dir "$path"
    lock_path=$(lock_path_for_path "$path")
    if lock_is_free "$lock_path"; then
        start_missing_instance "$path" "$spawn" "$capacity" "$permission_mode"
    else
        handle_running_instance "$path" "$spawn" "$capacity" "$permission_mode"
    fi
}

ensure_core() {
    local entries rc path spawn capacity permission_mode
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
    while IFS=$'\t' read -r path spawn capacity permission_mode; do
        [ -n "$path" ] || continue
        [ "$capacity" = "$TSV_NULL" ] && capacity=""
        process_instance "$path" "$spawn" "$capacity" "$permission_mode" || rc=1
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

is_failure_action() {
    case "$1" in
        path-missing|started|healthy|restarted-version-drift|deferred-active-sessions|deferred-unknown-activity)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

failed_instance_summary() {
    if [ ! -s "$RESULTS_FILE" ]; then
        printf 'action=%s' "$GLOBAL_ACTION"
        return
    fi
    local summary line path action
    summary=""
    while IFS=$'\t' read -r path action; do
        [ -n "$path" ] || continue
        if is_failure_action "$action"; then
            line="$path: $action"
            if [ -n "$summary" ]; then
                summary="${summary}; ${line}"
            else
                summary="$line"
            fi
        fi
    done < <(jq -r '[.path, .action] | @tsv' "$RESULTS_FILE")
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
