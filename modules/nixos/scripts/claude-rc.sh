#!/usr/bin/env bash
# claude-rc: Claude Code Remote Control headless multi-instance wrapper.
#
# This file is packaged by concatenating modules/nixos/scripts/claude-rc-lib.sh
# before it. The Nix package provides flock/jq/lsof/pgrep/etc.; claude itself is
# resolved from the caller's PATH tail so the user's launcher can self-update.

set -euo pipefail

ACTION="start"
RC_SPAWN="worktree"
RC_CAPACITY=""
RC_PERMISSION_MODE="bypassPermissions"
RC_SPAWN_SET=false
RC_CAPACITY_SET=false
RC_PERMISSION_MODE_SET=false
FORCE=false
STOP_PATH=""
LIFECYCLE_LOCK_TIMEOUT_SECONDS="${CLAUDE_RC_LIFECYCLE_LOCK_TIMEOUT_SECONDS:-120}"

log_info() { echo "[claude-rc] $*"; }
log_warn() { echo "[claude-rc] WARN: $*" >&2; }
log_error() { echo "[claude-rc] ERROR: $*" >&2; }

usage() {
    cat <<'EOF'
claude-rc: Claude Code Remote Control headless multi-instance wrapper

Usage:
  claude-rc [start] [--spawn worktree|same-dir] [--capacity N] [--permission-mode MODE]
  claude-rc stop [path] [--force]
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
        return 1
    fi
}

require_common_cmds() {
    require_cmd flock || return 1
    require_cmd git || return 1
    require_cmd jq || return 1
    require_cmd lsof || return 1
    require_cmd pgrep || return 1
}

