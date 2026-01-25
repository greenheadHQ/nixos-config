#!/usr/bin/env bash
set -euo pipefail

NOTES_DIR="${HOME}/.tmux/pane-notes"
[ -d "$NOTES_DIR" ] || mkdir -p "$NOTES_DIR"

fmt(){ tmux display-message -p "$1"; }

# 위험 ASCII만 치환하고, 한글 등 비-ASCII는 보존
slug() {
  local s="${1:-}"

  # 개행/탭 -> 공백
  s="${s//$'\n'/ }"; s="${s//$'\t'/ }"

  # 파일/셸에서 위험한 ASCII만 개별 치환(멀티바이트 안전)
  # / : " \ ` * ? < > | $ & ; # [ ] { } ( ) 를 '-'로
  s="${s//\//-}"
  s="${s//:/-}"
  s="${s//\"/-}"
  s="${s//\'/-}"
  s="${s//\`/-}"
  s="${s//\*/-}"
  s="${s//\?/-}"
  s="${s//</-}"
  s="${s//>/-}"
  s="${s//|/-}"
  s="${s//\$/-}"
  s="${s//&/-}"
  s="${s//;/-}"
  s="${s//#/-}"
  s="${s//[/\-}"
  s="${s//]/-}"
  s="${s//\{/-}"
  s="${s//\}/-}"
  # 괄호를 살리고 싶다면 아래 두 줄은 주석 처리하세요
  # s="${s//\(/-}"
  # s="${s//\)/-}"

  # 공백 묶음 -> _
  s="$(printf '%s' "$s" | sed -E 's/[[:space:]]+/_/g')"
  # 앞/뒤의 _ 제거
  s="$(printf '%s' "$s" | sed -E 's/^_+|_+$//g')"

  # ---- (선택) 너무 길면 바이트 기준으로 자르기 ----
  # macOS 파일명 한계는 255B. 넉넉히 200B로 제한 (원하면 조절)
  local MAXB=200
  if command -v iconv >/dev/null 2>&1; then
    # dd로 바이트 수만큼 자르고, iconv -c로 깨진 UTF-8 조각을 버림
    s="$(printf '%s' "$s" | dd bs=1 count="$MAXB" 2>/dev/null | iconv -f UTF-8 -t UTF-8 -c)"
  fi

  printf '%s' "$s"
}

pane_id="$(fmt '#{pane_id}')"
pane_path="$(fmt '#{pane_current_path}')"
# pane 옵션 읽기 (display-message로 현재 pane의 값 조회)
title="$(tmux display-message -p '#{@custom_pane_title}')"

# 리포/디렉토리명
if git -C "$pane_path" rev-parse --show-toplevel >/dev/null 2>&1; then
  repo="$(basename "$(git -C "$pane_path" rev-parse --show-toplevel)")"
else
  repo="$(basename "$pane_path")"
fi

sticky="$(tmux show-option -gv @pane_note_sticky 2>/dev/null || echo 0)"
repo_slug="$(slug "$repo")"
title_slug="$(slug "${title:-untitled}")"

# 기본 키(파일명 후보) 계산 함수
default_key(){
  if [ "$sticky" = "1" ]; then
    if [ -n "${title:-}" ]; then
      printf "%s_%s" "$repo_slug" "$title_slug"
    else
      # 제목 없으면 충돌 방지: pane별로
      printf "%s_%s" "$repo_slug" "${pane_id#%}"
    fi
  else
    printf "%s_%s_%s" "$repo_slug" "$title_slug" "${pane_id#%}"
  fi
}

# ★ 링크된 노트 경로(@pane_note_path)가 있으면 우선 사용
linked_note="$(tmux display-message -p '#{@pane_note_path}')"
if [ -n "${linked_note:-}" ]; then
  note="$linked_note"
else
  # (이전과 동일) 기본 키로 경로 구성
  note="${NOTES_DIR}/$(default_key).md"
fi

# 기존 값이 없을 때만 설정 (복원된 값 보호)
ensure_var(){
  local current
  current="$(tmux display-message -p '#{@pane_note_path}')"
  [ -z "$current" ] && tmux set -p @pane_note_path "$note"
}

ensure_exist_or_msg(){
  [ -f "$note" ] && return 0
  tmux display-message "🗒️ 노트가 아직 없습니다. 'prefix + N'으로 새 노트를 생성하세요."
  exit 1
}

open_popup_edit(){
  tmux display-popup -E -w 90% -h 85% \
    "NOTE=\"$note\"; :\${EDITOR:=nvim}; exec \"\${EDITOR}\" \"\$NOTE\""
}

open_popup_view(){
  tmux display-popup -E -w 80% -h 80% \
    "NOTE=\"$note\"; if command -v bat >/dev/null 2>&1; then bat -pp --paging=always \"\$NOTE\"; else LESS= less -+F -+X -R \"\$NOTE\"; fi"
}

