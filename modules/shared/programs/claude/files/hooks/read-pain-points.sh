#!/usr/bin/env bash
# Claude Code SessionStart Hook - Pain point 읽기
# stdin: JSON {session_id, source}
# stdout: JSON {hookSpecificOutput: {hookEventName, additionalContext}}
#
# 최근 7일 pain point를 severity별 섹션으로 그룹핑하여 additionalContext로 주입.
# Claude가 세션 시작 시 자동으로 읽어 행동을 조정할 수 있게 함.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# eval 모드에서는 pain point 주입 스킵 — 평가 세션 격리
[[ -n "${SKILL_EVAL_MODE:-}" ]] && exit 0
[[ -n "${PAIN_COLLECTING:-}" ]] && exit 0

INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -n "$INPUT" ] || exit 0

# 서브에이전트 가드
AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$AGENT_ID" ] && exit 0

# session-init-icons.sh과 동일 패턴: source를 파싱하여 startup만 처리
SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null || true)
case "$SOURCE" in
  startup) ;; # 신규 세션에서만 pain point 주입
  *) exit 0 ;; # clear/resume/compact에서는 불필요한 재주입 방지
esac

PAIN_FILE="${PAIN_POINTS_FILE:-$HOME/.claude/pain-points.jsonl}"

# 파일 없거나 비어있으면 skip
[ -f "$PAIN_FILE" ] && [ -s "$PAIN_FILE" ] || exit 0

# 현재 repo 이름 (worktree 보정)
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
REPO="${REPO:-unknown}"
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$COMMON_DIR" ] && [ "$COMMON_DIR" != ".git" ]; then
  REPO=$(basename "$(cd "$COMMON_DIR/.." 2>/dev/null && pwd)" 2>/dev/null || echo "$REPO")
fi

# 7일 전 날짜 계산 (macOS: -v, Linux: -d)
SEVEN_DAYS_AGO=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
  || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
  || exit 0)

# 최근 7일 + 현재 repo 필터 + 최근순 정렬 후 severity 섹션별 그룹핑 + 최대 5건
# (리서치: 컨텍스트 주입은 3-5건이 최적 — 과다 주입 시 노이즈)
CONTEXT=$(jq -rs --arg cutoff "$SEVEN_DAYS_AGO" --arg repo "$REPO" '
  map(select(.ts >= $cutoff and .repo == $repo))
  | sort_by(.ts) | reverse
  | .[0:5]
  | if length == 0 then empty
    else
      # 상호 배타적 그룹핑: manual은 source 기준, high/medium은 auto만
      (map(select(.severity == "high" and .source != "manual")) | length) as $high
      | (map(select(.severity == "medium" and .source == "auto")) | length) as $med
      | (map(select(.source == "manual")) | length) as $manual
      | . as $all
      |
      "## 최근 Pain Points (7일) -- \(length)건\n"
      + if $high > 0 then
          "\n### HIGH (\($high)건)\n"
          + ([$all[] | select(.severity == "high" and .source != "manual")]
            | map("- [\(.ts[5:10]) \(.session_id[0:8])] \(.description)\n  repo: \(.repo)/\(.branch)")
            | join("\n")) + "\n"
        else "" end
      + if $med > 0 then
          "\n### MEDIUM (\($med)건)\n"
          + ([$all[] | select(.severity == "medium" and .source == "auto")]
            | map("- [\(.ts[5:10]) \(.session_id[0:8])] \(.description)\n  repo: \(.repo)/\(.branch)")
            | join("\n")) + "\n"
        else "" end
      + if $manual > 0 then
          "\n### MANUAL (\($manual)건)\n"
          + ([$all[] | select(.source == "manual")]
            | map("- [\(.ts[5:10]) \(.session_id[0:8])] \(.user_note // .description)\n  repo: \(.repo)/\(.branch)")
            | join("\n")) + "\n"
        else "" end
    end
' "$PAIN_FILE" 2>/dev/null || true)

[ -n "$CONTEXT" ] || exit 0

jq -n --arg ctx "$CONTEXT" \
  '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":$ctx}}'

exit 0
