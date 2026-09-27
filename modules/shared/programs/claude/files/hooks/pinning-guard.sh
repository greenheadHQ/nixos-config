#!/usr/bin/env bash
# pinning-guard.sh — Claude Code PreToolUse hard-fail guard.
# 패턴 SSOT: modules/shared/programs/claude/files/lib/pinning-patterns.sh.
# 공통 helper SSOT: modules/shared/programs/claude/files/lib/hook-runtime.sh.
# 정책: PreToolUse fail-closed — lib 누락 시 deny JSON 반환 (보안 경계 유지).
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

_deny_with_reason() {
  local reason="$1"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}'
  exit 0
}

# Bootstrap: hook-runtime.sh source. 미발견 시 fail-closed (deny).
HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
if [ ! -f "$HOOK_RUNTIME_LIB" ]; then
  _deny_with_reason "[pinning-guard] shared pinning policy library is missing: hook-runtime.sh ($HOOK_RUNTIME_LIB)"
fi
# shellcheck source=../lib/hook-runtime.sh
. "$HOOK_RUNTIME_LIB"

# pinning-patterns.sh 로드. 미발견 시 fail-closed (deny).
PINNING_LIB=$(hook_load_lib PINNING_PATTERNS_LIB "$HOME/.claude/lib" pinning-patterns.sh) || PINNING_LIB=""
if [ -z "$PINNING_LIB" ]; then
  _deny_with_reason "[pinning-guard] shared pinning policy library is missing: pinning-patterns.sh. PINNING_PATTERNS_LIB env var 또는 ~/.claude/lib/pinning-patterns.sh 설치 필요."
fi
# shellcheck source=../lib/pinning-patterns.sh
. "$PINNING_LIB"

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | hook_parse_tool_name)

_deny() {
  local surface="$1" target="$2" findings="$3"
  local reason
  reason=$(printf '[pinning-guard] %s on %s contains volatile review/session metadata:%b\nUse stable identifiers or plain natural-language context before retrying.' \
    "$surface" "$target" "$findings")
  _deny_with_reason "$reason"
}

_scan_text_file() {
  local text="$1" out_file="$2"
  printf '%s' "$text" > "$out_file"
}

_targeted_bash_command() {
  local cmd="$1"
  case "$cmd" in
    *"git commit"* | *"git -"*" commit"* | \
    *"gh pr create"* | *"gh pr edit"* | *"gh pr comment"* | *"gh pr review"* | *"gh pr merge"* | \
    *"gh issue create"* | *"gh issue edit"* | *"gh issue comment"* | \
    *"gh api"*"issues/"*"comments"* | *"gh api"*"pulls/"*"comments"* | *"gh api"*"pulls/"*"reviews"*) return 0 ;;
  esac
  # 엔드포인트와 무관하게 gh api 쓰기(GraphQL mutation 포함)도 게시면이다 (#1477).
  pinning_gh_api_posts_content "$cmd"
}

case "$TOOL_NAME" in
  Edit | Write | NotebookEdit | Bash) ;;
  *) exit 0 ;;
esac

SCAN_DIR=$(hook_init_scan_dir pinning-guard) || _deny_with_reason "[pinning-guard] failed to initialize scan workspace; denying by fail-closed policy."
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
    # 박제 범주(A–D)와 Codex 봇 멘션(#1477)은 검사 대상 명령이 겹치지만 같지 않다.
    SCAN_PINNING=0
    SCAN_MENTION=0
    if _targeted_bash_command "$COMMAND_TEXT"; then SCAN_PINNING=1; fi
    if pinning_codex_mention_scope "$COMMAND_TEXT"; then SCAN_MENTION=1; fi
    [ "$SCAN_PINNING" = 1 ] || [ "$SCAN_MENTION" = 1 ] || exit 0

    _scan_text_file "$COMMAND_TEXT" "$SCAN_DIR/new.txt"
    if [ "$SCAN_PINNING" = 1 ]; then
      findings="$(pinning_findings_text "$SCAN_DIR/new.txt")"
      if [ -n "$findings" ]; then
        _deny "$TOOL_NAME" "durable shell command" "$findings"
      fi
    fi
    if [ "$SCAN_MENTION" = 1 ]; then
      findings="$(pinning_codex_mention_findings_text "$SCAN_DIR/new.txt" command)"
      if [ -n "$findings" ]; then
        _deny_with_reason "$(pinning_codex_mention_deny_reason "$TOOL_NAME" "durable shell command" "$findings")"
      fi
    fi

    # --body-file / -F(--field) / --input 으로 넘겨진 파일 내용도 재스캔한다 (issue #684, #1477).
    # command 문자열 자체는 클린해도 파일 내용에 박제 패턴이나 봇 멘션이 있는 케이스를 잡는다.
    while IFS= read -r body_file; do
      [ -n "$body_file" ] || continue
      [ -e "$body_file" ] || continue
      if ! cat "$body_file" > "$SCAN_DIR/new.txt" 2>/dev/null; then
        _deny_with_reason "[pinning-guard] failed to read $body_file referenced via --body-file; denying by fail-closed policy."
      fi
      if [ "$SCAN_PINNING" = 1 ]; then
        findings="$(pinning_findings_text "$SCAN_DIR/new.txt")"
        if [ -n "$findings" ]; then
          _deny "$TOOL_NAME" "$body_file (via --body-file)" "$findings"
        fi
      fi
      if [ "$SCAN_MENTION" = 1 ]; then
        findings="$(pinning_codex_mention_findings_text "$SCAN_DIR/new.txt" body)"
        if [ -n "$findings" ]; then
          _deny_with_reason "$(pinning_codex_mention_deny_reason "$TOOL_NAME" "$body_file (via --body-file)" "$findings")"
        fi
      fi
    done < <(pinning_extract_body_file_paths "$COMMAND_TEXT")
    ;;
esac

exit 0
