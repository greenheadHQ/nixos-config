#!/bin/bash
# Folder Action: 파일 이름을 타임스탬프로 변경
# 감시 폴더: ~/FolderActions/rename-asset/
# 결과물: ~/Downloads/<타임스탬프>.<확장자>

set -euo pipefail

WATCH_DIR="$HOME/FolderActions/rename-asset"
DEST_DIR="$HOME/Downloads"

LOCK_DIR="/tmp/rename-asset.lock.d"
LEGACY_LOCK_FILE="/tmp/rename-asset.lock"
LOCK_TOKEN_FILE="${LOCK_DIR}/owner.token"
LOCK_TTL_SECONDS=600
LOCK_CORRUPT_TTL_SECONDS=$((LOCK_TTL_SECONDS * 2))

CURRENT_UID=$(/usr/bin/id -u)
CURRENT_PID="$$"
CURRENT_PROC_START=""
CURRENT_NONCE=""
CURRENT_STARTED_AT=""
LOCK_ACQUIRED=0
SELF_REAP_DIR=""

log_info() {
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_warn() {
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] WARN: $1" >&2
}

log_error() {
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

now_epoch() {
    /bin/date +%s
}

generate_nonce() {
    local nonce
    nonce=$(/usr/bin/hexdump -n 16 -e '16/1 "%02x"' /dev/urandom 2>/dev/null || true)
    if [[ ! "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
        return 1
    fi
    printf '%s\n' "$nonce"
}

get_proc_start() {
    local pid="$1"
    local start

    if ! start=$(LC_ALL=C /bin/ps -p "$pid" -o lstart= 2>/dev/null); then
        return 1
    fi
    start=$(printf '%s' "$start" | /usr/bin/sed 's/^[[:space:]]*//')
    [ -n "$start" ] || return 1
    printf '%s\n' "$start"
}

classify_liveness() {
    local pid="$1"
    local expected_start="$2"
    local ps_out

    if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "uncertain"
        return 0
    fi

    if ! ps_out=$(LC_ALL=C /bin/ps -p "$pid" -o lstart= 2>/dev/null); then
        if LC_ALL=C /bin/kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "uncertain"
        else
            printf '%s\n' "dead"
        fi
        return 0
    fi

    ps_out=$(printf '%s' "$ps_out" | /usr/bin/sed 's/^[[:space:]]*//')
    if [ -z "$ps_out" ]; then
        printf '%s\n' "dead"
        return 0
    fi

    if [ -z "$expected_start" ]; then
        printf '%s\n' "uncertain"
        return 0
    fi

    if [ "$ps_out" = "$expected_start" ]; then
        printf '%s\n' "alive"
    else
        printf '%s\n' "uncertain"
    fi
}

classify_pid_only_liveness() {
    local pid="$1"
    local ps_out

    if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "uncertain"
        return 0
    fi

    if ! ps_out=$(LC_ALL=C /bin/ps -p "$pid" -o lstart= 2>/dev/null); then
        if LC_ALL=C /bin/kill -0 "$pid" 2>/dev/null; then
            printf '%s\n' "alive"
        else
            printf '%s\n' "dead"
        fi
        return 0
    fi

    ps_out=$(printf '%s' "$ps_out" | /usr/bin/sed 's/^[[:space:]]*//')
    if [ -z "$ps_out" ]; then
        printf '%s\n' "dead"
    else
        printf '%s\n' "alive"
    fi
}

calc_age() {
    local from="$1"
    local to="$2"
    local age

    if [[ -z "$from" || ! "$from" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "0"
        return 0
    fi

    age=$((to - from))
    if [ "$age" -lt 0 ]; then
        age=0
    fi
    printf '%s\n' "$age"
}

verify_path_security() {
    local path="$1"
    local expected_mode="$2"
    local label="$3"
    local owner mode acl_lines

    if [ -L "$path" ]; then
        log_error "$label is symlink: $path"
        return 1
    fi

    owner=$(/usr/bin/stat -f '%u' "$path" 2>/dev/null || true)
    mode=$(/usr/bin/stat -f '%Mp%Lp' "$path" 2>/dev/null || true)

    if [ -z "$owner" ] || [ -z "$mode" ]; then
        log_error "$label stat failed: $path"
        return 1
    fi

    if [ "$owner" != "$CURRENT_UID" ]; then
        log_error "$label owner mismatch: $path (owner=$owner, expected=$CURRENT_UID)"
        return 1
    fi

    if [ "$mode" != "$expected_mode" ]; then
        log_error "$label mode mismatch: $path (mode=$mode, expected=$expected_mode)"
        return 1
    fi

    acl_lines=$(/bin/ls -lde "$path" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d '[:space:]')
    if [[ -z "$acl_lines" || ! "$acl_lines" =~ ^[0-9]+$ ]]; then
        log_error "$label ACL check failed: $path"
        return 1
    fi

    if [ "$acl_lines" -gt 1 ]; then
        log_error "$label has ACL entries and is not trusted: $path"
        return 1
    fi

    return 0
}

write_lock_token() {
    local old_umask
    local rc

    old_umask=$(umask)
    umask 077
    cat > "$LOCK_TOKEN_FILE" <<EOF_TOKEN
pid=${CURRENT_PID}
proc_start=${CURRENT_PROC_START}
nonce=${CURRENT_NONCE}
started_at=${CURRENT_STARTED_AT}
EOF_TOKEN
    rc=$?
    umask "$old_umask"

    if [ "$rc" -ne 0 ]; then
        return 1
    fi

    verify_path_security "$LOCK_TOKEN_FILE" "0600" "lock token"
}

read_token_file() {
    local file="$1"
    local key value

    TOKEN_PID=""
    TOKEN_PROC_START=""
    TOKEN_NONCE=""
    TOKEN_STARTED_AT=""

    [ -f "$file" ] || return 1

    while IFS='=' read -r key value; do
        case "$key" in
            pid) TOKEN_PID="$value" ;;
            proc_start) TOKEN_PROC_START="$value" ;;
            nonce) TOKEN_NONCE="$value" ;;
            started_at) TOKEN_STARTED_AT="$value" ;;
        esac
    done < "$file"

    [[ "$TOKEN_PID" =~ ^[0-9]+$ ]] || return 1
    [ -n "$TOKEN_PROC_START" ] || return 1
    [[ "$TOKEN_NONCE" =~ ^[0-9a-f]{32}$ ]] || return 1
    [[ "$TOKEN_STARTED_AT" =~ ^[0-9]+$ ]] || return 1
    return 0
}

token_matches_current() {
    read_token_file "$LOCK_TOKEN_FILE" || return 1
    [ "$TOKEN_PID" = "$CURRENT_PID" ] || return 1
    [ "$TOKEN_PROC_START" = "$CURRENT_PROC_START" ] || return 1
    [ "$TOKEN_NONCE" = "$CURRENT_NONCE" ] || return 1
    [ "$TOKEN_STARTED_AT" = "$CURRENT_STARTED_AT" ] || return 1
    return 0
}

create_lock_dir_secure() {
    local old_umask
    local rc

    old_umask=$(umask)
    umask 077
    /bin/mkdir "$LOCK_DIR" 2>/dev/null
    rc=$?
    umask "$old_umask"

    if [ "$rc" -ne 0 ]; then
        return 1
    fi

    verify_path_security "$LOCK_DIR" "0700" "lock directory"
}

init_current_lock_token() {
    CURRENT_NONCE=$(generate_nonce) || {
        log_error "nonce generation failed"
        return 1
    }
    CURRENT_STARTED_AT=$(now_epoch)
    write_lock_token
}

log_uncertain_and_exit() {
    local reason="$1"
    local token_nonce="${2:-}"

    log_error "Lock state uncertain: ${reason}"
    log_error "Manual recovery steps:"
    log_error "  1) Verify owner process: /bin/ps -p <pid> -o lstart="
    log_error "  2) If owner is dead, remove lock: /bin/rm -rf '${LOCK_DIR}' '${LEGACY_LOCK_FILE}'"
    if [ -n "$token_nonce" ]; then
        log_error "Break-glass (one-shot): ALLOW_UNCERTAIN_RECLAIM=1 FORCE_RECLAIM_ACK=${token_nonce}"
    fi
    exit 1
}

should_force_uncertain_reclaim() {
    local token_nonce="$1"

    if [ "${ALLOW_UNCERTAIN_RECLAIM:-0}" != "1" ]; then
        return 1
    fi

    if [ -z "${FORCE_RECLAIM_ACK:-}" ] || [ "${FORCE_RECLAIM_ACK}" != "$token_nonce" ]; then
        log_error "Break-glass denied: FORCE_RECLAIM_ACK missing or mismatched"
        return 1
    fi

    log_warn "Break-glass forced reclaim approved (nonce matched)"
    return 0
}

try_reclaim_lock() {
    local reason="$1"
    local reap_nonce reap_dir

    reap_nonce=$(generate_nonce) || {
        log_error "failed to create reap nonce"
        return 1
    }
    reap_dir="${LOCK_DIR}.reap.${CURRENT_PID}.${reap_nonce}"

    if [ -e "$reap_dir" ]; then
        log_error "reap path collision: $reap_dir"
        return 1
    fi

    if ! /bin/mv "$LOCK_DIR" "$reap_dir" 2>/dev/null; then
        log_info "Lock reclaim race lost; another process handled it"
        return 2
    fi

    SELF_REAP_DIR="$reap_dir"

    if ! create_lock_dir_secure; then
        log_error "failed to recreate lock directory after reclaim"
        return 1
    fi

    if ! init_current_lock_token; then
        /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
        log_error "failed to create token after reclaim"
        return 1
    fi

    LOCK_ACQUIRED=1

    if ! /bin/rm -rf "$reap_dir" 2>/dev/null; then
        log_warn "failed to remove reap directory: $reap_dir"
    fi
    SELF_REAP_DIR=""

    log_info "Stale lock reclaimed: ${reason}"
    return 0
}

handle_legacy_lock() {
    local state legacy_pid legacy_proc_start raw key value

    [ -e "$LEGACY_LOCK_FILE" ] || return 0

    if [ -L "$LEGACY_LOCK_FILE" ]; then
        log_uncertain_and_exit "legacy lock file is a symlink"
    fi

    legacy_pid=""
    legacy_proc_start=""

    if /usr/bin/grep -q '^pid=' "$LEGACY_LOCK_FILE" 2>/dev/null; then
        while IFS='=' read -r key value; do
            case "$key" in
                pid) legacy_pid="$value" ;;
                proc_start) legacy_proc_start="$value" ;;
            esac
        done < "$LEGACY_LOCK_FILE"

        if [ -n "$legacy_proc_start" ]; then
            state=$(classify_liveness "$legacy_pid" "$legacy_proc_start")
        else
            state=$(classify_pid_only_liveness "$legacy_pid")
        fi
    else
        raw=$(/bin/cat "$LEGACY_LOCK_FILE" 2>/dev/null | /usr/bin/tr -d '[:space:]' || true)
        if [ -z "$raw" ]; then
            log_uncertain_and_exit "legacy lock file is unreadable or empty"
        fi
        state=$(classify_pid_only_liveness "$raw")
        legacy_pid="$raw"
    fi

    case "$state" in
        alive)
            log_info "Legacy lock is active (pid=${legacy_pid}); exiting"
            exit 0
            ;;
        dead)
            log_info "Legacy lock is stale; removing: $LEGACY_LOCK_FILE"
            /bin/rm -f "$LEGACY_LOCK_FILE" 2>/dev/null || {
                log_error "failed to remove stale legacy lock: $LEGACY_LOCK_FILE"
                exit 1
            }
            ;;
        uncertain)
            log_uncertain_and_exit "legacy lock liveness is uncertain"
            ;;
        *)
            log_uncertain_and_exit "legacy lock state parsing failed"
            ;;
    esac
}

