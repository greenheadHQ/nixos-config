#!/usr/bin/env bash
set -euo pipefail

# tmux-resurrect hook: 모든 pane의 커스텀 변수 저장
# 저장 위치: ~/.local/share/tmux/resurrect/pane_vars.txt
# 형식: var_type|line_num|value (순서 기반 매핑)

VARS_FILE="${HOME}/.local/share/tmux/resurrect/pane_vars.txt"
mkdir -p "$(dirname "$VARS_FILE")"

: > "$VARS_FILE"  # 파일 초기화

line_num=0

# process substitution으로 메인 셸에서 실행 (서브셸 문제 방지)
while read -r pane_id; do
  note_path="$(tmux display-message -t "$pane_id" -p '#{@pane_note_path}' 2>/dev/null || true)"
  pane_title="$(tmux display-message -t "$pane_id" -p '#{@custom_pane_title}' 2>/dev/null || true)"

  # 값이 있는 경우만 저장 (line_num으로 순서 기록)
  [ -n "$note_path" ] && echo "note_path|$line_num|$note_path" >> "$VARS_FILE"
  [ -n "$pane_title" ] && echo "pane_title|$line_num|$pane_title" >> "$VARS_FILE"

  line_num=$((line_num + 1))
done < <(tmux list-panes -a -F '#{pane_id}')

tmux display-message "Pane variables saved ($line_num panes)"
