#!/usr/bin/env bash
# claude-rc-maint: Claude Code Remote Control headless multi-instance ensure.
#
# This file is packaged by concatenating modules/nixos/scripts/claude-rc-lib.sh
# before it.
#
# NixOS systemd timer and macOS launchd run `claude-rc-maint ensure`
# periodically. The script seeds declared instances, starts dead servers, and
# applies the host-selected policy to live version drift.
set -euo pipefail

CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-30}"
MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"
PUSHOVER_CRED_FILE="${PUSHOVER_CRED_FILE:-}"
SERVICE_LIB="${SERVICE_LIB:-}"
CLAUDE_RC_DECLARED_INSTANCES="${CLAUDE_RC_DECLARED_INSTANCES:-}"
CLAUDE_RC_PERMISSION_MODE="${CLAUDE_RC_PERMISSION_MODE:-bypassPermissions}"
CLAUDE_RC_DRIFT_POLICY="${CLAUDE_RC_DRIFT_POLICY:-defer}"
CLAUDE_RC_DRIFT_APPROVAL_JSON="${CLAUDE_RC_DRIFT_APPROVAL_JSON:-[]}"
CLAUDE_RC_ALERT_HOST="${CLAUDE_RC_ALERT_HOST:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo claude-rc)}"
# launchd StandardOutPath처럼 append-only로 자라는 ensure 로그. 비어 있으면(NixOS journald) 로테이션을 건너뛴다.
CLAUDE_RC_ENSURE_LOG="${CLAUDE_RC_ENSURE_LOG:-}"

PROJECTS_DIR="$HOME/.claude/projects"

CLAUDE_LAUNCHER=""
DESIRED_VERSION=""
GLOBAL_ACTION="none"
CONFIRMED_DRIFT_APPROVALS="[]"
RESULTS_FILE=""

# launchd 로그에는 타임스탬프가 없어 실패 구간을 라인 수로 역산해야 했다 (#no-server-process 조사).
log_stamp() { date "+%Y-%m-%dT%H:%M:%S%z"; }
log_info() { echo "[claude-rc-maint $(log_stamp)] $*"; }
log_error() { echo "[claude-rc-maint $(log_stamp)] ERROR: $*" >&2; }

global_status_action_keys() {
    cat <<'EOF'
flock-missing
lock-acquire-timeout
lock-setup-failed
declared-instances-invalid
invalid-drift-policy
invalid-drift-approval
desired-version-unresolvable
instances-read-failed
no-instances
completed
failed
EOF
}

global_diagnostic_action_keys() {
    printf '%s\n' status-write-failed
}

global_action_keys() {
    global_status_action_keys
    global_diagnostic_action_keys
}

