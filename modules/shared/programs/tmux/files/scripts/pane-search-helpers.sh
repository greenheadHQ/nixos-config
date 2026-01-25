#!/usr/bin/env bash
set -euo pipefail

# pane-search.sh용 헬퍼 스크립트
# NOTE: format_search_entry는 pane-link-helpers.sh의 format_entry와 유사하나,
#       검색 특화 로직(매칭 수 표시)이 있어 별도 구현

NOTES_DIR="${HOME}/.tmux/pane-notes"

# 검색 결과 형식: 표시텍스트\t파일경로
format_search_entry() {
  local file="$1"
  local match_count="${2:-}"  # 검색 시에만 전달

  local repo title created date_part
  repo=$(basename "$(dirname "$file")")

  title=$(yq -r '.title // ""' "$file" 2>/dev/null || echo "")
  [ -z "$title" ] && title=$(basename "$file" .md)

  created=$(yq -r '.created // ""' "$file" 2>/dev/null || echo "")
  date_part="${created:5:5}"
  [ -z "$date_part" ] && date_part="--/--"

  # 매칭 수가 있으면 표시, 없으면 생략
  if [ -n "$match_count" ]; then
    local match_text
    [ "$match_count" -eq 1 ] && match_text="1 match" || match_text="${match_count} matches"
    printf "%s | [%s] %s (%s)\t%s\n" "$date_part" "$repo" "$title" "$match_text" "$file"
  else
    printf "%s | [%s] %s\t%s\n" "$date_part" "$repo" "$title" "$file"
  fi
}

# 전체 노트 목록 (초기 화면용, 최신순)
list_all() {
  while IFS= read -r -d '' f; do
    format_search_entry "$f"
  done < <(find "$NOTES_DIR" -mindepth 2 -name "*.md" \
    ! -path "*/_archive/*" ! -path "*/_trash/*" -print0 2>/dev/null) | sort -r
}

# 검색 (파일별 그룹화, 절대경로 사용)
# $1: 쿼리 문자열 또는 쿼리 파일 경로 (@로 시작하면 파일)
search() {
  local input="$1"
  local query

  # @로 시작하면 파일에서 읽기 (쉘 이스케이프 문제 회피)
  if [[ "$input" == @* ]]; then
    local query_file="${input:1}"
    query=$(cat "$query_file" 2>/dev/null || echo "")
  else
    query="$input"
  fi

  # 빈 쿼리 = 전체 목록 (초기 화면과 동일)
  if [ -z "$query" ]; then
    list_all
    return 0
  fi

  # rg --count 출력: /path/file.md:3
  # 파일명에 :가 포함될 수 있으므로 마지막 : 기준으로 파싱
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local file="${line%:*}"    # 마지막 : 앞부분 = 파일 경로
    local count="${line##*:}"  # 마지막 : 뒷부분 = 매칭 수
    format_search_entry "$file" "$count"
  done < <(rg --count -g '*.md' -g '!**/_archive/**' -g '!**/_trash/**' \
    "$query" "$NOTES_DIR" 2>/dev/null || true) | sort -r
}

# Preview: 첫 매칭 라인 하이라이트 (bat --highlight-line은 단일 값만 지원)
# $1: 파일 경로
# $2: 쿼리 문자열 또는 쿼리 파일 경로 (@로 시작하면 파일)
preview() {
  local file="$1"
  local input="${2:-}"
  local query

  # @로 시작하면 파일에서 읽기
  if [[ "$input" == @* ]]; then
    local query_file="${input:1}"
    query=$(cat "$query_file" 2>/dev/null || echo "")
  else
    query="$input"
  fi

  if [ ! -f "$file" ]; then
    echo "파일을 찾을 수 없습니다: $file"
    return 1
  fi

  if [ -n "$query" ]; then
    # 첫 번째 매칭 라인만 하이라이트
    local first_match_line
    first_match_line=$(rg --line-number "$query" "$file" 2>/dev/null | head -1 | cut -d: -f1)

    if [ -n "$first_match_line" ] && command -v bat >/dev/null 2>&1; then
      bat --color=always --style=numbers --highlight-line="$first_match_line" "$file"
    else
      bat --color=always --style=numbers "$file" 2>/dev/null || cat "$file"
    fi
  else
    bat --color=always --style=numbers "$file" 2>/dev/null || cat "$file"
  fi
}

# 첫 매칭 라인 번호 (에디터 점프용)
# $1: 파일 경로
# $2: 쿼리 문자열 또는 쿼리 파일 경로 (@로 시작하면 파일)
first_line() {
  local file="$1"
  local input="${2:-}"
  local query

  # @로 시작하면 파일에서 읽기
  if [[ "$input" == @* ]]; then
    local query_file="${input:1}"
    query=$(cat "$query_file" 2>/dev/null || echo "")
  else
    query="$input"
  fi

  # 쿼리 없거나 파일 없으면 1번 라인
  if [ -z "$query" ] || [ ! -f "$file" ]; then
    echo "1"
    return 0
  fi

  local line
  line=$(rg --line-number "$query" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  echo "${line:-1}"
}

case "${1:-}" in
  list-all)   list_all ;;
  search)     shift; search "$*" ;;
  preview)    shift; preview "$1" "${2:-}" ;;
  first-line) shift; first_line "$1" "${2:-}" ;;
  *)          echo "Usage: $0 {list-all|search|preview|first-line}" >&2; exit 1 ;;
esac
