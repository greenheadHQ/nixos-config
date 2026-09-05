#!/usr/bin/env bash
# Claude Code SessionEnd hook: .claude/plans/ transient plan buffer GC (#756)
#
# plan-mode runtime이 .claude/plans/에 떨어뜨리는 transient plan buffer는 아무도 지우지
# 않아 무한 누적되는 경향이 있다. 정리 주체를 두는 문서가 없었으므로, 세션 종료 시 mtime
# 임계를 넘긴 오래된 transient buffer만 정리하는 GC 주체를 여기 둔다. 정책 서술은
# .claude/plans/README.md "Transient buffer 식별 기준"이 정본이다.
#
# GC 대상 (둘 중 한 패턴 매칭 + mtime 임계 초과 + untracked + SSOT 마커 없음):
#   - <prefix>-<8hex>.md — 초기 harness가 붙이던 8자리 hex suffix buffer
#   - <형용사>-<동사>ing-<명사>.md — 현행 harness가 붙이는 3단어 slug buffer
#     (예: calm-pondering-llama.md). hex suffix가 없어 첫 패턴에 걸리지 않는다.
#
# 보존 대상:
#   - 두 패턴 어디에도 매칭되지 않는 파일 (canonical <prefix>.md, 날짜 prefix 문서 등)
#   - 본문에 SSOT 마커('## Document Status')가 있는 파일. 파일명이 harness slug여도
#     사람이 쓴 plan 문서이므로 보존한다 — 이름만으로는 둘을 구분할 수 없기 때문이다.
#   - git-tracked 파일 (README.md 등 force-add → ls-files 확인으로 제외)
#   - mtime 임계(GC_AGE_DAYS) 내 최근 buffer (활성/최근 세션 보호)
#   - 끝 8자(hex) 직전에 리터럴 '-'가 오지 않는 buffer. 정규식이 '-<8hex>.md$'를
#     요구하므로 -agent-<7|17hex> 같은 historical은 끝 8자 앞이 hex라 미매칭되어
#     보존된다. (주의: 끝이 정확히 '-<8hex>.md'이면 prefix 무관하게 GC 대상이다 —
#     예: foo-agent-1a2b3c4d.md는 매칭됨.)
#
# 잔존 위험과 완화: slug 패턴은 이름 휴리스틱이라, 가운데 단어가 -ing로 끝나는 3단어
# 사용자 문서(예: nix-building-cache.md)를 SSOT 마커 없이 두면 GC 대상이 된다. 이
# 디렉토리는 untracked라 git으로 되돌릴 수 없으므로, 삭제 대신 .trash/<YYYY-MM-DD>/로
# 옮겨 TRASH_KEEP_DAYS 동안 복구 가능하게 두고 그 뒤 만료시킨다.
#
# 동작 위치: SessionEnd input의 .cwd가 속한 git repo의 .claude/plans/.
# 정리 대상이 없으면 no-op. bash 3.2 호환 (mapfile 미사용).

# 7일: 멀티데이 작업 중인 최근 buffer의 조기 삭제를 막는 보수적 여유. 정책적
# 선택값이며, 줄이면 최근 buffer 보호 폭이 함께 좁아진다.
GC_AGE_DAYS=7
# 30일: 이름 휴리스틱 오판을 사람이 알아채고 되살릴 수 있는 유예. 줄이면 복구 창이 좁아진다.
TRASH_KEEP_DAYS=30
# 8자리 hex suffix transient buffer 식별 정규식. unquoted 변수로 bash regex 매칭
# (quote 시 literal 매칭됨).
HEX_RE='-[0-9a-f]{8}\.md$'
# 3단어 slug transient buffer 식별 정규식. 가운데 단어를 -ing로 한정하고 앵커(^...$)로
# 파일명 전체를 고정한다 — 넓히면 사용자 문서를 더 많이 삼킨다.
SLUG_RE='^[a-z]+-[a-z]+ing-[a-z]+\.md$'
# 사람이 쓴 plan 문서의 본문 마커. 이 줄이 있으면 파일명이 무엇이든 보존한다.
SSOT_MARKER_RE='^## Document Status[[:space:]]*$'

HOOK_RUNTIME_LIB="${HOOK_RUNTIME_LIB:-$HOME/.claude/lib/hook-runtime.sh}"
[ -f "$HOOK_RUNTIME_LIB" ] || exit 0
# shellcheck source=../lib/hook-runtime.sh
. "$HOOK_RUNTIME_LIB"

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | hook_parse_json_path '.cwd // empty')
[[ -z "$CWD" ]] && exit 0

GIT_TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
PLANS_DIR="$GIT_TOPLEVEL/.claude/plans"
[[ -d "$PLANS_DIR" ]] || exit 0
TRASH_ROOT="$PLANS_DIR/.trash"

# 되돌릴 수 없는 rm 대신 날짜별 trash로 옮긴다. 같은 이름이 이미 있으면 번호를 붙여
# 덮어쓰지 않는다. 옮기지 못하면(권한 등) 원본을 그대로 둔다.
retire_buffer() {
  local src="$1" day dest base n
  day=$(date +%Y-%m-%d)
  dest="$TRASH_ROOT/$day"
  mkdir -p "$dest" 2>/dev/null || return 1
  base="${src##*/}"
  n=1
  while [[ -e "$dest/$base" ]]; do
    base="${src##*/}.$n"
    n=$((n + 1))
  done
  mv "$src" "$dest/$base" 2>/dev/null
}

# 두 패턴 중 하나 + mtime > GC_AGE_DAYS 인 transient buffer만 회수 대상.
# find -mtime은 BSD/GNU 공통. -name '*-*.md'는 두 패턴 모두를 포함하는 성긴 후보
# 필터이고 (둘 다 '-'를 포함하는 .md), 실제 판정은 아래 정규식이 다시 한다
# (canonical <prefix>.md, 날짜 prefix 문서, suffix가 8 hex 아닌 -agent-<hex> 등 제외).
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  base="${f##*/}"
  [[ "$base" =~ $HEX_RE || "$base" =~ $SLUG_RE ]] || continue
  # 사람이 쓴 plan 문서(SSOT 마커 보유)는 이름과 무관하게 보존
  grep -qE "$SSOT_MARKER_RE" "$f" 2>/dev/null && continue
  # git-tracked 파일(README.md 등)은 보존
  git -C "$GIT_TOPLEVEL" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
  retire_buffer "$f"
done < <(find "$PLANS_DIR" -maxdepth 1 -type f -name '*-*.md' -mtime +"$GC_AGE_DAYS" 2>/dev/null)

# 유예를 넘긴 trash 날짜 디렉토리 만료
if [[ -d "$TRASH_ROOT" ]]; then
  find "$TRASH_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime +"$TRASH_KEEP_DAYS" \
    -exec rm -rf {} + 2>/dev/null
fi

exit 0
