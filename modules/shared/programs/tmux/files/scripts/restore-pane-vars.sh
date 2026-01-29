#!/usr/bin/env bash
set -euo pipefail

debug() {
  if [ "${TMUX_NOTE_DEBUG:-0}" = "1" ]; then
    printf "[DEBUG %s] %s\n" "$(basename "$0")" "$*" >&2
  fi
}

# tmux-resurrect hook: 저장된 pane 변수 복원
# 식별자 기반 매핑: session:window.pane → pane_id (순서 독립)
# 부가 효과: mapfile 제거로 bash 3.x 호환성도 개선

VARS_FILE="${HOME}/.local/share/tmux/resurrect/pane_vars.txt"
[ -f "$VARS_FILE" ] || exit 0

# ★ pane 목록을 한 번만 가져옴 (O(N) → 루프 내 tmux 호출 제거)
pane_map=$(tmux list-panes -a \
  -F '#{session_name}:#{window_index}.#{pane_index} #{pane_id}')

restored=0

# ⚠️ 스크립트 최상위 while 루프: `local` 사용 불가
while IFS='|' read -r var_type ident value; do
  [ -z "$var_type" ] && continue

  target_pane=$(printf '%s\n' "$pane_map" | awk -v id="$ident" '$1 == id { print $2 }')
  [ -z "$target_pane" ] && { debug "no match for ident=$ident"; continue; }

  case "$var_type" in
    note_path)
      tmux set-option -t "$target_pane" @pane_note_path "$value" 2>/dev/null || true
      restored=$((restored + 1))
      ;;
    pane_title)
      tmux set-option -t "$target_pane" @custom_pane_title "$value" 2>/dev/null || true
      restored=$((restored + 1))
      ;;
  esac
  debug "restored $var_type for $ident → $target_pane"
done < "$VARS_FILE"

tmux refresh-client -S 2>/dev/null || true
tmux display-message "Pane variables restored ($restored vars)"
