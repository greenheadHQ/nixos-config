#!/usr/bin/env bash
# Claude Code SessionEnd hook: .claude/plans/ transient plan buffer GC (#756)
#
# plan-mode runtime이 .claude/plans/에 떨어뜨리는 transient plan buffer
# (<prefix>-<8hex>.md)는 SSOT plan으로 승격되지 않고 무한 누적되는 경향이 있다.
# 스킬 문서는 "비승격"만 규정하고 정리 주체를 두지 않으므로, 세션 종료 시
# mtime 임계를 넘긴 오래된 transient buffer만 정리하는 GC 주체를 둔다.
#
# 보존 대상:
#   - canonical SSOT plan (<prefix>.md, 8hex suffix 없음 → 패턴 미매칭)
#   - git-tracked 파일 (README.md 등 force-add → ls-files 확인으로 제외)
#   - mtime 임계(GC_AGE_DAYS) 내 최근 buffer (활성/최근 세션 보호)
#   - 끝 8자(hex) 직전에 리터럴 '-'가 오지 않는 buffer. 정규식이 '-<8hex>.md$'를
#     요구하므로 -agent-<7|17hex> 같은 historical은 끝 8자 앞이 hex라 미매칭되어
#     보존된다. (주의: 끝이 정확히 '-<8hex>.md'이면 prefix 무관하게 GC 대상이다 —
#     예: foo-agent-1a2b3c4d.md는 매칭됨.)
#
# 동작 위치: SessionEnd input의 .cwd가 속한 git repo의 .claude/plans/.
# 정리 대상이 없으면 no-op. bash 3.2 호환 (mapfile 미사용).

# 7일: 멀티데이 작업 중인 최근 buffer의 조기 삭제를 막는 보수적 여유. 정책적
# 선택값이며, 줄이면 최근 buffer 보호 폭이 함께 좁아진다.
GC_AGE_DAYS=7
# 8자리 hex suffix transient buffer 식별 정규식 (.claude/plans/README.md #756 P0이
# 정의한 SSOT 기준). unquoted 변수로 bash regex 매칭 (quote 시 literal 매칭됨).
HEX_RE='-[0-9a-f]{8}\.md$'

INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
[[ -z "$CWD" ]] && exit 0

GIT_TOPLEVEL=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null) || exit 0
PLANS_DIR="$GIT_TOPLEVEL/.claude/plans"
[[ -d "$PLANS_DIR" ]] || exit 0

# <prefix>-<8hex>.md + mtime > GC_AGE_DAYS 인 transient buffer만 삭제.
# find -mtime은 BSD/GNU 공통. -name으로 '-' 포함 .md 후보를 거른 뒤 8hex 정규식으로
# 정확히 재확인한다 (canonical <prefix>.md, suffix가 8 hex 아닌 -agent-<hex> 등 제외).
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  base="${f##*/}"
  [[ "$base" =~ $HEX_RE ]] || continue
  # git-tracked 파일(README.md 등)은 보존
  git -C "$GIT_TOPLEVEL" ls-files --error-unmatch "$f" >/dev/null 2>&1 && continue
  rm -f "$f"
done < <(find "$PLANS_DIR" -maxdepth 1 -type f -name '*-*.md' -mtime +"$GC_AGE_DAYS" 2>/dev/null)

exit 0
