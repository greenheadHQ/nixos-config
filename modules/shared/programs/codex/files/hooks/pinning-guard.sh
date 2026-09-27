#!/usr/bin/env bash
# pinning-guard.sh — Codex PreToolUse hard-fail guard.
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

# tool_name 사전 분기 — 비대상 tool 은 lib bootstrap 비용 없이 즉시 종료한다.
# 이 순서는 fail-closed 경계의 영향 범위를 pinning 검사 대상 tool 로 한정한다.
INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

case "$TOOL_NAME" in
  Bash | Edit | Write | NotebookEdit | apply_patch) ;;
  *) exit 0 ;;
esac

# Bootstrap: hook-runtime.sh source. 미발견 시 fail-closed (deny).
HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.codex/lib/hook-runtime.sh}"
if [ ! -f "$HOOK_RUNTIME_LIB" ]; then
  _deny_with_reason "[pinning-guard] shared pinning policy library is missing: hook-runtime.sh ($HOOK_RUNTIME_LIB). HOOK_RUNTIME_LIB env var 또는 ~/.codex/lib/ 설치 필요."
fi
# shellcheck source=../../../claude/files/lib/hook-runtime.sh
. "$HOOK_RUNTIME_LIB"

# pinning-patterns.sh 로드. 미발견 시 fail-closed (deny).
PINNING_LIB=$(hook_load_lib PINNING_PATTERNS_LIB "$HOME/.codex/lib" pinning-patterns.sh) || PINNING_LIB=""
if [ -z "$PINNING_LIB" ]; then
  _deny_with_reason "[pinning-guard] shared pinning policy library is missing: pinning-patterns.sh. PINNING_PATTERNS_LIB env var 또는 ~/.codex/lib/pinning-patterns.sh 설치 필요."
fi
# shellcheck source=../../../claude/files/lib/pinning-patterns.sh
. "$PINNING_LIB"

SCAN_DIR=$(hook_init_scan_dir pinning-guard) || _deny_with_reason "[pinning-guard] failed to initialize scan workspace; denying by fail-closed policy."
trap 'rm -rf "$SCAN_DIR"' EXIT

_deny() {
  local surface="$1" target="$2" findings="$3"
  local reason
  reason=$(printf '[pinning-guard] %s on %s contains volatile review/session metadata:%b\nUse stable identifiers or plain natural-language context before retrying.' \
    "$surface" "$target" "$findings")
  _deny_with_reason "$reason"
}

# gh 게시 명령 전반(gh api 쓰기, `gh -R o/r pr comment` 같은 형태 포함)은 아래 Bash 분기에서
# pinning_codex_mention_scope가 먼저 A–D 대상으로 올린다 (#1477). 여기서는 그 밖의 durable 명령을
# 문자열로 고른다.
_targeted_bash_command() {
  local cmd="$1"
  case "$cmd" in
    *"git commit"* | *"git -"*" commit"* | \
    *"gh pr create"* | *"gh pr edit"* | *"gh pr comment"* | *"gh pr review"* | *"gh pr merge"* | \
    *"gh pr close"* | *"gh pr reopen"* | *"gh pr revert"* | \
    *"gh issue create"* | *"gh issue edit"* | *"gh issue comment"* | *"gh issue close"* | *"gh issue reopen"* | \
    *"gh api"*"issues/"*"comments"* | *"gh api"*"pulls/"*"comments"* | *"gh api"*"pulls/"*"reviews"*) return 0 ;;
  esac
  return 1
}

_scan_text_file() {
  local text="$1" scan_file="$2"
  printf '%s' "$text" > "$scan_file"
}

case "$TOOL_NAME" in
  Bash)
    COMMAND_TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
    [ -n "$COMMAND_TEXT" ] || exit 0
    # 박제 범주(A–D)와 Codex 봇 멘션(#1477)은 검사 대상 명령이 겹치지만 같지 않다. 멘션 대상(GitHub
    # 게시 명령)은 모두 A–D 대상이고, A–D는 git commit·gh pr merge 같은 durable 명령을 더 본다.
    SCAN_PINNING=0
    SCAN_MENTION=0
    if pinning_codex_mention_scope "$COMMAND_TEXT"; then
      SCAN_MENTION=1
      SCAN_PINNING=1
    elif _targeted_bash_command "$COMMAND_TEXT"; then
      SCAN_PINNING=1
    fi
    [ "$SCAN_PINNING" = 1 ] || exit 0

    _scan_text_file "$COMMAND_TEXT" "$SCAN_DIR/bash.txt"
    findings="$(pinning_findings_text "$SCAN_DIR/bash.txt")"
    if [ -n "$findings" ]; then
      _deny "$TOOL_NAME" "durable shell command" "$findings"
    fi
    if [ "$SCAN_MENTION" = 1 ]; then
      findings="$(pinning_codex_mention_findings_text "$SCAN_DIR/bash.txt" command)" \
        || _deny_with_reason "[pinning-guard] Codex mention scan failed; denying by fail-closed policy."
      if [ -n "$findings" ]; then
        _deny_with_reason "$(pinning_codex_mention_deny_reason "$TOOL_NAME" "durable shell command" "$findings")"
      fi
    fi

    # --body-file / -F(--field) / --input 으로 넘겨진 파일 내용도 재스캔한다 (issue #684, #1477).
    # command 문자열 자체는 클린해도 파일 내용에 박제 패턴이나 봇 멘션이 있는 케이스를 잡는다.
    while IFS= read -r body_file; do
      [ -n "$body_file" ] || continue
      # gh가 본문으로 읽는 것은 정규 파일뿐이다. 디렉터리(`awk -F/`의 `/`)·장치·파이프는 건너뛴다.
      [ -f "$body_file" ] || continue
      # cat이 루프의 stdin(남은 경로 목록)을 읽지 않도록 stdin을 막는다 (`-` 파일 등).
      if ! cat -- "$body_file" > "$SCAN_DIR/bash.txt" 2>/dev/null </dev/null; then
        _deny_with_reason "[pinning-guard] failed to read $body_file referenced via --body-file; denying by fail-closed policy."
      fi
      findings="$(pinning_findings_text "$SCAN_DIR/bash.txt")"
      if [ -n "$findings" ]; then
        _deny "$TOOL_NAME" "$body_file (via --body-file)" "$findings"
      fi
      if [ "$SCAN_MENTION" = 1 ]; then
        findings="$(pinning_codex_mention_findings_text "$SCAN_DIR/bash.txt" body)" \
          || _deny_with_reason "[pinning-guard] Codex mention scan failed; denying by fail-closed policy."
        if [ -n "$findings" ]; then
          _deny_with_reason "$(pinning_codex_mention_deny_reason "$TOOL_NAME" "$body_file (via --body-file)" "$findings")"
        fi
      fi
    done < <(pinning_extract_body_file_paths "$COMMAND_TEXT")
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
