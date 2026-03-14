#!/usr/bin/env bash
# nrs lock 상태 조회 및 해제 CLI
# standalone 스크립트 — rebuild-common.sh를 source하지 않음

set -euo pipefail

NRS_LOCK_FILE="/tmp/nrs-state"
NRS_LOCK_TIMEOUT_HOURS=2
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

cmd_status() {
    if [[ ! -f "$NRS_LOCK_FILE" ]]; then
        echo -e "${GREEN}No active lock${NC}"
        return 0
    fi

    local now lock_ts lock_worktree lock_branch lock_pid
    now=$(date +%s)
    lock_ts=$(jq -r '.timestamp' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "?")
    lock_branch=$(jq -r '.branch' "$NRS_LOCK_FILE" 2>/dev/null || echo "?")
    lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "?")

    local elapsed=$(( now - lock_ts ))
    local elapsed_min=$(( elapsed / 60 ))
    local expiry=$(( lock_ts + NRS_LOCK_TIMEOUT_HOURS * 3600 ))
    local remaining=$(( expiry - now ))

    echo "Lock active:"
    echo "  Branch:   $lock_branch"
    echo "  Worktree: $lock_worktree"
    echo "  PID:      $lock_pid"

    if (( elapsed < 3600 )); then
        echo "  Elapsed:  ${elapsed_min}m"
    else
        echo "  Elapsed:  $(( elapsed / 3600 ))h $(( elapsed_min % 60 ))m"
    fi

    if (( remaining > 0 )); then
        local remain_min=$(( remaining / 60 ))
        if (( remaining < 3600 )); then
            echo "  Expires:  in ${remain_min}m"
        else
            echo "  Expires:  in $(( remaining / 3600 ))h $(( remain_min % 60 ))m"
        fi
    else
        echo -e "  ${YELLOW}Expired:   $(( -remaining / 60 ))m ago (will be cleaned on next nrs run)${NC}"
    fi
}

cmd_unlock() {
    if [[ ! -f "$NRS_LOCK_FILE" ]]; then
        echo -e "${YELLOW}No lock to release${NC}"
        return 0
    fi
    rm -f "$NRS_LOCK_FILE"
    echo -e "${GREEN}🔓 Lock released${NC}"
}

case "${1:-}" in
    status)  cmd_status ;;
    unlock)  cmd_unlock ;;
    *)
        echo "Usage: nrs-lock.sh {status|unlock}" >&2
        exit 1
        ;;
esac