create_note(){
  # 인자로 받은 사용자 제목(필수)
  local user_title="${1:-}"
  # 공백/빈값 방지
  user_title="$(printf "%s" "$user_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -z "$user_title" ]; then
    tmux display-message "⚠️ 제목이 비어 있습니다. 다시 시도하세요."
    exit 2
  fi

  # ★ 새 폴더 구조: {NOTES_DIR}/{repo}/{title}.md
  local user_slug; user_slug="$(slug "$user_title")"
  mkdir -p "${NOTES_DIR}/${repo_slug}"
  note="${NOTES_DIR}/${repo_slug}/${user_slug}.md"

  # pane 변수에도 새로운 경로를 저장
  tmux set -p @pane_note_path "$note"

  # 파일이 이미 있으면 덮어쓰지 말고 열기만
  if [ -f "$note" ]; then
    open_popup_edit
    return
  fi

  # ★ 태그 팔레트 연동 (fzf multi-select)
  local selected_tags=""
  if command -v fzf >/dev/null 2>&1; then
    # 기본 태그
    local DEFAULT_TAGS="버그 기능 리팩토링 테스트 문서"
    # 기존 노트에서 태그 수집
    # 유효한 태그만 필터링: 30자 이내, 경로/URL 아님, 빈 값 아님
    local EXISTING_TAGS
    EXISTING_TAGS=$(find "$NOTES_DIR" -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" \
      -exec yq -r 'select(.tags) | .tags[]' {} \; 2>/dev/null \
      | grep -vE '^(/|https?://|[[:space:]]*$)' \
      | awk 'length <= 30' \
      | sort -u || true)
    # 합집합
    local ALL_TAGS
    ALL_TAGS=$(printf '%s\n' $DEFAULT_TAGS $EXISTING_TAGS | sort -u | grep -v '^$' || true)

    # tmux popup 내에서 fzf 태그 선택
    # ESC로 취소해도 빈 문자열로 진행 (tags: [])
    selected_tags=$(tmux display-popup -E -w 60% -h 50% \
      "echo '$ALL_TAGS' | fzf --multi --prompt='Tags (Tab으로 선택, ESC=건너뛰기)> ' | tr '\n' ',' | sed 's/,\$//'" 2>/dev/null || true)
  fi

  # ★ YAML frontmatter 생성
  {
    echo "---"
    echo "title: $user_title"
    if [ -n "$selected_tags" ]; then
      echo "tags: [$(echo "$selected_tags" | sed 's/,/, /g')]"
    else
      echo "tags: []"
    fi
    echo "created: $(date '+%Y-%m-%d')"
    echo "repo: $repo"
    echo "---"
    echo "# $user_title"
    echo ""
    echo "## TMI"
    echo "- "
    # 외부 설정 파일이 있으면 포함 (hostType별로 다른 내용)
    local links_file="${HOME}/.config/pane-note/links.txt"
    if [ -f "$links_file" ]; then
      echo ""
      echo "## Links"
      cat "$links_file"
    fi
  } >"$note"

  # (선택) pane 제목이 비어있으면 사용자 제목으로 채워주기
  if [ -z "${title:-}" ]; then
    tmux set -p @custom_pane_title "$user_title"
  fi

  open_popup_edit
}

case "${1:-}" in
  new)
    shift
    create_note "${1:-}"
    ;;
  filename)
    echo "$(basename "$note")"
    ;;
  path)
    echo "$note"
    ;;
  ensure-var)
    ensure_var
    ;;
  edit)
    ensure_exist_or_msg
    open_popup_edit
    ;;
  view)
    ensure_exist_or_msg
    open_popup_view
    ;;
  add-clipboard)
    ensure_exist_or_msg
    if command -v pbpaste >/dev/null; then
      clip="$(pbpaste)"
    elif command -v xclip >/dev/null 2>&1; then
      clip="$(xclip -o -selection clipboard || true)"
    else
      clip=""
    fi
    [ -n "${clip:-}" ] && printf -- "- %s\n" "$clip" >>"$note"
    tmux display-message "📌 Appended from clipboard"
    ;;
  open-url|open_url|openurl)
    ensure_exist_or_msg
    # 1) 라벨:URL
    labeled="$(sed -n -E 's/^[[:space:]]*[-*][[:space:]]*([^:]+)[[:space:]]*:[[:space:]]*(https?:\/\/[^ )]+).*/\1\t\2/p' "$note")"
    # 2) 라벨 없으면 전체 URL 수집
    if [ -z "$labeled" ]; then
      urls="$(grep -Eo 'https?://[^ )]+' "$note" | sed 's/[),.]\?$//' | awk '!seen[$0]++' || true)"
      [ -z "$urls" ] && { tmux display-message "No URLs found in note"; exit 0; }
      labeled=""
      while IFS= read -r u; do
        host="$(printf "%s" "$u" | sed -E 's#^https?://([^/]+).*#\1#')"
        case "$host" in
          *figma.com*)                     lbl="피그마 링크" ;;
          *atlassian.net*|*jira*|*atlassian.com*) lbl="지라" ;;
          *slack.com*)                     lbl="슬랙" ;;
          *github.com*)                    lbl="깃허브" ;;
          *linear.app*)                    lbl="Linear" ;;
          *notion.so*|*notion.site*)       lbl="노션" ;;
          *)                               lbl="$host" ;;
        esac
        labeled="${labeled}${lbl}\t${u}\n"
      done <<EOF
$urls
EOF
    fi

    MENU=(display-menu -T "Open URL" -x C -y C)
    i=1
    while IFS=$'\t' read -r label url; do
      [ -z "${url:-}" ] && continue
      lbl="$(printf "%s" "$label" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [ -z "$lbl" ] && lbl="$(printf "%s" "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
      disp="$(printf "%s" "$lbl" | cut -c1-40)"; [ "${#lbl}" -gt 40 ] && disp="${disp}…"
      esc="$(printf "%s" "$url" | sed "s/'/'\\\\''/g")"
      MENU+=( "$i. $disp" "" "run-shell \"if command -v open >/dev/null 2>&1; then open '$esc' >/dev/null 2>&1 & else (xdg-open '$esc' >/dev/null 2>&1 || true) & fi; tmux display-message '🌐 Opened: $esc'\"" )
      i=$((i+1))
    done <<EOF
$labeled
EOF
    tmux "${MENU[@]}" >/dev/null 2>&1 || true
    ;;
  *)
    echo "Usage: $0 {new <title>|edit|view|add-clipboard|open-url|path|filename|ensure-var}" >&2
    exit 2
    ;;
esac