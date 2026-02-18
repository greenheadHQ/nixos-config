#!/bin/bash
# Folder Action: Immich 자동 업로드
# 감시 폴더: $WATCH_DIR (기본값: ~/FolderActions/upload-immich/)
# 미디어 파일 → Immich 서버 업로드 → Pushover 알림 → 원본 삭제
# shellcheck disable=SC1090

WATCH_DIR="${WATCH_DIR:-$HOME/FolderActions/upload-immich}"
LOCK_FILE="/tmp/upload-immich.lock"
IMMICH_CREDENTIALS="$HOME/.config/immich/api-key"
PUSHOVER_CREDENTIALS="$HOME/.config/pushover/immich"

# Immich CLI 지원 확장자 (클라이언트 측 필터)
MEDIA_EXT="jpg|jpeg|jpe|png|heic|heif|webp|gif|avif|bmp|jp2|jxl|psd|raw|rw2|svg|tif|tiff|insp"
MEDIA_EXT="${MEDIA_EXT}|3gp|3gpp|avi|flv|m4v|mkv|mts|m2ts|m2t|mp4|insv|mpg|mpe|mpeg|mov|webm|wmv"

# ─── 유틸리티 함수 ────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
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
            snapshot="${snapshot}$(basename "$f"):$(stat -f%z "$f" 2>/dev/null)\n"
        done

        [ "$snapshot" = "$prev_snapshot" ] && return 0
        prev_snapshot="$snapshot"
        sleep 1
        ((waited++))
    done
    return 1
}

# ─── 중복 실행 방지 ───────────────────────────────────────────

if [ -f "$LOCK_FILE" ]; then
    # stale lock 감지 (PID 확인)
    lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
        exit 0
    fi
    log "Stale lock 감지 (PID: ${lock_pid}), 제거 후 계속"
    rm -f "$LOCK_FILE"
fi
echo $$ > "$LOCK_FILE"
trap 'rm -f "$LOCK_FILE"' EXIT

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
        file_size=$(stat -f%z "$f" 2>/dev/null || echo 0)
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
            rm -f "$f"
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
