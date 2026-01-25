#!/usr/bin/env bash
set -euo pipefail

# 기존 노트를 연결 없이 편집기로 열기
# pane-link.sh와 다르게 @pane_note_path를 설정하지 않음
# Phase 3: 헬퍼 스크립트로 개선된 UX

NOTES_DIR="${HOME}/.tmux/pane-notes"
HELPERS="$HOME/.tmux/scripts/pane-link-helpers.sh"
[ -d "$NOTES_DIR" ] || mkdir -p "$NOTES_DIR"

# 현재 프로젝트 감지
CURRENT_REPO=$(cd "$(tmux display-message -p '#{pane_current_path}')" && \
  basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# 노트 개수 확인
note_count=$(find "$NOTES_DIR" -mindepth 2 -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$note_count" -eq 0 ]; then
  echo "노트가 없습니다. prefix+N으로 새 노트를 생성하세요."
  read -rp "Press Enter to close..."
  exit 0
fi

use_fzf() { command -v fzf >/dev/null 2>&1 && fzf --version >/dev/null 2>&1; }

if use_fzf; then
  # 헬퍼 스크립트 존재 확인
  if [ ! -x "$HELPERS" ]; then
    echo "헬퍼 스크립트가 없습니다: $HELPERS"
    read -rp "Press Enter to close..."
    exit 1
  fi

  # fzf 실행 (개선된 UX)
  set +e
  selected=$("$HELPERS" list-all | fzf --ansi --prompt="Peek note> " \
      --with-nth=1 --delimiter=$'\t' \
      --header=$'Tab: 미리보기 아래로 스크롤 | S-Tab: 미리보기 위로 스크롤\nctrl-p: 현재 프로젝트 노트로 필터링 | ctrl-a: 모든 노트 보기\nctrl-d: 휴지통으로 보내기(_trash) | ctrl-x: 아카이브로 보내기(_archive)' \
      --preview 'file=$(echo {} | cut -f2); bat --color=always --style=plain "$file" 2>/dev/null || cat "$file"' \
      --preview-window=up:60% \
      --bind "tab:preview-down,shift-tab:preview-up" \
      --bind "ctrl-p:reload($HELPERS list-current '$CURRENT_REPO')" \
      --bind "ctrl-a:reload($HELPERS list-all)" \
      --bind "ctrl-d:execute-silent(file=\$(echo {} | cut -f2); $HELPERS move-trash \"\$file\")+reload($HELPERS list-all)" \
      --bind "ctrl-x:execute-silent(file=\$(echo {} | cut -f2); $HELPERS move-archive \"\$file\")+reload($HELPERS list-all)")
  set -e

  # ESC로 취소하거나 빈 선택
  [ -z "${selected:-}" ] && exit 0

  # ★ 연결 없이 에디터로 열기만
  file=$(echo "$selected" | cut -f2)
  "${EDITOR:-vim}" "$file"
  exit 0
fi

# fzf 없으면 display-menu fallback (상위 20개)
# yq로 메타데이터 추출
MENU=(display-menu -T "Peek Note" -x C -y C)
i=1
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  repo=$(basename "$(dirname "$f")")
  title=$(yq -r '.title // ""' "$f" 2>/dev/null || echo "")
  [ -z "$title" ] && title=$(basename "$f" .md)
  disp="[$repo] $title"
  disp_short="${disp:0:50}"
  [ "${#disp}" -gt 50 ] && disp_short="${disp_short}..."
  esc="$(printf "%s" "$f" | sed "s/'/'\\\\''/g")"
  # 에디터로 열기 ($EDITOR 또는 vim)
  MENU+=( "$i. $disp_short" "" "run-shell \"\\\"\\\${EDITOR:-vim}\\\" '$esc'\"" )
  i=$((i+1))
  [ "$i" -gt 20 ] && break
done < <(find "$NOTES_DIR" -mindepth 2 -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" -print0 2>/dev/null)

tmux "${MENU[@]}" >/dev/null 2>&1 || true
