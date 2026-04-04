# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# NRS Lock: worktree 간 동시 rebuild 방지를 위한 협조적 잠금
# Lock 파일: 기본값 /tmp/nrs-state (JSON: worktree, branch, timestamp, pid)
# 테스트/격리 실행에서는 NRS_LOCK_FILE env로 override 가능
# 타임아웃: 30분 자동 만료
#───────────────────────────────────────────────────────────────────────────────
NRS_LOCK_FILE="${NRS_LOCK_FILE:-/tmp/nrs-state}"
# 주의: 기본값은 rebuild-common.sh, nrs-lock.sh, nrs-lock-guard.sh와 동일하게 유지
NRS_LOCK_TIMEOUT_MINUTES=30
NRS_LOCK_ACQUIRED=false    # 이 프로세스가 lock을 획득했는가? (EXIT trap 보호용)
NRS_LOCK_REENTRY=false     # 기존 lock에 대한 재진입인가?
NRS_LOCK_SWITCH_SUCCESS=false

is_stale_lock() {
    # Returns 0 (true) if stale, 1 (false) if active
    # Stale 조건 (OR): worktree 경로 미존재 OR (타임아웃 초과 AND PID 미생존)
    # DA Fix: PID가 살아있으면 타임아웃 초과해도 stale 아님 (장시간 빌드 보호)
    local lock_worktree lock_ts lock_pid now
    lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
    lock_ts=$(jq -r '.timestamp' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)

    if [[ -n "$lock_worktree" && ! -d "$lock_worktree" ]]; then
        return 0
    fi

    local expiry=$(( lock_ts + NRS_LOCK_TIMEOUT_MINUTES * 60 ))
    if (( now > expiry )); then
        # PID가 살아있으면 stale 아님 (장시간 빌드 보호)
        if [[ "$lock_pid" != "0" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            return 1
        fi
        return 0
    fi

    return 1
}

acquire_nrs_lock() {
    local now
    now=$(date +%s)
    NRS_LOCK_ACQUIRED=false
    NRS_LOCK_REENTRY=false
    NRS_LOCK_SWITCH_SUCCESS=false

    # Main worktree: lock 취득하지 않음, 기존 lock 존재 시 경고만 표시
    if [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]]; then
        if [[ -f "$NRS_LOCK_FILE" ]]; then
            local lock_worktree lock_branch
            lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
            lock_branch=$(jq -r '.branch' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
            if is_stale_lock; then
                log_warn "⚠️  Stale lock detected. Removing."
                log_warn "    Branch: $lock_branch, Worktree: $lock_worktree"
                rm -f "$NRS_LOCK_FILE"
            else
                log_warn "⚠️  Worktree lock active (branch: $lock_branch). Proceeding from main."
            fi
        fi
        return 0
    fi

    if [[ -f "$NRS_LOCK_FILE" ]]; then
        local lock_ts lock_worktree lock_branch
        lock_ts=$(jq -r '.timestamp' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
        lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
        lock_branch=$(jq -r '.branch' "$NRS_LOCK_FILE" 2>/dev/null || echo "")

        if is_stale_lock; then
            local stale_reason=""
            if [[ -n "$lock_worktree" && ! -d "$lock_worktree" ]]; then
                stale_reason="worktree deleted"
            else
                stale_reason="timeout ($(( (now - lock_ts) / 60 ))m, limit: ${NRS_LOCK_TIMEOUT_MINUTES}m)"
            fi
            log_warn "⚠️  Stale lock detected ($stale_reason). Removing."
            log_warn "    Branch: $lock_branch, Worktree: $lock_worktree"
            rm -f "$NRS_LOCK_FILE"
        elif [[ "$lock_worktree" == "$FLAKE_PATH" ]]; then
            # 같은 worktree — re-entry
            # 기존 lock의 PID가 아직 살아있으면 동시 실행 → 차단
            local lock_pid
            lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
            if [[ "$lock_pid" != "0" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                if [[ "$lock_pid" != "$$" ]]; then
                    log_error "❌ Another nrs process (PID $lock_pid) is running in this worktree."
                    echo "  Wait for it to finish or run 'nrs-lock unlock' to force release."
                    exit 1
                fi
            fi
            NRS_LOCK_REENTRY=true
            NRS_LOCK_ACQUIRED=true
            local branch
            branch=$(git -C "$FLAKE_PATH" branch --show-current 2>/dev/null || echo "unknown")
            local json
            json=$(jq -n \
                --arg w "$FLAKE_PATH" \
                --arg b "$branch" \
                --argjson t "$now" \
                --argjson p "$$" \
                '{worktree: $w, branch: $b, timestamp: $t, pid: $p}')
            # tmpfile + mv로 원자적 교체 (truncate 중 partial read 방지)
            local tmpfile
            tmpfile=$(mktemp "${NRS_LOCK_FILE}.XXXXXX")
            echo "$json" > "$tmpfile"
            mv -f "$tmpfile" "$NRS_LOCK_FILE"
            log_info "🔒 Lock re-entry: $branch ($FLAKE_PATH)"
            return 0
        else
            # 다른 worktree — 충돌
            local elapsed=$(( (now - lock_ts) / 60 ))
            log_error "❌ Another worktree holds the nrs lock:"
            echo "  Branch:   $lock_branch"
            echo "  Worktree: $lock_worktree"
            echo "  Locked:   ${elapsed}m ago"
            echo ""
            echo "  Run 'nrs-lock unlock' to release the lock."
            exit 1
        fi
    fi

    # Lock 생성: tmpfile에 쓰고 ln으로 원자적 생성 (partial-read 방지)
    # ln은 대상이 이미 존재하면 실패 → noclobber와 동일한 경쟁 방지
    local branch
    branch=$(git -C "$FLAKE_PATH" branch --show-current 2>/dev/null || echo "unknown")
    local json
    json=$(jq -n \
        --arg w "$FLAKE_PATH" \
        --arg b "$branch" \
        --argjson t "$now" \
        --argjson p "$$" \
        '{worktree: $w, branch: $b, timestamp: $t, pid: $p}')

    local tmpfile
    tmpfile=$(mktemp "${NRS_LOCK_FILE}.XXXXXX")
    echo "$json" > "$tmpfile"
    if ! ln "$tmpfile" "$NRS_LOCK_FILE" 2>/dev/null; then
        rm -f "$tmpfile"
        log_error "❌ Race condition: another process acquired the lock."
        exit 1
    fi
    rm -f "$tmpfile"

    NRS_LOCK_ACQUIRED=true
    log_info "🔒 Lock acquired: $branch ($FLAKE_PATH)"
}

release_nrs_lock() {
    rm -f "$NRS_LOCK_FILE"
    NRS_LOCK_ACQUIRED=false
    log_info "🔓 Lock released"
}

release_nrs_lock_after_no_changes() {
    if [[ "$NRS_LOCK_ACQUIRED" == true && "$NRS_LOCK_REENTRY" != true ]]; then
        local lock_pid
        lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
        if [[ "$lock_pid" == "$$" ]]; then
            release_nrs_lock
        fi
    fi
}

mark_nrs_lock_switch_success() {
    NRS_LOCK_SWITCH_SUCCESS=true
}

release_nrs_lock_on_failure() {
    # 4가지 조건 모두 충족 시에만 lock 삭제:
    #   1. 이 프로세스가 lock을 획득한 경우
    #   2. switch가 성공하지 않은 경우
    #   3. re-entry가 아닌 경우 (기존 lock 보호)
    #   4. 현재 lock 파일의 PID가 자기 것인 경우 (owner-blind rm 방지)
    if [[ "$NRS_LOCK_ACQUIRED" == true && "${NRS_LOCK_SWITCH_SUCCESS:-}" != true && "$NRS_LOCK_REENTRY" != true ]]; then
        local lock_pid
        lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$NRS_LOCK_FILE"
            log_warn "🔓 Lock released (build failed)"
        fi
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Rebuild serialize: main-vs-main 동시 실행 방지
# rebuild critical section(cleanup + restore + switch)을 serialize하여
# activation scripts 충돌 방지.
# 워크트리 간 상호 배제는 기존 NRS lock이 담당하므로, 여기서는 rebuild 자체만 보호.
# - flock 가용 시 (NixOS): fd 기반 파일 락, 프로세스 종료 시 자동 해제
# - lockf 가용 시 (macOS): fd 기반 파일 락 (BSD flock(2) 기반), 프로세스 종료 시 자동 해제
#
# 사용법: acquire_rebuild_lock → critical section → release_rebuild_lock
#         EXIT trap에 release_rebuild_lock_on_failure 등록 필수
#───────────────────────────────────────────────────────────────────────────────
NRS_REBUILD_LOCK="/tmp/nrs-rebuild.lock"
NRS_REBUILD_LOCK_TIMEOUT=1800  # 30분 — NRS lock 타임아웃과 동일
NRS_REBUILD_LOCK_HELD=false

acquire_rebuild_lock() {
    exec 200>"$NRS_REBUILD_LOCK"
    if command -v flock &>/dev/null; then
        # Linux (NixOS): flock fd 기반, 프로세스 종료 시 자동 해제
        if ! flock --timeout "$NRS_REBUILD_LOCK_TIMEOUT" 200; then
            log_error "❌ Timed out waiting for rebuild lock (${NRS_REBUILD_LOCK_TIMEOUT}s)"
            return 1
        fi
    elif command -v lockf &>/dev/null; then
        # macOS (Darwin): lockf fd 기반, BSD flock(2) 사용, 프로세스 종료 시 자동 해제
        # DA Fix #2: PID 기반 fallback의 TOCTOU를 lockf로 완전 제거
        # -s: silent (에러 메시지 억제, 자체 메시지 사용)
        if ! lockf -s -t "$NRS_REBUILD_LOCK_TIMEOUT" 200; then
            log_error "❌ Timed out waiting for rebuild lock (${NRS_REBUILD_LOCK_TIMEOUT}s)"
            return 1
        fi
    else
        log_warn "⚠️  Neither flock nor lockf available. Rebuild lock disabled."
    fi
    NRS_REBUILD_LOCK_HELD=true
}

release_rebuild_lock() {
    [[ "$NRS_REBUILD_LOCK_HELD" != true ]] && return 0
    # fd 닫으면 flock/lockf 자동 해제
    exec 200>&- 2>/dev/null || true
    NRS_REBUILD_LOCK_HELD=false
}

release_rebuild_lock_on_failure() {
    if [[ "$NRS_REBUILD_LOCK_HELD" == true ]]; then
        release_rebuild_lock
    fi
}
