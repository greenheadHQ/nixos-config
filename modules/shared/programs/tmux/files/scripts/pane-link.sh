#!/usr/bin/env bash
set -euo pipefail

# 통합 검색 스크립트
# - fzf 모드: 제목/태그 퍼지 필터링
# - rg 모드: ripgrep 내용 검색
# - Ctrl-/: 모드 전환
# - Enter: 노트 연결 (pane-link 동작)
# - Ctrl-O: 열기만 (pane-peek 동작)

NOTES_DIR="${HOME}/.tmux/pane-notes"
HELPERS="$HOME/.tmux/scripts/pane-helpers.sh"
[ -d "$NOTES_DIR" ] || mkdir -p "$NOTES_DIR"

# 필수 도구 체크
command -v fzf >/dev/null 2>&1 || { echo "fzf가 필요합니다."; read -rp "Press Enter..."; exit 1; }
command -v rg >/dev/null 2>&1 || { echo "ripgrep(rg)이 필요합니다."; read -rp "Press Enter..."; exit 1; }
[ -x "$HELPERS" ] || { echo "헬퍼 스크립트가 없습니다: $HELPERS"; read -rp "Press Enter..."; exit 1; }

# 현재 pane id 저장
PANE="$(tmux display-message -p '#{pane_id}')"

# 현재 프로젝트 감지
REPO=$(cd "$(tmux display-message -p '#{pane_current_path}')" && \
  basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# 노트 개수 확인
note_count=$(find "$NOTES_DIR" -mindepth 2 -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$note_count" -eq 0 ]; then
  echo "노트가 없습니다. prefix+N으로 새 노트를 생성하세요."
  read -rp "Press Enter to close..."
  exit 0
fi

# 상태 관리용 임시 파일
MODE_FILE=$(mktemp)
QUERY_FILE=$(mktemp)
SORT_FILE=$(mktemp)
echo "fzf" > "$MODE_FILE"
echo "created" > "$SORT_FILE"
trap 'rm -f "$MODE_FILE" "$QUERY_FILE" "$SORT_FILE"' EXIT

# 헤더
HEADER="Ctrl-/: 모드전환 | Ctrl-O: 열기만 | Ctrl-P: 프로젝트 | Ctrl-A: 전체
Ctrl-S: 정렬 | Ctrl-D: 휴지통 | Ctrl-X: 아카이브 | Tab: 미리보기"

# fzf 실행
set +e
selected=$("$HELPERS" list-all | fzf --ansi \
    --prompt='Link note [fzf/created]> ' \
    --with-nth=1 --delimiter=$'\t' \
    --header="$HEADER" \
    --preview "$HELPERS preview \$(echo {} | cut -f2) @$QUERY_FILE @$MODE_FILE" \
    --preview-window=up:60% \
    --bind "tab:preview-down,shift-tab:preview-up" \
    --bind "ctrl-/:transform:$HELPERS toggle-mode '$MODE_FILE' '$QUERY_FILE' '$SORT_FILE' {q}" \
    --bind "change:transform:$HELPERS handle-change '$MODE_FILE' '$QUERY_FILE' '$SORT_FILE' {q}" \
    --bind "ctrl-s:transform:$HELPERS toggle-sort '$MODE_FILE' '$SORT_FILE'" \
    --bind "ctrl-a:transform:$HELPERS handle-ctrl-a '$MODE_FILE' '$SORT_FILE'" \
    --bind "ctrl-p:reload($HELPERS list-current '$REPO')+change-prompt(Link note [$REPO]> )" \
    --bind "ctrl-d:execute-silent($HELPERS move-trash \$(echo {} | cut -f2))+reload($HELPERS list-all \$(cat '$SORT_FILE'))" \
    --bind "ctrl-x:execute-silent($HELPERS move-archive \$(echo {} | cut -f2))+reload($HELPERS list-all \$(cat '$SORT_FILE'))" \
    --bind "ctrl-o:execute(
      file=\$(echo {} | cut -f2)
      mode=\$(cat '$MODE_FILE')
      if [ \"\$mode\" = 'rg' ]; then
        line=\$($HELPERS first-line \"\$file\" @$QUERY_FILE)
        \${EDITOR:-vim} +\$line \"\$file\"
      else
        \${EDITOR:-vim} \"\$file\"
      fi
    )+abort" \
    --expect=enter)
fzf_exit=$?
set -e

# ESC로 취소 (exit code 130)
[ $fzf_exit -eq 130 ] && exit 0
[ -z "${selected:-}" ] && exit 0

# expect로 인해 첫 줄은 눌린 키, 둘째 줄은 선택 항목
key=$(echo "$selected" | head -1)
selection=$(echo "$selected" | tail -n +2)

[ -z "$selection" ] && exit 0

file=$(echo "$selection" | cut -f2)
mode=$(cat "$MODE_FILE")

# Enter 시 노트 연결
if [ "$key" = "enter" ]; then
  tmux set -pt "$PANE" @pane_note_path "$file"

  # rg 모드면 라인 점프
  if [ "$mode" = "rg" ]; then
    line=$("$HELPERS" first-line "$file" "@$QUERY_FILE")
    "${EDITOR:-vim}" "+$line" "$file"
  else
    tmux display-message "Linked: $(basename "$file")"
  fi
fi
