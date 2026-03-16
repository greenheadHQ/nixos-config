#!/usr/bin/env bash
# Claude Code custom statusline - plan 파일 경로 + status icons 표시
# stdin으로 JSON 세션 데이터를 받아 statusbar 내용을 stdout으로 출력

input=$(cat)

TRANSCRIPT=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null) || true

# transcript_path 비어있으면 전체 skip
if [ -z "$TRANSCRIPT" ]; then
  exit 0
fi

# --- Session ID 추출 (Plan, Icons 공통 사용) ---
# 주의: session_id == basename(transcript_path, .jsonl) 가정
# statusline stdin에는 session_id 필드가 없으므로 transcript 파일명에서 유도한다.
SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)

# --- Plan 파일 감지 ---
# 현재 세션의 transcript에서 plan 파일 Read/Write 기록을 추출한다.
# ※ 이전 ls -t 방식은 세션과 무관하게 가장 최근 파일을 반환하여
#   다른 세션의 plan을 오표시하는 버그가 있었음 (worktree fallback 포함).
PLAN_FILE=""
PLAN_STATE_FILE=""

if [ -n "$TRANSCRIPT" ]; then
  # 상태 파일: session_id 포함하여 세션별 격리
  # context clear 후 새 transcript에 plan 기록이 없을 때 fallback으로 사용
  PLAN_STATE_FILE="$(dirname "$TRANSCRIPT")/.statusline-plan-${SESSION_ID}"
fi

if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  # agent_progress 이벤트 제외 (subagent가 다른 세션 plan을 읽은 기록 필터링)
  # agent plan 파일명(-agent-) 제외
  PLAN_FILE=$(grep -v '"type":"agent_progress"' "$TRANSCRIPT" 2>/dev/null \
    | grep -oE '"(filePath|file_path|planFilePath)":"[^"]*\.claude/plans/[^"]*\.md"' \
    | grep -v 'plans/[^"]*-agent-' \
    | tail -1 | sed 's/^"[^"]*":"//;s/"$//')
fi

# --- Plan state file 관리 ---
# 마이그레이션: 이전 프로젝트 단위 상태 파일 경로 (세션별 격리 이전)
LEGACY_PLAN_STATE="$(dirname "$TRANSCRIPT")/.statusline-plan"

if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] && [ -n "$PLAN_STATE_FILE" ]; then
  # transcript에서 plan 감지 성공 + 파일 존재 확인 → 상태 파일에 저장
  printf '%s' "$PLAN_FILE" > "$PLAN_STATE_FILE" 2>/dev/null
  # 레거시 파일 정리 (세션별 파일이 생성되었으므로 더 이상 불필요)
  rm -f "$LEGACY_PLAN_STATE" 2>/dev/null
elif [ -z "$PLAN_FILE" ] && [ -n "$PLAN_STATE_FILE" ] && [ -f "$PLAN_STATE_FILE" ]; then
  # transcript에서 감지 실패 (context clear 등) → 상태 파일에서 복원
  PLAN_FILE=$(cat "$PLAN_STATE_FILE" 2>/dev/null)
fi

# --- Memory 디렉토리 감지 ---
#
# === Change Intent Record ===
# v1 (PR #264): dirname(transcript_path)/memory/로 경로 유도.
#    main repo에서는 정상 동작하나 worktree 세션에서 아이콘 미표시 버그 발견.
#    원인: Claude Code는 findCanonicalGitRoot(.git → gitdir → commondir)로
#    worktree에서도 main repo의 memory를 사용하지만, transcript_path는
#    worktree별 프로젝트 디렉토리(~/.claude/projects/<worktree-encoded>/)에
#    저장되어 memory 경로와 불일치.
# v2 (이번): cwd + git rev-parse --git-common-dir로 canonical root를 해석.
#    transcript 경로에 memory/가 없으면 cwd에서 git common dir를 찾아
#    main repo 경로를 유도하고 zP 인코딩(non-alphanumeric → -)으로
#    ~/.claude/projects/<main-repo-encoded>/memory/를 구성.
#    trade-off: worktree 세션에서 git rev-parse 1~2회 추가 실행(~5ms)하지만,
#              main repo와 동일한 memory를 정확히 표시.
#
# orphan 감지 (v2 추가):
#    MEMORY.md에 등록되지 않은 파일은 Claude가 접근 불가(getMemoryFiles는
#    MEMORY.md만 읽고 디렉토리를 스캔하지 않음). orphan 존재 시 ⚠ 표시.
#    대안 검토: MEMORY.md 참조만 카운트 → 실제 파일 수와 괴리 혼동,
#              양쪽 분수 표시(5/7) → label 과도, 자동 등록/삭제 → 데이터 손실 위험.
#    trade-off: ⚠ 의미를 사용자가 알아야 하지만, 평소엔 깔끔하고
#              orphan 존재 시에만 시각적 신호를 제공.
MEMORY_LINK=""
MEMORY_LABEL=""

