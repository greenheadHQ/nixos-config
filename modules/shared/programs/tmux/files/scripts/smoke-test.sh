#!/usr/bin/env bash
set -euo pipefail

# pane-note 시스템 Smoke Test
# 사용법: ~/.tmux/scripts/smoke-test.sh

NOTES_DIR="${HOME}/.tmux/pane-notes"
TEST_REPO="__test__"
TEST_TITLE="smoke-test-$(date +%s)"

cleanup() { rm -rf "${NOTES_DIR:?}/${TEST_REPO:?}"; }
trap cleanup EXIT

echo "=== Smoke Test: pane-note ==="
echo ""

# 0. 의존성 확인
echo "[의존성 확인]"
command -v yq >/dev/null || { echo "FAIL: yq 미설치"; exit 1; }
yq --version 2>&1 | grep -q "mikefarah" || echo "WARN: yq-go가 아닐 수 있음 (mikefarah/yq 권장)"

# yq 버전 체크 (// 연산자는 4.18+ 필요)
yq_version=$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "  yq 버전: $yq_version"
echo "  OK: yq 설치 확인 (4.18+ 권장)"

command -v fzf >/dev/null || { echo "FAIL: fzf 미설치"; exit 1; }
echo "  OK: fzf 설치 확인"

command -v rg >/dev/null || { echo "FAIL: ripgrep 미설치"; exit 1; }
echo "  OK: ripgrep 설치 확인"

echo ""

# 1. 디렉토리 생성 확인
echo "[디렉토리 구조]"
[ -d "$NOTES_DIR" ] || { echo "FAIL: pane-notes 디렉토리 없음"; exit 1; }
[ -d "$NOTES_DIR/_archive" ] || { echo "FAIL: _archive 없음"; exit 1; }
[ -d "$NOTES_DIR/_trash" ] || { echo "FAIL: _trash 없음"; exit 1; }
echo "  OK: 디렉토리 구조 확인"
echo ""

# 2. 노트 생성 테스트
echo "[노트 생성]"
mkdir -p "$NOTES_DIR/$TEST_REPO"
cat > "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" <<EOF
---
title: Smoke Test Note
tags: [테스트, 자동화]
created: $(date +%Y-%m-%d)
repo: $TEST_REPO
---
# Smoke Test Note

Test content for smoke test.
EOF
[ -f "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" ] || { echo "FAIL: 노트 생성 실패"; exit 1; }
echo "  OK: 노트 생성"
echo ""

# 3. YAML frontmatter 파싱 테스트
echo "[YAML 파싱]"
tags=$(yq '.tags[0]' "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md")
[ "$tags" = "테스트" ] || { echo "FAIL: 태그 파싱 실패 (got: $tags)"; exit 1; }
echo "  OK: 태그 파싱"

# yq // 연산자 테스트 (호환성 확인)
title=$(yq -r '.title // ""' "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" 2>/dev/null || echo "")
[ "$title" = "Smoke Test Note" ] || { echo "FAIL: yq // 연산자 (got: $title)"; exit 1; }
echo "  OK: yq // 연산자 호환성"

# tags join 테스트
tags_joined=$(yq -r '.tags // [] | join(" #")' "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" 2>/dev/null || echo "")
[ "$tags_joined" = "테스트 #자동화" ] || { echo "FAIL: tags join (got: $tags_joined)"; exit 1; }
echo "  OK: tags join"
echo ""

# 4. 아카이브 테스트
echo "[아카이브/삭제]"
mv "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" "$NOTES_DIR/_archive/"
[ -f "$NOTES_DIR/_archive/$TEST_TITLE.md" ] || { echo "FAIL: 아카이브 실패"; exit 1; }
echo "  OK: 아카이브 이동"

# 5. 삭제 테스트
mv "$NOTES_DIR/_archive/$TEST_TITLE.md" "$NOTES_DIR/_trash/"
[ -f "$NOTES_DIR/_trash/$TEST_TITLE.md" ] || { echo "FAIL: 삭제 실패"; exit 1; }
rm "$NOTES_DIR/_trash/$TEST_TITLE.md"
echo "  OK: 삭제 (trash)"
echo ""

# 6. 헬퍼 스크립트 테스트
echo "[헬퍼 스크립트]"
HELPERS="$HOME/.tmux/scripts/pane-link-helpers.sh"
if [ -x "$HELPERS" ]; then
  # list-all 명령 테스트 (빈 결과도 OK)
  set +e
  result=$("$HELPERS" list-all 2>/dev/null | head -1)
  exit_code=$?
  set -e
  if [ $exit_code -eq 0 ]; then
    if [ -n "$result" ]; then
      echo "  OK: list-all (노트 있음)"
    else
      echo "  OK: list-all (노트 없음 - 정상)"
    fi
  else
    echo "FAIL: list-all 실패 (exit: $exit_code)"
    exit 1
  fi

  # format 명령 테스트 (테스트용 노트 재생성)
  mkdir -p "$NOTES_DIR/$TEST_REPO"
  cat > "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" <<EOF
---
title: Format Test
tags: [테스트]
created: 2024-01-15
repo: $TEST_REPO
---
# Format Test
EOF
  format_result=$("$HELPERS" format "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md" 2>/dev/null || echo "")
  if [[ "$format_result" == *"01-15"* ]] && [[ "$format_result" == *"[$TEST_REPO]"* ]]; then
    echo "  OK: format (날짜/repo 추출)"
  else
    echo "FAIL: format 결과 이상 (got: $format_result)"
    exit 1
  fi
  rm "$NOTES_DIR/$TEST_REPO/$TEST_TITLE.md"
else
  echo "  SKIP: 헬퍼 스크립트 미설치"
fi
echo ""

# 7. 스크립트 존재 확인
echo "[스크립트 설치]"
scripts=(
  "pane-note.sh"
  "pane-link.sh"
  "pane-peek.sh"
  "pane-tag.sh"
  "pane-search.sh"
  "pane-link-helpers.sh"
  "prefix-help.sh"
)
for script in "${scripts[@]}"; do
  if [ -x "$HOME/.tmux/scripts/$script" ]; then
    echo "  OK: $script"
  else
    echo "  FAIL: $script 미설치 또는 실행 권한 없음"
    exit 1
  fi
done
echo ""

echo "==========================================="
echo "  All tests passed!"
echo "==========================================="