resolve_bridge_claude_launcher() {
    local launcher
    launcher=$(PATH="$CLAUDE_RC_BRIDGE_PATH" command -v claude 2>/dev/null) || {
        log_error "Claude launcher not found in CLAUDE_RC_BRIDGE_PATH"
        return 1
    }
    case "$launcher" in
        /*) ;;
        *)
            log_error "Claude launcher from CLAUDE_RC_BRIDGE_PATH is not absolute: $launcher"
            return 1
            ;;
    esac
    [ -f "$launcher" ] && [ -x "$launcher" ] || {
        log_error "Claude launcher from CLAUDE_RC_BRIDGE_PATH is not an executable file: $launcher"
        return 1
    }
    printf '%s\n' "$launcher"
}

wrapper_lifecycle_lock_missing() {
    log_error "required command not found in PATH: flock"
}

wrapper_lifecycle_lock_timeout() {
    local lock_path="$1"
    log_error "lifecycle lock acquire timeout: $lock_path"
}

wrapper_lifecycle_lock_setup_failed() {
    local lock_path="$1"
    log_error "lifecycle lock setup failed: $lock_path"
}

with_lifecycle_lock() {
    with_lifecycle_lock_fd9 \
        "$LIFECYCLE_LOCK_TIMEOUT_SECONDS" \
        "$STATE_DIR/ensure.lock" \
        wrapper_lifecycle_lock_missing \
        wrapper_lifecycle_lock_timeout \
        wrapper_lifecycle_lock_setup_failed \
        "$@"
}

current_git_root() {
    local root
    if ! root=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
        log_error "git repo가 아님"
        return 1
    fi
    printf '%s\n' "$root"
}

stop_target_path() {
    if [ -z "$STOP_PATH" ]; then
        current_git_root
        return
    fi
    if [[ "$STOP_PATH" != /* ]]; then
        log_error "stop path must be absolute: $STOP_PATH"
        return 1
    fi
    if [ -d "$STOP_PATH" ]; then
        canonical_existing_path "$STOP_PATH"
    else
        printf '%s\n' "$STOP_PATH"
    fi
}

instance_options_tsv() {
    local path="$1" source_filter="${2:-}"
    [ -f "$INSTANCES_FILE" ] || return 0
    jq -r --arg path "$path" --arg sourceFilter "$source_filter" --arg tsv_null "$TSV_NULL" '
        if (.version == 1 and (.instances | type) == "object" and (.instances | has($path))) then
          .instances[$path]
          | select($sourceFilter == "" or (.source == $sourceFilter))
          | [
              (.spawn // "worktree"),
              (if (.capacity // null) == null then $tsv_null else (.capacity | tostring) end),
              (.permissionMode // "bypassPermissions")
            ]
          | @tsv
        else
          empty
        end
    ' "$INSTANCES_FILE"
}

start_option_diffs() {
    local reference_label="$1" options_tsv="$2"
    local ref_spawn ref_capacity ref_permission_mode
    [ -n "$options_tsv" ] || return 0
    IFS=$'\t' read -r ref_spawn ref_capacity ref_permission_mode <<<"$options_tsv"
    [ "$ref_capacity" = "$TSV_NULL" ] && ref_capacity=""

    if [ "$RC_SPAWN_SET" = true ] && [ "$RC_SPAWN" != "$ref_spawn" ]; then
        printf 'spawn: %s=%s, requested=%s\n' "$reference_label" "${ref_spawn:-<unset>}" "$RC_SPAWN"
    fi
    if [ "$RC_CAPACITY_SET" = true ] && [ "$RC_CAPACITY" != "$ref_capacity" ]; then
        printf 'capacity: %s=%s, requested=%s\n' "$reference_label" "${ref_capacity:-<omitted>}" "$RC_CAPACITY"
    fi
    if [ "$RC_PERMISSION_MODE_SET" = true ] && [ "$RC_PERMISSION_MODE" != "$ref_permission_mode" ]; then
        printf 'permission-mode: %s=%s, requested=%s\n' "$reference_label" "${ref_permission_mode:-<unset>}" "$RC_PERMISSION_MODE"
    fi
}

warn_for_start_option_diffs() {
    local reference_label="$1" options_tsv="$2" message="$3"
    local diffs line
    if [ "$RC_SPAWN_SET" != true ] && [ "$RC_CAPACITY_SET" != true ] && [ "$RC_PERMISSION_MODE_SET" != true ]; then
        return 0
    fi
    diffs=$(start_option_diffs "$reference_label" "$options_tsv")
    [ -n "$diffs" ] || return 0
    log_warn "$message"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '[claude-rc] WARN: %s\n' "$line" >&2
    done <<<"$diffs"
}

warn_if_start_options_ignored() {
    local registered
    registered=$(instance_options_tsv "$1")
    if [ -n "$registered" ]; then
        warn_for_start_option_diffs "running" "$registered" "실행 중인 서버에는 반영되지 않음 — 변경하려면 claude-rc stop 후 재기동"
    fi
}

declared_instance_options_tsv() {
    instance_options_tsv "$1" "declared"
}

warn_if_declared_start_options_differ() {
    warn_for_start_option_diffs "declared" "$1" "이 경로는 Nix 선언 관리 대상 — 다음 ensure에서 선언값으로 복원됨"
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
                validate_spawn "$2" || { log_error "Invalid spawn mode: $2"; exit 1; }
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
                validate_permission_mode "$2" || { log_error "Invalid permission mode: $2"; exit 1; }
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
                if [ "$ACTION" = "stop" ] && [ -z "$STOP_PATH" ]; then
                    STOP_PATH="$1"
                    shift
                else
                    log_error "Unknown option: $1"
                    usage
                    exit 1
                fi
                ;;
        esac
    done
}

do_start() {
    require_common_cmds || return 1
    local instance_path lock_path log_path env_line declared_options claude_launcher
    local launch_status started_identity started_pid started_version
    claude_launcher=$(resolve_bridge_claude_launcher) || return 1
    instance_path=$(current_git_root) || return $?
    ensure_instance_dir "$instance_path" || return 1
    lock_path=$(lock_path_for_path "$instance_path") || return $?
    log_path=$(log_path_for_path "$instance_path") || return $?
    declared_options=$(declared_instance_options_tsv "$instance_path") || return $?

    if ! lock_is_free "$lock_path"; then
        started_identity=$(wait_for_started_identity "$instance_path") || started_identity=""
        if [ -z "$started_identity" ]; then
            log_error "lock은 잡혔지만 exact managed server identity를 확인하지 못함"
            return 1
        fi
        IFS=$'\t' read -r started_pid started_version <<<"$started_identity"
        log_info "이미 실행 중: $instance_path"
        log_info "verified: pid=$started_pid version=$started_version"
        warn_if_start_options_ignored "$instance_path" || return 1
        log_info "log: $log_path"
        return 0
    fi

    # Wrapper-bypassed plain CLI servers do not hold this flock. Starting a
    # second server in the same cwd permanently creates an undeletable ghost
    # environment, so cwd-based process detection is a hard safety gate.
    if has_unmanaged_server_for_path "$instance_path"; then
        log_error "same-dir claude remote-control process already exists outside claude-rc"
        log_error "refusing duplicate start for: $instance_path"
        return 1
    fi

    warn_if_declared_start_options_differ "$declared_options" || return 1
    launch_and_verify_server \
        "$instance_path" "$RC_SPAWN" "$RC_CAPACITY" "$RC_PERMISSION_MODE" "$claude_launcher" \
        launch_status started_pid started_version || return $?
    case "$launch_status" in
        started) ;;
        launch-failed)
            log_error "server failed to start: $instance_path"
            [ ! -f "$log_path" ] || tail -n 30 "$log_path" >&2 || true
            return 1
            ;;
        identity-unresolvable|identity-unresolvable-cleaned|environment-attestation-failed|environment-attestation-failed-cleaned)
            log_error "server process/version/environment identity를 확인하지 못함: $instance_path"
            return 1
            ;;
        *)
            log_error "unknown launch outcome: $launch_status"
            return 1
            ;;
    esac

    if [ -z "$declared_options" ]; then
        upsert_instance "$instance_path" "$RC_SPAWN" "$RC_CAPACITY" "$RC_PERMISSION_MODE" "manual" || return $?
    else
        log_info "declared registry entry preserved: $instance_path"
    fi
    log_info "서버 시작됨: $instance_path"
    log_info "verified: pid=$started_pid version=$started_version"
    log_info "log: $log_path"
    env_line=$(grep 'environment=' "$log_path" 2>/dev/null | tail -n 1 || true)
    if [ -n "$env_line" ]; then
        log_info "$env_line"
    else
        log_info "접속 URL은 server.log의 environment= 라인을 확인하세요."
    fi
}

do_stop() {
    require_common_cmds || return 1
    local instance_path session_count pid lock_path started_version
    instance_path=$(stop_target_path) || return $?
    ensure_instance_dir "$instance_path" || return 1
    lock_path=$(lock_path_for_path "$instance_path") || return $?

    session_count=$(count_worktree_session_procs "$instance_path") || return $?
    if [ "$session_count" -gt 0 ] && [ "$FORCE" != true ]; then
        log_error "재시작 불가(tombstone) 세션 ${session_count}개 존재"
        log_error "정말 종료하려면: claude-rc stop --force"
        return 1
    fi

    if pid=$(find_server_pid_for_path "$instance_path"); then
        started_version=$(pid_exe_version "$pid" 2>/dev/null) || {
            log_error "server version identity를 확인하지 못함: pid=$pid"
            return 1
        }
        log_info "SIGTERM: pid=$pid"
        if ! stop_verified_started_server "$instance_path" "$pid" "$started_version"; then
            log_error "server identity/exit/lock-release 검증 실패: pid=$pid"
            return 1
        fi
        log_info "서버 종료됨"
    else
        if ! lock_is_free "$lock_path"; then
            log_error "lock은 잡혔지만 cwd가 같은 서버 PID를 찾지 못함"
            log_error "maint의 no-server-process와 같은 이상 상태이므로 등록을 보존함"
            return 1
        fi
        log_info "서버가 이미 죽어 있음 — 등록만 해제"
    fi

    remove_instance "$instance_path" || return $?
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
        start) with_lifecycle_lock do_start ;;
        stop) with_lifecycle_lock do_stop ;;
        ls) do_ls ;;
        cleanup) do_cleanup ;;
        *) usage; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
