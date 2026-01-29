#!/usr/bin/env bash
set -euo pipefail

debug() {
  if [ "${TMUX_NOTE_DEBUG:-0}" = "1" ]; then
    printf "[DEBUG %s] %s\n" "$(basename "$0")" "$*" >&2
  fi
}

# tmux-resurrect hook: 모든 pane의 커스텀 변수 저장
# 형식: var_type|session:window.pane|value (순서 독립)
# 한계: tmux-resurrect가 세션 이름/인덱스를 변경하면(예: 동명 세션 충돌 → main_0)
#       해당 pane의 변수 복원이 건너뛰어질 수 있음. line_num 순서 기반보다 견고하지만 완벽하지는 않음.

VARS_FILE="${HOME}/.local/share/tmux/resurrect/pane_vars.txt"
mkdir -p "$(dirname "$VARS_FILE")"
: > "$VARS_FILE"

pane_count=0

# ⚠️ 스크립트 최상위 while 루프: `local` 사용 불가 (bash에서 local은 함수 내부만 허용)
while read -r pane_id; do
  note_path="$(tmux display-message -t "$pane_id" -p '#{@pane_note_path}' 2>/dev/null || true)"
  pane_title="$(tmux display-message -t "$pane_id" -p '#{@custom_pane_title}' 2>/dev/null || true)"
  ident="$(tmux display-message -t "$pane_id" -p '#{session_name}:#{window_index}.#{pane_index}')"

  debug "pane=$pane_id ident=$ident note=$note_path title=$pane_title"

  [ -n "$note_path" ] && echo "note_path|$ident|$note_path" >> "$VARS_FILE"
  [ -n "$pane_title" ] && echo "pane_title|$ident|$pane_title" >> "$VARS_FILE"

  pane_count=$((pane_count + 1))
done < <(tmux list-panes -a -F '#{pane_id}')

tmux display-message "Pane variables saved ($pane_count panes)"
