#!/usr/bin/env bash
set -euo pipefail

# 기존 노트를 연결 없이 편집기로 열기
# pane-link.sh와 다르게 @pane_note_path를 설정하지 않음

NOTES_DIR="${HOME}/.tmux/pane-notes"
[ -d "$NOTES_DIR" ] || mkdir -p "$NOTES_DIR"

list_files(){ local n="${1:-30}"; (cd "$NOTES_DIR" && ls -1t *.md 2>/dev/null | head -n "$n" || true); }

use_fzf(){ command -v fzf >/dev/null 2>&1 && fzf --version >/dev/null 2>&1; }

if use_fzf; then
  # fzf로 선택 후 에디터로 열기 (pane-link.sh와 동일한 패턴)
  tmux display-popup -E -w 80% -h 80% \
    "cd \"$NOTES_DIR\" 2>/dev/null || exit 0;
     sel=\$(ls -1t *.md 2>/dev/null | fzf --prompt='Peek note> ' --height=100% --reverse --preview 'bat --color=always --style=plain {} 2>/dev/null || cat {}') || exit 0;
     \"\${EDITOR:-vim}\" \"$NOTES_DIR/\$sel\"" \
    >/dev/null 2>&1 || true
  exit 0
fi

# fzf 없으면 display-menu로 상위 30개
files="$(list_files 30)"
[ -z "${files:-}" ] && { tmux display-message "노트가 없습니다."; exit 0; }

MENU=(display-menu -T "Peek Note" -x C -y C)
i=1
while IFS= read -r f; do
  [ -z "$f" ] && continue
  disp="$(printf "%s" "$f" | cut -c1-60)"; [ "${#f}" -gt 60 ] && disp="${disp}…"
  esc="$(printf "%s" "$NOTES_DIR/$f" | sed "s/'/'\\\\''/g")"
  # 에디터로 열기 ($EDITOR 또는 vim)
  MENU+=( "$i. $disp" "" "run-shell \"\\\"\\\${EDITOR:-vim}\\\" '$esc'\"" )
  i=$((i+1))
done <<< "$files"

tmux "${MENU[@]}" >/dev/null 2>&1 || true
