#!/usr/bin/env bash
# Atuin Watchdog
# 동기화 상태를 감시하고 지연 시 알림 전송
# 참고: 실제 sync는 atuin 내장 auto_sync가 담당

set -euo pipefail

# PATH 설정 (Hammerspoon 등 다양한 환경에서 실행 가능하도록)
export PATH="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$HOME/.nix-profile/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# 환경변수에서 설정 읽기 (default.nix에서 주입)
THRESHOLD_MINUTES="${ATUIN_SYNC_THRESHOLD_MINUTES:-5}"

CREDENTIALS_FILE="$HOME/.config/pushover/atuin"
HOSTNAME=$(scutil --get LocalHostName 2>/dev/null || hostname -s)
LOG_FILE="${HOME}/.local/share/atuin/watchdog.log"

# 로그 디렉토리 생성
mkdir -p "$(dirname "$LOG_FILE")"

# 로깅 함수
log_message() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 콘솔 출력
    echo "[$timestamp] [$level] $message"

    # 파일 로깅
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # 로그 파일 크기 제한 (최근 500줄)
    if [[ -f "$LOG_FILE" ]]; then
        tail -500 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null && mv "${LOG_FILE}.tmp" "$LOG_FILE" || true
    fi
}

log_info() { log_message "INFO" "$1"; }
log_warn() { log_message "WARN" "$1"; }
log_error() { log_message "ERROR" "$1"; }

# 알림 전송 함수
send_alert() {
    local title="$1"
    local message="$2"
    local is_error="${3:-false}"

    # 1. macOS 기본 알림 (항상 시도)
    osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true

    # 2. Hammerspoon 알림 (있으면 추가)
    if command -v hs >/dev/null 2>&1; then
        hs -c "hs.notify.new({title='$title', informativeText='$message'}):send()" 2>/dev/null || true
    fi

    # 3. Pushover 알림 (에러일 때만)
    if [[ -f "$CREDENTIALS_FILE" ]] && [[ "$is_error" == "true" ]]; then
        # 권한 체크 (600 권장)
        PERMS=$(stat -f %A "$CREDENTIALS_FILE" 2>/dev/null || echo "unknown")
        if [[ "$PERMS" != "600" && "$PERMS" != "400" ]]; then
            log_warn "credentials file permission is $PERMS (recommended: 600)"
        fi

        # shellcheck source=/dev/null
        source "$CREDENTIALS_FILE"
        curl -s \
            --form-string "token=$PUSHOVER_TOKEN" \
            --form-string "user=$PUSHOVER_USER" \
            --form-string "priority=1" \
            -F "sound=falling" \
            --form-string "message=$message" \
            https://api.pushover.net/1/messages.json > /dev/null
        log_info "Alert sent via Pushover"
    fi
}

# 메뉴바 상태 업데이트 함수
update_menubar() {
    local status="$1"
    if command -v hs >/dev/null 2>&1; then
        hs -c "if atuinMenubar then atuinMenubar:setStatus('$status') end" 2>/dev/null || true
    fi
}

# last_sync 시간 조회 (atuin doctor에서) - epoch 반환
get_last_sync_epoch() {
    local doctor_output
    local last_sync_raw
    local last_sync_clean
    local last_sync_epoch

    doctor_output=$(atuin doctor 2>&1)
    last_sync_raw=$(echo "$doctor_output" | grep -o '"last_sync": "[^"]*"' | cut -d'"' -f4)

    if [[ -z "$last_sync_raw" || "$last_sync_raw" == "no last sync" ]]; then
        echo "error"
        return 1
    fi

    # UTC 시간을 epoch로 변환 (밀리초 및 타임존 제거)
    last_sync_clean=$(echo "$last_sync_raw" | sed 's/\.[0-9]*//; s/ +00:00:00//')
    last_sync_epoch=$(TZ=UTC date -j -f "%Y-%m-%d %H:%M:%S" "$last_sync_clean" "+%s" 2>/dev/null || echo "0")

    if [[ "$last_sync_epoch" == "0" ]]; then
        echo "error"
        return 1
    fi

    echo "$last_sync_epoch"
    return 0
}

# 마지막 CLI 커맨드 입력 시간 조회 - epoch 반환
# 참고: atuin history last는 $ATUIN_SESSION 환경변수가 필요하므로
#       Hammerspoon 등 외부 환경에서는 SQLite DB를 직접 쿼리
get_last_command_epoch() {
    local last_cmd_epoch
    local db_path="$HOME/.local/share/atuin/history.db"

    # SQLite DB에서 마지막 명령 시간 조회 (나노초 단위)
    if [[ ! -f "$db_path" ]]; then
        echo "error"
        return 1
    fi

    # timestamp는 나노초 단위이므로 10^9로 나눠서 초 단위로 변환
    last_cmd_epoch=$(sqlite3 "$db_path" "SELECT timestamp / 1000000000 FROM history ORDER BY timestamp DESC LIMIT 1;" 2>/dev/null)

    if [[ -z "$last_cmd_epoch" || "$last_cmd_epoch" == "0" ]]; then
        echo "error"
        return 1
    fi

    echo "$last_cmd_epoch"
    return 0
}

