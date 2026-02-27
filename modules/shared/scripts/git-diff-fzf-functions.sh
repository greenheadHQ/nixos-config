#!/usr/bin/env zsh
# Git Diff → fzf → Neovim 함수
# shell/default.nix에서 source로 로딩됨
# shellcheck shell=bash  # zsh 호환 코드이나 bash 수준 검증

# gdf: git diff 파일을 fzf로 선택하여 nvim으로 열기
# 사용법: gdf [git diff 옵션]
#   gdf              # 워킹 트리 변경 파일
#   gdf --cached     # 스테이징된 파일
#   gdf HEAD~3       # 최근 3커밋 변경 파일
gdf() {
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Git 저장소가 아닙니다" >&2
    return 1
  fi

  local files
  files=$(git diff --name-only "$@" 2>/dev/null)

  if [[ -z "$files" ]]; then
    echo "변경된 파일이 없습니다"
    return 0
  fi

  local selected
  selected=$(echo "$files" | fzf --multi --ansi \
    --preview "git diff $* -- {} 2>/dev/null | delta --paging=never --width=\$FZF_PREVIEW_COLUMNS" \
    --preview-window=right:60% \
    --bind='space:toggle' \
    --header="Space: 다중 선택 / Enter: nvim으로 열기")

  [[ -n "$selected" ]] && echo "$selected" | xargs nvim
}

# gdl: 직전 커밋 파일을 fzf로 선택하여 nvim으로 열기
# 사용법: gdl [커밋 수]
#   gdl        # 직전 1커밋 변경 파일
#   gdl 3      # 최근 3커밋 변경 파일
gdl() {
  gdf "HEAD~${1:-1}..HEAD"
}
