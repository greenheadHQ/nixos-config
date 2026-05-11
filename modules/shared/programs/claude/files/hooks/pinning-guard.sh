#!/usr/bin/env bash
# pinning-guard.sh — Claude Code PreToolUse hard-fail guard.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINNING_LIB="${PINNING_PATTERNS_LIB:-$HOME/.claude/lib/pinning-patterns.sh}"
if [ ! -f "$PINNING_LIB" ]; then
  PINNING_LIB="$SCRIPT_DIR/../lib/pinning-patterns.sh"
fi
if [ ! -f "$PINNING_LIB" ]; then
  jq -n --arg reason "[pinning-guard] shared pinning policy library is missing: $PINNING_LIB" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi
# shellcheck source=../lib/pinning-patterns.sh
. "$PINNING_LIB"

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

_deny() {
  local surface="$1" target="$2" findings="$3"
  local reason
  reason=$(printf '[pinning-guard] %s on %s contains volatile review/session metadata:%b\nUse stable identifiers or plain natural-language context before retrying.' \
    "$surface" "$target" "$findings")
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

_scan_text_file() {
  local text="$1" out_file="$2"
  printf '%s' "$text" > "$out_file"
}

_targeted_bash_command() {
  local cmd="$1"
  case "$cmd" in
    *"git commit"* | *"git -"*" commit"* | \
    *"gh pr create"* | *"gh pr edit"* | *"gh pr comment"* | *"gh pr review"* | \
    *"gh issue create"* | *"gh issue edit"* | *"gh issue comment"* | \
    *"gh api"*"issues/"*"comments"* | *"gh api"*"pulls/"*"comments"* | *"gh api"*"pulls/"*"reviews"*) return 0 ;;
    *) return 1 ;;
  esac
}

case "$TOOL_NAME" in
  Edit | Write | NotebookEdit | Bash) ;;
  *) exit 0 ;;
esac

SCAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pinning-guard-XXXXXX") || exit 0
trap 'rm -rf "$SCAN_DIR"' EXIT

case "$TOOL_NAME" in
  Edit)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
    pinning_should_check_path "$FILE_PATH" || exit 0

    OLD_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
    NEW_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
    [ -n "$NEW_STR" ] || exit 0

    _scan_text_file "${OLD_STR:-}" "$SCAN_DIR/old.txt"
    _scan_text_file "$NEW_STR" "$SCAN_DIR/new.txt"
    findings="$(pinning_guard_findings_text_for_path "$SCAN_DIR/old.txt" "$SCAN_DIR/new.txt" "$FILE_PATH")"
    if [ -n "$findings" ]; then
      _deny "$TOOL_NAME" "$FILE_PATH" "$findings"
    fi
    ;;
  Write)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
    pinning_should_check_path "$FILE_PATH" || exit 0

    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
    [ -n "$CONTENT" ] || exit 0
    if [ -f "$FILE_PATH" ]; then
      cat "$FILE_PATH" > "$SCAN_DIR/old.txt"
    else
      : > "$SCAN_DIR/old.txt"
    fi
    _scan_text_file "$CONTENT" "$SCAN_DIR/new.txt"
    findings="$(pinning_guard_findings_text_for_path "$SCAN_DIR/old.txt" "$SCAN_DIR/new.txt" "$FILE_PATH")"
    if [ -n "$findings" ]; then
      _deny "$TOOL_NAME" "$FILE_PATH" "$findings"
    fi
    ;;
  NotebookEdit)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
    pinning_should_check_path "$FILE_PATH" || exit 0

    NEW_SOURCE=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_source // empty' 2>/dev/null)
    [ -n "$NEW_SOURCE" ] || exit 0
    OLD_SOURCE=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_source // .tool_input.old_string // empty' 2>/dev/null)
    _scan_text_file "${OLD_SOURCE:-}" "$SCAN_DIR/old.txt"
    _scan_text_file "$NEW_SOURCE" "$SCAN_DIR/new.txt"
    findings="$(pinning_guard_findings_text_for_path "$SCAN_DIR/old.txt" "$SCAN_DIR/new.txt" "$FILE_PATH")"
    if [ -n "$findings" ]; then
      _deny "$TOOL_NAME" "$FILE_PATH" "$findings"
    fi
    ;;
  Bash)
    COMMAND_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$COMMAND_TEXT" ] || exit 0
    _targeted_bash_command "$COMMAND_TEXT" || exit 0

    _scan_text_file "$COMMAND_TEXT" "$SCAN_DIR/new.txt"
    findings="$(pinning_findings_text "$SCAN_DIR/new.txt")"
    [ -n "$findings" ] || exit 0
    _deny "$TOOL_NAME" "durable shell command" "$findings"
    ;;
esac

exit 0
