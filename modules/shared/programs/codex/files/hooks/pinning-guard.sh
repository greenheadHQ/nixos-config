#!/usr/bin/env bash
# pinning-guard.sh — Codex PreToolUse hard-fail guard.
# 패턴 SSOT: modules/shared/programs/claude/files/lib/pinning-patterns.sh.
# 공통 helper SSOT: modules/shared/programs/claude/files/lib/hook-runtime.sh.
# 정책: PreToolUse fail-closed — lib 누락 시 deny JSON 반환 (보안 경계 유지).
# 범위: 에이전트가 실수로 남긴 박제 메타데이터를 게시 전에 거르는 위생 검사다. 우회하려는 입력이나
# 드문 셸 문법(특이한 here-doc 구분자, 로캘에 따른 중괄호 범위, 대화형 장치 등)까지 더 해석하는 것은
# 목표가 아니다. 그런 형태는 알려진 한계로 기록하고 처리 범위를 넓히지 않는다. 판별을 넓힐 때는
# 실제로 쓰이는 게시 명령 형태를 우선한다.
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

_targeted_bash_command() {
  local cmd="$1"
  case "$cmd" in
    *gh* | *git*) ;;
    *) return 1 ;;
  esac
  # 판별에만 쓰는 정규화다(검사 대상인 명령 원문은 그대로 둔다). 명령 이름 사이의 줄 연속은
  # 지우고 탭·연속 공백은 한 칸으로 줄이며, gh가 하위 명령 앞에서 받는 저장소 옵션
  # (-R, --repo)은 뗀다. 정규화가 실패하면 게시 명령으로 보고 검사한다(fail-closed).
  # 줄 연속도 sed에서 지운다. bash 3.2의 패턴 치환은 줄 연속이 많은 긴 명령에서 크게 느려진다.
  cmd=$(printf '%s\n' "$cmd" | sed -E -e :a -e '/\\$/{$!N;s/\\\n//;ta' -e '}' \
    -e 's/[[:blank:]]+/ /g; s/gh (-R ?|--repo[= ])[^ ]+ /gh /g') || return 0
  case "$cmd" in
    *"git commit"* | *"git -"*" commit"* | \
    *"gh pr create"* | *"gh pr edit"* | *"gh pr comment"* | *"gh pr review"* | *"gh pr merge"* | \
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
    if [ -n "$findings" ]; then
      _deny "$TOOL_NAME" "durable shell command" "$findings"
    fi

    # --body-file / -F(--field) 로 넘겨진 파일 내용도 재스캔한다 (issue #684).
    # command 문자열 자체는 클린해도 파일 내용에 박제 패턴이 있는 케이스를 잡는다.
    # 이전 공백 분할 후보를 먼저 검사하고, 인용·공백 경로까지 읽는 정적 추출 결과를 이어서
    # 검사한다. 정적 추출이 느리거나 실패해도 이전 검사 범위는 먼저 끝난다. 각 단계는 후보를
    # 모두 읽은 뒤 검사한다. 후보 스트림을 stdin으로 둔 채 cat하면 표준 입력을 가리키는
    # 후보(/dev/stdin 등)가 남은 후보를 삼켜 뒤 파일 검사가 빠지므로, 본문 읽기의 stdin은 /dev/null로 둔다.
    # 추출이 실패하면 확인하지 못한 경로가 남을 수 있으므로 거부한다(fail-closed).
    # FIFO는 읽으면 게시 명령이 받을 본문을 소비하거나 쓰는 쪽이 없어 멈추므로 읽지 않고 거부한다.
    # 일반 파일은 전부 읽는다(분할 후보는 게시 명령이 아닌 --file·-F 파일도 내므로 크기로 막지 않는다).
    # 그 밖의 파일(끝나지 않는 장치 파일 등)은 최대 크기까지만 읽고, 넘으면 전부 확인할 수 없으므로
    # 거부한다. 한도는 GitHub 본문 한도(65,536자)보다 넉넉하다.
    # 같은 경로 문자열은 한 번만 읽는다(패턴이 아닌 문자열로 비교). 표기가 다른 같은 파일
    # (./a와 a)은 따로 읽으며, 확인한 목록을 매번 훑으므로 후보 수에 대해 이차 시간이 든다.
    checked_body_files=$'\n'
    body_file_max_bytes=1048576
    for body_file_source in pinning_split_body_file_candidates pinning_extract_body_file_paths; do
      if ! "$body_file_source" "$COMMAND_TEXT" > "$SCAN_DIR/body-candidates.txt" 2>/dev/null; then
        _deny_with_reason "[pinning-guard] failed to extract --body-file paths; denying by fail-closed policy."
      fi
      body_files=()
      while IFS= read -r body_file; do
        [ -n "$body_file" ] || continue
        body_files+=("$body_file")
      done < "$SCAN_DIR/body-candidates.txt"
      for body_file in ${body_files[@]+"${body_files[@]}"}; do
        case "$checked_body_files" in
          *$'\n'"$body_file"$'\n'*) continue ;;
        esac
        checked_body_files+="$body_file"$'\n'
        [ -e "$body_file" ] || continue
        # 판정도 읽기와 같이 stdin을 /dev/null로 두어, /dev/stdin 같은 경로가 hook 입력 pipe를 가리키지 않게 한다.
        if [ -p "$body_file" ] < /dev/null; then
          _deny_with_reason "[pinning-guard] $body_file referenced via --body-file is a FIFO; it cannot be inspected without consuming it, so denying. Use a regular file."
        fi
        if [ -f "$body_file" ] < /dev/null; then
          body_file_regular=1
          body_file_reader=(cat --)
        else
          body_file_regular=0
          body_file_reader=(head -c "$((body_file_max_bytes + 1))" --)
        fi
        if ! "${body_file_reader[@]}" "$body_file" > "$SCAN_DIR/bash.txt" 2>/dev/null < /dev/null; then
          _deny_with_reason "[pinning-guard] failed to read $body_file referenced via --body-file; denying by fail-closed policy."
        fi
        if [ "$body_file_regular" = 0 ]; then
          body_file_bytes=$(wc -c < "$SCAN_DIR/bash.txt")
          if [ "$((body_file_bytes))" -gt "$body_file_max_bytes" ]; then
            _deny_with_reason "[pinning-guard] $body_file referenced via --body-file is not a regular file and is larger than $body_file_max_bytes bytes or does not end; it cannot be fully inspected, so denying."
          fi
        fi
        findings="$(pinning_findings_text "$SCAN_DIR/bash.txt")"
        [ -n "$findings" ] || continue
        _deny "$TOOL_NAME" "$body_file (via --body-file)" "$findings"
      done
    done
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
