#!/usr/bin/env bash
set -euo pipefail

# cheat + fzf 브라우징 (tmux display-popup용)
# display-popup 셸의 PATH 불완전 방지를 위해 절대 경로 resolve
cheat_cmd="$(command -v cheat 2>/dev/null || echo cheat)"
fzf_cmd="$(command -v fzf 2>/dev/null || echo fzf)"

"$cheat_cmd" -l | "$fzf_cmd" \
  --header-lines=1 \
  --preview "$cheat_cmd {1}" \
  --preview-window=right:70% \
  --bind "enter:become($cheat_cmd {1})"
