# 1Password shortcuts launcher helpers. Home Manager inlines this file into the
# onepassword-shortcuts command; shell fixtures source it directly.
# shellcheck shell=bash

# AppData TCC prompt가 activation을 무기한 붙잡지 않도록 helper의 실제 파일 접근을 제한한다.
# 값은 선언이며, 상속된 activation 환경이 바꿀 수 없다.
ONEPASSWORD_SHORTCUTS_DEADLINE="10s"
ONEPASSWORD_SHORTCUTS_KILL_AFTER="2s"

onepassword_shortcuts_is_timeout() {
    [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

# Usage: onepassword_shortcuts_run TIMEOUT_BIN COMMAND [ARGS...]
# Runs the helper under the deadline. A timeout leaves the helper no chance to
# explain itself, so name the likely cause here; every other result passes through.
onepassword_shortcuts_run() {
    local timeout_bin="$1" status=0
    shift
    "$timeout_bin" --kill-after="$ONEPASSWORD_SHORTCUTS_KILL_AFTER" "$ONEPASSWORD_SHORTCUTS_DEADLINE" "$@" || status=$?
    if onepassword_shortcuts_is_timeout "$status"; then
        echo "1Password shortcuts: timed out after $ONEPASSWORD_SHORTCUTS_DEADLINE (possible AppData TCC prompt for the terminal app); no shortcuts applied. Answer the prompt or grant the terminal app access, then run onepassword-shortcuts again." >&2
    fi
    return "$status"
}
