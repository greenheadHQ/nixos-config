#!/usr/bin/env bash
set -euo pipefail

debug() {
  if [ "${TMUX_NOTE_DEBUG:-0}" = "1" ]; then
    printf "[DEBUG %s] %s\n" "$(basename "$0")" "$*" >&2
  fi
}

# 휴지통/아카이브에서 노트 복원
# 1. 소스 선택 (휴지통 vs 아카이브)
# 2. 파일 선택
# 3. 복원 위치 선택 (원래 프로젝트 자동 감지 또는 수동 선택)

NOTES_DIR="${HOME}/.tmux/pane-notes"
HELPERS="$HOME/.tmux/scripts/pane-helpers.sh"

# 필수 도구 체크
command -v fzf >/dev/null 2>&1 || { echo "fzf가 필요합니다."; read -rp "Press Enter..."; exit 1; }
[ -x "$HELPERS" ] || { echo "헬퍼 스크립트가 없습니다: $HELPERS"; read -rp "Press Enter..."; exit 1; }

# 1. 소스 선택 (휴지통 vs 아카이브)
set +e
source=$(printf "휴지통 (_trash)\n아카이브 (_archive)" | fzf --prompt="복원 위치> " --height=5 --no-info)
fzf_exit=$?
set -e

[ $fzf_exit -eq 130 ] && exit 0
[ -z "$source" ] && exit 0

case "$source" in
  *trash*)   list_cmd="list-trash"; src_dir="_trash" ;;
  *archive*) list_cmd="list-archive"; src_dir="_archive" ;;
  *)         exit 0 ;;
esac

# 소스 디렉토리 확인
if [ ! -d "$NOTES_DIR/$src_dir" ] || [ -z "$(find "$NOTES_DIR/$src_dir" -name "*.md" 2>/dev/null)" ]; then
  echo "${src_dir}에 복원할 노트가 없습니다."
  read -rp "Press Enter to close..."
  exit 0
fi

# 2. 파일 선택
set +e
selected=$("$HELPERS" $list_cmd | fzf --ansi \
  --prompt="복원할 노트> " \
  --with-nth=1 --delimiter=$'\t' \
  --preview 'bat --color=always --style=plain $(echo {} | cut -f2) 2>/dev/null || cat $(echo {} | cut -f2)' \
  --preview-window=up:60%)
fzf_exit=$?
set -e

[ $fzf_exit -eq 130 ] && exit 0
[ -z "$selected" ] && exit 0

file=$(echo "$selected" | cut -f2)

# 3. 원래 프로젝트 자동 감지 (YAML frontmatter의 repo 필드)
original_repo=$(yq --front-matter=extract -r '.repo // ""' "$file" 2>/dev/null || echo "")
target_repo=""

if [ -n "$original_repo" ] && [ -d "$NOTES_DIR/$original_repo" ]; then
  # 원래 프로젝트 존재 -> 자동 복원 제안
  set +e
  confirm=$(printf "원래 위치로 복원: $original_repo\n다른 프로젝트 선택" | fzf --prompt="복원 위치> " --height=5 --no-info)
  fzf_exit=$?
  set -e

  [ $fzf_exit -eq 130 ] && exit 0

  if [[ "$confirm" == *"원래"* ]]; then
    target_repo="$original_repo"
  fi
fi

# 4. 프로젝트 선택 (자동 감지 실패 또는 다른 위치 선택 시)
if [ -z "$target_repo" ]; then
  repos=$(find "$NOTES_DIR" -mindepth 1 -maxdepth 1 -type d ! -name "_*" -exec basename {} \; | sort)

  if [ -z "$repos" ]; then
    echo "복원할 프로젝트가 없습니다. 먼저 노트를 생성하세요."
    read -rp "Press Enter to close..."
    exit 0
  fi

  set +e
  target_repo=$(echo "$repos" | fzf --prompt="복원할 프로젝트> " --height=10)
  fzf_exit=$?
  set -e

  [ $fzf_exit -eq 130 ] && exit 0
  [ -z "$target_repo" ] && exit 0
fi

# 5. 파일명 충돌 확인
# 타임스탬프 정규식: YYYYMMDD-HHMMSS_ 형식만 제거
original_name=$(basename "$file" | sed 's/^[0-9]\{8\}-[0-9]\{6\}_//')
target_path="$NOTES_DIR/$target_repo/$original_name"

if [ -f "$target_path" ]; then
  echo "동일한 이름의 파일이 이미 존재합니다: $target_path"

  set +e
  action=$(printf "덮어쓰기\n다른 이름으로 저장\n취소" | fzf --prompt="선택> " --height=5 --no-info)
  fzf_exit=$?
  set -e

  [ $fzf_exit -eq 130 ] && exit 0

  case "$action" in
    "덮어쓰기") ;;
    "다른 이름"*)
      # fzf --print-query로 파일명 입력
      set +e
      new_name=$(echo "" | fzf --print-query --prompt="새 파일명 (확장자 제외): " \
        --header="Enter로 확인" | head -1)
      fzf_exit=$?
      set -e

      [ $fzf_exit -eq 130 ] && exit 0
      [ -z "$new_name" ] && exit 0

      original_name="${new_name}.md"
      target_path="$NOTES_DIR/$target_repo/$original_name"
      ;;
    *) exit 0 ;;
  esac
fi

# 6. 복원 실행
mv "$file" "$target_path"
echo "복원 완료: $target_path"
read -rp "Press Enter to close..."
