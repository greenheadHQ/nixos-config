# Shottr defaults access helpers. This file is sourced into Home Manager
# activation entries and is also exercised directly by shell fixtures.
# shellcheck shell=bash

# Direct shell fixtures source this helper from the repository. Home Manager
# activation entries inline the same shared file immediately before this body.
shottr_defaults_helper_source="${BASH_SOURCE[0]:-}"
if [ -n "$shottr_defaults_helper_source" ]; then
    shottr_defaults_helper_dir=$(cd -- "$(dirname -- "$shottr_defaults_helper_source")" && pwd -P)
    shottr_defaults_deadlines_file="$shottr_defaults_helper_dir/../../../../scripts/secrets/shottr-deadlines.sh"
    if [ -r "$shottr_defaults_deadlines_file" ]; then
        # shellcheck disable=SC1090 # Repository-relative path is computed above.
        . "$shottr_defaults_deadlines_file"
    fi
fi
unset shottr_defaults_helper_source shottr_defaults_helper_dir shottr_defaults_deadlines_file
: "${SHOTTR_DEFAULTS_KILL_AFTER:?Shottr defaults kill-after bound is unavailable}"
: "${SHOTTR_DEFAULTS_DEADLINE:?Shottr defaults deadline is unavailable}"

shottr_defaults_is_timeout() {
    [ "$1" -eq 124 ] || [ "$1" -eq 137 ]
}

shottr_defaults_record_failure() {
    local operation="$1" key="$2" status="$3"
    if shottr_defaults_is_timeout "$status"; then
        SHOTTR_DEFAULTS_WRITES_BLOCKED=1
        echo "Warning: defaults $operation $key timed out (possible AppData TCC prompt)."
        if [ "$operation" = "read" ]; then
            echo "Skipping Shottr defaults writes for this activation."
        else
            echo "Skipping remaining Shottr defaults writes for this activation."
        fi
    elif [ "$operation" = "write" ]; then
        echo "Warning: defaults write $key failed (sandbox restriction?). Skipping."
    fi
}

shottr_defaults_write() {
    local timeout_bin="$1" defaults_bin="$2" domain="$3" key="$4"
    local status
    shift 4

    if [ "${SHOTTR_DEFAULTS_WRITES_BLOCKED:-0}" = "1" ]; then
        return 0
    fi

    if "$timeout_bin" -k "$SHOTTR_DEFAULTS_KILL_AFTER" "$SHOTTR_DEFAULTS_DEADLINE" \
        "$defaults_bin" write "$domain" "$key" "$@" 2>/dev/null; then
        return 0
    else
        status=$?
    fi

    shottr_defaults_record_failure write "$key" "$status"
}

shottr_defaults_write_stdin() {
    local timeout_bin="$1" writer_bin="$2" preferences_target="$3" key="$4"
    local status

    if [ "${SHOTTR_DEFAULTS_WRITES_BLOCKED:-0}" = "1" ]; then
        return 0
    fi

    if (
        # Do not let hostile/inherited activation exports duplicate the secret
        # into the timeout/writer environment. The value reaches the writer
        # only through this subshell's inherited stdin.
        unset kc_license kc_vault KC_LICENSE KC_VAULT
        "$timeout_bin" -k "$SHOTTR_DEFAULTS_KILL_AFTER" "$SHOTTR_DEFAULTS_DEADLINE" \
            "$writer_bin" "$preferences_target" "$key" 2>/dev/null
    ); then
        return 0
    else
        status=$?
    fi

    shottr_defaults_record_failure write "$key" "$status"
}

shottr_defaults_read() {
    local result_var="$1" timeout_bin="$2" defaults_bin="$3" domain="$4" key="$5"
    local value status

    if value=$("$timeout_bin" -k "$SHOTTR_DEFAULTS_KILL_AFTER" "$SHOTTR_DEFAULTS_DEADLINE" \
        "$defaults_bin" read "$domain" "$key" 2>/dev/null); then
        printf -v "$result_var" '%s' "$value"
        return 0
    else
        status=$?
    fi

    printf -v "$result_var" '%s' ""
    shottr_defaults_record_failure read "$key" "$status"
}
