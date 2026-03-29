#!/usr/bin/env bash
# Claude Code Stop Hook - 세션 메트릭 수집 + pain point 정제
# stdin: JSON {session_id, transcript_path, agent_id}
# stdout: (없음)
#
# 키워드 감지는 UserPromptSubmit hook (detect-pain-point.sh)이 실시간 담당.
# 이 Stop hook은 세션 메트릭(턴 수, 시간) 기록 + 7일 distillation만 수행.

set -euo pipefail

umask 077

command -v jq >/dev/null 2>&1 || exit 0

[[ -n "${SKILL_EVAL_MODE:-}" ]] && exit 0
[[ -n "${PAIN_COLLECTING:-}" ]] && exit 0

# --- stdin 읽기 ---
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi
[ -n "$INPUT" ] || exit 0

AGENT_ID=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null || true)
[ -n "$AGENT_ID" ] && exit 0

SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null || true)

[ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ] || exit 0

# --- 설정 ---
PAIN_FILE="${PAIN_POINTS_FILE:-$HOME/.claude/pain-points.jsonl}"
ARCHIVE_FILE="${PAIN_ARCHIVE_FILE:-$HOME/.claude/pain-points.archive.jsonl}"
TURN_THRESHOLD=30

# --- Transcript 안정화 대기 (stop-notification.sh와 동일 패턴) ---
wait_for_stable_transcript() {
  local file="$1"
  local prev_size=-1
  local curr_size
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curr_size=$(wc -c < "$file" 2>/dev/null || echo 0)
    if [ "$curr_size" = "$prev_size" ] && [ "$curr_size" -gt 0 ]; then
      return 0
    fi
    prev_size=$curr_size
    sleep 0.3
  done
}
wait_for_stable_transcript "$TRANSCRIPT_PATH"

# --- Git 정보 (worktree 보정) ---
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null)" 2>/dev/null)
REPO="${REPO:-unknown}"
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
COMMON_DIR=$(git rev-parse --git-common-dir 2>/dev/null || true)
if [ -n "$COMMON_DIR" ] && [ "$COMMON_DIR" != ".git" ]; then
  REPO=$(basename "$(cd "$COMMON_DIR/.." 2>/dev/null && pwd)" 2>/dev/null || echo "$REPO")
fi

# --- 세션 메트릭 수집 ---

