#!/usr/bin/env bash
# Read Shottr license values with a deadline and atomically encrypt stdin.
set +x
set -euo pipefail
set +a
unset kc_license kc_vault KC_LICENSE KC_VAULT
umask 077

if [ "$#" -lt 2 ]; then
    printf 'usage: %s OUTPUT AGE_COMMAND [ARG...]\n' "${0##*/}" >&2
    exit 64
fi

output="$1"
shift
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck disable=SC1091 # Fixed sibling file in the deployed script bundle.
. "$script_dir/shottr-deadlines.sh"
# Internal hermetic-test seams, not operator-facing configuration knobs.
atomic_helper="${SHOTTR_AGE_ENCRYPT_ATOMIC:-$script_dir/age-encrypt-atomic.sh}"
defaults_bin="${SHOTTR_DEFAULTS_BIN:-/usr/bin/defaults}"
timeout_bin="${SHOTTR_TIMEOUT_BIN:-}"

if [ -z "$timeout_bin" ]; then
    timeout_bin=$(command -v timeout) || {
        printf 'GNU timeout is required; enter the repo devShell first.\n' >&2
        exit 69
    }
fi
[ -x "$timeout_bin" ] || {
    printf 'timeout executable is unavailable: %s\n' "$timeout_bin" >&2
    exit 69
}
[ -x "$defaults_bin" ] || {
    printf 'defaults executable is unavailable: %s\n' "$defaults_bin" >&2
    exit 69
}
[ -x "$atomic_helper" ] || {
    printf 'atomic encryption helper is unavailable: %s\n' "$atomic_helper" >&2
    exit 69
}

kc_license="$("$timeout_bin" -k "$SHOTTR_DEFAULTS_KILL_AFTER" "$SHOTTR_DEFAULTS_DEADLINE" \
    "$defaults_bin" read cc.ffitch.shottr kc-license)" || {
    printf 'kc-license read failed or timed out; secret file was not changed.\n' >&2
    exit 1
}
export -n kc_license
kc_vault="$("$timeout_bin" -k "$SHOTTR_DEFAULTS_KILL_AFTER" "$SHOTTR_DEFAULTS_DEADLINE" \
    "$defaults_bin" read cc.ffitch.shottr kc-vault)" || {
    printf 'kc-vault read failed or timed out; secret file was not changed.\n' >&2
    exit 1
}
export -n kc_vault

printf 'KC_LICENSE=%s\nKC_VAULT=%s\n' "$kc_license" "$kc_vault" \
    | "$atomic_helper" "$output" "$@"
