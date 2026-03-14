#!/usr/bin/env bash
# Claude Code custom statusline - plan 파일 경로 표시
# stdin으로 JSON 세션 데이터를 받아 statusbar 내용을 stdout으로 출력

input=$(cat)

TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty')

# --- Plan 파일 감지 ---
# 현재 세션의 transcript에서 plan 파일 Read/Write 기록을 추출한다.
# ※ 이전 ls -t 방식은 세션과 무관하게 가장 최근 파일을 반환하여
#   다른 세션의 plan을 오표시하는 버그가 있었음 (worktree fallback 포함).
PLAN_FILE=""
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # agent_progress 이벤트 제외 (subagent가 다른 세션 plan을 읽은 기록 필터링)
  # agent plan 파일명(-agent-) 제외
  PLAN_FILE=$(grep -v '"type":"agent_progress"' "$TRANSCRIPT" 2>/dev/null \
    | grep -oE '"(filePath|file_path|planFilePath)":"[^"]*\.claude/plans/[^"]*\.md"' \
    | grep -v 'plans/[^"]*-agent-' \
    | tail -1 | sed 's/^"[^"]*":"//;s/"$//')
fi

# --- 출력 ---
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  # OSC 8 하이퍼링크로 Cmd+Click 시 plan 파일 열림
  # \e[4;36m = underline + cyan → 클릭 가능한 링크 느낌
  printf '%b' "\e[4;36m\e]8;;file://${PLAN_FILE}\a\xf0\x9f\x93\x9d Plan\e]8;;\a\e[0m\n"
fi
