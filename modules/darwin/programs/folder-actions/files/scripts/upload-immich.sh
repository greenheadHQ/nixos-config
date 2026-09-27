#!/usr/bin/env bash
# Folder Action: Immich 자동 업로드
# 감시 폴더: $WATCH_DIR (기본값: ~/FolderActions/upload-immich/)
# 미디어 파일 → Immich 서버 업로드 → 서버 저장이 확인된 원본만 삭제 → Pushover 알림
# shellcheck disable=SC1090

WATCH_DIR="${WATCH_DIR:-$HOME/FolderActions/upload-immich}"
LOCK_DIR="/tmp/upload-immich.lock.d"
LEGACY_LOCK_FILE="/tmp/upload-immich.lock"
LOCK_TOKEN_FILE="${LOCK_DIR}/owner.token"
LOCK_TTL_SECONDS=2700
LOCK_CORRUPT_TTL_SECONDS=$((LOCK_TTL_SECONDS * 2))
IMMICH_CREDENTIALS="$HOME/.config/immich/api-key"
PUSHOVER_CREDENTIALS="$HOME/.config/pushover/immich"
PUSHOVER_HELPER="$HOME/.local/lib/pushover.sh"

CURRENT_UID=$(/usr/bin/id -u)
CURRENT_PID="$$"
CURRENT_PROC_START=""
CURRENT_NONCE=""
CURRENT_STARTED_AT=""
LOCK_ACQUIRED=0
SELF_REAP_DIR=""

# 업로드 대상 확장자. CLI에는 이 목록에 든 파일만 넘기므로 서버가 받는 목록과 같아야 한다.
# 출처: immich-server v3.0.0 server/src/utils/mime-types.ts의 image(4-70행: raw,
# webSupportedImage, webUnsupportedImage)와 video(106-127행). 서버 이미지 메이저를 올리면 다시 맞춘다.
MEDIA_EXT="3fr|ari|arw|cap|cin|cr2|cr3|crw|dcr|dng|erf|fff|iiq|k25|kdc|mrw|nef|nrw|orf|ori"
MEDIA_EXT="${MEDIA_EXT}|pef|psd|raf|raw|rw2|rwl|sr2|srf|srw|x3f"
MEDIA_EXT="${MEDIA_EXT}|avif|bmp|gif|jpeg|jpg|png|webp"
MEDIA_EXT="${MEDIA_EXT}|heic|heif|hif|insp|jp2|jpe|jxl|mpo|svg|tif|tiff"
MEDIA_EXT="${MEDIA_EXT}|3gp|3gpp|avi|flv|insv|m2t|m2ts|m4v|mkv|mov|mp4|mpe|mpeg|mpg|mts|mxf|ts|vob|webm|wmv"

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

    [ -r "$PUSHOVER_HELPER" ] || return 0
    # shellcheck disable=SC1090
    source "$PUSHOVER_HELPER" 2>/dev/null || return 0

    pushover_send "$PUSHOVER_CREDENTIALS" "$title" "$message" "$priority" "$sound" || true
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

# ─── 서버 저장 확인 (bulk-upload-check) ───────────────────────
# CLI 업로드 뒤에도 남은 원본이 서버에 이미 있는지 스크립트가 직접 확인한다. CLI의
# --delete-duplicates는 쓰지 않는다: 서버 휴지통에만 있는 자산(isTrashed)도 중복으로 보고
# 지우고, 올리지 않은 .xmp 사이드카까지 함께 지운다 (CLI 3.2.2 deleteFiles/findSidecar).
#
# 계약 (immich-server v3.0.0 server/src):
# - POST <IMMICH_INSTANCE_URL>/api/assets/bulk-upload-check, 인증 헤더 x-api-key
#   (controllers/asset-media.controller.ts, enum.ts ImmichHeader.ApiKey; CLI 3.2.2도 같은 헤더)
# - 요청 {"assets":[{"id":<클라이언트 식별자>,"checksum":<SHA1>}]} (dtos/asset-media.dto.ts).
#   checksum은 28자면 base64, 아니면 hex로 읽는다 (utils/request.ts fromChecksum). CLI 3.2.2와
#   같이 hex를 보낸다. id는 경로 대신 요청 순번을 써서 JSON 이스케이프를 피한다.
# - 응답 {"results":[{"id","action":"accept"|"reject","reason"?,"assetId"?,"isTrashed"?}]}
#   (dtos/asset-media-response.dto.ts). bulkUploadCheck는 휴지통 자산도 reject/duplicate에
#   isTrashed=true로 돌려준다 (services/asset-media.service.ts).
# 확인 요청이 실패하거나 응답을 해석할 수 없으면 아무것도 지우지 않는다.

