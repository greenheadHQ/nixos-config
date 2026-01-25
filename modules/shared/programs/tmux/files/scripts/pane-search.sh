#!/usr/bin/env bash
set -euo pipefail

NOTES_DIR="${HOME}/.tmux/pane-notes"
HELPERS="$HOME/.tmux/scripts/pane-search-helpers.sh"

# 필수 도구 체크
command -v rg >/dev/null 2>&1 || { echo "ripgrep(rg)이 필요합니다."; read -rp "Press Enter..."; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf가 필요합니다."; read -rp "Press Enter..."; exit 1; }
[ -x "$HELPERS" ] || { echo "헬퍼 스크립트가 없습니다: $HELPERS"; read -rp "Press Enter..."; exit 1; }

# 노트 개수 확인
note_count=$(find "$NOTES_DIR" -mindepth 2 -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" 2>/dev/null | wc -l | tr -d ' ')
if [ "$note_count" -eq 0 ]; then
  echo "노트가 없습니다. prefix+N으로 새 노트를 생성하세요."
  read -rp "Press Enter to close..."
  exit 0
fi

# 쿼리 저장용 파일 (쉘 이스케이프 문제 완전 회피)
# 헬퍼에 @/path/to/file 형식으로 전달하면 파일에서 쿼리를 읽음
QUERY_FILE=$(mktemp)
trap 'rm -f "$QUERY_FILE"' EXIT

# fzf 실행
# - 초기: 전체 노트 목록 (list-all)
# - 타이핑 시: 검색 결과로 교체 (search @파일)
# - {q}를 직접 사용하지 않고, fzf가 파일에 저장 후 헬퍼가 읽음
set +e
selected=$("$HELPERS" list-all | fzf --ansi --disabled --prompt='Search> ' \
    --with-nth=1 --delimiter=$'\t' \
    --header=$'타이핑하면 검색 | Enter: 파일 열기 | 빈 검색어: 전체 목록' \
    --bind "change:reload:printf '%s' {q} > '$QUERY_FILE'; $HELPERS search @$QUERY_FILE" \
    --preview "$HELPERS preview \$(echo {} | cut -f2) @$QUERY_FILE" \
    --preview-window=right:60%)
set -e

[ -z "${selected:-}" ] && exit 0

file=$(echo "$selected" | cut -f2)
line=$("$HELPERS" first-line "$file" "@$QUERY_FILE")

"${EDITOR:-vim}" "+$line" "$file"