handle_reclaim_result_or_exit() {
    local rc="$1"

    if [ "$rc" -eq 0 ]; then
        return 0
    fi

    if [ "$rc" -eq 2 ]; then
        exit 0
    fi

    exit 1
}

handle_existing_lock() {
    local now age state mtime rc

    if [ -L "$LOCK_DIR" ]; then
        log_error "lock directory path is symlink: $LOCK_DIR"
        exit 1
    fi

    if [ ! -d "$LOCK_DIR" ]; then
        log_error "lock path exists but is not a directory: $LOCK_DIR"
        exit 1
    fi

    verify_path_security "$LOCK_DIR" "0700" "lock directory" || exit 1
    now=$(now_epoch)

    if read_token_file "$LOCK_TOKEN_FILE"; then
        verify_path_security "$LOCK_TOKEN_FILE" "0600" "lock token" || exit 1
        age=$(calc_age "$TOKEN_STARTED_AT" "$now")
        state=$(classify_liveness "$TOKEN_PID" "$TOKEN_PROC_START")

        if [ "$state" = "dead" ]; then
            try_reclaim_lock "dead owner (age=${age}s)"
            rc=$?
            handle_reclaim_result_or_exit "$rc"
            return 0
        fi

        if [ "$state" = "uncertain" ] && should_force_uncertain_reclaim "$TOKEN_NONCE"; then
            try_reclaim_lock "forced uncertain reclaim"
            rc=$?
            handle_reclaim_result_or_exit "$rc"
            return 0
        fi

        if [ "$state" = "alive" ]; then
            log_info "Lock held by active process (pid=${TOKEN_PID}); exiting"
            exit 0
        fi

        log_uncertain_and_exit "token owner liveness uncertain (pid=${TOKEN_PID})" "$TOKEN_NONCE"
    else
        mtime=$(/usr/bin/stat -f '%m' "$LOCK_DIR" 2>/dev/null || true)
        if [[ -z "$mtime" || ! "$mtime" =~ ^[0-9]+$ ]]; then
            log_uncertain_and_exit "token missing/corrupt and lockdir mtime unreadable"
        fi

        age=$(calc_age "$mtime" "$now")
        if [ "$age" -gt "$LOCK_CORRUPT_TTL_SECONDS" ]; then
            try_reclaim_lock "missing/corrupt token (age=${age}s)"
            rc=$?
            handle_reclaim_result_or_exit "$rc"
            return 0
        fi

        log_uncertain_and_exit "token missing/corrupt and younger than stale-B ttl (${age}s <= ${LOCK_CORRUPT_TTL_SECONDS}s)"
    fi
}

