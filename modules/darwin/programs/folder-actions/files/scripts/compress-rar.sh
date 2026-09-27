#!/usr/bin/env bash
# Folder Action: RAR 압축 + 체크섬 가이드 생성
# 감시 폴더: ~/FolderActions/compress-rar/
# 결과물: ~/Downloads/<파일명>/<파일명>.rar + 데이터_무결성_검증방법.txt
#         (그 이름이 이미 있으면 <파일명>_2, <파일명>_3 … 폴더에 같은 구조로 만든다)

set -euo pipefail

WATCH_DIR="$HOME/FolderActions/compress-rar"
DEST_ROOT="$HOME/Downloads"

LOCK_DIR="/tmp/compress-rar.lock.d"
LEGACY_LOCK_FILE="/tmp/compress-rar.lock"
LOCK_TOKEN_FILE="${LOCK_DIR}/owner.token"
LOCK_TTL_SECONDS=600  # Base TTL used to derive the missing/corrupt-token reclaim threshold.
LOCK_CORRUPT_TTL_SECONDS=$((LOCK_TTL_SECONDS * 2))

CURRENT_UID=$(/usr/bin/id -u)
CURRENT_PID="$$"
CURRENT_PROC_START=""
CURRENT_NONCE=""
CURRENT_STARTED_AT=""
LOCK_ACQUIRED=0
SELF_REAP_DIR=""
RESERVED_OUTPUT_NAME=""
ACTIVE_OUTPUT_DIR=""

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
    # 압축 도중 멈추면 예약한 결과 폴더가 비어 있을 때만 치운다. 부분 결과가 있으면 rmdir이
    # 실패해 그대로 남는다 (#1403).
    if [ -n "$ACTIVE_OUTPUT_DIR" ]; then
        /bin/rmdir "$ACTIVE_OUTPUT_DIR" 2>/dev/null || true
    fi
    cleanup_lock
    exit 1
}

trap cleanup_lock EXIT
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

acquire_lock

# shellcheck source=/dev/null
. "$(/usr/bin/dirname "$0")/_folder-actions-lib.sh"

# rar는 PATH로 찾는다 — launchd는 default.nix가 선언한 Nix bin, 셸 실행은 호출자 PATH (#1402)
require_commands_or_abort rar

# 처리 대상 후보 (필터를 한 곳에만 정의)
find_candidates() {
    find "$WATCH_DIR" -maxdepth 1 -type f ! -name ".*"
}

# 결과 폴더 mkdir이 실패했는데 그 경로가 없을 때, DEST_ROOT에 짧은 이름의 탐침 폴더를 만들었다
# 지워 본다. 파일·끊어진 링크·쓰기 금지뿐 아니라 -w가 참인데 생성이 거부되는 경우(TCC, 용량 부족 등)도
# 이것으로 가린다.
# 만들 수 있으면 0(그 이름만의 문제), 만들 수 없으면 1(DEST_ROOT의 문제)이다.
# 탐침 이름이 이미 있으면 그 항목은 건드리지 않고 다른 이름으로 다시 시도하며, 끝내 판단하지
# 못하면 입력을 옮기지 않는 쪽인 1로 본다. 탐침을 지우지 못하면 경고만 남긴다.
dest_root_accepts_new_dir() {
    local try probe
    for try in 1 2 3; do
        probe="${DEST_ROOT}/.compress-rar-probe.$$.${try}.${RANDOM}"
        if /bin/mkdir "$probe" 2>/dev/null; then
            /bin/rmdir "$probe" 2>/dev/null || log_warn "탐침 폴더를 지우지 못함: $probe"
            return 0
        fi
        if [ ! -e "$probe" ] && [ ! -L "$probe" ]; then
            return 1
        fi
    done
    return 1
}

# 결과 폴더 이름을 예약해 RESERVED_OUTPUT_NAME에 두고, 확보한 폴더를 곧바로 ACTIVE_OUTPUT_DIR에
# 올려 신호 처리가 알 수 있게 한다 (#1403).
# 명령 치환으로 돌려받지 않는다. 끝 개행이 잘리면 예약한 폴더와 실제로 쓰는 폴더가 어긋난다.
# DEST_ROOT에 <stem>이 없으면 그 이름을, 있으면 <stem>_2, <stem>_3 … 중 아직 없는 첫 이름을 쓴다.
# 이미 있는 항목은 종류(폴더·파일·심볼릭 링크)와 관계없이 건너뛰어 앞선 결과에 쓰지 않는다.
# 확보는 mkdir(-p 없이) 한 번으로 한다. 이미 있는 경로면 mkdir이 실패하므로, 없음을 확인한 뒤
# 다른 실행이 같은 이름을 차지하는 틈이 없다.
# 반환: 0 예약함, 1 이 이름만 만들 수 없음(이름 길이 초과 등), 2 DEST_ROOT에 새 폴더를 만들 수 없음
reserve_output_name() {
    local stem="$1"
    local name="$stem"
    local n=1

    RESERVED_OUTPUT_NAME=""
    # DEST_ROOT가 아예 없으면 전처럼 만든다. 만들 수 없는 경우는 아래 mkdir과 탐침이 가린다.
    [ -e "$DEST_ROOT" ] || [ -L "$DEST_ROOT" ] || /bin/mkdir -p "$DEST_ROOT" 2>/dev/null || true
    until /bin/mkdir "${DEST_ROOT}/${name}" 2>/dev/null; do
        # 경로가 없는데 실패했다면 충돌이 아니다. 탐침으로 이 이름만의 문제인지 가린다.
        if [ ! -e "${DEST_ROOT}/${name}" ] && [ ! -L "${DEST_ROOT}/${name}" ]; then
            dest_root_accepts_new_dir || return 2
            log_error "결과 폴더를 만들 수 없음: ${DEST_ROOT}/${name}"
            return 1
        fi
        n=$((n + 1))
        name="${stem}_${n}"
    done
    ACTIVE_OUTPUT_DIR="${DEST_ROOT}/${name}"
    RESERVED_OUTPUT_NAME="$name"
}

