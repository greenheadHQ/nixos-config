#!/usr/bin/env bash
# pinning-guard.sh — Codex PreToolUse hard-fail guard.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

case "$TOOL_NAME" in
  Bash | Edit | Write | NotebookEdit | apply_patch) ;;
  *) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PINNING_LIB="${PINNING_PATTERNS_LIB:-$HOME/.codex/lib/pinning-patterns.sh}"
if [ ! -f "$PINNING_LIB" ]; then
  PINNING_LIB="$SCRIPT_DIR/../../../claude/files/lib/pinning-patterns.sh"
fi
if [ ! -f "$PINNING_LIB" ]; then
  jq -n --arg reason "[pinning-guard] shared pinning policy library is missing: $PINNING_LIB" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
fi
# shellcheck source=../../../claude/files/lib/pinning-patterns.sh
. "$PINNING_LIB"

SCAN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pinning-guard-XXXXXX") || exit 0
trap 'rm -rf "$SCAN_DIR"' EXIT

_deny() {
  local surface="$1" target="$2" findings="$3"
  local reason
  reason=$(printf '[pinning-guard] %s on %s contains volatile review/session metadata:%b\nUse stable identifiers or plain natural-language context before retrying.' \
    "$surface" "$target" "$findings")
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
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

_scan_text_file() {
  local text="$1" scan_file="$2"
  printf '%s' "$text" > "$scan_file"
}

case "$TOOL_NAME" in
  Bash)
    COMMAND_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$COMMAND_TEXT" ] || exit 0
    _targeted_bash_command "$COMMAND_TEXT" || exit 0

    _scan_text_file "$COMMAND_TEXT" "$SCAN_DIR/bash.txt"
    findings="$(pinning_findings_text "$SCAN_DIR/bash.txt")"
    [ -n "$findings" ] || exit 0
    _deny "$TOOL_NAME" "durable shell command" "$findings"
    ;;
  Edit | Write | NotebookEdit)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '
      .tool_input.file_path
      // .tool_input.notebook_path
      // empty
    ' 2>/dev/null)
    [ -n "$FILE_PATH" ] || exit 0
    pinning_should_check_path "$FILE_PATH" || exit 0

    case "$TOOL_NAME" in
      Edit)
        OLD_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
        NEW_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
        [ -n "$NEW_STR" ] || exit 0
        _scan_text_file "${OLD_STR:-}" "$SCAN_DIR/old.txt"
        _scan_text_file "$NEW_STR" "$SCAN_DIR/new.txt"
        ;;
      Write)
        CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
        [ -n "$CONTENT" ] || exit 0
        if [ -f "$FILE_PATH" ]; then
          cat "$FILE_PATH" > "$SCAN_DIR/old.txt"
        else
          : > "$SCAN_DIR/old.txt"
        fi
        _scan_text_file "$CONTENT" "$SCAN_DIR/new.txt"
        ;;
      NotebookEdit)
        NEW_SOURCE=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_source // empty' 2>/dev/null)
        [ -n "$NEW_SOURCE" ] || exit 0
        OLD_SOURCE=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_source // .tool_input.old_string // empty' 2>/dev/null)
        _scan_text_file "${OLD_SOURCE:-}" "$SCAN_DIR/old.txt"
        _scan_text_file "$NEW_SOURCE" "$SCAN_DIR/new.txt"
        ;;
    esac
    findings="$(pinning_guard_findings_text_for_path "$SCAN_DIR/old.txt" "$SCAN_DIR/new.txt" "$FILE_PATH")"
    if [ -n "$findings" ]; then
      _deny "$TOOL_NAME" "$FILE_PATH" "$findings"
    fi
    ;;
  apply_patch)
    PATCH_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$PATCH_TEXT" ] || exit 0

    PATCH_FILE="$SCAN_DIR/patch.txt"
    printf '%s' "$PATCH_TEXT" > "$PATCH_FILE"
    SECTIONS_FILE="$SCAN_DIR/sections.records"
    pinning_apply_patch_added_sections "$PATCH_FILE" > "$SECTIONS_FILE"

    [ -s "$SECTIONS_FILE" ] || exit 0

    while IFS= read -r path; do
      [ -n "$path" ] || continue
      pinning_should_check_path "$path" || continue
      PATH_SCAN_FILE=$(mktemp "$SCAN_DIR/scan-XXXXXX")
      pinning_apply_patch_section_lines_for_path "$SECTIONS_FILE" "$path" > "$PATH_SCAN_FILE"
      [ -s "$PATH_SCAN_FILE" ] || continue
      findings="$(pinning_guard_findings_text_for_scan_path "$PATH_SCAN_FILE" "$path")"
      [ -n "$findings" ] || continue
      _deny "$TOOL_NAME" "$path" "$findings"
    done < <(pinning_apply_patch_section_paths "$SECTIONS_FILE")
    ;;
esac

exit 0
