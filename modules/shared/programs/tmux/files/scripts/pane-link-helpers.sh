#!/usr/bin/env bash
# fzf에서 직접 호출 가능한 헬퍼 스크립트
# export -f는 bash 전용이고 서브셸에서 불안정 → 별도 헬퍼 스크립트로 분리
set -euo pipefail

NOTES_DIR="${HOME}/.tmux/pane-notes"

# yq로 메타데이터 추출
# 형식: MM-DD | [repo] 제목 #태그1 #태그2 \t 파일경로
format_entry() {
  local file="$1"
  local repo
  repo=$(basename "$(dirname "$file")")

  # yq -r '.field // ""' 문법 사용 (yq 4.x 호환)
  local title
  title=$(yq -r '.title // ""' "$file" 2>/dev/null || echo "")
  local tags
  tags=$(yq -r '.tags // [] | join(" #")' "$file" 2>/dev/null || echo "")
  local created
  created=$(yq -r '.created // ""' "$file" 2>/dev/null || echo "")

  # fallback: title 없으면 파일명
  [ -z "$title" ] && title=$(basename "$file" .md)

  # 날짜 파싱: MM-DD
  local date_part="${created:5:5}"  # YYYY-MM-DD에서 MM-DD 추출
  [ -z "$date_part" ] && date_part="--/--"

  # 태그 형식화 (밝은 주황색으로 표시)
  if [ -n "$tags" ]; then
    # 각 태그에 ANSI 색상 코드 추가 (bright orange: \033[38;5;214m, reset: \033[0m)
    tags=$(echo " #$tags" | sed 's/#\([^ ]*\)/\\033[38;5;214m#\1\\033[0m/g')
  fi

  printf "%s | [%s] %s%b\t%s\n" "$date_part" "$repo" "$title" "$tags" "$file"
}

# 모든 노트 목록 (최신순)
list_all() {
  while IFS= read -r -d '' f; do
    format_entry "$f"
  done < <(find "$NOTES_DIR" -mindepth 2 -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" -print0 2>/dev/null) | sort -r
}

# 현재 프로젝트 노트만
list_current() {
  local repo="${1:-}"
  [ -z "$repo" ] && return
  [ ! -d "$NOTES_DIR/$repo" ] && return
  while IFS= read -r -d '' f; do
    format_entry "$f"
  done < <(find "$NOTES_DIR/$repo" -name "*.md" -print0 2>/dev/null) | sort -r
}

# _trash로 이동 (소프트 삭제)
move_to_trash() {
  local file="$1"
  [ ! -f "$file" ] && return 1
  mkdir -p "$NOTES_DIR/_trash"
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  mv "$file" "$NOTES_DIR/_trash/${ts}_$(basename "$file")"
}

# _archive로 이동
move_to_archive() {
  local file="$1"
  [ ! -f "$file" ] && return 1
  mkdir -p "$NOTES_DIR/_archive"
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  mv "$file" "$NOTES_DIR/_archive/${ts}_$(basename "$file")"
}

# 명령어 인터페이스 (fzf --bind에서 호출)
case "${1:-}" in
  list-all)       list_all ;;
  list-current)   shift; list_current "$@" ;;
  move-trash)     shift; move_to_trash "$@" ;;
  move-archive)   shift; move_to_archive "$@" ;;
  format)         shift; format_entry "$@" ;;
  *)              echo "Usage: $0 {list-all|list-current <repo>|move-trash <file>|move-archive <file>|format <file>}" >&2; exit 1 ;;
esac