process_one() {
    local f="$1"
    local filename name_no_ext output_name target_dir rar_output_path checksum_val guide_file
    local reserve_rc=0

    filename=$(basename "$f")
    name_no_ext="${filename%.*}"

    # 결과 폴더 예약. DEST_ROOT에 새 폴더를 만들 수 없는 것은 입력 결함이 아니라 환경 오류이므로
    # require_commands_or_abort(#1402)처럼 입력을 watch dir에 두고 run을 중단한다.
    # 이 이름만 만들 수 없으면 압축하지 않고 입력을 격리한다.
    reserve_output_name "$name_no_ext" || reserve_rc=$?
    case "$reserve_rc" in
        0) ;;
        2)
            log_error "환경 오류: 결과 폴더 위치에 쓸 수 없음: ${DEST_ROOT}; 입력 파일은 그대로 두고 run 중단"
            notify_failure "FolderActions 환경 오류" "$(basename "$WATCH_DIR"): 결과 폴더 위치에 쓸 수 없음: ${DEST_ROOT}" 1
            exit 1
            ;;
        *)
            log_error "결과 폴더 예약 실패: $filename"
            quarantine_or_abort "$f"
            return 0
            ;;
    esac
    output_name="$RESERVED_OUTPUT_NAME"
    target_dir="${DEST_ROOT}/${output_name}"

    # RAR 압축
    rar_output_path="${target_dir}/${output_name}.rar"
    if rar a -rr10% -ma5 -ep1 -idq "$rar_output_path" "$f"; then
        # 체크섬 계산
        checksum_val=$(/usr/bin/shasum -a 256 "$rar_output_path" | /usr/bin/awk '{print $1}')

        # 품질보증서 생성
        guide_file="${target_dir}/데이터_무결성_검증방법.txt"
        cat <<EOF_GUIDE > "$guide_file"
[데이터 품질 보증서]

파일명: ${output_name}.rar
생성일: $(/bin/date "+%Y-%m-%d %H:%M:%S")
SHA-256 Checksum:
${checksum_val}

================================================================
## 데이터 무결성 검증 가이드

이 파일은 원본 데이터의 변조나 손상을 확인하기 위한 인증서입니다.
아래의 명령어를 사용하여 위 Checksum과 일치하는지 확인하세요.

### 1. macOS / Linux (터미널)
터미널을 열고 압축 파일이 있는 폴더로 이동한 뒤 입력:
$ shasum -a 256 "${output_name}.rar"

### 2. Windows (PowerShell)
파워셸을 열고 압축 파일이 있는 폴더로 이동한 뒤 입력:
> Get-FileHash "${output_name}.rar" -Algorithm SHA256

----------------------------------------------------------------
※ 만약 출력된 코드가 위 Checksum과 단 한 글자라도 다르다면,
   파일이 손상된 것이므로 복구(RAR Recovery)를 시도하거나 백업을 다시 받으세요.
================================================================
EOF_GUIDE

        # 원본 삭제
        /bin/rm -f "$f"
        ACTIVE_OUTPUT_DIR=""
        log_info "압축 완료: $filename -> ${target_dir}/"
    else
        log_error "압축 실패: $filename"
        # 예약한 폴더는 이 입력만 쓰므로 부분 결과와 함께 치운다. 다른 항목이 남아 있으면 rmdir이 실패해 그대로 둔다.
        /bin/rm -f "$rar_output_path" || true
        # rmdir 뒤에는 이 이름을 다른 실행이 가질 수 있으므로 신호 처리 대상에서 먼저 뺀다.
        ACTIVE_OUTPUT_DIR=""
        /bin/rmdir "$target_dir" 2>/dev/null || log_warn "예약한 결과 폴더를 비우지 못함: $target_dir"
        quarantine_or_abort "$f"
    fi
}

# 큐 비우기 + 락 보유 재스캔 (#374). drain_queue가 안정화 대기와 종료 조건을 통합.
drain_queue process_one
