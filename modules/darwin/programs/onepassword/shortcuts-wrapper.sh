# 1Password shortcuts launcher helpers. Home Manager inlines this file into the
# onepassword-shortcuts command; shell fixtures source it directly.
# shellcheck shell=bash

# AppData TCC prompt가 activation을 무기한 붙잡지 않도록 helper의 실제 파일 접근을 제한한다.
# 값은 선언이며, 상속된 activation 환경이 바꿀 수 없다.
ONEPASSWORD_SHORTCUTS_DEADLINE="10s"
ONEPASSWORD_SHORTCUTS_KILL_AFTER="2s"

# Usage: onepassword_shortcuts_explain_exit STATUS ELAPSED_SECONDS
# GNU timeout returns 124 only when the deadline expired, but 137 whenever the helper
# (or timeout itself) received SIGKILL — including kills by memory pressure or an
# operator. Treat 137 as the kill-after path only once the deadline has actually
# elapsed; otherwise name it as an external kill. Every other status stays silent.
onepassword_shortcuts_explain_exit() {
    local status="$1" elapsed="$2" deadline_seconds="${ONEPASSWORD_SHORTCUTS_DEADLINE%s}"
    case "$status" in
        124) ;;
        137)
            if [ "$elapsed" -lt "$deadline_seconds" ]; then
                echo "1Password shortcuts: helper was killed (SIGKILL) after ${elapsed}s, before the ${ONEPASSWORD_SHORTCUTS_DEADLINE} deadline; not a timeout, and no shortcuts applied. Check what killed it (memory pressure, another controller), then run onepassword-shortcuts again." >&2
                return 0
            fi
            ;;
        *) return 0 ;;
    esac
    echo "1Password shortcuts: timed out after ${ONEPASSWORD_SHORTCUTS_DEADLINE} (possible AppData TCC prompt for the app that launched this shell); no shortcuts applied. Answer the prompt or grant that app access, then run onepassword-shortcuts again." >&2
}

# Usage: onepassword_shortcuts_run TIMEOUT_BIN COMMAND [ARGS...]
# Runs the helper under the deadline. A timeout leaves the helper no chance to
# explain itself, so the exit status and elapsed time are explained here; every
# result passes through unchanged.
onepassword_shortcuts_run() {
    local timeout_bin="$1" status=0 started
    shift
    started=$SECONDS
    "$timeout_bin" --kill-after="$ONEPASSWORD_SHORTCUTS_KILL_AFTER" "$ONEPASSWORD_SHORTCUTS_DEADLINE" "$@" || status=$?
    onepassword_shortcuts_explain_exit "$status" "$((SECONDS - started))"
    return "$status"
}
