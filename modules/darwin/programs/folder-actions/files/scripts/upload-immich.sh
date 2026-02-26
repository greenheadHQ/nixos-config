#!/bin/bash
# Folder Action: Immich 자동 업로드
# 감시 폴더: $WATCH_DIR (기본값: ~/FolderActions/upload-immich/)
# 미디어 파일 → Immich 서버 업로드 → Pushover 알림 → 원본 삭제
# shellcheck disable=SC1090

WATCH_DIR="${WATCH_DIR:-$HOME/FolderActions/upload-immich}"
LOCK_DIR="/tmp/upload-immich.lock.d"
LEGACY_LOCK_FILE="/tmp/upload-immich.lock"
LOCK_TOKEN_FILE="${LOCK_DIR}/owner.token"
LOCK_TTL_SECONDS=2700
LOCK_CORRUPT_TTL_SECONDS=$((LOCK_TTL_SECONDS * 2))
IMMICH_CREDENTIALS="$HOME/.config/immich/api-key"
PUSHOVER_CREDENTIALS="$HOME/.config/pushover/immich"

CURRENT_UID=$(/usr/bin/id -u)
CURRENT_PID="$$"
CURRENT_PROC_START=""
CURRENT_NONCE=""
CURRENT_STARTED_AT=""
LOCK_ACQUIRED=0
SELF_REAP_DIR=""

# Immich CLI 지원 확장자 (클라이언트 측 필터)
MEDIA_EXT="jpg|jpeg|jpe|png|heic|heif|webp|gif|avif|bmp|jp2|jxl|psd|raw|rw2|svg|tif|tiff|insp"
MEDIA_EXT="${MEDIA_EXT}|3gp|3gpp|avi|flv|m4v|mkv|mts|m2ts|m2t|mp4|insv|mpg|mpe|mpeg|mov|webm|wmv"

# ─── 유틸리티 함수 ────────────────────────────────────────────

log() {
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $1"
}

log_warn() {
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] WARN: $1" >&2
}

log_error() {
    echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] ERROR: $1" >&2
}

is_media_ext() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    echo "$ext" | grep -qiE "^(${MEDIA_EXT})$"
}

human_size() {
    local bytes=$1
    if [ "$bytes" -ge 1073741824 ]; then
        echo "$(echo "scale=1; $bytes / 1073741824" | bc)GB"
    elif [ "$bytes" -ge 1048576 ]; then
        echo "$(echo "scale=1; $bytes / 1048576" | bc)MB"
    elif [ "$bytes" -ge 1024 ]; then
        echo "$(echo "scale=1; $bytes / 1024" | bc)KB"
    else
        echo "${bytes}B"
    fi
}

send_notification() {
    local title="$1"
    local message="$2"
    local priority="${3:-"-1"}"
    local sound="${4:-"none"}"

    curl -sf --max-time 10 \
        --form-string "token=${PUSHOVER_TOKEN}" \
        --form-string "user=${PUSHOVER_USER}" \
        --form-string "title=${title}" \
        --form-string "message=${message}" \
        --form-string "priority=${priority}" \
        --form-string "sound=${sound}" \
        https://api.pushover.net/1/messages.json > /dev/null 2>&1 || true
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
        log "Lock reclaim race lost; another process handled it"
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

    log "Stale lock reclaimed: ${reason}"
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
            log "Legacy lock is active (pid=${legacy_pid}); exiting"
            exit 0
            ;;
        dead)
            log "Legacy lock is stale; removing: $LEGACY_LOCK_FILE"
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
            log "Lock held by active process (pid=${TOKEN_PID}); exiting"
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

