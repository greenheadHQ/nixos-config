# shellcheck shell=bash
# Folder Actions 공유 헬퍼 — 4개 스크립트(compress-video, convert-video-to-gif,
# rename-asset, compress-rar)의 큐 처리/안정화 대기/실패 격리/실패 전용
# Pushover 알림 전용. upload-immich.sh의 send_notification과 wait_all_stable는
# 별도 owner를 유지한다 (디렉토리 전체 snapshot 기반, 다른 입력 도메인).
#
# 호출 라이프사이클:
#   1) source 시점에 정의되어 있어야 함:
#      - log_info / log_warn / log_error
#      - verify_path_security <path> <expected_mode> <label>
#      - WATCH_DIR, CURRENT_PID
#      - set -euo pipefail
#   2) drain_queue 호출 전에 정의되어 있어야 함:
#      - find_candidates    — 처리 대상 파일을 한 줄씩 stdout으로 출력
#      - process_one <file> — drain_queue가 호출하는 단일 파일 processor

# Pushover credential 경로는 agenix 고정 path로 hard-code (override 금지).
PUSHOVER_CREDENTIALS="$HOME/.config/pushover/folder-actions"

# 실패 격리 sibling 경로 — watch root 밖이므로 launchd WatchPaths 추가 wakeup 없음.
# 사용자 복구 절차는 .claude/skills/managing-macos/references/features.md 참조.
_FA_LIB_FAILED_ROOT="$HOME/FolderActions/.failed"