acquire_lock() {
    CURRENT_PROC_START=$(get_proc_start "$CURRENT_PID") || {
        log_error "failed to read current process start time"
        exit 1
    }

    handle_legacy_lock

    if [ -e "$LOCK_DIR" ]; then
        handle_existing_lock
        if [ "$LOCK_ACQUIRED" -eq 1 ]; then
            return 0
        fi
    fi

    if ! create_lock_dir_secure; then
        if [ -e "$LOCK_DIR" ]; then
            handle_existing_lock
            if [ "$LOCK_ACQUIRED" -eq 1 ]; then
                return 0
            fi
        fi
        log_error "failed to create lock directory: $LOCK_DIR"
        exit 1
    fi

    if ! init_current_lock_token; then
        /bin/rm -rf "$LOCK_DIR" 2>/dev/null || true
        log_error "failed to initialize lock token"
        exit 1
    fi

    LOCK_ACQUIRED=1
}

cleanup_lock() {
    if [ "${LOCK_ACQUIRED:-0}" -eq 1 ] && [ -d "$LOCK_DIR" ]; then
        if token_matches_current; then
            /bin/rm -rf "$LOCK_DIR" 2>/dev/null || log_warn "failed to remove lock directory"
        fi
    fi

    if [ -n "${SELF_REAP_DIR:-}" ] && [ -d "$SELF_REAP_DIR" ]; then
        /bin/rm -rf "$SELF_REAP_DIR" 2>/dev/null || true
    fi
}

on_signal() {
    local sig="$1"
    log_warn "received signal ${sig}; shutting down"
    cleanup_lock
    exit 1
}

trap cleanup_lock EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

acquire_lock

# 카운터 (동시에 여러 파일 처리 시)
i=1

# 감시 폴더 내 파일 처리
find "$WATCH_DIR" -type f -maxdepth 1 ! -name ".*" | while read -r f; do
    [ -f "$f" ] || continue

    filename=$(basename "$f")
    ext="${filename##*.}"
    timestamp=$(/bin/date +"%Y%m%dT%H%M%S%3N")

    # 새 파일명 생성
    new_filename="${timestamp}_${i}.${ext}"
    output_path="${DEST_DIR}/${new_filename}"

    # 파일 이동
    if /bin/mv -- "$f" "$output_path"; then
        log_info "이동 완료: $filename -> $new_filename"
    else
        log_error "이동 실패: $filename"
    fi

    ((i++))
done
