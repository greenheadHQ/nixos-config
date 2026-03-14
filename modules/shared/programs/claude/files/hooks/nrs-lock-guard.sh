#!/usr/bin/env bash
# Claude Code PreToolUse hook: nrs worktree lock guard
# Bash 도구가 nrs/rebuild 명령을 실행할 때 lock 충돌을 차단

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Early return: Bash 도구가 아니면 즉시 통과
[[ "$TOOL_NAME" != "Bash" ]] && exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
[[ -z "$COMMAND" ]] && exit 0

NRS_LOCK_FILE="/tmp/nrs-state"

# 규칙 3: nrs-unlock / nrs-lock.sh unlock 시도 차단
if echo "$COMMAND" | grep -qE '(nrs-unlock|nrs-lock\.sh[[:space:]]+unlock)'; then
    jq -n '{decision: "block", reason: "nrs-unlock은 사용자가 직접 터미널에서 실행해야 합니다."}'
    exit 0
fi

# 규칙 2: lock 파일 직접 삭제 차단
if echo "$COMMAND" | grep -qE 'rm[[:space:]].*nrs-state'; then
    jq -n '{decision: "block", reason: "nrs lock 파일을 직접 삭제할 수 없습니다. 사용자가 nrs-unlock을 실행하세요."}'
    exit 0
fi

# 규칙 0: nrs-status / nrs-lock.sh status는 항상 통과 (읽기 전용)
# nrs\b가 nrs-status 내에서도 매칭되어 lock 시 status 조회가 차단되는 버그 수정
if echo "$COMMAND" | grep -qE '(nrs-status|nrs-lock\.sh[[:space:]]+status)'; then
    exit 0
fi

# 규칙 1: nrs/darwin-rebuild/nixos-rebuild 실행 시 lock 충돌 확인
# 절대경로(/run/.../darwin-rebuild 등)도 매칭
if echo "$COMMAND" | grep -qE '(^|[[:space:]]|&&|\||;)(sudo[[:space:]]+)?([^[:space:]]*/)?(nrs(\.sh)?|darwin-rebuild|nixos-rebuild)\b'; then
    # lock 없으면 통과
    [[ ! -f "$NRS_LOCK_FILE" ]] && exit 0

    # 현재 worktree 판별
    # === CIR (PR #213) ===
    # hook CWD 기반 판별 한계: `cd /other-wt && nrs`는 cd 전 CWD로 판별되어 오판 가능.
    # 대안 검토: 명령어 문자열에서 cd 대상 경로 파싱 → 기각.
    #   이유: 셸 문법 파싱이 fragile (변수 치환, 중첩 subshell 등 고려 불가),
    #         Claude Code 세션은 단일 worktree에서 동작하여 발생 가능성 극히 낮음.
    # trade-off: `cd other-wt && nrs` 패턴에서 false block 가능성 수용.
    CURRENT_WORKTREE=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    LOCK_WORKTREE=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")

    # 같은 worktree: nrs.sh 경유 시 내부 PID 체크로 보호되지만,
    # raw darwin-rebuild/nixos-rebuild는 acquire_nrs_lock을 거치지 않음.
    # 같은 worktree에서도 lock PID가 살아있으면 차단
    if [[ -n "$CURRENT_WORKTREE" && "$CURRENT_WORKTREE" == "$LOCK_WORKTREE" ]]; then
        LOCK_PID=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
        if [[ "$LOCK_PID" != "0" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
            jq -n --arg pid "$LOCK_PID" \
                '{decision: "block", reason: ("nrs 프로세스(PID " + $pid + ")가 실행 중입니다. 완료를 기다리거나 nrs-unlock을 실행하세요.")}'
            exit 0
        fi
        exit 0
    fi

    LOCK_BRANCH=$(jq -r '.branch' "$NRS_LOCK_FILE" 2>/dev/null || echo "?")
    jq -n --arg wt "$LOCK_WORKTREE" --arg br "$LOCK_BRANCH" \
        '{decision: "block", reason: ("다른 worktree(" + $wt + ", branch: " + $br + ")가 nrs lock을 보유 중입니다. 사용자가 nrs-unlock을 실행하세요.")}'
    exit 0
fi

# 매칭 없음 — 통과
exit 0