notify_failure() {
    local title="$1"
    local message="$2"
    local priority="${3:-0}"

    # credential 부재는 silent skip (agenix 미배포 창 호환).
    [ -f "$PUSHOVER_CREDENTIALS" ] || return 0

    # source 실패는 추적 가능하도록 경고만 남기고 알림 생략.
    # shellcheck disable=SC1090
    if ! source "$PUSHOVER_CREDENTIALS" 2>/dev/null; then
        log_warn "notify_failure: PUSHOVER_CREDENTIALS source 실패: $PUSHOVER_CREDENTIALS"
        return 0
    fi
    if [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
        log_warn "notify_failure: PUSHOVER_TOKEN/USER 미설정"
        return 0
    fi

    if ! /usr/bin/curl -sf --max-time 10 \
            --form-string "token=${PUSHOVER_TOKEN}" \
            --form-string "user=${PUSHOVER_USER}" \
            --form-string "title=${title}" \
            --form-string "message=${message}" \
            --form-string "priority=${priority}" \
            https://api.pushover.net/1/messages.json > /dev/null 2>&1; then
        log_warn "notify_failure: Pushover API 호출 실패 (네트워크/credential 확인)"
    fi
    return 0
}

ensure_failed_dir() {
    local script_name failed_dir

    script_name=$(basename "$WATCH_DIR")
    failed_dir="${_FA_LIB_FAILED_ROOT}/${script_name}"

    if [ -L "${_FA_LIB_FAILED_ROOT}" ]; then
        log_error "failed root is symlink: ${_FA_LIB_FAILED_ROOT}"
        return 1
    fi
    if [ -L "$failed_dir" ]; then
        log_error "failed dir is symlink: $failed_dir"
        return 1
    fi

    /bin/mkdir -p "$failed_dir" || {
        log_error "mkdir failed: $failed_dir"
        return 1
    }
    /bin/chmod 700 "$failed_dir" || {
        log_error "chmod failed: $failed_dir"
        return 1
    }

    # 기존 스크립트의 verify_path_security와 동일 수준 검증.
    verify_path_security "$failed_dir" "0700" "failed dir" || return 1

    printf '%s\n' "$failed_dir"
}

move_to_failed() {
    local src="$1"
    local failed_dir basename_f target stamp

    [ -f "$src" ] || return 0

    failed_dir=$(ensure_failed_dir) || {
        notify_failure "FolderActions 오류" "실패 격리 디렉토리 준비 실패: $(basename "$src")" 1
        return 1
    }

    basename_f=$(basename "$src")
    # 충돌 회피: 초 단위 timestamp + PID + RANDOM
    # (macOS BSD date는 GNU `%N`(나노초)을 지원하지 않아 초 단위로 둔다.)
    stamp=$(/bin/date +%Y%m%dT%H%M%S 2>/dev/null) || stamp="unknown"
    target="${failed_dir}/${stamp}_${CURRENT_PID}_${RANDOM}_${basename_f}"

    if /bin/mv -- "$src" "$target"; then
        # 절대경로를 함께 남겨야 사용자가 .failed/ 위치를 즉시 찾을 수 있다.
        log_warn "실패 파일 격리: ${basename_f} -> ${target}"
        notify_failure "FolderActions 실패" \
            "처리 실패 격리: ${basename_f}
복구 경로: ${target}" 0
        return 0
    else
        log_error "실패 파일 격리 mv 실패: ${basename_f} -> ${target}"
        notify_failure "FolderActions 오류" \
            "실패 파일 mv 실패: ${basename_f}
대상: ${target}" 1
        return 1
    fi
}

# 단일 파일 안정화 대기 — size+mtime이 짧은 시간 동안 변하지 않으면 stable로 간주.
# 복사 중 파일/일시적 쓰기를 ffmpeg 등이 incomplete read하여 영구 격리되는 회귀
# (즉시 quarantine) 방지용. timeout이면 false → drain_queue가 deferred 처리.
wait_file_stable() {
    local file="$1"
    local max_wait="${2:-30}"
    local check_interval="${3:-2}"
    local prev_sig="" cur_sig
    local waited=0

    [ -f "$file" ] || return 1

    while [ "$waited" -le "$max_wait" ]; do
        cur_sig=$(/usr/bin/stat -f '%z:%m' "$file" 2>/dev/null) || return 1
        if [ -n "$prev_sig" ] && [ "$cur_sig" = "$prev_sig" ]; then
            return 0
        fi
        prev_sig="$cur_sig"
        sleep "$check_interval"
        waited=$((waited + check_interval))
    done
    return 1
}

# 큐 비우기: find_candidates 결과를 process_one으로 처리하며,
# 처리 중 도착한 파일도 같은 락 하에서 재스캔으로 회수한다 (#374 핵심 로직).
# - wait_file_stable로 복사 중 파일은 지연시켜 같은 run에서 재시도하지 않는다.
# - process_one에서 quarantine 실패 시 exit 1로 무한 루프 차단 (호출부 책임)
# - process substitution 사용으로 outer shell 변수(예: rename-asset의 i)가 유지됨
# - unstable 파일은 deferred 배열에 누적해 같은 run에서 재대기하지 않는다.
#   stable 잔여만 계속 처리하며, 모두 unstable일 때만 종료한다.
#
# Deferred 파일의 재처리는 launchd `WatchPaths`가 다음 watch dir 변경을 감지할
# 때만 자동으로 일어난다. 즉 unstable 파일이 더 이상 size/mtime 변경을 일으키지
# 않으면, 그 파일은 새 외부 이벤트(다른 파일 추가/이동)가 watch dir에 도착할
# 때까지 잔류한다. 운영상 일시적 처리 지연이지 데이터 유실은 아니지만,
# “자동 재시도 보장”은 launchd 계약상 성립하지 않는다 (#374 R3 C-1).
# 영구 보장이 필요하면 `QueueDirectories` + ready-marker 프로토콜 전환이 필요하나,
# 이슈 본문에서 “과도한 변경, YAGNI”로 판단해 이번 스코프에서 제외했다.
drain_queue() {
    local processor="$1"
    # deferred는 함수 local. 멤버십 검사는 함수 안에서 인라인으로 수행하여
    # outer 함수의 local에 암묵 의존하는 helper(dynamic scope)를 만들지 않는다.
    local -a deferred=()
    local total_remaining stable_remaining f entry skip

    while true; do
        while IFS= read -r f; do
            [ -f "$f" ] || continue
            skip=0
            for entry in "${deferred[@]:-}"; do
                if [ "$entry" = "$f" ]; then skip=1; break; fi
            done
            [ "$skip" -eq 1 ] && continue
            if ! wait_file_stable "$f"; then
                log_warn "unstable; deferred to next wakeup: $(basename "$f")"
                deferred+=("$f")
                continue
            fi
            "$processor" "$f"
        done < <(find_candidates)

        # 잔여 후보 중 deferred를 제외한 stable 후보 수
        total_remaining=0
        stable_remaining=0
        while IFS= read -r f; do
            total_remaining=$((total_remaining + 1))
            skip=0
            for entry in "${deferred[@]:-}"; do
                if [ "$entry" = "$f" ]; then skip=1; break; fi
            done
            [ "$skip" -eq 0 ] && stable_remaining=$((stable_remaining + 1))
        done < <(find_candidates 2>/dev/null)

        if [ "$stable_remaining" -eq 0 ]; then
            if [ "$total_remaining" -gt 0 ]; then
                log_info "unstable 파일 ${total_remaining}개 잔존; run 종료 (외부 이벤트 시 자동 재시도)"
            fi
            return 0
        fi
        log_info "재스캔: stable 후보 ${stable_remaining}개 / 총 잔여 ${total_remaining}개"
    done
}

# move_to_failed 호출 + 실패 시 abort.
# 4개 스크립트의 process_one에서 동일 분기를 반복하던 것을 헬퍼로 추출.
quarantine_or_abort() {
    local f="$1"
    if ! move_to_failed "$f"; then
        log_error "quarantine 실패; run 중단 (락 해제 후 외부 이벤트 시 재시도)"
        exit 1
    fi
}