# ===== 상태 판단 함수 =====

# 상태 계산 (epoch 값들도 함께 반환)
calculate_status() {
    local last_sync_epoch
    local last_cmd_epoch
    local diff_seconds
    local threshold_seconds=$((THRESHOLD_MINUTES * 60))

    # last_sync 시간 조회
    last_sync_epoch=$(get_last_sync_epoch)
    if [[ "$last_sync_epoch" == "error" ]]; then
        echo "error|0|0|last_sync 조회 실패"
        return 1
    fi

    # 마지막 CLI 커맨드 시간 조회
    last_cmd_epoch=$(get_last_command_epoch)
    if [[ "$last_cmd_epoch" == "error" ]]; then
        echo "error|0|$last_sync_epoch|마지막 커맨드 조회 실패"
        return 1
    fi

    # 새 로직: (마지막 커맨드 시간) - (last_sync 시간) > N분이면 경고
    # 의미: 명령을 쳤는데 sync가 안 됐으면 문제
    diff_seconds=$((last_cmd_epoch - last_sync_epoch))

    if [[ $diff_seconds -gt $threshold_seconds ]]; then
        local diff_minutes=$((diff_seconds / 60))
        echo "warning|$last_cmd_epoch|$last_sync_epoch|CLI 입력 후 ${diff_minutes}분 미동기화"
        return 0
    else
        echo "ok|$last_cmd_epoch|$last_sync_epoch|정상"
        return 0
    fi
}

# ===== 메인 로직 =====

# --status 모드: JSON으로 상태만 출력 (알림 없이)
if [[ "${1:-}" == "--status" ]]; then
    # atuin 명령어 확인
    if ! command -v atuin >/dev/null 2>&1; then
        echo '{"status":"error","lastCmdEpoch":0,"lastSyncEpoch":0,"message":"atuin not found"}'
        exit 0
    fi

    RESULT=$(calculate_status)
    STATUS=$(echo "$RESULT" | cut -d'|' -f1)
    LAST_CMD_EPOCH=$(echo "$RESULT" | cut -d'|' -f2)
    LAST_SYNC_EPOCH=$(echo "$RESULT" | cut -d'|' -f3)
    MESSAGE=$(echo "$RESULT" | cut -d'|' -f4)

    echo "{\"status\":\"$STATUS\",\"lastCmdEpoch\":$LAST_CMD_EPOCH,\"lastSyncEpoch\":$LAST_SYNC_EPOCH,\"message\":\"$MESSAGE\"}"
    exit 0
fi

# 기본 모드: 상태 판단 + 알림 전송

log_info "=== Atuin Watchdog ==="
log_info "Host: $HOSTNAME, Threshold: ${THRESHOLD_MINUTES}m"

# atuin 명령어 확인
if ! command -v atuin >/dev/null 2>&1; then
    log_error "atuin not found"
    update_menubar "error"
    send_alert "🐢 Atuin 모니터" "atuin 명령어를 찾을 수 없음 [$HOSTNAME]" "true"
    exit 1
fi

# 상태 계산
RESULT=$(calculate_status)
STATUS=$(echo "$RESULT" | cut -d'|' -f1)
LAST_CMD_EPOCH=$(echo "$RESULT" | cut -d'|' -f2)
LAST_SYNC_EPOCH=$(echo "$RESULT" | cut -d'|' -f3)
MESSAGE=$(echo "$RESULT" | cut -d'|' -f4)

# 시간 정보 로깅
if [[ "$LAST_CMD_EPOCH" != "0" ]]; then
    LAST_CMD_TIME=$(date -r "$LAST_CMD_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    log_info "Last CLI command: $LAST_CMD_TIME"
fi
if [[ "$LAST_SYNC_EPOCH" != "0" ]]; then
    LAST_SYNC_TIME=$(date -r "$LAST_SYNC_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    log_info "Last sync: $LAST_SYNC_TIME"
fi

# 상태별 처리
case "$STATUS" in
    "error")
        log_error "$MESSAGE"
        update_menubar "error"
        send_alert "🐢❌ Atuin 모니터 오류" "$MESSAGE [$HOSTNAME]" "true"
        ;;
    "warning")
        log_warn "$MESSAGE"
        update_menubar "warning"
        # 경고 알림 (Pushover는 30분 초과 시에만)
        DIFF_MINUTES=$(( (LAST_CMD_EPOCH - LAST_SYNC_EPOCH) / 60 ))
        if [[ $DIFF_MINUTES -ge 30 ]]; then
            send_alert "🐢⚠️ Atuin 동기화 지연" "$MESSAGE [$HOSTNAME]" "true"
        else
            send_alert "🐢⚠️ Atuin 동기화 지연" "$MESSAGE [$HOSTNAME]" "false"
        fi
        ;;
    "ok")
        log_info "$MESSAGE"
        update_menubar "ok"
        ;;
esac
