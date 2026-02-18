#!/usr/bin/env bash
# writeShellApplication provides set -euo pipefail

: "${HOOK_SRC:?HOOK_SRC is required}"
: "${HOOK_DST:?HOOK_DST is required}"
: "${QUEUE_FILE:?QUEUE_FILE is required}"

hook_dir=$(dirname "$HOOK_DST")
queue_dir=$(dirname "$QUEUE_FILE")

mkdir -p "$hook_dir" "$queue_dir"
cp "$HOOK_SRC" "$HOOK_DST"
chmod 0755 "$HOOK_DST"

touch "$QUEUE_FILE"
chmod 0644 "$QUEUE_FILE"

echo "ArchiveBox notify hook installed: $HOOK_DST"
