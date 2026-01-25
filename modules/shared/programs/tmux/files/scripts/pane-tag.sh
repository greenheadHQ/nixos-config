#!/usr/bin/env bash
set -euo pipefail

# 현재 pane에 연결된 노트의 태그 수정
# fzf multi-select로 태그 선택, yq로 frontmatter 업데이트

NOTES_DIR="${HOME}/.tmux/pane-notes"

# 현재 pane에 연결된 노트 경로 가져오기
note=$(tmux display-message -p '#{@pane_note_path}')
if [ -z "$note" ] || [ ! -f "$note" ]; then
  echo "연결된 노트가 없습니다. (prefix+K로 노트를 먼저 연결하세요)"
  read -rp "Press Enter to close..."
  exit 1
fi

echo "노트: $(basename "$note")"
echo ""

# 기본 태그 (하드코딩)
DEFAULT_TAGS="버그 기능 리팩토링 테스트 문서"

# 기존 노트에서 태그 수집
# 유효한 태그만 필터링: 30자 이내, 경로/URL 아님, 빈 값 아님
EXISTING_TAGS=$(find "$NOTES_DIR" -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" \
  -exec yq -r 'select(.tags) | .tags[]' {} \; 2>/dev/null \
  | grep -vE '^(/|https?://|[[:space:]]*$)' \
  | awk 'length <= 30' \
  | sort -u || true)

# 합집합
ALL_TAGS=$(printf '%s\n' $DEFAULT_TAGS $EXISTING_TAGS | sort -u | grep -v '^$' || true)

# 현재 태그 표시
current=$(yq -r '.tags // [] | join(", ")' "$note" 2>/dev/null || echo "")
echo "현재 태그: ${current:-없음}"
echo ""

# fzf가 없으면 안내
if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf가 설치되어 있지 않습니다."
  read -rp "Press Enter to close..."
  exit 1
fi

# fzf multi-select로 태그 선택
# ESC (exit 130) = 취소, Enter = 적용 (빈 선택 시 태그 모두 제거)
set +e
selected=$(echo "$ALL_TAGS" | fzf --multi --prompt='Tags (Tab으로 선택)> ' \
  --header="현재: ${current:-없음} | ESC=취소, Enter=적용 (빈 선택=모두 제거)")
fzf_exit=$?
set -e

# ESC로 취소한 경우 (exit code 130)
if [ $fzf_exit -eq 130 ]; then
  echo "취소됨"
  exit 0
fi

# 빈 선택도 적용 (태그 모두 제거)
export SELECTED_TAGS="${selected:-}"
yq -i '.tags = (env(SELECTED_TAGS) | split("\n") | map(select(. != "")))' "$note"
unset SELECTED_TAGS

if [ -z "$selected" ]; then
  echo "태그 모두 제거됨"
else
  echo "태그 업데이트 완료"
fi
