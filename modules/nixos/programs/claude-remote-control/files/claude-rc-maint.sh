#!/usr/bin/env bash
# claude-rc-maint: Claude Code Remote Control bridge의 version-drift 감시 엔진.
#
# 사용자 래퍼(claude-rc)와 책임을 분리한 maintenance 전용 스크립트로,
# systemd timer(claude-rc-ensure)가 주기 실행한다. codex-remote-control-maint.sh 골격 차용.
#
# 동작: 실행 중 bridge 바이너리(/proc/PID/exe)와 claude launcher가 가리키는
# 최신 버전을 비교해 drift가 있으면 — 활성 원격 세션이 없을 때만 — bridge를 재시작한다.
# bridge 재시작은 활성 세션을 tombstone시키므로 idle 게이트가 핵심 안전장치다.
set -euo pipefail

#───────────────────────────────────────────────────────────────────────────────
# env 파라미터 (systemd unit이 주입, 수동 실행 시 기본값)
#───────────────────────────────────────────────────────────────────────────────
CLAUDE_RC_BIN="${CLAUDE_RC_BIN:-$HOME/.local/bin/claude-rc}"
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
STATE_DIR="${STATE_DIR:-$HOME/.local/state/claude-rc}"
TMUX_SESSION="${TMUX_SESSION:-claude-rc}"
IDLE_THRESHOLD_MINUTES="${IDLE_THRESHOLD_MINUTES:-30}"
MAINT_LOCK_TIMEOUT_SECONDS="${MAINT_LOCK_TIMEOUT_SECONDS:-120}"
ALERT_COOLDOWN_SECONDS="${ALERT_COOLDOWN_SECONDS:-1800}"
PUSHOVER_CRED_FILE="${PUSHOVER_CRED_FILE:-}"
SERVICE_LIB="${SERVICE_LIB:-}"
# bridge 시작 옵션 — NixOS 모듈(homeserver.claudeRemoteControl.*)이 주입한다.
# maint가 명시 전달하지 않으면 자동 재시작 시 래퍼 기본값으로 조용히 되돌아가므로
# (예: capacity 10 → 5) 반드시 전량 전달한다.
CLAUDE_RC_PERMISSION_MODE="${CLAUDE_RC_PERMISSION_MODE:-bypassPermissions}"
CLAUDE_RC_CAPACITY="${CLAUDE_RC_CAPACITY:-5}"
CLAUDE_RC_NAME="${CLAUDE_RC_NAME:-minipc}"

#───────────────────────────────────────────────────────────────────────────────
# upstream 의존 selector — Claude Code CLI/spawn process shape 또는 transcript
# 프로젝트 디렉토리 명명 규칙이 바뀌면 아래 3개를 함께 갱신한다.
#───────────────────────────────────────────────────────────────────────────────
BRIDGE_PROCESS_PATTERN='claude remote-control'
# 스폰 세션의 argv[0]은 versions 디렉토리 절대경로라 "claude "가 나타나지 않는다
# (실측: /home/.../claude/versions/2.1.169 --print --sdk-url ...). --sdk-url 자체로
# 식별하되, ERE [-]로 시작해 pgrep이 패턴을 옵션으로 오해하지 않게 한다.
BRIDGE_CHILD_PROCESS_PATTERN='[-]-sdk-url'
# transcript 프로젝트 디렉토리 glob. 경로의 비영숫자([._/])는 하이픈으로
# 정규화되어 저장되므로 underscore 변형은 나타나지 않는다 (실측 확인).
BRIDGE_TRANSCRIPT_GLOBS=('*bridge-cse-*' '*bridge-session-*')

VERSIONS_DIR="$HOME/.local/share/claude/versions"
PROJECTS_DIR="$HOME/.claude/projects"

ACTION="none"
RUNNING_VERSION=""
DESIRED_VERSION=""
RECENT_TRANSCRIPT_COUNT=0

log_info()  { echo "[claude-rc-maint] $*"; }
log_error() { echo "[claude-rc-maint] ERROR: $*" >&2; }

#───────────────────────────────────────────────────────────────────────────────
# flock 직렬화 (수동 실행과 timer의 동시 실행 방지)
#───────────────────────────────────────────────────────────────────────────────
with_lock() {
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/ensure.lock"
    if ! flock --timeout "$MAINT_LOCK_TIMEOUT_SECONDS" 9; then
        ACTION="lock-acquire-timeout"
        return 1
    fi
    # fd 9는 이 셸이 락을 유지하는 동안만 살아야 한다. 9>&- 없이 실행하면
    # detach되는 tmux server/bridge가 fd 9를 상속해 락을 영구 점유하고
    # 이후 모든 타이머 실행이 lock-acquire-timeout으로 실패한다
    # (codex-remote-control-maint.sh의 PR #983과 동일 근거).
    "$@" 9>&-
}