CHECK_FILES=()
CHECK_VERDICTS=()

sha1_hex() {
    local sum
    # stdin으로 읽어 파일명이 출력 형식을 바꾸지 않게 한다.
    sum=$(/usr/bin/shasum -a 1 < "$1" 2>/dev/null) || return 1
    sum="${sum%% *}"
    [[ "$sum" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "$sum"
}

# curl config의 quoted string escape (modules/shared/scripts/lib/pushover.sh와 같은 규칙)
curl_cfg_escape() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/\\n}"
    v="${v//$'\r'/\\r}"
    v="${v//$'\t'/\\t}"
    printf '%s' "$v"
}

# API 키는 명령줄에 싣지 않고 curl config로 stdin에 넘긴다.
request_bulk_check() {
    local body="" sep="" sum i

    for ((i = 0; i < ${#CHECK_FILES[@]}; i++)); do
        sum=$(sha1_hex "${CHECK_FILES[$i]}") || return 1
        body="${body}${sep}{\"id\":\"${i}\",\"checksum\":\"${sum}\"}"
        sep=","
    done

    {
        printf 'url = "%s"\n' "$(curl_cfg_escape "${IMMICH_INSTANCE_URL}/api/assets/bulk-upload-check")"
        printf 'header = "%s"\n' "$(curl_cfg_escape "x-api-key: ${IMMICH_API_KEY}")"
        printf 'header = "Content-Type: application/json"\n'
        printf 'data-binary = "%s"\n' "$(curl_cfg_escape "{\"assets\":[${body}]}")"
    } | curl -q -sf --max-time 30 --config -
}

json_value() {
    printf '%s' "$1" | /usr/bin/plutil -extract "$2" raw -expect "$3" -o - - 2>/dev/null
}

# 결과를 CHECK_VERDICTS[요청 순번]에 duplicate | trashed | missing으로 채운다.
# 모든 결과를 해석하지 못하면 1을 돌려준다.
parse_bulk_check() {
    local resp="$1" n count i id action reason trashed

    n=${#CHECK_FILES[@]}
    CHECK_VERDICTS=()
    count=$(json_value "$resp" results array) || return 1
    [ "$count" = "$n" ] || return 1

    for ((i = 0; i < n; i++)); do
        id=$(json_value "$resp" "results.$i.id" string) || return 1
        [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -lt "$n" ] || return 1
        [ -z "${CHECK_VERDICTS[$id]:-}" ] || return 1
        action=$(json_value "$resp" "results.$i.action" string) || return 1
        case "$action" in
            accept)
                CHECK_VERDICTS[$id]="missing"
                ;;
            reject)
                reason=$(json_value "$resp" "results.$i.reason" string) || return 1
                if [ "$reason" != "duplicate" ]; then
                    CHECK_VERDICTS[$id]="missing"
                    continue
                fi
                trashed=$(json_value "$resp" "results.$i.isTrashed" bool) || return 1
                case "$trashed" in
                    false) CHECK_VERDICTS[$id]="duplicate" ;;
                    true) CHECK_VERDICTS[$id]="trashed" ;;
                    *) return 1 ;;
                esac
                ;;
            *)
                return 1
                ;;
        esac
    done
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

# CLI에는 안정화 대기를 거친 목록만 넘긴다. --delete는 이번 실행에 업로드 응답을 받은
# 파일만 지우고, 업로드 실패로 남은 파일은 지우지 않는다. 서버에 이미 있어 업로드를 건너뛴
# 파일은 아래 서버 저장 확인에서 다룬다. 메이저 버전은
# modules/nixos/programs/docker/immich.nix의 immich-server 이미지와 맞춘다.
upload_output=$(bun x @immich/cli@3 upload \
    --album-name "Desktop Upload" \
    --delete \
    --concurrency 2 \
    -- "${media_files[@]}" 2>&1) && upload_exit=0 || upload_exit=$?

