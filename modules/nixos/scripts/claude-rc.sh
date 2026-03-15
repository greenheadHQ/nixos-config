#!/usr/bin/env bash
# claude-rc: Claude Code Remote Control tmux wrapper
#
# 사용법:
#   claude-rc                              # 서버 시작 (tmux attach)
#   claude-rc --detach                     # 서버 시작 (백그라운드)
#   claude-rc --attach                     # 기존 세션 접속
#   claude-rc --stop                       # 서버 종료
#   claude-rc --permission-mode default    # 권한 모드 오버라이드
#   claude-rc --capacity 10               # 동시 세션 수 오버라이드
#   claude-rc --name "NixOS HQ"           # 세션 이름 변경

set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# 기본값
#───────────────────────────────────────────────────────────────────────────────
WORK_DIR="@flakePath@"
TMUX_SESSION="claude-rc"
RC_NAME="minipc"
RC_PERMISSION_MODE="bypassPermissions"
RC_SPAWN="worktree"
RC_CAPACITY=5

# 재시작 전략
MAX_QUICK_FAILURES=30
QUICK_FAIL_THRESHOLD=30  # seconds
BACKOFF_INITIAL=2
BACKOFF_MAX=60

#───────────────────────────────────────────────────────────────────────────────
# 유틸리티
#───────────────────────────────────────────────────────────────────────────────
log_info()  { echo "[claude-rc] $*"; }
log_error() { echo "[claude-rc] ERROR: $*" >&2; }

usage() {
    cat <<'EOF'
claude-rc: Claude Code Remote Control tmux wrapper

사용법:
  claude-rc                              서버 시작 (tmux attach)
  claude-rc --detach                     서버 시작 (백그라운드)
  claude-rc --attach                     기존 세션 접속
  claude-rc --stop                       서버 종료

옵션:
  --permission-mode <mode>   권한 모드 (default: bypassPermissions)
  --capacity <N>             동시 세션 수 (default: 5)
  --name <name>              세션 이름 (default: minipc)
  --help                     이 도움말 출력
EOF
}

#───────────────────────────────────────────────────────────────────────────────
# tmux 세션 내부 감지
#───────────────────────────────────────────────────────────────────────────────
inside_rc_session() {
    [[ "${CLAUDE_RC_INSIDE:-}" == "1" ]] && return 0
    # env var 없이도 감지: claude-rc 세션의 idle pane에서 직접 재실행 시
    # 다른 pane에서 실행 + wrapper 활성 중이면 false → do_start_outer가 "이미 실행 중" 처리
    if [[ -n "${TMUX:-}" ]]; then
        local current_session
        current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || return 1
        [[ "$current_session" == "$TMUX_SESSION" ]] && is_session_stale && return 0
    fi
    return 1
}

#───────────────────────────────────────────────────────────────────────────────
# stale 세션 감지: foreground가 shell이면 stale
#───────────────────────────────────────────────────────────────────────────────
is_session_stale() {
    # tmux 환경변수로 wrapper 활성 여부 판별 (pane command보다 정확)
    local rc_active
    rc_active=$(tmux show-environment -t "$TMUX_SESSION" CLAUDE_RC_ACTIVE 2>/dev/null) || return 0
    # CLAUDE_RC_ACTIVE=1 → active, 그 외 → stale
    [[ "$rc_active" != "CLAUDE_RC_ACTIVE=1" ]]
}

