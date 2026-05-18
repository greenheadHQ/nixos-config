#!/usr/bin/env bash
# pinning-alert.sh — PostToolUse Edit/Write/NotebookEdit warn-only alert (Claude Code).
# 패턴 SSOT: modules/shared/programs/claude/files/lib/pinning-patterns.sh.
# 공통 helper SSOT: modules/shared/programs/claude/files/lib/hook-runtime.sh.
# commit-msg, Claude/Codex PostToolUse alert, Claude/Codex PreToolUse guard가 같은
# shared library를 source한다. runtime별 hook에는 stdin 파싱과 출력 정책만 남긴다.
# 정책: warn-only — stderr alert + exit 0. permissionDecision 사용 금지.
#
# pipefail 안전 모델 (commit-msg-pinning.sh와 동일 SSOT):
#   `printf '%s' "$TEXT" | grep -qE ...` 조합은 큰 입력에서 grep -q 조기 종료 + SIGPIPE로
#   producer가 nonzero를 반환해 pipefail 환경에서 silent miss를 만든다. 검사 텍스트를 mktemp
#   파일에 저장하고 `grep -qE "$PATTERN" "$tmpfile"`로 검사하여 회피한다.
set -euo pipefail

# 환경 가드(CLAUDECODE/CODEX_PROGRAMMATIC) 없음 — PostToolUse pinning-alert는 자식 LLM 세션의
# Edit/Write를 부모가 보지 못하기 때문에 항상 검사해야 한다 (record-prompt-submit/stop-notification
# 등의 부모-처리-신뢰 가드와 의미가 다르다). 중복 alert는 운영 noise로 수용.

command -v jq >/dev/null 2>&1 || exit 0

# Bootstrap: hook-runtime.sh source. 미발견 시 warn-only 계약대로 exit 0.
HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
if [ ! -f "$HOOK_RUNTIME_LIB" ]; then
  printf '[pinning-alert] hook-runtime.sh 미발견 (%s) — 검사 skip\n' "$HOOK_RUNTIME_LIB" >&2
  exit 0
fi
# shellcheck source=../lib/hook-runtime.sh
. "$HOOK_RUNTIME_LIB"

# pinning-patterns.sh 로드. 미발견 시 warn-only 계약대로 exit 0.
PINNING_LIB=$(hook_load_lib PINNING_PATTERNS_LIB "$HOME/.claude/lib" pinning-patterns.sh) || PINNING_LIB=""
if [ -z "$PINNING_LIB" ]; then
  printf '[pinning-alert] pinning-patterns.sh 미발견 — 검사 skip. PINNING_PATTERNS_LIB env var 또는 ~/.claude/lib/ 설치 필요.\n' >&2
  exit 0
fi
# shellcheck source=../lib/pinning-patterns.sh
. "$PINNING_LIB"

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | hook_parse_tool_name)
case "$TOOL_NAME" in
  Edit | Write | NotebookEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '
  .tool_input.file_path
  // .tool_input.notebook_path
  // empty
' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

pinning_should_check_path "$FILE_PATH" || exit 0

# 검사 대상 텍스트 추출
TEXT=""
case "$TOOL_NAME" in
  Edit) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null) ;;
  Write) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null) ;;
  NotebookEdit) TEXT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_source // empty' 2>/dev/null) ;;
esac
[ -n "$TEXT" ] || exit 0

# 검사 디렉토리 생성 (pipefail 안전 모델 — 파일 기반 grep). trap은 호출자가 설치.
SCAN_DIR=$(hook_init_scan_dir pinning-scan) || exit 0
trap 'rm -rf "$SCAN_DIR"' EXIT
SCAN_FILE="$SCAN_DIR/scan.txt"
printf '%s' "$TEXT" > "$SCAN_FILE"

findings="$(pinning_findings_text_for_path "$SCAN_FILE" "$FILE_PATH")"

if [ -n "$findings" ]; then
  printf '[pinning-alert] %s on %s 매치:%b\n' "$TOOL_NAME" "$FILE_PATH" "$findings" >&2
fi

exit 0
