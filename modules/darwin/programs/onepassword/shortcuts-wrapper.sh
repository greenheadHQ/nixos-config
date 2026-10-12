# 1Password shortcuts launcher helpers. Home Manager inlines this file into the
# onepassword-shortcuts command; shell fixtures source it directly.
# shellcheck shell=bash

# AppData TCC prompt가 activation을 무기한 붙잡지 않도록 helper의 실제 파일 접근을 제한한다.
# 값은 선언이며, 상속된 activation 환경이 바꿀 수 없다.
ONEPASSWORD_SHORTCUTS_DEADLINE="10s"
ONEPASSWORD_SHORTCUTS_KILL_AFTER="2s"

# Usage: onepassword_shortcuts_explain_exit STATUS
# The Python helper only exits 0/1, so 124 identifies timeout here. Exit 137 can
# mean timeout's kill-after or an external SIGKILL; elapsed time cannot prove the
# cause. Every other status stays silent.
onepassword_shortcuts_explain_exit() {
    local status="$1"
    case "$status" in
        124) ;;
        137)
            echo "1Password shortcuts: helper was killed (SIGKILL); the cause cannot be determined from exit 137 (timeout kill-after or an external kill). Check what killed it and the current shortcuts before running onepassword-shortcuts again." >&2
            return 0
            ;;
        *) return 0 ;;
    esac
    echo "1Password shortcuts: timed out after ${ONEPASSWORD_SHORTCUTS_DEADLINE} (possible AppData TCC prompt for the app that launched this shell); no shortcuts applied. Retry from the approved Ghostty direct shell. If remote access is required, follow the exact-launcher manual approval and verification procedure in .claude/skills/managing-macos/references/tcc.md." >&2
}

# Usage: onepassword_shortcuts_run TIMEOUT_BIN COMMAND [ARGS...]
# Runs the helper under the deadline. A timeout leaves the helper no chance to
# explain itself, so the exit status is explained here; every
# result passes through unchanged.
onepassword_shortcuts_run() {
    local timeout_bin="$1" status=0
    shift
    "$timeout_bin" --kill-after="$ONEPASSWORD_SHORTCUTS_KILL_AFTER" "$ONEPASSWORD_SHORTCUTS_DEADLINE" "$@" || status=$?
    onepassword_shortcuts_explain_exit "$status"
    return "$status"
}
