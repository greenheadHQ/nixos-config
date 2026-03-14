#!/usr/bin/env bash
# Claude Code custom statusline - plan 파일 경로 표시
# stdin으로 JSON 세션 데이터를 받아 statusbar 내용을 stdout으로 출력

input=$(cat)

CWD=$(echo "$input" | jq -r '.cwd // empty')

# --- Plan 파일 감지 ---
# .claude/plans/ 에서 가장 최근 수정된 plan 파일을 찾는다.
# worktree에서는 plans가 main repo에만 존재하므로 fallback 탐색.
PLAN_FILE=""
if [ -n "$CWD" ]; then
  PLAN_FILE=$(ls -t "$CWD/.claude/plans/"*.md 2>/dev/null | head -1)

  # Worktree fallback: CWD가 .claude/worktrees/ 하위이면 main repo의 plans 확인
  if [ -z "$PLAN_FILE" ]; then
    MAIN_REPO=${CWD%/.claude/worktrees/*}
    if [ "$MAIN_REPO" != "$CWD" ]; then
      PLAN_FILE=$(ls -t "$MAIN_REPO/.claude/plans/"*.md 2>/dev/null | head -1)
    fi
  fi
fi

# --- 출력 ---
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  # OSC 8 하이퍼링크로 Cmd+Click 시 plan 파일 열림
  # \e[4;36m = underline + cyan → 클릭 가능한 링크 느낌
  printf '%b' "\e[4;36m\e]8;;file://${PLAN_FILE}\a\xf0\x9f\x93\x9d Plan\e]8;;\a\e[0m\n"
fi
