#!/usr/bin/env bash
set -euo pipefail

# 기존 노트를 선택하여 현재 pane에 연결
# Phase 3: 헬퍼 스크립트로 개선된 UX

NOTES_DIR="${HOME}/.tmux/pane-notes"
HELPERS="$HOME/.tmux/scripts/pane-link-helpers.sh"
[ -d "$NOTES_DIR" ] || mkdir -p "$NOTES_DIR"

# 현재 pane id 저장 (이 pane에 링크를 심어야 함)
PANE="$(tmux display-message -p '#{pane_id}')"

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
  selected=$("$HELPERS" list-all | fzf --ansi --prompt="Link note> " \
      --with-nth=1 --delimiter=$'\t' \
      --header="ctrl-p: 현재 프로젝트 | ctrl-a: 전체 | ctrl-d: 삭제 | ctrl-x: 아카이브" \
      --preview 'file=$(echo {} | cut -f2); bat --color=always --style=plain "$file" 2>/dev/null || cat "$file"' \
      --bind "ctrl-p:reload($HELPERS list-current '$CURRENT_REPO')" \
      --bind "ctrl-a:reload($HELPERS list-all)" \
      --bind "ctrl-d:execute-silent(file=\$(echo {} | cut -f2); $HELPERS move-trash \"\$file\")+reload($HELPERS list-all)" \
      --bind "ctrl-x:execute-silent(file=\$(echo {} | cut -f2); $HELPERS move-archive \"\$file\")+reload($HELPERS list-all)")
  set -e

  # ESC로 취소하거나 빈 선택
  [ -z "${selected:-}" ] && exit 0

  # 선택된 노트 연결
  file=$(echo "$selected" | cut -f2)
  tmux set -pt "$PANE" @pane_note_path "$file"
  tmux display-message "Linked: $(basename "$file")"
  exit 0
fi

# fzf 없으면 display-menu fallback (상위 20개)
# yq로 메타데이터 추출
MENU=(display-menu -T "Link Note" -x C -y C)
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
  MENU+=( "$i. $disp_short" "" "run-shell \"tmux set -pt '$PANE' @pane_note_path '$esc'; tmux display-message 'Linked: $(basename "$f")'\"" )
  i=$((i+1))
  [ "$i" -gt 20 ] && break
done < <(find "$NOTES_DIR" -mindepth 2 -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" -print0 2>/dev/null)

tmux "${MENU[@]}" >/dev/null 2>&1 || true