if [ -n "$TRANSCRIPT" ]; then
  PROJECT_MEMORY_DIR="$(dirname "$TRANSCRIPT")/memory"
  GLOBAL_MEMORY_DIR="$HOME/.claude/memory"
  MEMORY_COUNT=0
  MEMORY_INDEX=""

  # worktree 보정: transcript 경로에 memory/가 없으면 cwd에서 canonical root를 해석
  CWD=$(echo "$input" | jq -r '.cwd // empty' 2>/dev/null) || true
  if [ ! -d "$PROJECT_MEMORY_DIR" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
    GIT_COMMON=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null) || true
    if [ -n "$GIT_COMMON" ]; then
      # 상대 경로를 절대 경로로 변환
      if [[ "$GIT_COMMON" != /* ]]; then
        GIT_DIR=$(git -C "$CWD" rev-parse --git-dir 2>/dev/null) || true
        if [ -n "$GIT_DIR" ]; then
          [[ "$GIT_DIR" != /* ]] && GIT_DIR="$CWD/$GIT_DIR"
          GIT_COMMON=$(cd "$GIT_DIR" && cd "$GIT_COMMON" && pwd 2>/dev/null) || true
        fi
      fi
      if [ -n "$GIT_COMMON" ]; then
        MAIN_REPO=$(dirname "$GIT_COMMON")
        ENCODED=$(echo "$MAIN_REPO" | sed 's/[^a-zA-Z0-9]/-/g')
        CANONICAL_MEMORY="$HOME/.claude/projects/$ENCODED/memory"
        [ -d "$CANONICAL_MEMORY" ] && PROJECT_MEMORY_DIR="$CANONICAL_MEMORY"
      fi
    fi
  fi

  # 프로젝트 메모리 (주 표시 대상)
  if [ -d "$PROJECT_MEMORY_DIR" ]; then
    MEMORY_INDEX="$PROJECT_MEMORY_DIR/MEMORY.md"
    MEMORY_COUNT=$(find "$PROJECT_MEMORY_DIR" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  # 글로벌 메모리 (존재하면 합산)
  if [ -d "$GLOBAL_MEMORY_DIR" ]; then
    GLOBAL_COUNT=$(find "$GLOBAL_MEMORY_DIR" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    MEMORY_COUNT=$((MEMORY_COUNT + GLOBAL_COUNT))
    [ -z "$MEMORY_INDEX" ] && MEMORY_INDEX="$GLOBAL_MEMORY_DIR/MEMORY.md"
  fi

  if [ "$MEMORY_COUNT" -gt 0 ] && [ -n "$MEMORY_INDEX" ] && [ -f "$MEMORY_INDEX" ]; then
    # orphan 감지: MEMORY.md 참조 수 vs 실제 파일 수
    REFERENCED=$(grep -cE '^[[:space:]]*-[[:space:]]*\[.*\.md\]' "$MEMORY_INDEX" 2>/dev/null) || REFERENCED=0
    MEMORY_WARN=""
    [ "$MEMORY_COUNT" -gt "$REFERENCED" ] && MEMORY_WARN=$'\xe2\x9a\xa0'
    MEMORY_LINK="file://${MEMORY_INDEX}"
    MEMORY_LABEL="Memory (${MEMORY_COUNT}${MEMORY_WARN})"
  fi
fi

# --- Status icons 읽기 ---
# SessionStart hook은 session_id로 상태 파일을 생성하므로 이 가정이 깨지면 아이콘이 미표시된다.
ICONS_FILE="$HOME/.claude/status-icons/$SESSION_ID.json"

JIRA_URL="" JIRA_LABEL=""
SLACK_URL="" SLACK_LABEL=""
FIGMA_URL="" FIGMA_LABEL=""
MEMO_PATH="" MEMO_LABEL=""

if [ -n "$SESSION_ID" ] && [ -f "$ICONS_FILE" ] && command -v jq >/dev/null 2>&1; then
  # 단일 jq 호출로 모든 필드를 원자적으로 읽기 (TOCTOU 방지)
  # @sh로 shell-safe 이스케이프 (printf %b의 \n 해석 방지)
  eval "$(jq -r '
    @sh "JIRA_URL=\(.jira.url // "")",
    @sh "JIRA_LABEL=\(.jira.label // "")",
    @sh "SLACK_URL=\(.slack.url // "")",
    @sh "SLACK_LABEL=\(.slack.label // "")",
    @sh "FIGMA_URL=\(.figma.url // "")",
    @sh "FIGMA_LABEL=\(.figma.label // "")",
    @sh "MEMO_PATH=\(.memo.path // "")",
    @sh "MEMO_LABEL=\(.memo.label // "")"
  ' "$ICONS_FILE" 2>/dev/null)" 2>/dev/null || true
fi

# --- 출력 ---
# 아이콘을 한 줄에 렌더링. ANSI/OSC 코드는 %b로, 사용자 텍스트(label)는 %s로 출력하여
# label에 포함된 \n, \t 등이 printf에 의해 해석되는 것을 방지한다.
HAS_OUTPUT=false

# print_icon: 아이콘 하나를 OSC 8 하이퍼링크로 출력
# $1=color_code $2=url $3=emoji_bytes $4=label
print_icon() {
  $HAS_OUTPUT && printf '  '
  # ANSI start + OSC 8 open (URL은 사용자 입력이지만 OSC 8 spec상 escape 불필요)
  printf '%b' "\e[4;${1}m\e]8;;${2}\a${3} "
  # label은 %s로 안전하게 출력 (escape sequence 해석 방지)
  printf '%s' "$4"
  # OSC 8 close + ANSI reset
  printf '%b' "\e]8;;\a\e[0m"
  HAS_OUTPUT=true
}

# 아이콘 순서: Jira → Slack → Figma → Plan → Memo → Memory

# Jira: yellow underline — ⚡
if [ -n "$JIRA_URL" ] && [ -n "$JIRA_LABEL" ]; then
  print_icon "33" "$JIRA_URL" "\xe2\x9a\xa1" "$JIRA_LABEL"
fi

# Slack: magenta underline — 💬
if [ -n "$SLACK_URL" ] && [ -n "$SLACK_LABEL" ]; then
  print_icon "35" "$SLACK_URL" "\xf0\x9f\x92\xac" "$SLACK_LABEL"
fi

# Figma: red underline — 🎨
if [ -n "$FIGMA_URL" ] && [ -n "$FIGMA_LABEL" ]; then
  print_icon "31" "$FIGMA_URL" "\xf0\x9f\x8e\xa8" "$FIGMA_LABEL"
fi

# Plan: cyan underline — 📝
# stale state file은 [ -f "$PLAN_FILE" ]에 의해 아이콘 미표시,
# 새 plan 생성 시 자연 덮어쓰기로 갱신됨
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  print_icon "36" "file://${PLAN_FILE}" "\xf0\x9f\x93\x9d" "Plan"
fi

# Memo: green underline — 📓
if [ -n "$MEMO_PATH" ] && [ -f "$MEMO_PATH" ]; then
  print_icon "32" "file://${MEMO_PATH}" "\xf0\x9f\x93\x93" "${MEMO_LABEL:-Memo}"
fi

# Memory: blue underline — 🧠
# statusline에서 직접 감지 (Plan과 동일한 방식, 상태 파일 불필요)
if [ -n "$MEMORY_LINK" ]; then
  print_icon "34" "$MEMORY_LINK" "\xf0\x9f\xa7\xa0" "$MEMORY_LABEL"
fi

# 아이콘이 하나라도 있으면 최종 개행
if $HAS_OUTPUT; then printf '\n'; fi
