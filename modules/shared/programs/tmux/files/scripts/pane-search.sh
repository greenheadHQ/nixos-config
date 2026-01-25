#!/usr/bin/env bash
set -euo pipefail

# ripgrep + fzf로 노트 내용 검색
# 선택 시 해당 파일:라인으로 에디터 점프

NOTES_DIR="${HOME}/.tmux/pane-notes"

# ripgrep 필수
if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep(rg)이 설치되어 있지 않습니다."
  read -rp "Press Enter to close..."
  exit 1
fi

# fzf 필수
if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf가 설치되어 있지 않습니다."
  read -rp "Press Enter to close..."
  exit 1
fi

# fzf 내 실시간 검색 (change:reload 패턴)
# {q} = 현재 쿼리, 타이핑할 때마다 rg 재실행
# ripgrep glob: 포함 glob(*.md) 먼저, 제외 glob(!_archive/**) 나중에
# 상대경로에서만 정상 동작하므로 cd 후 검색, 결과는 절대경로로 변환
set +e
selected=$(: | fzf --ansi --disabled --prompt='Search> ' \
    --header="타이핑하면 실시간 검색 | Enter: 선택한 라인으로 이동" \
    --bind "change:reload:cd '$NOTES_DIR' && rg --line-number --color=always -g '*.md' -g '!_archive/**' -g '!_trash/**' {q} . 2>/dev/null | sed \"s|^\\./|$NOTES_DIR/|\" || true" \
    --preview 'line=$(echo {} | cut -d: -f1-2); file=$(echo {} | cut -d: -f1); linenum=$(echo {} | cut -d: -f2); bat --color=always --highlight-line="$linenum" --line-range="$((linenum>5?linenum-5:1)):$((linenum+10))" "$file" 2>/dev/null || head -20 "$file"' \
    --preview-window=right:60%)
set -e

[ -z "${selected:-}" ] && exit 0

# 파일:라인 파싱
file=$(echo "$selected" | cut -d: -f1)
line=$(echo "$selected" | cut -d: -f2)

# 에디터로 해당 라인 점프
"${EDITOR:-vim}" "+$line" "$file"