# 전체 디렉토리 스냅샷 비교 방식 안정화 대기
wait_all_stable() {
    local max_wait=300
    local waited=0
    local prev_snapshot=""

    while [ "$waited" -lt "$max_wait" ]; do
        local snapshot=""
        for f in "$WATCH_DIR"/*; do
            [ -f "$f" ] || continue
            [[ "$(basename "$f")" == .* ]] && continue
            snapshot="${snapshot}$(basename "$f"):$(/usr/bin/stat -f%z "$f" 2>/dev/null)"$'\n'
        done

        [ "$snapshot" = "$prev_snapshot" ] && return 0
        prev_snapshot="$snapshot"
        sleep 1
        ((waited++))
    done
    return 1
}

trap cleanup_lock EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

acquire_lock

# ─── 파일 목록 수집 ───────────────────────────────────────────

has_any_file=false
has_media=false

for f in "$WATCH_DIR"/*; do
    [ -f "$f" ] || continue
    [[ "$(basename "$f")" == .* ]] && continue
    has_any_file=true
    if is_media_ext "$f"; then
        has_media=true
        break
    fi
done

# 파일 없으면 종료
if ! $has_any_file; then
    exit 0
fi

# 미디어 파일 없으면 종료 (비미디어만 있을 때 알림 스팸 방지)
if ! $has_media; then
    exit 0
fi

# ─── 안정화 대기 ──────────────────────────────────────────────

log "파일 안정화 대기 시작"

if ! wait_all_stable; then
    # 자격증명 로드 (알림 전송용)
    if [ -f "$PUSHOVER_CREDENTIALS" ]; then
        source "$PUSHOVER_CREDENTIALS"
        send_notification "Immich [❌ 업로드 실패]" "파일 복사 5분 초과 - 대용량 파일 확인 필요" 0 "falling"
    fi
    log "안정화 타임아웃 (5분)"
    exit 0
fi

log "파일 안정화 완료"

# ─── 파일 분류 + 기록 ─────────────────────────────────────────

media_files=()
non_media_count=0
total_size=0

for f in "$WATCH_DIR"/*; do
    [ -f "$f" ] || continue
    [[ "$(basename "$f")" == .* ]] && continue

    if is_media_ext "$f"; then
        media_files+=("$f")
        file_size=$(/usr/bin/stat -f%z "$f" 2>/dev/null || echo 0)
        total_size=$((total_size + file_size))
    else
        non_media_count=$((non_media_count + 1))
    fi
done

media_count=${#media_files[@]}
if [ "$media_count" -eq 0 ]; then
    exit 0
fi

readable_size=$(human_size "$total_size")
log "미디어 ${media_count}개 (${readable_size}), 비미디어 ${non_media_count}개"

# ─── 자격증명 로드 ────────────────────────────────────────────

if [ ! -f "$IMMICH_CREDENTIALS" ]; then
    log "자격증명 없음: $IMMICH_CREDENTIALS"
    exit 0
fi
if [ ! -f "$PUSHOVER_CREDENTIALS" ]; then
    log "자격증명 없음: $PUSHOVER_CREDENTIALS"
    exit 0
fi

source "$IMMICH_CREDENTIALS"
source "$PUSHOVER_CREDENTIALS"

if [ -z "$IMMICH_API_KEY" ] || [ -z "${IMMICH_INSTANCE_URL:-}" ]; then
    log "IMMICH_API_KEY 또는 IMMICH_INSTANCE_URL 미설정"
    exit 0
fi

export IMMICH_API_KEY
export IMMICH_INSTANCE_URL

# ─── 서버 연결 사전 확인 ──────────────────────────────────────

if ! curl -sf --max-time 5 "${IMMICH_INSTANCE_URL}/api/server/ping" > /dev/null 2>&1; then
    log "Immich 서버 연결 불가: ${IMMICH_INSTANCE_URL}"
    send_notification "Immich [❌ 업로드 실패]" "서버 연결 불가" 0 "falling"
    exit 0
fi

# ─── 업로드 실행 ──────────────────────────────────────────────

log "업로드 시작: ${media_count}개 (${readable_size})"

upload_output=$(bunx @immich/cli upload \
    --album-name "Desktop Upload" \
    --delete \
    --concurrency 2 \
    "$WATCH_DIR" 2>&1) && upload_exit=0 || upload_exit=$?

log "CLI 종료 코드: ${upload_exit}"
log "CLI 출력: ${upload_output}"

# ─── 결과 처리 ────────────────────────────────────────────────

if [ "$upload_exit" -eq 0 ]; then
    # 성공: 사전 기록된 미디어 파일만 삭제 (--delete 버그 대응: 중복 파일도 삭제)
    deleted=0
    for f in "${media_files[@]}"; do
        if [ -f "$f" ]; then
            /bin/rm -f "$f"
            deleted=$((deleted + 1))
        fi
    done
    log "삭제 완료: ${deleted}/${media_count}개"

    message="📸 ${media_count}개 파일 (${readable_size}) → Desktop Upload"
    if [ "$non_media_count" -gt 0 ]; then
        message="${message}\n⚠️ 비미디어 ${non_media_count}개 무시됨"
    fi
    send_notification "Immich [✅ 업로드 완료]" "$message" -1 "none"
else
    # 실패: 모든 파일 보존
    error_tail=$(echo "$upload_output" | tail -c 200)
    message="CLI 오류: ${error_tail}"
    if [ "$non_media_count" -gt 0 ]; then
        message="${message}\n⚠️ 비미디어 ${non_media_count}개 무시됨"
    fi
    send_notification "Immich [❌ 업로드 실패]" "$message" 0 "falling"
fi

log "완료"
