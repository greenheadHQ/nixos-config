#!/usr/bin/env bash
# PreToolUse Hook: SKILL.md fragile hardcoding 감지
# 코드에서 동적으로 확인 가능한 정보(줄 수, 파일 수, 경로 열거)를
# SKILL.md에 하드코딩하면 코드 변경 시 즉시 outdated 되므로 차단한다.

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

case "$TOOL_NAME" in Edit|Write) ;; *) exit 0 ;; esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0

# [WHY] SKILL.md body와 references/는 LLM이 생성/수정하는 스킬 콘텐츠.
# 이 영역에 코드 상태를 하드코딩하면 코드 변경 시 문서가 즉시 stale 됨.
# project-scope (.claude/skills/) + user-scope 소스 (modules/.../skills/) 모두 대상.
case "$FILE_PATH" in
  */.claude/skills/*/SKILL.md|*/.claude/skills/*/references/*|\
  */modules/*/claude/files/skills/*/SKILL.md|*/modules/*/claude/files/skills/*/references/*) ;;
  *) exit 0 ;;
esac

if [ "$TOOL_NAME" = "Write" ]; then
  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null)
else
  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null)
fi
[ -z "$CONTENT" ] && exit 0

# [WHY] Write 전용: 코드 블록 내부는 예시/템플릿이므로 검사 대상이 아님.
# Edit의 new_string은 조각이라 fence 경계가 불완전할 수 있으므로 strip하지 않음.
# awk fence parser: Markdown spec 기준 0-3칸 들여쓰기 + 3개 이상 backtick.
#   depth=fence 내부 여부, fence_len=opening backtick 수.
#   닫힘 조건: backtick 수 >= opening 길이 && 뒤에 텍스트 없음.
if [ "$TOOL_NAME" = "Write" ]; then
  SCAN_INPUT=$(printf '%s' "$CONTENT" | awk '
    BEGIN { depth = 0; fence_len = 0 }
    {
      s = $0; sub(/^[ ]{0,3}/, "", s); ticks = 0
      while (substr(s, ticks+1, 1) == "`") ticks++
      if (ticks >= 3) {
        tail = substr(s, ticks+1); gsub(/[ \t\r]/, "", tail)
        if (depth == 0) { depth = 1; fence_len = ticks; next }
        if (ticks >= fence_len && tail == "") { depth = 0; fence_len = 0; next }
      }
      if (depth == 0) print
    }')
else
  SCAN_INPUT="$CONTENT"
fi

WARNINGS=""

# [WHY] 줄 수는 코드 수정 시 즉시 변경됨 → wc -l로 동적 확인 가능
printf '%s' "$SCAN_INPUT" | grep -qE '[0-9]+줄|[0-9]+ lines' && \
  WARNINGS="${WARNINGS}줄 수 하드코딩. "

# [WHY] 파일/참조 수는 파일 추가/삭제 시 변경됨 → grep -c로 동적 확인 가능
printf '%s' "$SCAN_INPUT" | grep -qE '[0-9]+개 파일|[0-9]+곳' && \
  WARNINGS="${WARNINGS}파일/참조 수 하드코딩. "

# [WHY] 스킬 경로를 3개 이상 나열하면 스킬 추가/삭제 시 목록이 stale 됨.
# 3개 미만은 정당한 교차 참조(예: "NOT for X, use Y")로 간주.
SKILL_PATH_COUNT=$(printf '%s' "$SCAN_INPUT" | grep -oE '\.claude/skills/[a-z0-9_-]+' | sort -u | wc -l)
[ "$SKILL_PATH_COUNT" -ge 3 ] && \
  WARNINGS="${WARNINGS}.claude/skills/ 경로 ${SKILL_PATH_COUNT}개 열거. "

[ -z "$WARNINGS" ] && exit 0

# Claude Code PreToolUse hook 차단 형식: {decision: "block", reason: "..."}
jq -n --arg reason "[Fragile hardcoding] ${WARNINGS}코드에서 동적 확인 가능한 정보입니다. 하드코딩 대신 확인 방법을 기술하세요." \
  '{decision: "block", reason: $reason}'
exit 0
