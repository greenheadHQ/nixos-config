#!/usr/bin/env bash
set -euo pipefail

NOTES_DIR="${HOME}/.tmux/pane-notes"
[ -d "$NOTES_DIR" ] || mkdir -p "$NOTES_DIR"

# ★ 현재 pane id 저장(이 pane에 링크를 심어야 함)
PANE="$(tmux display-message -p '#{pane_id}')"

list_files(){ local n="${1:-30}"; (cd "$NOTES_DIR" && ls -1t *.md 2>/dev/null | head -n "$n" || true); }

use_fzf(){ command -v fzf >/dev/null 2>&1 && fzf --version >/dev/null 2>&1; }

if use_fzf; then
  tmux display-popup -E -w 80% -h 80% \
    "cd \"$NOTES_DIR\" 2>/dev/null || exit 0;
     sel=\$(ls -1t *.md 2>/dev/null | fzf --prompt='Link note> ' --height=100% --reverse --preview 'bat --color=always --style=plain {} 2>/dev/null || cat {}') || exit 0;
     # ★ 원래 pane(-t \"$PANE\")에 옵션 설정
     tmux set -pt \"$PANE\" @pane_note_path \"$NOTES_DIR/\$sel\";
     tmux display-message \"🔗 Linked: \$sel\"" \
    >/dev/null 2>&1 || true
  exit 0
fi

files="$(list_files 30)"
[ -z "${files:-}" ] && { tmux display-message "노트가 없습니다."; exit 0; }

MENU=(display-menu -T "Link Note" -x C -y C)
i=1
printf "%s\n" "$files" | while IFS= read -r f; do
  [ -z "$f" ] && continue
  disp="$(printf "%s" "$f" | cut -c1-60)"; [ "${#f}" -gt 60 ] && disp="${disp}…"
  esc="$(printf "%s" "$NOTES_DIR/$f" | sed "s/'/'\\\\''/g")"
  # ★ 여기서도 -t "$PANE" 로 원래 pane에 지정
  MENU+=( "$i. $disp" "" "run-shell \"tmux set -pt '$PANE' @pane_note_path '$esc'; tmux display-message '🔗 Linked: $f'\"" )
  i=$((i+1))
done

tmux "${MENU[@]}" >/dev/null 2>&1 || true

# #!/usr/bin/env bash
# set -euo pipefail

# NOTES_DIR="${HOME}/.tmux/pane-notes"
# mkdir -p "$NOTES_DIR"

# # 최근 수정순 목록(상위 N)
# list_files(){
#   local limit="${1:-30}"
#   # 공백/특수문자 안전: find -print0 | xargs -0 stat … 는 BSD/gnu 차이가 있어 간단히 ls 활용
#   # macOS 기본 ls는 -t(시간순), -1(한 줄) 지원
#   (cd "$NOTES_DIR" && ls -1t *.md 2>/dev/null | head -n "$limit")
# }

# # 1) fzf가 있으면 fzf로 선택
# if command -v fzf >/dev/null 2>&1; then
#   # 팝업에서 fzf 실행
#   tmux display-popup -E -w 80% -h 80% \
#     "cd \"$NOTES_DIR\" || exit 0; sel=\$(ls -1t *.md 2>/dev/null | fzf --prompt='Link note> ' --height=100% --reverse) || exit 0; tmux set -p @pane_note_path \"$NOTES_DIR/\$sel\"; tmux display-message \"🔗 Linked: \$sel\""
#   exit 0
# fi

# # 2) fzf 없으면 display-menu로 상위 30개
# files="$(list_files 30)"
# [ -z "$files" ] && { tmux display-message "노트가 없습니다."; exit 0; }

# MENU=(display-menu -T "Link Note" -x C -y C)
# i=1
# # Bash 3.x: while-read
# echo "$files" | while IFS= read -r f; do
#   [ -z "$f" ] && continue
#   disp="$(printf "%s" "$f" | cut -c1-60)"; [ "${#f}" -gt 60 ] && disp="${disp}…"
#   esc_path="$(printf "%s" "$NOTES_DIR/$f" | sed "s/'/'\\\\''/g")"
#   MENU+=( "$i. $disp" "" "run-shell \"tmux set -p @pane_note_path '$esc_path'; tmux display-message '🔗 Linked: $f'\"" )
#   i=$((i+1))
# done

# tmux "${MENU[@]}" >/dev/null 2>&1 || true