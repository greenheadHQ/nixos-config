#!/usr/bin/env bash
# Existing Claude background spares can keep sourcing a pre-deployment shell
# snapshot. Append a zsh PATH repair without restarting those live processes.
set -u

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <snapshot-dir> <dispatcher-bin>\n' "$0" >&2
  exit 2
fi

snapshot_dir="$1"
dispatcher_bin="$2"
marker="# nixos-config headless SSH PATH recovery v1"

case "$dispatcher_bin" in
  /*) ;;
  *)
    printf 'refresh-claude-snapshot-paths: dispatcher path must be absolute\n' >&2
    exit 2
    ;;
esac

[ -d "$snapshot_dir" ] || exit 0

for snapshot in "$snapshot_dir"/snapshot-zsh-*.sh; do
  [ -f "$snapshot" ] || continue
  [ ! -L "$snapshot" ] || continue

  has_marker=0
  path_is_current=0
  while IFS= read -r line; do
    [ "$line" = "$marker" ] && has_marker=1
    case "$line" in
      "export PATH="*"$dispatcher_bin"*) path_is_current=1 ;;
    esac
  done < "$snapshot"

  [ "$has_marker" -eq 0 ] || continue
  [ "$path_is_current" -eq 0 ] || continue

  # One append preserves the vendor snapshot and lets in-flight readers either
  # finish on the old EOF or observe the complete recovery block next time.
  if ! printf '%s\n' \
    "$marker" \
    "export PATH=\"$dispatcher_bin:\$PATH\"" \
    >> "$snapshot"
  then
    printf 'refresh-claude-snapshot-paths: warning: could not update %s\n' "$snapshot" >&2
  fi
done
