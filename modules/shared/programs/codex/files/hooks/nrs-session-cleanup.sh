#!/usr/bin/env bash
# Codex 사본 — ~/.claude/hooks/nrs-session-cleanup.sh에서 파생.
# 본문 로직은 Claude 원본과 동일하나, 호출 계약은 다음 차이가 있다 (issue #585):
#   - Codex Stop dispatcher 경유로만 호출된다. Codex 0.124+에 SessionEnd 등가는 없지만 Stop이
#     main turn 종료를 cover하므로 lock cleanup 누락은 없다. dispatcher 안에서의 구체 호출
#     순서와 rationale은 _stop-dispatcher.sh의 헤더가 SoT다.
#   - Programmatic codex subprocess의 lock cleanup도 의도된 동작이므로 CLAUDECODE/CODEX_PROGRAMMATIC
#     early-exit 가드를 적용하지 않는다.
# Claude 원본 배경 (Codex runtime 계약은 위 헤더가 SoT):
#   - Claude에서는 Stop과 SessionEnd 양쪽에서 호출되어 LLM turn 종료 또는 CC 세션 종료 시
#     해당 worktree의 lock을 자동 해제했다.
#   - PoC 검증 결과 (2026-03-15): Stop은 main agent turn 종료에만, SessionEnd는 main 세션
#     종료에만 트리거되어 두 이벤트 모두 안전하게 lock 해제 가능.
#   - Codex 0.124+에는 SessionEnd 등가가 없으므로 Codex 사본에서는 Stop dispatcher 경유만 사용.

NRS_LOCK_FILE="/tmp/nrs-state"
[[ ! -f "$NRS_LOCK_FILE" ]] && exit 0

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[[ -z "$CWD" ]] && exit 0

# CWD에서 git toplevel 추출 → lock worktree와 비교
GIT_TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
LOCK_WORKTREE=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null) || exit 0

if [[ "$GIT_TOPLEVEL" == "$LOCK_WORKTREE" ]]; then
    # DA Fix: PID가 살아있으면 lock 보존 (다른 터미널에서 nrs 실행 중일 수 있음)
    LOCK_PID=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    if [[ "$LOCK_PID" != "0" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        exit 0
    fi
    # DA Fix R2: TOCTOU 방지 — rm 직전 PID 재확인 (다른 프로세스가 lock을 재취득했을 수 있음)
    RECHECK_PID=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    if [[ "$RECHECK_PID" != "$LOCK_PID" ]]; then
        exit 0  # lock이 다른 프로세스에 의해 재취득됨
    fi
    rm -f "$NRS_LOCK_FILE"
fi

exit 0