# 턴 수
TURNS=$(jq -Rrs '
  split("\n")
  | map(select(length > 0) | fromjson?)
  | map(select(.type == "user"))
  | length
' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")

# 세션 시간 (분)
DURATION_MIN=$(jq -Rrs '
  split("\n")
  | map(select(length > 0) | fromjson?)
  | map(.timestamp // empty | select(. != null and . != ""))
  | if length > 1 then
      ( (last | sub("\\.[0-9]+Z$"; "Z") | sub("\\+00:00$"; "Z") | fromdateiso8601)
      - (first | sub("\\.[0-9]+Z$"; "Z") | sub("\\+00:00$"; "Z") | fromdateiso8601) ) / 60 | floor
    else 0 end
' "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")

# 긴 세션(31턴+, TURN_THRESHOLD 초과)이면 메트릭 레코드 기록
# 중복 방지: 동일 session_id로 이미 기록된 long_session이 있으면 skip
# (Stop hook은 매 턴 발동하므로 30턴 이후 매번 기록되는 것을 방지)
if [ "$TURNS" -gt "$TURN_THRESHOLD" ]; then
  ALREADY_RECORDED=false
  if [ -f "$PAIN_FILE" ]; then
    ALREADY_RECORDED=$(jq -rs --arg sid "${SESSION_ID:-unknown}" \
      'map(select(.session_id == $sid and .signals.keyword == "long_session")) | length > 0' \
      "$PAIN_FILE" 2>/dev/null || echo "false")
  fi

  if [ "$ALREADY_RECORDED" != "true" ]; then
    TS=$(date -u +"%Y-%m-%dT%H:%M:%S+00:00")
    # append는 OS 레벨에서 원자적 (1줄 JSONL < PIPE_BUF)
    jq -nc \
      --arg ts "$TS" \
      --arg sid "${SESSION_ID:-unknown}" \
      --arg repo "$REPO" \
      --arg branch "$BRANCH" \
      --argjson turns "$TURNS" \
      --argjson dur "$DURATION_MIN" \
      '{
        ts: $ts, session_id: $sid, repo: $repo, branch: $branch,
        source: "auto", severity: "medium",
        signals: { keyword: "long_session", turns: ($turns), duration_min: ($dur) },
        description: ("\($turns)턴, \($dur)분 — 긴 세션"),
        user_note: null
      }' >> "$PAIN_FILE" 2>/dev/null || true
  fi
fi

# --- 정제: 7일 이전 항목 처리 ---
if [ -f "$PAIN_FILE" ] && [ -s "$PAIN_FILE" ]; then
  SEVEN_DAYS_AGO=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || true)

  if [ -n "$SEVEN_DAYS_AGO" ]; then
    OLD_COUNT=$(jq -rs --arg cutoff "$SEVEN_DAYS_AGO" --arg repo "$REPO" \
      'map(select(.ts < $cutoff and .repo == $repo)) | length' "$PAIN_FILE" 2>/dev/null || echo "0")

    if [ "$OLD_COUNT" -ge 5 ]; then
      OLD_ENTRIES=$(jq -rs --arg cutoff "$SEVEN_DAYS_AGO" --arg repo "$REPO" \
        'map(select(.ts < $cutoff and .repo == $repo))' "$PAIN_FILE" 2>/dev/null)

      # worktree에서도 canonical main repo 경로로 memory 디렉토리 탐색
      CANONICAL_ROOT=""
      GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null || true)
      if [ -n "$GIT_COMMON" ] && [ "$GIT_COMMON" != ".git" ]; then
        CANONICAL_ROOT=$(cd "$GIT_COMMON/.." 2>/dev/null && pwd)
      else
        CANONICAL_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
      fi
      if [ -n "$CANONICAL_ROOT" ]; then
        ENCODED=$(printf '%s' "$CANONICAL_ROOT" | sed 's|[^a-zA-Z0-9]|-|g')
        MEMORY_DIR="$HOME/.claude/projects/$ENCODED/memory"
      else
        MEMORY_DIR=""
      fi

      # claude -p로 패턴 분석 — best-effort
      if command -v claude >/dev/null 2>&1 && [ -n "$MEMORY_DIR" ] && [ -d "$MEMORY_DIR" ]; then
        DISTILL_PROMPT="아래 pain point 로그를 분석하세요. 반복 패턴(2회+)이 있으면 feedback memory를 생성하세요.

