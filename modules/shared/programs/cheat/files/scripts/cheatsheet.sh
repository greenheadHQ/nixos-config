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

# --preview TITLE: cheatsheet 내용을 구문 강조하여 출력
# 섹션 헤더 → bold cyan, 키바인딩 → bold yellow, 설명/본문 → 기본색
if [[ "${1:-}" == "--preview" ]]; then
  "$cheat_cmd" "${2:?title required}" 2>/dev/null | awk '
    /^[^[:space:]]/ && NF > 0 {
      printf "\033[1;36m%s\033[0m\n", $0; next
    }
    /^[[:space:]]+[^[:space:]]/ {
      n = match($0, /[^[:space:]]/)
      indent = substr($0, 1, n - 1)
      rest = substr($0, n)
      m = match(rest, /  /)
      if (m > 0) {
        printf "%s\033[1;33m%s\033[0m%s\n", indent, substr(rest, 1, m - 1), substr(rest, m)
      } else { print }
      next
    }
    { print }
  '
  exit 0
fi

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
    echo "reload($SELF --content)+change-header(  [content 모드] Ctrl-S: title 모드 전환)+change-prompt(content> )+change-nth(..)"
  else
    echo "title" > "$state_file"
    echo "reload($cheat_cmd -l | awk 'NR>1 {print \$1}')+change-header(  [title 모드] Ctrl-S: content 모드 전환)+change-prompt(title> )+change-nth(..)"
  fi
  exit 0
fi

# 기본: fzf 브라우저 실행
state_file="$(mktemp)"
echo "title" > "$state_file"
trap 'rm -f "$state_file"' EXIT

"$cheat_cmd" -l | awk 'NR>1 {print $1}' | "$fzf_cmd" \
  --ansi \
  --header "  [title 모드] Ctrl-S: content 모드 전환" \
  --prompt "title> " \
  --preview "$SELF --preview {1}" \
  --preview-window=right:70% \
  --bind "enter:become($SELF --preview {1} | less -FRX)" \
  --bind "ctrl-s:transform:$SELF --toggle $state_file"
