#!/usr/bin/env bash
set -euo pipefail

debug() {
  if [ "${TMUX_NOTE_DEBUG:-0}" = "1" ]; then
    printf "[DEBUG %s] %s\n" "$(basename "$0")" "$*" >&2
  fi
}

# 현재 pane에 연결된 노트의 태그 수정
# 두 단계 UI: 1) 제거할 태그 선택 2) 추가할 태그 선택
# 현재 태그가 기본 유지됨 (명시적으로 제거해야 삭제)

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

# fzf가 없으면 안내
if ! command -v fzf >/dev/null 2>&1; then
  echo "fzf가 설치되어 있지 않습니다."
  read -rp "Press Enter to close..."
  exit 1
fi

# 기본 태그 + 기존 노트에서 수집한 태그
DEFAULT_TAGS="버그 기능 리팩토링 테스트 문서"
EXISTING_TAGS=$(find "$NOTES_DIR" -name "*.md" ! -path "*/_archive/*" ! -path "*/_trash/*" \
  -exec yq --front-matter=extract -r 'select(.tags) | .tags[]' {} + 2>/dev/null \
  | grep -vE '^(/|https?://|[[:space:]]*$)' \
  | awk 'length <= 30' \
  | LC_ALL=C sort -u || true)
ALL_TAGS=$(printf '%s\n' $DEFAULT_TAGS $EXISTING_TAGS | LC_ALL=C sort -u | grep -v '^$' || true)

# 현재 태그 추출
current_tags=$(yq --front-matter=extract -r '.tags // [] | .[]' "$note" 2>/dev/null || echo "")
current_display=$(echo "$current_tags" | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')

echo "현재 태그: ${current_display:-없음}"
echo ""

# ===== 1단계: 제거할 태그 선택 =====
to_remove=""
if [ -n "$current_tags" ]; then
  echo "1단계: 제거할 태그 선택 (없으면 Enter)"
  set +e
  to_remove=$(echo "$current_tags" | fzf --multi \
    --prompt='제거할 태그 (Space로 선택)> ' \
    --bind='space:toggle' \
    --header="Space: 선택/해제 | Enter: 다음 단계, ESC: 취소")
  fzf_exit=$?
  set -e

  # ESC로 취소
  [ $fzf_exit -eq 130 ] && { echo "취소됨"; exit 0; }
fi

# ===== 2단계: 추가할 태그 선택 =====
# 현재 태그에서 제거할 것을 뺀 나머지
remaining_tags=""
while IFS= read -r tag; do
  [ -z "$tag" ] && continue
  if ! echo "$to_remove" | grep -qxF "$tag"; then
    remaining_tags="${remaining_tags}${tag}"$'\n'
  fi
done <<< "$current_tags"

# 추가 가능한 태그 (현재 태그 제외)
available_tags=""
while IFS= read -r tag; do
  [ -z "$tag" ] && continue
  if ! echo "$current_tags" | grep -qxF "$tag"; then
    available_tags="${available_tags}${tag}"$'\n'
  fi
done <<< "$ALL_TAGS"

echo ""
echo "2단계: 추가할 태그 선택"
set +e
# fzf --print-query로 쿼리(직접 입력)와 선택 모두 처리
result=$(echo "$available_tags" | grep -v '^$' | fzf --multi \
  --prompt='추가할 태그 (Tab으로 선택, 직접 입력도 가능)> ' \
  --bind='tab:toggle+down,shift-tab:toggle+up' \
  --header="새 태그 선택 | Enter: 적용, ESC: 취소" \
  --print-query)
fzf_exit=$?
set -e

[ $fzf_exit -eq 130 ] && { echo "취소됨"; exit 0; }

# 결과 파싱
query=$(echo "$result" | head -1)      # 첫 줄: 직접 입력한 쿼리
to_add=$(echo "$result" | tail -n +2)  # 나머지: 선택된 태그

# 쿼리가 기존 태그가 아니면 새 태그로 추가
if [ -n "$query" ]; then
  if ! echo "$ALL_TAGS" | grep -qxF "$query"; then
    to_add="${to_add}"$'\n'"${query}"
  fi
fi

# ===== 최종 태그 계산 =====
# 최종 = 유지(remaining) + 추가(to_add)
final_tags=$(printf '%s\n%s' "$remaining_tags" "$to_add" | grep -v '^$' | LC_ALL=C sort -u)

# yq로 태그 업데이트
# --front-matter=process: frontmatter만 수정하고 본문 유지
# 줄바꿈을 쉼표로 변환 (yq split이 줄바꿈을 제대로 처리 못함)
tags_csv=$(echo "${final_tags:-}" | tr '\n' ',' | sed 's/,$//')
export FINAL_TAGS="$tags_csv"
yq --front-matter=process -i '.tags = (env(FINAL_TAGS) | split(",") | map(select(. != "")))' "$note"
unset FINAL_TAGS

if [ -z "$final_tags" ]; then
  echo "태그 모두 제거됨"
else
  final_display=$(echo "$final_tags" | tr '\n' ', ' | sed 's/,$//' | sed 's/,/, /g')
  echo "태그 업데이트 완료: $final_display"
fi
