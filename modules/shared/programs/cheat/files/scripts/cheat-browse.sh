#!/usr/bin/env bash
set -euo pipefail

# cheat + fzf 브라우징 (title/content 모드 전환)
# 사용처: tmux prefix+C (display-popup), nvim <leader>C (Snacks.terminal), 터미널 직접 실행
#
# display-popup 셸의 PATH 불완전 방지를 위해 절대 경로 resolve
cheat_cmd="$(command -v cheat 2>/dev/null || echo cheat)"
fzf_cmd="$(command -v fzf 2>/dev/null || echo fzf)"

# SELF: 배포 환경(~/.local/bin)과 개발 환경(worktree 직접 실행) 모두 지원
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --content: 모든 시트 내용을 title\t내용줄 형태로 출력
if [[ "${1:-}" == "--content" ]]; then
  "$cheat_cmd" -l | awk 'NR>1 {print $1}' | while read -r title; do
    "$cheat_cmd" "$title" 2>/dev/null | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '%s\t%s\n' "$title" "$line"
    done || true
  done
  exit 0
fi

# --toggle STATE_FILE: 상태 파일 기반 모드 전환 fzf 액션 출력
if [[ "${1:-}" == "--toggle" ]]; then
  state_file="${2:?STATE_FILE required}"
  if [[ "$(cat "$state_file")" == "title" ]]; then
    echo "content" > "$state_file"
    echo "reload($SELF --content)+change-header(  [content 모드] Ctrl-S: title 모드 전환)+change-prompt(content> )"
  else
    echo "title" > "$state_file"
    echo "reload($cheat_cmd -l | tail -n +2)+change-header(  [title 모드] Ctrl-S: content 모드 전환)+change-prompt(title> )"
  fi
  exit 0
fi

# 기본: fzf 브라우저 실행
state_file="$(mktemp)"
echo "title" > "$state_file"
trap 'rm -f "$state_file"' EXIT

"$cheat_cmd" -l | tail -n +2 | "$fzf_cmd" \
  --ansi \
  --header "  [title 모드] Ctrl-S: content 모드 전환" \
  --prompt "title> " \
  --preview "$cheat_cmd {1}" \
  --preview-window=right:70% \
  --bind "enter:become($cheat_cmd {1})" \
  --bind "ctrl-s:transform:$SELF --toggle $state_file"