#───────────────────────────────────────────────────────────────────────────────
# tmux attach/switch (nested 방지)
#───────────────────────────────────────────────────────────────────────────────
attach_session() {
    if [[ -n "${TMUX:-}" ]]; then
        tmux switch-client -t "$TMUX_SESSION"
    else
        exec tmux attach-session -t "$TMUX_SESSION"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 인자 파싱
#───────────────────────────────────────────────────────────────────────────────
ACTION="start"
DETACH=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --stop)    ACTION="stop"; shift ;;
            --attach)  ACTION="attach"; shift ;;
            --detach)  DETACH=true; shift ;;
            --help|-h) usage; exit 0 ;;
            --permission-mode)
                [[ $# -ge 2 ]] || { log_error "$1 requires an argument"; exit 1; }
                case "$2" in
                    acceptEdits|bypassPermissions|default|dontAsk|plan) ;;
                    *) log_error "Invalid permission mode: $2"; exit 1 ;;
                esac
                RC_PERMISSION_MODE="$2"; shift 2 ;;
            --capacity)
                [[ $# -ge 2 ]] || { log_error "$1 requires an argument"; exit 1; }
                [[ "$2" =~ ^[0-9]+$ ]] || { log_error "capacity must be a number: $2"; exit 1; }
                RC_CAPACITY="$2"; shift 2 ;;
            --name)
                [[ $# -ge 2 ]] || { log_error "$1 requires an argument"; exit 1; }
                RC_NAME="$2"; shift 2 ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
# 서브커맨드: stop
#───────────────────────────────────────────────────────────────────────────────
do_stop() {
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TMUX_SESSION"
        log_info "서버 종료됨"
    else
        log_info "실행 중인 세션 없음"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 서브커맨드: attach
#───────────────────────────────────────────────────────────────────────────────
do_attach() {
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        attach_session
    else
        log_error "실행 중인 세션 없음 (claude-rc로 시작하세요)"
        exit 1
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 서브커맨드: start (외부에서)
#───────────────────────────────────────────────────────────────────────────────
do_start_outer() {
    # 기존 세션 확인
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        if is_session_stale; then
            log_info "stale 세션 감지 → 재생성"
            tmux kill-session -t "$TMUX_SESSION"
        else
            log_info "서버 이미 실행 중"
            if [[ "$DETACH" == true ]]; then
                return 0
            fi
            attach_session
            return 0
        fi
    fi

    # 새 tmux 세션 생성
    tmux new-session -d -s "$TMUX_SESSION"

    # shell-escaped 인자로 self 재호출
    local cmd
    cmd="CLAUDE_RC_INSIDE=1 $(printf '%q ' "$0" \
        --permission-mode "$RC_PERMISSION_MODE" \
        --capacity "$RC_CAPACITY" \
        --name "$RC_NAME")"
    tmux send-keys -t "$TMUX_SESSION" "$cmd" Enter

    log_info "서버 시작됨 (세션: ${TMUX_SESSION})"

    if [[ "$DETACH" == true ]]; then
        log_info "백그라운드 실행 중 — claude-rc --attach 로 접속"
        return 0
    fi

    attach_session
}

#───────────────────────────────────────────────────────────────────────────────
# 내부 루프 (tmux 세션 안에서)
#───────────────────────────────────────────────────────────────────────────────
do_start_inner() {
    cd "$WORK_DIR" || exit 1

    # wrapper 활성 표시 (stale 감지용, 종료 시 해제)
    tmux set-environment -t "$TMUX_SESSION" CLAUDE_RC_ACTIVE 1
    trap 'tmux set-environment -t "$TMUX_SESSION" -u CLAUDE_RC_ACTIVE 2>/dev/null' EXIT

    local failure_count=0
    local backoff=$BACKOFF_INITIAL

    log_info "Remote Control 시작: name=${RC_NAME}, mode=${RC_PERMISSION_MODE}, spawn=${RC_SPAWN}, capacity=${RC_CAPACITY}"

    while true; do
        local start_time=$SECONDS

        # claude remote-control 실행
        local rc=0
        claude remote-control \
            --name "$RC_NAME" \
            --permission-mode "$RC_PERMISSION_MODE" \
            --spawn "$RC_SPAWN" \
            --capacity "$RC_CAPACITY" \
            --no-create-session-in-dir || rc=$?

        # 정상 종료
        if [[ $rc -eq 0 ]]; then
            log_info "정상 종료"
            break
        fi

        local elapsed=$(( SECONDS - start_time ))

        if [[ $elapsed -ge $QUICK_FAIL_THRESHOLD ]]; then
            # Transient: 충분히 실행된 후 종료 → 일시적 장애
            failure_count=0
            backoff=$BACKOFF_INITIAL
            log_info "일시적 장애 (${elapsed}s 실행 후 종료, exit=${rc}) → 즉시 재시작"
        else
            # Fatal 후보: 빠른 종료
            failure_count=$((failure_count + 1))
            log_info "빠른 종료 (${elapsed}s, exit=${rc}) → 실패 ${failure_count}/${MAX_QUICK_FAILURES}"

            if [[ $failure_count -ge $MAX_QUICK_FAILURES ]]; then
                log_error "연속 ${MAX_QUICK_FAILURES}회 빠른 실패 — 루프 종료"
                log_error "수동 확인 후 claude-rc로 재시작하세요"
                break
            fi

            log_info "${backoff}s 후 재시작..."
            sleep "$backoff"

            # Exponential backoff (cap at max)
            backoff=$(( backoff * 2 ))
            if [[ $backoff -gt $BACKOFF_MAX ]]; then
                backoff=$BACKOFF_MAX
            fi
        fi
    done
}

#───────────────────────────────────────────────────────────────────────────────
# 메인
#───────────────────────────────────────────────────────────────────────────────
parse_args "$@"

case "$ACTION" in
    stop)   do_stop ;;
    attach) do_attach ;;
    start)
        if inside_rc_session; then
            do_start_inner
        else
            do_start_outer
        fi
        ;;
esac