규칙:
- 2회 이상 반복되는 패턴만 memory로 추출
- 1회성 항목은 무시
- 출력: JSON {\"memories\": [{\"filename\": \"pain-xxx.md\", \"content\": \"---\nname: pain-xxx\ndescription: one-line\ntype: feedback\n---\n\n본문\n\n**Why:** 근거\n**How to apply:** 적용 방법\"}]}
- memory가 없으면 {\"memories\": []}

로그:
$OLD_ENTRIES"

        RESULT=$(printf '%s' "$DISTILL_PROMPT" | PAIN_COLLECTING=1 timeout 120 claude -p 2>/dev/null || echo "")

        if [ -n "$RESULT" ]; then
          MEMORY_COUNT=$(printf '%s' "$RESULT" | jq '.memories | length' 2>/dev/null || echo "0")
          for i in $(seq 0 $((MEMORY_COUNT - 1))); do
            FNAME=$(printf '%s' "$RESULT" | jq -r ".memories[$i].filename" 2>/dev/null || true)
            MCONTENT=$(printf '%s' "$RESULT" | jq -r ".memories[$i].content" 2>/dev/null || true)
            if [ -n "$FNAME" ] && [ "$FNAME" != "null" ] && [ -n "$MCONTENT" ] && [ "$MCONTENT" != "null" ] \
               && [[ "$FNAME" =~ ^pain-[a-zA-Z0-9_-]+\.md$ ]]; then
              printf '%s\n' "$MCONTENT" > "$MEMORY_DIR/$FNAME" 2>/dev/null || true
              MDESC=$(printf '%s' "$MCONTENT" | grep '^description:' | head -1 | sed 's/^description: *//' || true)
              if [ -f "$MEMORY_DIR/MEMORY.md" ] && ! grep -qF "$FNAME" "$MEMORY_DIR/MEMORY.md" 2>/dev/null; then
                printf -- '- [%s](%s) — %s\n' "$FNAME" "$FNAME" "${MDESC:-pain point 자동 정제}" >> "$MEMORY_DIR/MEMORY.md" 2>/dev/null || true
              fi
            fi
          done
        fi
      fi

      # mkdir 기반 lock으로 archive + rewrite를 원자적으로 수행 (macOS/Linux 호환)
      # patchClaudeJson (default.nix)과 동일 패턴
      PAIN_LOCK="$PAIN_FILE.lock.d"
      LOCK_ACQUIRED=false
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        if mkdir "$PAIN_LOCK" 2>/dev/null; then
          echo $$ > "$PAIN_LOCK/pid" 2>/dev/null
          LOCK_ACQUIRED=true
          break
        fi
        # stale lock 감지
        if [ -f "$PAIN_LOCK/pid" ]; then
          LOCK_PID=$(cat "$PAIN_LOCK/pid" 2>/dev/null || true)
          if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
            rm -rf "$PAIN_LOCK" 2>/dev/null
            continue
          fi
        elif [ -d "$PAIN_LOCK" ]; then
          # PID 파일 없는 stale lock (crash 등): 즉시 제거
          rm -rf "$PAIN_LOCK" 2>/dev/null
          continue
        fi
        sleep 0.5
      done

      if [ "$LOCK_ACQUIRED" = true ]; then
        ARCHIVE_OK=false
        if jq -rsc --arg cutoff "$SEVEN_DAYS_AGO" --arg repo "$REPO" \
          '.[] | select(.ts < $cutoff and .repo == $repo)' "$PAIN_FILE" >> "$ARCHIVE_FILE" 2>/dev/null; then
          ARCHIVE_OK=true
        fi

        if [ "$ARCHIVE_OK" = true ]; then
          tmp=$(mktemp 2>/dev/null) || true
          if [ -n "$tmp" ]; then
            jq -rsc --arg cutoff "$SEVEN_DAYS_AGO" --arg repo "$REPO" \
              '[.[] | select((.ts >= $cutoff) or (.repo != $repo))] | .[]' "$PAIN_FILE" > "$tmp" 2>/dev/null \
              && mv "$tmp" "$PAIN_FILE" \
              || rm -f "$tmp"
          fi
        fi

        rm -rf "$PAIN_LOCK" 2>/dev/null
      fi
    fi
  fi
fi

# 아카이브 30일 초과 정리
if [ -f "$ARCHIVE_FILE" ] && [ -s "$ARCHIVE_FILE" ]; then
  THIRTY_DAYS_AGO=$(date -u -v-30d +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || date -u -d "30 days ago" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null \
    || true)
  if [ -n "$THIRTY_DAYS_AGO" ]; then
    tmp=$(mktemp)
    jq -rsc --arg cutoff "$THIRTY_DAYS_AGO" \
      '[.[] | select(.ts >= $cutoff)] | .[]' "$ARCHIVE_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$ARCHIVE_FILE" \
      || rm -f "$tmp"
  fi
fi

exit 0
