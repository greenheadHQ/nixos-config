#!/usr/bin/env bash
set -euo pipefail

# tmux-resurrect hook: 저장된 pane 변수 복원
# 순서 기반 매핑: 저장 시 line_num과 복원 시 pane 순서를 매칭

VARS_FILE="${HOME}/.local/share/tmux/resurrect/pane_vars.txt"

[ -f "$VARS_FILE" ] || exit 0

# 현재 pane 목록을 배열로 저장 (순서 유지)
mapfile -t pane_ids < <(tmux list-panes -a -F '#{pane_id}')

restored=0

while IFS='|' read -r var_type line_num value; do
  [ -z "$var_type" ] && continue

  # line_num으로 해당 pane_id 찾기
  pane_id="${pane_ids[$line_num]:-}"
  [ -z "$pane_id" ] && continue

  case "$var_type" in
    note_path)
      tmux set-option -t "$pane_id" @pane_note_path "$value" 2>/dev/null || true
      restored=$((restored + 1))
      ;;
    pane_title)
      tmux set-option -t "$pane_id" @custom_pane_title "$value" 2>/dev/null || true
      restored=$((restored + 1))
      ;;
  esac
done < "$VARS_FILE"

# 상태 표시줄 강제 갱신 (border-format 반영)
tmux refresh-client -S 2>/dev/null || true

tmux display-message "Pane variables restored ($restored vars)"