log "CLI 종료 코드: ${upload_exit}"
log "CLI 출력: ${upload_output}"

# ─── 결과 처리 ────────────────────────────────────────────────

# 종료 코드 0은 개별 파일의 업로드 성공을 뜻하지 않는다 (CLI는 일부 업로드가 실패해도
# 0으로 끝난다). 결과는 사전 목록 중 CLI 실행 뒤에도 남은 원본으로 판단한다.
remaining_files=()
for f in "${media_files[@]}"; do
    if [ -e "$f" ]; then
        remaining_files+=("$f")
    fi
done
remaining=${#remaining_files[@]}
uploaded_count=$((media_count - remaining))
log "CLI 업로드 ${uploaded_count}/${media_count}개, 남은 원본 ${remaining}개"

# 남은 원본 중 서버에 있고 휴지통이 아닌 것만 원본을 지운다 (사이드카는 남긴다).
# CLI가 실패했으면 확인하지 않는다: 앨범 추가 같은 뒷단계가 다음 실행에서 다시 돌게 둔다.
duplicate_count=0
trashed_count=0
missing_count=0
unchecked_count=0
if [ "$upload_exit" -eq 0 ] && [ "$remaining" -gt 0 ]; then
    CHECK_FILES=("${remaining_files[@]}")
    if check_response=$(request_bulk_check) && parse_bulk_check "$check_response"; then
        for ((i = 0; i < remaining; i++)); do
            case "${CHECK_VERDICTS[$i]}" in
                duplicate)
                    if /bin/rm -f "${CHECK_FILES[$i]}"; then
                        duplicate_count=$((duplicate_count + 1))
                    else
                        log_warn "서버에 있는 원본 삭제 실패: ${CHECK_FILES[$i]}"
                    fi
                    ;;
                trashed) trashed_count=$((trashed_count + 1)) ;;
                *) missing_count=$((missing_count + 1)) ;;
            esac
        done
    else
        unchecked_count=$remaining
        log_warn "서버 저장 확인 실패; 남은 원본 ${remaining}개를 지우지 않음"
    fi
    log "서버 확인: 중복 삭제 ${duplicate_count}, 휴지통 보존 ${trashed_count}, 미업로드 ${missing_count}, 확인 실패 ${unchecked_count}"
fi
stored_count=$((uploaded_count + duplicate_count))

if [ "$upload_exit" -ne 0 ]; then
    error_tail=$(echo "$upload_output" | tail -c 200)
    title="Immich [❌ 업로드 실패]"
    message="CLI 오류: ${error_tail}"$'\n'"⚠️ 남은 파일 ${remaining}/${media_count}개 원본 보존"
    priority=0
    sound="falling"
else
    if [ "$stored_count" -eq "$media_count" ]; then
        title="Immich [✅ 업로드 완료]"
        message="📸 ${media_count}개 파일 (${readable_size}) → Desktop Upload"
        priority=-1
        sound="none"
    else
        if [ "$stored_count" -eq 0 ]; then
            title="Immich [❌ 업로드된 파일 없음]"
        else
            title="Immich [⚠️ 일부 미업로드]"
        fi
        message="📸 ${stored_count}/${media_count}개 업로드 → Desktop Upload"
        priority=0
        sound="falling"
    fi
    if [ "$duplicate_count" -gt 0 ]; then
        message="${message}"$'\n'"♻️ 서버에 이미 있던 ${duplicate_count}개 원본 정리"
    fi
    if [ "$missing_count" -gt 0 ]; then
        message="${message}"$'\n'"⚠️ 업로드 안 된 ${missing_count}개 원본 보존"
    fi
    if [ "$trashed_count" -gt 0 ]; then
        message="${message}"$'\n'"⚠️ 서버 휴지통에 있는 ${trashed_count}개 원본 보존"
    fi
    if [ "$unchecked_count" -gt 0 ]; then
        message="${message}"$'\n'"⚠️ 서버 확인 실패로 ${unchecked_count}개 원본 보존"
    fi
fi
if [ "$non_media_count" -gt 0 ]; then
    message="${message}"$'\n'"⚠️ 비미디어 ${non_media_count}개 무시됨"
fi
send_notification "$title" "$message" "$priority" "$sound"

log "완료"