set_global_action() {
    local wanted="$1" action
    while IFS= read -r action; do
        if [ "$action" = "$wanted" ]; then
            GLOBAL_ACTION="$wanted"
            return 0
        fi
    done < <(global_action_keys)
    log_error "unknown global action: $wanted"
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# flock 직렬화 (maint 실행과 interactive start/stop의 동시 lifecycle 변경 방지)
#───────────────────────────────────────────────────────────────────────────────
maint_lifecycle_lock_missing() {
    set_global_action flock-missing
    log_error "required command not found in PATH: flock"
}

maint_lifecycle_lock_timeout() {
    set_global_action lock-acquire-timeout
}

maint_lifecycle_lock_setup_failed() {
    set_global_action lock-setup-failed
    log_error "lifecycle lock setup failed: $1"
}

with_lock() {
    with_lifecycle_lock_fd9 \
        "$MAINT_LOCK_TIMEOUT_SECONDS" \
        "$STATE_DIR/ensure.lock" \
        maint_lifecycle_lock_missing \
        maint_lifecycle_lock_timeout \
        maint_lifecycle_lock_setup_failed \
        "$@"
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
        set_global_action declared-instances-invalid
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
            set_global_action declared-instances-invalid
            log_error "declared instance path must be absolute: ${path:-<empty>}"
            return 1
        fi
        if [ -d "$path" ]; then
            path=$(canonical_existing_path "$path")
        fi
        if ! validate_spawn "$spawn"; then
            set_global_action declared-instances-invalid
            log_error "invalid declared spawn for $path: $spawn"
            return 1
        fi
        if [ -n "$capacity" ] && ! [[ "$capacity" =~ ^[0-9]+$ ]]; then
            set_global_action declared-instances-invalid
            log_error "invalid declared capacity for $path: $capacity"
            return 1
        fi
        if ! validate_permission_mode "$permission_mode"; then
            set_global_action declared-instances-invalid
            log_error "invalid declared permissionMode for $path: $permission_mode"
            return 1
        fi
        # Declared paths are authoritative desired state. If a manual start
        # temporarily uses different options, the next ensure reconciles the
        # registry back to the declaration and treats the manual change as an
        # experiment.
        # cmd_ensure runs this subtree under `|| rc=$?`, which disables set -e,
        # so a reconcile failure (mktemp/jq) must be propagated explicitly or
        # the declared instance is silently never registered nor ensured.
        if ! with_instances_lock reconcile_declared_instance_unlocked "$path" "$spawn" "$capacity" "$permission_mode"; then
            set_global_action declared-instances-invalid
            log_error "failed to reconcile declared instance: $path"
            return 1
        fi
    done < <(jq -c '.[]' <<<"$payload")
}

instance_action_metadata_table() {
    cat <<'EOF'
path-missing	stopped	false
path-missing-lock-held	unknown	true
started	running	false
healthy	running	false
restarted-version-drift	running	false
deferred-restart-confirmation	running	false
restart-approval-mismatch	running	true
deferred-active-sessions	running	false
deferred-unknown-activity	running	false
start-version-mismatch	stopped	true
restart-version-mismatch	stopped	true
restart-gate-failed	running	true
start-failed	dynamic	true
invalid-spawn	dynamic	true
invalid-capacity	unknown	true
invalid-permission-mode	unknown	true
unmanaged-server-present	unknown	true
start-version-unresolvable	unknown	true
start-version-unresolvable-cleaned	stopped	true
start-version-mismatch-cleanup-failed	unknown	true
no-server-process	unknown	true
running-version-unresolvable	unknown	true
restart-failed	unknown	true
restart-version-unresolvable	unknown	true
restart-version-unresolvable-cleaned	stopped	true
restart-version-mismatch-cleanup-failed	unknown	true
EOF
}

instance_action_metadata() {
    local wanted="$1" action state failure
    while IFS=$'\t' read -r action state failure; do
        if [ "$action" = "$wanted" ]; then
            # `dynamic` actions can be emitted before identity is known or
            # while a previously identified process is still running. The
            # caller supplies observed state; failure classification stays in
            # this canonical table.
            printf '%s\t%s\n' "$state" "$failure"
            return 0
        fi
    done < <(instance_action_metadata_table)
    return 1
}

# 알림 본문용 인스턴스별 근거. RESULTS_FILE 옆 .detail에 path<TAB>텍스트로 남기고
# cmd_ensure가 함께 지운다. status.json 스키마에는 넣지 않는다.
record_instance_detail() {
    printf '%s\t%s\n' "$1" "$2" >>"$RESULTS_FILE.detail" 2>/dev/null || true
}

instance_detail_for_path() {
    [ -f "$RESULTS_FILE.detail" ] || return 0
    awk -F'\t' -v p="$1" '$1 == p { print $2; exit }' "$RESULTS_FILE.detail"
}

record_instance_result() {
    local path="$1" running_version="$2" observed_version="$3"
    local desired_version="$4" action="$5" state_override="${6:-}"
    local metadata process_state
    if ! metadata=$(instance_action_metadata "$action"); then
        log_error "unknown instance action metadata: $action"
        return 1
    fi
    IFS=$'\t' read -r process_state _ <<<"$metadata"
    if [ "$process_state" = "dynamic" ]; then
        process_state="$state_override"
    elif [ -n "$state_override" ] && [ "$state_override" != "$process_state" ]; then
        log_error "instance action/state mismatch: $action/$state_override (expected $process_state)"
        return 1
    fi
    case "$process_state" in
        running)
            [ -n "$running_version" ] || return 1
            ;;
        stopped | unknown)
            [ -z "$running_version" ] || return 1
            ;;
        *) return 1 ;;
    esac
    jq -n -c \
        --arg path "$path" \
        --arg processState "$process_state" \
        --arg runningVersion "$running_version" \
        --arg observedVersion "$observed_version" \
        --arg desiredVersion "$desired_version" \
        --arg action "$action" \
        '{path: $path, processState: $processState,
          runningVersion: $runningVersion, observedVersion: $observedVersion,
          desiredVersion: $desiredVersion, action: $action}' \
        >>"$RESULTS_FILE"
}