#───────────────────────────────────────────────────────────────────────────────
# bridge 세션/프로세스 판정
#───────────────────────────────────────────────────────────────────────────────
bridge_session_alive() {
    tmux has-session -t "$TMUX_SESSION" 2>/dev/null || return 1
    # 조회 실패(변수 없음 포함) = stale — 래퍼 is_session_stale과 동일 판정.
    # systemd oneshot은 tmux 클라이언트 밖에서 실행되므로 -t 타깃 명시가 필수다.
    local rc_active
    rc_active=$(tmux show-environment -t "$TMUX_SESSION" CLAUDE_RC_ACTIVE 2>/dev/null) || return 1
    [ "$rc_active" = "CLAUDE_RC_ACTIVE=1" ]
}

# 첫 번째 유효 bridge PID를 출력. 유효 = exe가 claude versions 디렉토리 아래.
find_bridge_pid() {
    local pid exe
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        case "${exe% (deleted)}" in
            "$VERSIONS_DIR"/*) echo "$pid"; return 0 ;;
        esac
    done < <(pgrep -u "$(id -u)" -f "$BRIDGE_PROCESS_PATTERN" 2>/dev/null || true)
    return 1
}

# /proc/PID/exe 기준 실행 중 버전. 바이너리가 삭제된 구버전이면 "deleted"를 붙여
# 호출측이 drift로 취급하게 한다.
pid_exe_version() {
    local pid="$1" exe
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    case "$exe" in
        *" (deleted)") echo "$(basename "${exe% (deleted)}") (deleted)" ;;
        *) basename "$exe" ;;
    esac
}

desired_claude_version() {
    basename "$(readlink -f "$CLAUDE_BIN")"
}

#───────────────────────────────────────────────────────────────────────────────
# 활성 세션 판정 (restart 게이트)
#───────────────────────────────────────────────────────────────────────────────
# 허용 glob에 매치되는 transcript 프로젝트 디렉토리 수 (명명 규칙 유효성 신호)
count_matching_transcript_dirs() {
    local total=0 glob
    [ -d "$PROJECTS_DIR" ] || { echo 0; return; }
    for glob in "${BRIDGE_TRANSCRIPT_GLOBS[@]}"; do
        total=$((total + $(find "$PROJECTS_DIR" -maxdepth 1 -type d -name "$glob" 2>/dev/null | wc -l)))
    done
    echo "$total"
}

# 최근 활동한 bridge transcript 파일 수. transcript file은 세션의 proxy이며
# 측정 단위(파일)를 이름에 그대로 노출한다.
count_recent_bridge_transcripts() {
    local total=0 glob dir
    [ -d "$PROJECTS_DIR" ] || { echo 0; return; }
    for glob in "${BRIDGE_TRANSCRIPT_GLOBS[@]}"; do
        while IFS= read -r dir; do
            [ -n "$dir" ] || continue
            total=$((total + $(find "$dir" -maxdepth 1 -name '*.jsonl' -mmin "-$IDLE_THRESHOLD_MINUTES" 2>/dev/null | wc -l)))
        done < <(find "$PROJECTS_DIR" -maxdepth 1 -type d -name "$glob" 2>/dev/null)
    done
    echo "$total"
}

# bridge가 스폰한 세션 프로세스 수 (transcript 명명에 비의존인 2차 신호).
# pgrep -c는 매치 0일 때도 "0"을 출력하며 rc=1이므로, || echo를 쓰면 "0"이
# 이중 출력된다 — 캡처 후 실패 시 대입으로 처리한다.
count_bridge_session_procs() {
    local count
    count=$(pgrep -u "$(id -u)" -c -f "$BRIDGE_CHILD_PROCESS_PATTERN" 2>/dev/null) || count=0
    echo "$count"
}

# 재시작이 안전한지 판정. 반환: 0=안전, 1=defer(활동 중), 2=defer(판정 불가)
restart_gate() {
    RECENT_TRANSCRIPT_COUNT=$(count_recent_bridge_transcripts)
    local session_procs
    session_procs=$(count_bridge_session_procs)

    if [ "$RECENT_TRANSCRIPT_COUNT" -gt 0 ]; then
        return 1 # 최근 활동 세션 존재 — 재시작하면 tombstone
    fi
    if [ "$session_procs" -eq 0 ]; then
        return 0 # 세션 프로세스 자체가 없음 — 재시작 안전
    fi
    # 세션 프로세스는 있는데 최근 transcript가 없는 경우:
    # 허용 glob 매치 디렉토리가 존재하면 명명 규칙이 현재도 유효하다는 증거이므로
    # idle 세션으로 판단해 재시작하고, 매치가 0이면 upstream 명명 규칙 drift
    # 가능성이 있어 보수적으로 유예한다 (tombstone 재시작 직행 방지).
    if [ "$(count_matching_transcript_dirs)" -gt 0 ]; then
        return 0
    fi
    return 2
}

#───────────────────────────────────────────────────────────────────────────────
# bridge 시작/재시작
#───────────────────────────────────────────────────────────────────────────────
# systemd LoadCredential의 CREDENTIALS_DIRECTORY와 Pushover env가 장기 실행
# tmux server → bridge → 스폰 세션 트리로 상속되지 않도록 항상 env를 정리해 시작한다.
start_bridge() {
    env -u CREDENTIALS_DIRECTORY -u PUSHOVER_CRED_FILE -u PUSHOVER_TOKEN -u PUSHOVER_USER -u SERVICE_LIB \
        "$CLAUDE_RC_BIN" --detach \
        --permission-mode "$CLAUDE_RC_PERMISSION_MODE" \
        --capacity "$CLAUDE_RC_CAPACITY" \
        --name "$CLAUDE_RC_NAME"
    # tmux server가 이 maint 유닛 환경에서 새로 떴을 경우 global env에 복사된
    # credential 경로를 제거한다 (이미 없으면 no-op).
    tmux set-environment -gu CREDENTIALS_DIRECTORY 2>/dev/null || true
    tmux set-environment -gu PUSHOVER_CRED_FILE 2>/dev/null || true
}

restart_bridge() {
    tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
    start_bridge
}

#───────────────────────────────────────────────────────────────────────────────
# 상태 기록 + 알림
#───────────────────────────────────────────────────────────────────────────────
write_status() {
    local exit_code="${1:-0}"
    mkdir -p "$STATE_DIR"
    local tmp
    tmp=$(mktemp "$STATE_DIR/status.XXXXXX") || return 1
    jq -n \
        --arg timestamp "$(date -Is)" \
        --arg runningVersion "$RUNNING_VERSION" \
        --arg desiredVersion "$DESIRED_VERSION" \
        --arg action "$ACTION" \
        --argjson recentTranscriptCount "$RECENT_TRANSCRIPT_COUNT" \
        --argjson exitCode "$exit_code" \
        '{
          timestamp: $timestamp,
          runningVersion: $runningVersion,
          desiredVersion: $desiredVersion,
          action: $action,
          recentTranscriptCount: $recentTranscriptCount,
          exitCode: $exitCode
        }' >"$tmp" || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$STATE_DIR/status.json"
}

load_alerting() {
    # shellcheck source=/dev/null
    [ -n "$SERVICE_LIB" ] && [ -f "$SERVICE_LIB" ] && source "$SERVICE_LIB"
    local cred="$PUSHOVER_CRED_FILE"
    if [ -z "$cred" ] && [ -n "${CREDENTIALS_DIRECTORY:-}" ]; then
        cred="$CREDENTIALS_DIRECTORY/pushover-system-monitor"
    fi
    if [ -n "$cred" ] && [ -r "$cred" ]; then
        # shellcheck source=/dev/null
        source "$cred"
    fi
}

send_alerts() {
    local exit_code="$1"
    # graceful fallback: 크리덴셜/서비스 lib이 없는 호스트(예: work-MacBookPro는
    # pushover-system-monitor.age가 minipcOnly 암호화라 복호화 불가)에서 수동
    # 실행해도 알림만 스킵하고 ensure 본체는 정상 동작한다.
    if ! command -v send_notification >/dev/null 2>&1 \
        || [ -z "${PUSHOVER_TOKEN:-}" ] || [ -z "${PUSHOVER_USER:-}" ]; then
        log_info "알림 스킵 (Pushover 크리덴셜/서비스 lib 없음)"
        return 0
    fi

    local now state_file last_failure_file previous
    now=$(date +%s)
    state_file="$STATE_DIR/last-health-state"
    last_failure_file="$STATE_DIR/last-failure-alert"
    previous="unknown"
    [ -f "$state_file" ] && previous=$(cat "$state_file" 2>/dev/null || echo unknown)

    if [ "$exit_code" -eq 0 ]; then
        if [ "$previous" = "failed" ]; then
            send_notification "Claude RC Recovered" \
                "greenhead-minipc claude-rc bridge is healthy (${RUNNING_VERSION:-unknown})." 0
        fi
        echo "healthy" >"$state_file"
        return 0
    fi

    local last=0
    [ -f "$last_failure_file" ] && last=$(cat "$last_failure_file" 2>/dev/null || echo 0)
    if [ $((now - last)) -ge "$ALERT_COOLDOWN_SECONDS" ]; then
        send_notification "Claude RC Ensure Failed" \
            "exit=${exit_code}, action=${ACTION}, running=${RUNNING_VERSION:-unknown}, desired=${DESIRED_VERSION:-unknown}" 0
        echo "$now" >"$last_failure_file"
    fi
    echo "failed" >"$state_file"
}

#───────────────────────────────────────────────────────────────────────────────
# ensure 본체 (조기 exit 없음 — action만 설정하고 cmd_ensure의 finalizer가 마무리)
#───────────────────────────────────────────────────────────────────────────────
ensure_core() {
    DESIRED_VERSION=$(desired_claude_version) || {
        ACTION="desired-version-unresolvable"
        return 1
    }

    if ! bridge_session_alive; then
        # tmux 세션 부재/stale — 부팅 후 자동 시작 겸 자가 복구
        start_bridge
        ACTION="started"
        log_info "bridge 시작됨 (session absent/stale)"
        return 0
    fi

    local pid
    if ! pid=$(find_bridge_pid); then
        # 세션은 살아있는데 bridge 프로세스가 없음 — 래퍼 루프가 backoff 재시작
        # 중일 수 있으므로 maint는 개입하지 않는다 (다음 주기 재확인).
        ACTION="no-bridge-process"
        log_info "bridge 프로세스 없음 — 래퍼 루프에 위임 (다음 주기 재확인)"
        return 0
    fi

    RUNNING_VERSION=$(pid_exe_version "$pid") || {
        ACTION="running-version-unresolvable"
        return 1
    }

    if [ "$RUNNING_VERSION" = "$DESIRED_VERSION" ]; then
        ACTION="healthy"
        return 0
    fi

    # version drift — 활성 세션 게이트 통과 시에만 재시작
    local gate_rc=0
    restart_gate || gate_rc=$?
    case "$gate_rc" in
        0)
            restart_bridge
            ACTION="restarted-version-drift"
            log_info "재시작: ${RUNNING_VERSION} → ${DESIRED_VERSION}"
            ;;
        1)
            ACTION="deferred-active-sessions"
            log_info "drift 감지했으나 활성 세션 ${RECENT_TRANSCRIPT_COUNT}건 — 유예"
            ;;
        2)
            ACTION="deferred-unknown-activity"
            log_info "drift 감지했으나 활동 판정 불가 (transcript 명명 drift 의심) — 유예"
            ;;
    esac
    return 0
}

#───────────────────────────────────────────────────────────────────────────────
# 서브커맨드
#───────────────────────────────────────────────────────────────────────────────
cmd_ensure() {
    local rc=0
    with_lock ensure_core || rc=$?
    # 단일 finalizer: 어떤 분기도 이 경로를 우회하지 않는다
    # (recovered/failure 알림 상태 전이가 모든 실행에서 평가되도록).
    write_status "$rc" || true
    load_alerting
    send_alerts "$rc" || true
    return "$rc"
}

usage() {
    cat >&2 <<'EOF'
Usage: claude-rc-maint ensure

env:
  CLAUDE_RC_BIN, CLAUDE_BIN, STATE_DIR, TMUX_SESSION,
  IDLE_THRESHOLD_MINUTES (default 30), MAINT_LOCK_TIMEOUT_SECONDS (default 120),
  ALERT_COOLDOWN_SECONDS (default 1800), PUSHOVER_CRED_FILE, SERVICE_LIB,
  CLAUDE_RC_PERMISSION_MODE, CLAUDE_RC_CAPACITY, CLAUDE_RC_NAME

상태 확인: cat $STATE_DIR/status.json (기본 ~/.local/state/claude-rc/status.json)
EOF
}

main() {
    case "${1:-}" in
        ensure) cmd_ensure ;;
        -h | --help | help) usage ;;
        *)
            usage
            return 2
            ;;
    esac
}

main "$@"
