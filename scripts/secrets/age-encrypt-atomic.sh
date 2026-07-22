#!/usr/bin/env bash
# Encrypt stdin to a same-directory temporary file and atomically replace OUTPUT.
set -euo pipefail

if [ "$#" -lt 2 ]; then
    printf 'usage: %s OUTPUT AGE_COMMAND [ARG...]\n' "${0##*/}" >&2
    exit 64
fi

requested_output="$1"
shift
requested_output_dir="${requested_output%/*}"
requested_output_name="${requested_output##*/}"
[ "$requested_output_dir" != "$requested_output" ] || requested_output_dir="."
case "$requested_output_name" in
    ''|.|..) printf 'invalid output path: %s\n' "$requested_output" >&2; exit 64 ;;
esac
[ -d "$requested_output_dir" ] || {
    printf 'output directory does not exist: %s\n' "$requested_output_dir" >&2
    exit 66
}

resolve_output_target() {
    local current="$1" link current_dir current_name hops=0
    while [ -L "$current" ]; do
        [ "$hops" -lt 40 ] || {
            printf 'too many output symlink hops: %s\n' "$requested_output" >&2
            return 74
        }
        link=$(readlink "$current") || return 74
        case "$link" in
            /*) current="$link" ;;
            *)
                current_dir="${current%/*}"
                [ "$current_dir" != "$current" ] || current_dir="."
                current="$current_dir/$link"
                ;;
        esac
        current_dir="${current%/*}"
        current_name="${current##*/}"
        [ "$current_dir" != "$current" ] || current_dir="."
        current_dir=$(cd -- "$current_dir" 2>/dev/null && pwd -P) || return 66
        current="$current_dir/$current_name"
        hops=$((hops + 1))
    done
    printf '%s\n' "$current"
}

file_mode() {
    stat -c '%a' "$1" 2>/dev/null || /usr/bin/stat -f '%Lp' "$1" 2>/dev/null
}

file_uid() {
    stat -c '%u' "$1" 2>/dev/null || /usr/bin/stat -f '%u' "$1" 2>/dev/null
}

file_gid() {
    stat -c '%g' "$1" 2>/dev/null || /usr/bin/stat -f '%g' "$1" 2>/dev/null
}

output=$(resolve_output_target "$requested_output") || exit $?
output_dir="${output%/*}"
output_name="${output##*/}"
[ "$output_dir" != "$output" ] || output_dir="."
case "$output_name" in
    ''|.|..) printf 'invalid output path: %s\n' "$output" >&2; exit 64 ;;
esac
[ -d "$output_dir" ] || {
    printf 'output directory does not exist: %s\n' "$output_dir" >&2
    exit 66
}

umask 077
tmp="$(mktemp "$output_dir/.${output_name}.tmp.XXXXXX")"
cleanup() {
    rc=$?
    trap - EXIT
    [ -z "${tmp:-}" ] || rm -f -- "$tmp" || true
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"$@" -o "$tmp"

if [ -e "$output" ]; then
    [ -f "$output" ] || {
        printf 'output target is not a regular file: %s\n' "$output" >&2
        exit 73
    }
    mode=$(file_mode "$output") || exit 74
    uid=$(file_uid "$output") || exit 74
    gid=$(file_gid "$output") || exit 74
    tmp_uid=$(file_uid "$tmp") || exit 74
    tmp_gid=$(file_gid "$tmp") || exit 74
    if [ "$tmp_uid:$tmp_gid" != "$uid:$gid" ]; then
        chown "$uid:$gid" "$tmp"
    fi
    # chown may clear setuid/setgid bits, so restore the saved mode last.
    chmod "$mode" "$tmp"
fi

mv -f -- "$tmp" "$output"
tmp=""
trap - HUP INT TERM
