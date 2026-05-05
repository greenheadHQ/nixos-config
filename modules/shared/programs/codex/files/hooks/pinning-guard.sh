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

_is_git_commit_command() {
  local cmd="$1"
  case "$cmd" in
    *"git commit"* | *"git -"*" commit"*) return 0 ;;
    *) return 1 ;;
  esac
}

_targeted_bash_command() {
  local cmd="$1"
  if _is_git_commit_command "$cmd"; then
    return 0
  fi
  case "$cmd" in
    *"gh pr create"* | *"gh pr edit"* | *"gh pr comment"* | *"gh pr review"* | \
    *"gh issue create"* | *"gh issue edit"* | *"gh issue comment"* | \
    *"gh api"*"issues/"*"comments"* | *"gh api"*"pulls/"*"comments"* | *"gh api"*"pulls/"*"reviews"*) return 0 ;;
    *) return 1 ;;
  esac
}

_allow_partial_hash_exception() {
  local cmd="$1"
  _is_git_commit_command "$cmd" || return 1
  case "$cmd" in
    *"Revert "* | *"cherry-pick"* | *"cherry picked"*) return 0 ;;
    *) return 1 ;;
  esac
}

_scan_text_file() {
  local text="$1" scan_file="$2"
  printf '%s' "$text" > "$scan_file"
}

_scan_text() {
  local text="$1" scan_file="$2"
  _scan_text_file "$text" "$scan_file"
  pinning_findings_text "$scan_file"
}

_count_text() {
  local text="$1" scan_file="$2"
  _scan_text_file "$text" "$scan_file"
  pinning_match_count "$scan_file"
}

case "$TOOL_NAME" in
  Bash)
    COMMAND_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$COMMAND_TEXT" ] || exit 0
    _targeted_bash_command "$COMMAND_TEXT" || exit 0

    findings="$(_scan_text "$COMMAND_TEXT" "$SCAN_DIR/bash.txt")"
    if _allow_partial_hash_exception "$COMMAND_TEXT"; then
      findings="$(pinning_strip_partial_hash_finding "$findings")"
    fi
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

    OLD_COUNT=0
    NEW_COUNT=0
    case "$TOOL_NAME" in
      Edit)
        OLD_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty' 2>/dev/null)
        NEW_STR=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
        [ -n "$NEW_STR" ] || exit 0
        if [ -n "$OLD_STR" ]; then
          OLD_COUNT=$(_count_text "$OLD_STR" "$SCAN_DIR/old.txt")
        fi
        NEW_COUNT=$(_count_text "$NEW_STR" "$SCAN_DIR/new.txt")
        ;;
      Write)
        CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
        [ -n "$CONTENT" ] || exit 0
        NEW_COUNT=$(_count_text "$CONTENT" "$SCAN_DIR/new.txt")
        if [ -f "$FILE_PATH" ]; then
          OLD_COUNT=$(_count_text "$(cat "$FILE_PATH")" "$SCAN_DIR/old.txt")
        fi
        ;;
      NotebookEdit)
        NEW_SOURCE=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_source // empty' 2>/dev/null)
        [ -n "$NEW_SOURCE" ] || exit 0
        OLD_SOURCE=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_source // .tool_input.old_string // empty' 2>/dev/null)
        NEW_COUNT=$(_count_text "$NEW_SOURCE" "$SCAN_DIR/new.txt")
        if [ -n "$OLD_SOURCE" ]; then
          OLD_COUNT=$(_count_text "$OLD_SOURCE" "$SCAN_DIR/old.txt")
        fi
        ;;
    esac
    if [ "$NEW_COUNT" -gt "$OLD_COUNT" ]; then
      findings="$(pinning_findings_text "$SCAN_DIR/new.txt")"
      _deny "$TOOL_NAME" "$FILE_PATH" "$findings"
    fi
    ;;
  apply_patch)
    PATCH_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$PATCH_TEXT" ] || exit 0

    PATCH_FILE="$SCAN_DIR/patch.txt"
    printf '%s' "$PATCH_TEXT" > "$PATCH_FILE"
    SECTIONS_FILE="$SCAN_DIR/sections.tsv"
    awk '
      /^\*\*\* (Update|Add|Delete) File: / {
        path = $0
        sub(/^\*\*\* [A-Za-z]+ File: /, "", path)
        next
      }
      /^\*\*\* Move to: / {
        newpath = $0
        sub(/^\*\*\* Move to: /, "", newpath)
        path = newpath
        next
      }
      /^\*\*\* End Patch/ { path = ""; next }
      path != "" && /^\+/ && !/^\*\*\*/ {
        line = $0
        sub(/^\+/, "", line)
        printf "%s\t%s\n", path, line
      }
    ' "$PATCH_FILE" > "$SECTIONS_FILE"

    [ -s "$SECTIONS_FILE" ] || exit 0

    while IFS= read -r path; do
      [ -n "$path" ] || continue
      pinning_should_check_path "$path" || continue
      PATH_SCAN_FILE=$(mktemp "$SCAN_DIR/scan-XXXXXX")
      awk -F'\t' -v target="$path" '$1 == target { print substr($0, length(target) + 2) }' \
        "$SECTIONS_FILE" > "$PATH_SCAN_FILE"
      [ -s "$PATH_SCAN_FILE" ] || continue
      findings="$(pinning_findings_text "$PATH_SCAN_FILE")"
      [ -n "$findings" ] || continue
      _deny "$TOOL_NAME" "$path" "$findings"
    done < <(awk -F'\t' '{print $1}' "$SECTIONS_FILE" | sort -u)
    ;;
esac

exit 0