resolve_claude_launcher() {
    local resolved versions_root
    # Resolve both boundaries once before any launcher can run. The verified
    # canonical executable, not the mutable symlink, is used for every start so
    # a retarget between version comparison and exec cannot cross the boundary.
    versions_root=$(canonical_existing_path "$VERSIONS_DIR") || {
        log_error "Claude versions directory is not resolvable: $VERSIONS_DIR"
        return 1
    }
    resolved=$(readlink -f "$CLAUDE_BIN") || {
        log_error "Claude launcher is not resolvable: $CLAUDE_BIN"
        return 1
    }
    [ -n "$resolved" ] && [ -f "$resolved" ] && [ -x "$resolved" ] || {
        log_error "Claude launcher target is not an executable file: ${resolved:-<empty>}"
        return 1
    }
    case "$resolved" in
        "$versions_root"/*) ;;
        *)
            log_error "Claude launcher target is outside VERSIONS_DIR: $resolved"
            return 1
            ;;
    esac
    VERSIONS_DIR="$versions_root"
    CLAUDE_LAUNCHER="$resolved"
    DESIRED_VERSION=$(basename "$resolved")
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
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local result_outcome_var="$5" result_version_var="$6"
    local pid lock_path launch_status started_pid started_version
    printf -v "$result_outcome_var" '%s' "restart-failed"
    printf -v "$result_version_var" '%s' ""
    lock_path=$(lock_path_for_path "$path")
    if pid=$(find_server_pid_for_path "$path"); then
        # Discovery and signal are separate syscalls; fail closed if the PID no
        # longer has the exact managed launcher/lock lineage at action time.
        pid_is_managed_server_for_path "$pid" "$path" || return 0
        kill -TERM "$pid" 2>/dev/null || true
        wait_until_server_stops "$pid" || return 0
        wait_until_instance_lock_free "$lock_path" || return 0
    elif ! lock_is_free "$lock_path"; then
        return 0
    fi

    if ! lock_is_free "$lock_path"; then
        return 0
    fi
    if has_unmanaged_server_for_path "$path"; then
        printf -v "$result_outcome_var" '%s' "unmanaged-server-present"
        return 0
    fi

    launch_and_verify_server \
        "$path" "$spawn" "$capacity" "$permission_mode" "$CLAUDE_LAUNCHER" \
        launch_status started_pid started_version
    case "$launch_status" in
        launch-failed)
            return 0
            ;;
        identity-unresolvable)
            log_error "restart failed; server process/version unresolvable: $path"
            printf -v "$result_outcome_var" '%s' "restart-version-unresolvable"
            return 0
            ;;
        identity-unresolvable-cleaned)
            log_error "restart failed; server process/version unresolvable; replacement stopped: $path"
            printf -v "$result_outcome_var" '%s' "restart-version-unresolvable-cleaned"
            return 0
            ;;
        started)
            printf -v "$result_version_var" '%s' "$started_version"
            ;;
        *)
            log_error "restart failed; unknown launch outcome: $launch_status"
            return 0
            ;;
    esac

    if [ "$started_version" != "$DESIRED_VERSION" ]; then
        if stop_verified_started_server "$path" "$started_pid" "$started_version"; then
            printf -v "$result_outcome_var" '%s' "restart-version-mismatch"
        else
            printf -v "$result_outcome_var" '%s' "restart-version-mismatch-cleanup-failed"
        fi
        return 0
    fi
    printf -v "$result_outcome_var" '%s' "restarted-version-drift"
}

record_restart_outcome() {
    local path="$1" mode="$2" running_version="$3" outcome="$4" started_version="$5"
    case "$outcome" in
        restarted-version-drift)
            log_info "restarted ${mode} drift: $path (${running_version} -> ${started_version})"
            record_instance_result \
                "$path" "$started_version" "$started_version" "$DESIRED_VERSION" "$outcome" \
                || return 1
            return 0
            ;;
        unmanaged-server-present)
            record_instance_result \
                "$path" "" "${started_version:-$running_version}" "$DESIRED_VERSION" "$outcome"
            log_error "unmanaged same-cwd server present after stop: $path"
            ;;
        restart-version-mismatch)
            record_instance_result \
                "$path" "" "$started_version" "$DESIRED_VERSION" "$outcome"
            log_error "restart version mismatch: $path (started=${started_version:-unresolved}, desired=${DESIRED_VERSION})"
            ;;
        restart-version-mismatch-cleanup-failed)
            record_instance_result \
                "$path" "" "$started_version" "$DESIRED_VERSION" "$outcome"
            log_error "restart version mismatch cleanup failed: $path (started=${started_version:-unresolved}, desired=${DESIRED_VERSION})"
            ;;
        restart-version-unresolvable)
            record_instance_result "$path" "" "" "$DESIRED_VERSION" "$outcome"
            log_error "restart replacement version unresolvable: $path"
            ;;
        restart-version-unresolvable-cleaned)
            record_instance_result \
                "$path" "" "" "$DESIRED_VERSION" "$outcome"
            log_error "restart replacement version unresolvable and stopped: $path"
            ;;
        restart-failed)
            record_instance_result \
                "$path" "" "${started_version:-$running_version}" "$DESIRED_VERSION" "$outcome"
            ;;
        *)
            log_error "unknown restart outcome: $outcome"
            record_instance_result \
                "$path" "" "${started_version:-$running_version}" "$DESIRED_VERSION" "restart-failed"
            ;;
    esac
    return 1
}

validate_instance_config() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local action

    if ! validate_spawn "$spawn"; then
        action="invalid-spawn"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action" unknown
        return 1
    fi
    if [ -n "$capacity" ] && ! [[ "$capacity" =~ ^[0-9]+$ ]]; then
        action="invalid-capacity"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
        return 1
    fi
    if ! validate_permission_mode "$permission_mode"; then
        action="invalid-permission-mode"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
        return 1
    fi
}

start_missing_instance() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local action reaped launch_status started_pid started_version
    # A wrapper-bypassed plain CLI server in the same cwd does not hold our
    # lock. Starting another server here permanently creates an undeletable
    # ghost environment, so ensure must share the wrapper's cwd guard.
    if has_unmanaged_server_for_path "$path"; then
        action="unmanaged-server-present"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
        log_error "unmanaged same-cwd server present: $path"
        return 1
    fi
    # SIGKILLed servers can leave --sdk-url session children re-parented to
    # init. They are not remote-control servers and do not match the unmanaged
    # server guard above; preserving them only keeps broken, unreachable
    # sessions around, so reap them before the replacement server starts.
    reaped=$(reap_orphan_session_procs_for_path "$path") || reaped=0
    if [ "$reaped" -gt 0 ]; then
        log_info "reaped ${reaped} orphan session process(es): $path"
    fi
    launch_and_verify_server \
        "$path" "$spawn" "$capacity" "$permission_mode" "$CLAUDE_LAUNCHER" \
        launch_status started_pid started_version
    case "$launch_status" in
        launch-failed)
            action="start-failed"
            # No verified launcher/lock identity exists on this path. A
            # successor may have acquired the instance lock as our guardian
            # returned, so never claim a global stopped state from launch
            # failure alone.
            record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action" unknown
            log_error "start failed: $path"
            return 1
            ;;
        identity-unresolvable)
            action="start-version-unresolvable"
            record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
            log_error "start failed; server process/version unresolvable: $path"
            return 1
            ;;
        identity-unresolvable-cleaned)
            action="start-version-unresolvable-cleaned"
            record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
            log_error "start failed; server process/version unresolvable; replacement stopped: $path"
            return 1
            ;;
        started)
            ;;
        *)
            action="start-failed"
            record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action" unknown
            log_error "start failed; unknown launch outcome: $launch_status"
            return 1
            ;;
    esac
    if [ "$started_version" != "$DESIRED_VERSION" ]; then
        if stop_verified_started_server "$path" "$started_pid" "$started_version"; then
            action="start-version-mismatch"
            log_error "start version mismatch: $path (started=${started_version}, desired=${DESIRED_VERSION})"
        else
            action="start-version-mismatch-cleanup-failed"
            log_error "start version mismatch cleanup failed: $path (started=${started_version}, desired=${DESIRED_VERSION})"
        fi
        record_instance_result \
            "$path" "" "$started_version" "$DESIRED_VERSION" "$action"
        return 1
    fi
    action="started"
    record_instance_result \
        "$path" "$started_version" "$started_version" "$DESIRED_VERSION" "$action" \
        || return 1
    log_info "started: $path"
}

normalize_confirmed_drift_approvals() {
    jq -ce '
      if type != "array" or length == 0 then
        error("approval must be a non-empty array")
      elif all(.[];
        type == "object"
        and (keys | sort) == ["desiredVersion", "path", "runningVersion"]
        and (.path | type) == "string" and (.path | length) > 0
        and (.runningVersion | type) == "string" and (.runningVersion | length) > 0
        and (.desiredVersion | type) == "string" and (.desiredVersion | length) > 0
      ) then
        map({path, runningVersion, desiredVersion})
        | sort_by([.path, .runningVersion, .desiredVersion])
      else
        error("approval entries must contain exact non-empty path/version fields")
      end
    ' <<<"$CLAUDE_RC_DRIFT_APPROVAL_JSON"
}

collect_current_drift_approvals() {
    local entries="$1" path lock_path pid running_version
    local _spawn _capacity _permission_mode

    while IFS=$'\t' read -r path _spawn _capacity _permission_mode; do
        [ -n "$path" ] || continue
        [ -d "$path" ] || continue
        lock_path=$(lock_path_for_path "$path")
        lock_is_free "$lock_path" && continue
        if ! pid=$(find_server_pid_for_path "$path"); then
            log_error "cannot bind confirmed drift approval to server identity: $path"
            return 1
        fi
        if ! running_version=$(pid_exe_version "$pid"); then
            log_error "cannot bind confirmed drift approval to running version: $path"
            return 1
        fi
        [ "$running_version" != "$DESIRED_VERSION" ] || continue
        jq -nc \
            --arg path "$path" \
            --arg runningVersion "$running_version" \
            --arg desiredVersion "$DESIRED_VERSION" \
            '{path: $path, runningVersion: $runningVersion, desiredVersion: $desiredVersion}'
    done <<<"$entries"
}

validate_confirmed_drift_approvals() {
    local entries="$1" approved observed
    if ! approved=$(normalize_confirmed_drift_approvals); then
        set_global_action invalid-drift-approval
        log_error "confirmed drift approval is malformed or empty"
        return 1
    fi
    if ! observed=$(collect_current_drift_approvals "$entries" | jq -sc 'sort_by([.path, .runningVersion, .desiredVersion])'); then
        set_global_action invalid-drift-approval
        return 1
    fi
    if [ "$approved" != "$observed" ]; then
        set_global_action invalid-drift-approval
        log_error "confirmed drift approval no longer matches the locked runtime snapshot"
        return 1
    fi
    CONFIRMED_DRIFT_APPROVALS="$approved"
}

drift_tuple_is_confirmed() {
    local path="$1" running_version="$2"
    jq -e \
        --arg path "$path" \
        --arg runningVersion "$running_version" \
        --arg desiredVersion "$DESIRED_VERSION" \
        'any(.[];
          .path == $path
          and .runningVersion == $runningVersion
          and .desiredVersion == $desiredVersion
        )' <<<"$CONFIRMED_DRIFT_APPROVALS" >/dev/null
}

handle_running_instance() {
    local path="$1" desired_spawn="$2" capacity="$3" permission_mode="$4"
    local pid running_version action diag_line scan_rejects
    if ! pid=$(find_server_pid_for_path "$path"); then
        action="no-server-process"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
        log_error "lock held but server process not found: $path"
        # 원 스캔이 후보를 탈락시킨 술어가 1차 증거다 — transient 실패는 아래 재스캔에서
        # 이미 회복돼 전부 ok로 보일 수 있다. 재스캔은 raw 값(cwd/exe/txt 목록) 보조용.
        if [ -s "$SERVER_SCAN_REJECT_FILE" ]; then
            scan_rejects=$(paste -sd ',' "$SERVER_SCAN_REJECT_FILE")
            log_error "  scan-rejects $scan_rejects"
            record_instance_detail "$path" "탈락 술어: $scan_rejects"
        else
            log_error "  scan-rejects (none recorded)"
            record_instance_detail "$path" "탈락 술어: 기록 없음 (pgrep 후보 0개 가능)"
        fi
        while IFS= read -r diag_line; do
            log_error "  rescan $diag_line"
        done < <(diagnose_server_pid_for_path "$path")
        return 1
    fi

    if ! running_version=$(pid_exe_version "$pid"); then
        action="running-version-unresolvable"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
        return 1
    fi

    if [ "$running_version" = "$DESIRED_VERSION" ]; then
        action="healthy"
        record_instance_result \
            "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action" \
            || return 1
        return 0
    fi

    handle_drift "$path" "$desired_spawn" "$capacity" "$permission_mode" "$pid" "$running_version"
}

handle_drift() {
    local path="$1" desired_spawn="$2" capacity="$3" permission_mode="$4" pid="$5" running_version="$6"
    local effective_spawn gate_rc restart_outcome restarted_version action
    if [ "$CLAUDE_RC_DRIFT_POLICY" = "defer" ]; then
        action="deferred-restart-confirmation"
        record_instance_result \
            "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action" \
            || return 1
        log_info "deferred version drift pending operator-confirmed restart: $path"
        return 0
    fi
    if [ "$CLAUDE_RC_DRIFT_POLICY" = "confirmed" ] \
        && ! drift_tuple_is_confirmed "$path" "$running_version"; then
        action="restart-approval-mismatch"
        record_instance_result \
            "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action" \
            || return 1
        log_error "runtime drift no longer matches the confirmed approval: $path"
        return 1
    fi

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
            restart_server \
                "$path" "$desired_spawn" "$capacity" "$permission_mode" \
                restart_outcome restarted_version
            record_restart_outcome \
                "$path" "same-dir" "$running_version" "$restart_outcome" "$restarted_version"
            ;;
        worktree)
            gate_rc=0
            restart_gate "$path" || gate_rc=$?
            case "$gate_rc" in
                0)
                    restart_server \
                        "$path" "$desired_spawn" "$capacity" "$permission_mode" \
                        restart_outcome restarted_version
                    record_restart_outcome \
                        "$path" "worktree" "$running_version" "$restart_outcome" "$restarted_version"
                    ;;
                1)
                    action="deferred-active-sessions"
                    record_instance_result \
                        "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action" \
                        || return 1
                    log_info "deferred active worktree sessions: $path"
                    return 0
                    ;;
                2)
                    action="deferred-unknown-activity"
                    record_instance_result \
                        "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action" \
                        || return 1
                    log_info "deferred unknown worktree activity: $path"
                    return 0
                    ;;
                *)
                    action="restart-gate-failed"
                    record_instance_result \
                        "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action"
                    return 1
                    ;;
            esac
            ;;
        *)
            action="invalid-spawn"
            record_instance_result \
                "$path" "$running_version" "$running_version" "$DESIRED_VERSION" "$action" running
            return 1
            ;;
    esac
}

process_instance() {
    local path="$1" spawn="$2" capacity="$3" permission_mode="$4"
    local lock_path action

    lock_path=$(lock_path_for_path "$path")
    if [ ! -d "$path" ]; then
        if [ -e "$lock_path" ] && ! lock_is_free "$lock_path"; then
            action="path-missing-lock-held"
            log_error "path missing while instance lock remains held: $path"
            record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action"
            return 1
        fi
        action="path-missing"
        log_info "path missing: $path"
        record_instance_result "$path" "" "" "$DESIRED_VERSION" "$action" || return 1
        return 0
    fi

    validate_instance_config "$path" "$spawn" "$capacity" "$permission_mode" || return 1

    ensure_instance_dir "$path"
    if lock_is_free "$lock_path"; then
        start_missing_instance "$path" "$spawn" "$capacity" "$permission_mode"
    else
        handle_running_instance "$path" "$spawn" "$capacity" "$permission_mode"
    fi
}

ensure_core() {
    local entries rc path spawn capacity permission_mode
    GLOBAL_ACTION="running"

    case "$CLAUDE_RC_DRIFT_POLICY" in
        automatic | confirmed | defer) ;;
        *)
            set_global_action invalid-drift-policy
            log_error "invalid CLAUDE_RC_DRIFT_POLICY: $CLAUDE_RC_DRIFT_POLICY"
            return 1
            ;;
    esac

    seed_declared_instances || return 1

    if ! resolve_claude_launcher; then
        set_global_action desired-version-unresolvable
        return 1
    fi

    if ! entries=$(with_instances_lock emit_instances_tsv_unlocked); then
        set_global_action instances-read-failed
        return 1
    fi
    if [ -z "$entries" ]; then
        set_global_action no-instances
        log_info "no registered instances"
        return 0
    fi
    if [ "$CLAUDE_RC_DRIFT_POLICY" = "confirmed" ]; then
        validate_confirmed_drift_approvals "$entries" || return 1
    fi

    rc=0
    while IFS=$'\t' read -r path spawn capacity permission_mode; do
        [ -n "$path" ] || continue
        [ "$capacity" = "$TSV_NULL" ] && capacity=""
        process_instance "$path" "$spawn" "$capacity" "$permission_mode" || rc=1
    done <<<"$entries"

    if [ "$rc" -eq 0 ]; then
        set_global_action completed
    else
        set_global_action failed
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
    local metadata is_failure
    if ! metadata=$(instance_action_metadata "$1"); then
        return 0
    fi
    IFS=$'\t' read -r _ is_failure <<<"$metadata"
    [ "$is_failure" = "true" ]
}

# Pushover 본문 상한(1024자) 안의 예산. 인스턴스가 많으면 앞 2건만 상세히 싣는다.
ALERT_BODY_MAX_BYTES=1000
ALERT_DETAIL_INSTANCES=2

# 바이트 예산으로 자르되 꼬리의 잘린 UTF-8 시퀀스를 버린다. GNU cut -c는 바이트 단위라
# 한글(3바이트)이 쪼개져 잘못된 UTF-8이 Pushover로 갈 수 있다. 로케일에 의존하지 않는다.
truncate_utf8() {
    local text="$1" max="$2" s n i byte need
    s="$(printf '%s' "$text" | head -c "$max")"
    local LC_ALL=C
    n=${#s}
    if [ "$n" -lt "$max" ]; then
        printf '%s' "$s"
        return 0
    fi
    for ((i = 1; i <= 4 && i <= n; i++)); do
        byte=$(printf '%d' "'${s:n-i:1}")
        if ((byte < 0x80)); then
            printf '%s' "$s"
            return 0
        fi
        if ((byte >= 0xC0)); then
            if ((byte >= 0xF0)); then need=4; elif ((byte >= 0xE0)); then need=3; else need=2; fi
            if ((i < need)); then printf '%s' "${s:0:n-i}"; else printf '%s' "$s"; fi
            return 0
        fi
    done
    printf '%s' "$s"
}

# instance action / global action 코드 → 한국어 "원인<TAB>조치". managing-claude-rc 스킬의
# 트러블슈팅 표를 알림 크기에 맞게 압축한 것이다. 알림만 보고도 왜 실패했고 무엇을
# 해야 하는지 알 수 있어야 한다 (2026-09 no-server-process 13시간 알림 폭주 때
# "exit=1, action=completed, failed=<path>: no-server-process"만으로는 원인을 몰랐다).
action_explain() {
    local action="${1:-unknown}"
    case "$action" in
        no-server-process)
            printf '%s\t%s' \
                "lock은 잡혀 있는데 관리 대상 bridge 프로세스를 식별하지 못함" \
                "'claude-rc ls'로 실제 생존 확인. ensure 로그의 scan-rejects에서 어느 술어(cwd/exe/lineage/lock)가 떨어졌는지 본 뒤, 죽은 lock이면 다음 ensure가 재시작"
            ;;
        path-missing-lock-held)
            printf '%s\t%s' \
                "등록 경로는 사라졌는데 instance lock이 살아 있음 (고아 bridge 가능)" \
                "lock 소유 PID와 bridge 신원을 읽기 전용으로 확인. 경로가 없으면 'claude-rc stop'은 서버 신원을 못 찾아 거부되므로, 디렉토리를 원래 경로에 복원한 뒤 stop하거나 확인된 bridge PID를 직접 TERM"
            ;;
        start-failed)
            printf '%s\t%s' \
                "bridge 시작 또는 guardian 핸드셰이크를 확인하지 못함" \
                "server.log(~/.local/state/claude-rc/<slug>/)와 launcher(~/.local/bin/claude) 확인. 다음 ensure가 재시도"
            ;;
        unmanaged-server-present)
            printf '%s\t%s' \
                "같은 디렉토리에 래퍼 밖에서 띄운 remote-control 서버가 있음" \
                "그 서버를 종료한 뒤 'claude-rc start' (같은 디렉토리에 서버 2개면 유령 환경이 생김)"
            ;;
        running-version-unresolvable)
            printf '%s\t%s' \
                "실행 중 bridge의 바이너리 경로를 조회하지 못함" \
                "lsof(/proc) 접근 가능 여부 확인"
            ;;
        restart-failed | restart-version-unresolvable | restart-version-mismatch-cleanup-failed | start-version-unresolvable | start-version-mismatch-cleanup-failed)
            printf '%s\t%s' \
                "재시작/시작 중 기존 서버 정지 또는 새 서버 식별에 실패" \
                "현재 PID와 instance lock 소유자를 확인. 신원 미확인 PID는 수동 kill 금지"
            ;;
        start-version-mismatch | restart-version-mismatch | start-version-unresolvable-cleaned | restart-version-unresolvable-cleaned)
            printf '%s\t%s' \
                "새로 뜬 서버 버전이 desired와 다르거나 식별 전 정리됨" \
                "launcher(~/.local/bin/claude)가 가리키는 버전과 배포 generation 확인 후 nrs"
            ;;
        restart-approval-mismatch)
            printf '%s\t%s' \
                "confirmed 승인 JSON이 현재 runtime drift 집합과 다름" \
                "defer 정책으로 새 snapshot을 뜬 뒤 승인부터 다시"
            ;;
        restart-gate-failed)
            printf '%s\t%s' \
                "worktree 활동 게이트(transcript/세션 프로세스 조회)를 평가하지 못함" \
                "transcript 디렉토리(~/.claude/projects) 접근과 pgrep 동작 확인. live bridge는 유지됨"
            ;;
        invalid-spawn | invalid-capacity | invalid-permission-mode)
            printf '%s\t%s' \
                "registry(instances.json)의 옵션 값이 잘못됨" \
                "instances.json과 Nix 선언(CLAUDE_RC_DECLARED_INSTANCES) 대조 후 수정"
            ;;
        flock-missing)
            printf '%s\t%s' "lifecycle 직렬화 도구(flock)가 없음" "배포 package/PATH가 current generation과 일치하는지 확인 후 nrs"
            ;;
        lock-acquire-timeout | lock-setup-failed)
            printf '%s\t%s' "ensure lifecycle lock을 얻지 못함" "다른 ensure/claude-rc start·stop 진행 중인지, ensure.lock fd 누수인지 확인"
            ;;
        declared-instances-invalid | invalid-drift-policy | invalid-drift-approval)
            printf '%s\t%s' "선언 환경변수(instances/drift policy/approval JSON)가 잘못됨" "launchd/systemd 환경변수 선언을 Nix에서 확인"
            ;;
        desired-version-unresolvable)
            printf '%s\t%s' "launcher(~/.local/bin/claude)가 없거나 versions 디렉토리 밖을 가리킴" "'readlink -f ~/.local/bin/claude'와 ~/.local/share/claude/versions 확인"
            ;;
        instances-read-failed)
            printf '%s\t%s' "instances.json 읽기/파싱 실패" "파일 type·mode와 instances.json.lock 소유자 확인"
            ;;
        status-write-failed)
            printf '%s\t%s' "status.json 게시 실패" "STATE_DIR mode·filesystem 상태 확인 (디스크 여유 포함)"
            ;;
        *)
            printf '%s\t%s' "분류되지 않은 실패 ($action)" "managing-claude-rc 스킬의 트러블슈팅 표와 ensure 로그 확인"
            ;;
    esac
}

failure_alert_body() {
    local exit_code="$1" body cause fix path action detail count=0 total=0
    body="${CLAUDE_RC_ALERT_HOST}의 Claude 원격 제어 점검이 실패했습니다 (exit=${exit_code}, 전체: ${GLOBAL_ACTION}, desired=${DESIRED_VERSION:-unknown})"
    if [ -s "$RESULTS_FILE" ]; then
        while IFS=$'\t' read -r path action; do
            [ -n "$path" ] || continue
            is_failure_action "$action" || continue
            total=$((total + 1))
            [ "$count" -lt "$ALERT_DETAIL_INSTANCES" ] || continue
            count=$((count + 1))
            IFS=$'\t' read -r cause fix <<<"$(action_explain "$action")"
            body="${body}
• ${path}: ${action}
  원인: ${cause}
  조치: ${fix}"
            detail=$(instance_detail_for_path "$path")
            [ -z "$detail" ] || body="${body}
  근거: ${detail}"
        done < <(jq -r '[.path, .action] | @tsv' "$RESULTS_FILE")
        [ "$total" -le "$count" ] || body="${body}
… 외 $((total - count))건 (status.json 참조)"
    fi
    if [ "$total" -eq 0 ]; then
        IFS=$'\t' read -r cause fix <<<"$(action_explain "$GLOBAL_ACTION")"
        body="${body}
원인: ${cause}
조치: ${fix}"
    fi
    truncate_utf8 "$body" "$ALERT_BODY_MAX_BYTES"
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
            send_notification "Claude 원격 제어 복구 · ${CLAUDE_RC_ALERT_HOST}" \
                "${CLAUDE_RC_ALERT_HOST}의 Claude 원격 제어 점검이 정상으로 돌아왔습니다 (desired=${DESIRED_VERSION:-unknown})." 0
        fi
        echo "healthy" >"$state_file"
        return 0
    fi

    last=0
    if [ -f "$last_failure_file" ]; then
        last=$(cat "$last_failure_file" 2>/dev/null || echo 0)
    fi
    if [ $((now - last)) -ge "$ALERT_COOLDOWN_SECONDS" ]; then
        summary=$(failure_alert_body "$exit_code")
        send_notification "Claude 원격 제어 실패 · ${CLAUDE_RC_ALERT_HOST}" "$summary" 0
        echo "$now" >"$last_failure_file"
    fi
    echo "failed" >"$state_file"
}

cmd_ensure() {
    local rc
    rc=0
    mkdir -p "$STATE_DIR"
    if [ -n "$CLAUDE_RC_ENSURE_LOG" ]; then
        # launchd가 매 실행마다 파일을 새로 열므로 mv 로테이션이 다음 실행부터 반영된다.
        rotate_log_if_needed "$CLAUDE_RC_ENSURE_LOG" || true
    fi
    RESULTS_FILE=$(mktemp "$STATE_DIR/results.XXXXXX") || return 1
    # 원 스캔의 탈락 기록은 이 실행 전용 스크래치에만 쓴다 (lib 기본값은 기록 안 함).
    SERVER_SCAN_REJECT_FILE="$RESULTS_FILE.scan"
    with_lock ensure_core || rc=$?
    # 단일 finalizer: 어떤 분기도 이 경로를 우회하지 않는다
    # (recovered/failure 알림 상태 전이가 모든 실행에서 평가되도록).
    if ! write_status "$rc"; then
        set_global_action status-write-failed
        log_error "failed to write final status"
        # Preserve an existing lifecycle failure, but never report success when
        # the observable status contract could not be published.
        [ "$rc" -ne 0 ] || rc=1
    fi
    # source되는 credential/lib 파일이 malformed여도 (source가 && 리스트의
    # 마지막 명령이라 set -e 발동) finalizer가 send_alerts 전에 죽지 않게 guard.
    load_alerting || true
    send_alerts "$rc" || true
    rm -f "$RESULTS_FILE" "$RESULTS_FILE.detail" "$RESULTS_FILE.scan"
    return "$rc"
}

usage() {
    cat >&2 <<'EOF'
Usage: claude-rc-maint ensure

env:
  CLAUDE_BIN (maint launcher; basename need not be claude),
  STATE_DIR, CLAUDE_RC_DECLARED_INSTANCES,
  VERSIONS_DIR (default ~/.local/share/claude/versions; exe boundary for server/session PID detection),
  IDLE_THRESHOLD_MINUTES (default 30), MAINT_LOCK_TIMEOUT_SECONDS (default 120),
  ALERT_COOLDOWN_SECONDS (default 1800), PUSHOVER_CRED_FILE, SERVICE_LIB,
  CLAUDE_RC_PERMISSION_MODE, CLAUDE_RC_ALERT_HOST,
  CLAUDE_RC_ENSURE_LOG (optional append-only ensure log path; rotated to .1 past LOG_MAX_BYTES),
  CLAUDE_RC_DRIFT_POLICY (automatic, confirmed, or defer; default defer),
  CLAUDE_RC_DRIFT_APPROVAL_JSON (exact non-empty path/runningVersion/desiredVersion array for confirmed)

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
