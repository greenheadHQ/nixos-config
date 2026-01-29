#!/usr/bin/env bash
# 통합 헬퍼 스크립트 (pane-link, pane-search 공용)
# fzf에서 직접 호출 가능한 함수들
set -euo pipefail

debug() {
  if [ "${TMUX_NOTE_DEBUG:-0}" = "1" ]; then
    printf "[DEBUG %s] %s\n" "$(basename "$0")" "$*" >&2
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS="$SCRIPT_DIR/pane-helpers.sh"
NOTES_DIR="${HOME}/.tmux/pane-notes"

# ============================================================================
# 포맷팅 함수
# ============================================================================

# yq로 메타데이터 추출
# 형식: MM-DD | [repo] 제목 (N matches) #태그1 #태그2 \t 파일경로
format_entry() {
  local file="$1"
  local match_count="${2:-}"  # 검색 모드에서만

  local repo
  repo=$(basename "$(dirname "$file")")

  # 한 번의 yq 호출로 모든 필드 추출 (성능 최적화)
  # --front-matter=extract: 마크다운 frontmatter만 파싱 (본문 파싱 에러 방지)
  # cut으로 파싱: bash read는 연속된 탭(빈 필드)을 건너뛰는 문제가 있음
  local metadata title tags created
  if metadata=$(yq --front-matter=extract -r '[.title // "", (.tags // [] | join(" #")), .created // ""] | @tsv' "$file" 2>/dev/null); then
    title=$(printf '%s' "$metadata" | cut -f1)
    tags=$(printf '%s' "$metadata" | cut -f2)
    created=$(printf '%s' "$metadata" | cut -f3)
  else
    title=""
    tags=""
    created=""
  fi

  # fallback: title 없으면 파일명
  [ -z "$title" ] && title=$(basename "$file" .md)

  # 날짜 파싱: YYYY-MM-DD 그대로 사용
  local date_part="${created}"
  [ -z "$date_part" ] && date_part="----/--/--"

  # 태그 색상 (밝은 주황색) - 두 모드 모두 적용
  local tags_formatted=""
  if [ -n "$tags" ]; then
    tags_formatted=$(echo " #$tags" | sed 's/#\([^ ]*\)/\\033[38;5;214m#\1\\033[0m/g')
  fi

  # 매칭 수 (검색 모드에서만)
  local match_text=""
  if [ -n "$match_count" ]; then
    [ "$match_count" -eq 1 ] && match_text=" (1 match)" || match_text=" (${match_count} matches)"
  fi

  printf "%s | [%s] %s%s%b\t%s\n" "$date_part" "$repo" "$title" "$match_text" "$tags_formatted" "$file"
}

# ============================================================================
# 목록 함수
# ============================================================================

# 모든 노트 목록 (정렬 옵션 지원)
list_all() {
  local sort_by="${1:-created}"  # created 또는 mtime

  if [ "$sort_by" = "mtime" ]; then
    # 파일 수정 시간 기준 정렬
    while IFS= read -r -d '' f; do
      local mtime
      if [[ "$OSTYPE" == "darwin"* ]]; then
        mtime=$(stat -f %m "$f")
      else
        mtime=$(stat -c %Y "$f")
      fi
      printf "%s\t%s\n" "$mtime" "$(format_entry "$f")"
    done < <(find "$NOTES_DIR" -mindepth 2 -name "*.md" \
      ! -path "*/_archive/*" ! -path "*/_trash/*" -print0 2>/dev/null) \
      | sort -t$'\t' -k1,1nr | cut -f2-
  else
    # 생성일 기준 정렬 (인라인 처리: 서브셸 오버헤드 제거)
    while IFS= read -r -d '' f; do
      local repo metadata title tags created date_part tags_formatted
      repo=$(basename "$(dirname "$f")")

      if metadata=$(yq --front-matter=extract -r \
        '[.title // "", (.tags // [] | join(" #")), .created // ""] | @tsv' \
        "$f" 2>/dev/null); then
        title=$(printf '%s' "$metadata" | cut -f1)
        tags=$(printf '%s' "$metadata" | cut -f2)
        created=$(printf '%s' "$metadata" | cut -f3)
      else
        title="" tags="" created=""
      fi

      [ -z "$title" ] && title=$(basename "$f" .md)
      date_part="${created:-"----/--/--"}"
      tags_formatted=""
      if [ -n "$tags" ]; then
        tags_formatted=$(printf '%s' " #$tags" | sed 's/#\([^ ]*\)/\\033[38;5;214m#\1\\033[0m/g')
      fi
      printf "%s | [%s] %s%b\t%s\n" "$date_part" "$repo" "$title" "$tags_formatted" "$f"
    done < <(find "$NOTES_DIR" -mindepth 2 -name "*.md" \
      ! -path "*/_archive/*" ! -path "*/_trash/*" -print0 2>/dev/null) | sort -r
  fi
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

# 휴지통 노트 목록
list_trash() {
  [ ! -d "$NOTES_DIR/_trash" ] && return
  while IFS= read -r -d '' f; do
    format_entry "$f"
  done < <(find "$NOTES_DIR/_trash" -name "*.md" -print0 2>/dev/null) | sort -r
}

# 아카이브 노트 목록
list_archive() {
  [ ! -d "$NOTES_DIR/_archive" ] && return
  while IFS= read -r -d '' f; do
    format_entry "$f"
  done < <(find "$NOTES_DIR/_archive" -name "*.md" -print0 2>/dev/null) | sort -r
}

# ============================================================================
# 검색 함수
# ============================================================================

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

  # #으로 시작하면 태그 검색
  if [[ "$query" == \#* ]]; then
    local tag="${query:1}"
    while IFS= read -r -d '' f; do
      format_entry "$f"
    done < <(rg --files-with-matches -g '*.md' -g '!**/_archive/**' -g '!**/_trash/**' \
      "tags:.*$tag" "$NOTES_DIR" -0 2>/dev/null || true) | sort -r
    return 0
  fi

  # rg --count 출력: /path/file.md:3
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local file="${line%:*}"    # 마지막 : 앞부분 = 파일 경로
    local count="${line##*:}"  # 마지막 : 뒷부분 = 매칭 수
    format_entry "$file" "$count"
  done < <(rg --count -g '*.md' -g '!**/_archive/**' -g '!**/_trash/**' \
    "$query" "$NOTES_DIR" 2>/dev/null || true) | sort -r
}

# Preview: 첫 매칭 라인 하이라이트
# $1: 파일 경로
# $2: 쿼리 문자열 또는 쿼리 파일 경로 (@로 시작하면 파일)
# $3: 모드 파일 경로 (@로 시작하면 파일, 선택사항)
preview() {
  local file="$1"
  local input="${2:-}"
  local mode_input="${3:-}"
  local query
  local mode="fzf"

  # @로 시작하면 파일에서 읽기
  if [[ "$input" == @* ]]; then
    local query_file="${input:1}"
    query=$(cat "$query_file" 2>/dev/null || echo "")
  else
    query="$input"
  fi

  # 모드 파일 읽기
  if [[ "$mode_input" == @* ]]; then
    local mode_file="${mode_input:1}"
    mode=$(cat "$mode_file" 2>/dev/null || echo "fzf")
  fi

  if [ ! -f "$file" ]; then
    echo "파일을 찾을 수 없습니다: $file"
    return 1
  fi

  # rg 모드이고 쿼리가 있을 때만 하이라이트
  if [ "$mode" = "rg" ] && [ -n "$query" ]; then
    # 태그 검색은 하이라이트 불필요
    if [[ "$query" != \#* ]]; then
      local first_match_line
      first_match_line=$(rg --line-number "$query" "$file" 2>/dev/null | head -1 | cut -d: -f1)

      if [ -n "$first_match_line" ] && command -v bat >/dev/null 2>&1; then
        bat --color=always --style=numbers --highlight-line="$first_match_line" "$file"
        return 0
      fi
    fi
  fi

  # 기본 프리뷰
  bat --color=always --style=numbers "$file" 2>/dev/null || cat "$file"
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

  # 태그 검색은 1번 라인
  if [[ "$query" == \#* ]]; then
    echo "1"
    return 0
  fi

  local line
  line=$(rg --line-number "$query" "$file" 2>/dev/null | head -1 | cut -d: -f1)
  echo "${line:-1}"
}

# ============================================================================
# 이동/복원 함수
# ============================================================================

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

# 복원 (휴지통/아카이브에서)
# $1: 파일 경로
# $2: 대상 프로젝트
restore_from() {
  local file="$1"
  local target_repo="$2"

  [ ! -f "$file" ] && return 1
  [ -z "$target_repo" ] && return 1

  mkdir -p "$NOTES_DIR/$target_repo"

  # 타임스탬프 정규식: YYYYMMDD-HHMMSS_ 형식만 제거
  local original_name
  original_name=$(basename "$file" | sed 's/^[0-9]\{8\}-[0-9]\{6\}_//')

  mv "$file" "$NOTES_DIR/$target_repo/$original_name"
}

# ============================================================================
# fzf transform용 헬퍼 함수
# ============================================================================

# 모드 전환 (fzf -> rg 또는 rg -> fzf)
toggle_mode() {
  local mode_file="$1"
  local query_file="$2"
  local sort_file="$3"
  local query="$4"

  local mode sort_val
  mode=$(cat "$mode_file")
  sort_val=$(cat "$sort_file")

  if [ "$mode" = "fzf" ]; then
    echo "rg" > "$mode_file"
    printf '%s' "$query" > "$query_file"
    echo "change-prompt(Link note [rg/$sort_val]> )+reload($HELPERS search @$query_file)+disable-search"
  else
    echo "fzf" > "$mode_file"
    echo "change-prompt(Link note [fzf/$sort_val]> )+reload($HELPERS list-all $sort_val)+enable-search"
  fi
}

# change 이벤트 처리 (rg 모드에서 타이핑 시)
handle_change() {
  local mode_file="$1"
  local query_file="$2"
  local sort_file="$3"
  local query="$4"

  local mode
  mode=$(cat "$mode_file")

  # 쿼리 저장
  printf '%s' "$query" > "$query_file"

  # rg 모드일 때만 reload
  if [ "$mode" = "rg" ]; then
    echo "reload($HELPERS search @$query_file)"
  fi
}

# 정렬 토글 (created <-> mtime)
toggle_sort() {
  local mode_file="$1"
  local sort_file="$2"

  local mode sort_val new_sort
  mode=$(cat "$mode_file")
  sort_val=$(cat "$sort_file")

  if [ "$sort_val" = "created" ]; then
    echo "mtime" > "$sort_file"
    new_sort="mtime"
  else
    echo "created" > "$sort_file"
    new_sort="created"
  fi

  echo "reload($HELPERS list-all $new_sort)+change-prompt(Link note [$mode/$new_sort]> )"
}

# Ctrl-A 처리 (전체 노트 보기)
handle_ctrl_a() {
  local mode_file="$1"
  local sort_file="$2"

  local mode sort_val
  mode=$(cat "$mode_file")
  sort_val=$(cat "$sort_file")

  echo "fzf" > "$mode_file"
  echo "reload($HELPERS list-all $sort_val)+change-prompt(Link note [fzf/$sort_val]> )+enable-search"
}

# ============================================================================
# 명령어 인터페이스
# ============================================================================

case "${1:-}" in
  # 목록
  list-all)       shift; list_all "${1:-created}" ;;
  list-current)   shift; list_current "$@" ;;
  list-trash)     list_trash ;;
  list-archive)   list_archive ;;

  # 검색/프리뷰
  search)         shift; search "$*" ;;
  preview)        shift; preview "$1" "${2:-}" "${3:-}" ;;
  first-line)     shift; first_line "$1" "${2:-}" ;;

  # 이동/복원
  move-trash)     shift; move_to_trash "$@" ;;
  move-archive)   shift; move_to_archive "$@" ;;
  restore)        shift; restore_from "$1" "$2" ;;

  # fzf transform용 헬퍼
  toggle-mode)    shift; toggle_mode "$1" "$2" "$3" "$4" ;;
  handle-change)  shift; handle_change "$1" "$2" "$3" "$4" ;;
  toggle-sort)    shift; toggle_sort "$1" "$2" ;;
  handle-ctrl-a)  shift; handle_ctrl_a "$1" "$2" ;;

  # 포맷팅 (단독 테스트용)
  format)         shift; format_entry "$@" ;;

  *)
    echo "Usage: $0 {list-all|list-current|list-trash|list-archive|search|preview|first-line|move-trash|move-archive|restore|toggle-mode|handle-change|toggle-sort|handle-ctrl-a|format}" >&2
    exit 1
    ;;
esac
