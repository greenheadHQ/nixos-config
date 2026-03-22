#!/usr/bin/env bash
# Claude Code custom statusline - plan 파일 경로, status icons, rate limits 표시
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

# --- SSH 환경 감지 ---
# SSH 세션에서는 OSC 8 하이퍼링크가 클릭 불가하므로,
# 외부 링크(Jira/Slack/Figma)는 숨기고 로컬 상태(Plan/Memo/Memory)는 텍스트만 표시.
# SSH_CONNECTION은 sshd가 export하며 모든 자식 프로세스에서 상속됨.
# 비SSH 환경에서는 IS_SSH=false → 기존 동작 완전 유지 (fallback 안전).
IS_SSH=false
[ -n "$SSH_CONNECTION" ] && IS_SSH=true

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
    # CIR: MEMORY_INDEX(파일) 대신 dirname(디렉토리)을 링크 대상으로 사용.
    #   MEMORY_INDEX는 project/global fallback을 따르므로 dirname도 정확한 디렉토리를 가리킨다.
    #   대안: ${PROJECT_MEMORY_DIR} 직접 사용 → global-only 시나리오에서 dead link (DA 발견).
    MEMORY_LINK="file://$(dirname "$MEMORY_INDEX")"
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

# --- Rate Limits 읽기 ---
# v2.1.80에서 추가된 rate_limits 필드: Claude.ai 플랜의 5시간/7일 롤링 윈도우 사용률
# API 사용자나 필드 미지원 버전에서는 빈 값으로 graceful skip
RATE_5H="" RATE_5H_RESET=""
RATE_7D="" RATE_7D_RESET=""

if command -v jq >/dev/null 2>&1; then
  eval "$(echo "$input" | jq -r '
    @sh "RATE_5H=\(.rate_limits.five_hour.used_percentage // "")",
    @sh "RATE_5H_RESET=\(.rate_limits.five_hour.resets_at // "")",
    @sh "RATE_7D=\(.rate_limits.seven_day.used_percentage // "")",
    @sh "RATE_7D_RESET=\(.rate_limits.seven_day.resets_at // "")"
  ' 2>/dev/null)" 2>/dev/null || true
fi

# --- 출력 ---
# 아이콘을 한 줄에 렌더링. ANSI/OSC 코드는 %b로, 사용자 텍스트(label)는 %s로 출력하여
# label에 포함된 \n, \t 등이 printf에 의해 해석되는 것을 방지한다.
HAS_OUTPUT=false

# print_icon: 아이콘 하나를 출력
# $1=color_code $2=url (빈 문자열이면 OSC 8 생략) $3=emoji_bytes $4=label
print_icon() {
  $HAS_OUTPUT && printf '  '
  if [ -n "$2" ]; then
    # With link: underline + color + OSC 8 하이퍼링크
    printf '%b' "\e[4;${1}m\e]8;;${2}\a${3} "
    printf '%s' "$4"
    printf '%b' "\e]8;;\a\e[0m"
  else
    # Without link: color only (SSH 환경에서 사용)
    printf '%b' "\e[${1}m${3} "
    printf '%s' "$4"
    printf '%b' "\e[0m"
  fi
  HAS_OUTPUT=true
}

# rate_color: 사용률에 따른 ANSI 색상 코드 반환
# $1=percentage → 32(green <50%) / 33(yellow 50-79%) / 31(red ≥80%)
rate_color() {
  if [ "${1:-0}" -ge 80 ] 2>/dev/null; then echo "31"
  elif [ "${1:-0}" -ge 50 ] 2>/dev/null; then echo "33"
  else echo "32"
  fi
}

# format_remaining: 초 → 사람이 읽기 쉬운 형식 (XdYh / XhYYm / Xm)
format_remaining() {
  local secs=${1:-0}
  if [ "$secs" -le 0 ] 2>/dev/null; then echo "0m"; return; fi
  local d=$((secs / 86400)) h=$(((secs % 86400) / 3600)) m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' $d $h
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' $h $m
  else printf '%dm' $m
  fi
}

# render_rate_window: progress bar + 잔여 시간 + 리셋 시각
# $1=pct $2=window_name $3=resets_at(unix) $4=now(unix) $5=detail_level
# detail: 4=full, 3=no date, 2=no remaining, 1=no bar
render_rate_window() {
  local pct=${1:-0} window=$2 resets_at=$3 now=$4 detail=${5:-4}
  # 소수점 truncate (bash 산술은 정수만 지원, e.g. "37.5" → "37")
  pct=${pct%%.*}
  pct=${pct:-0}
  # pct를 0-100으로 clamp (음수/초과값 방어)
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local color
  color=$(rate_color "$pct")

  # Progress bar (detail ≥ 2)
  if [ "$detail" -ge 2 ]; then
    local filled=$((pct / 10)) empty
    # 0%가 아니면 최소 1블록으로 시각적 존재감 확보
    [ "$pct" -gt 0 ] 2>/dev/null && [ "$filled" -eq 0 ] && filled=1
    empty=$((10 - filled))
    local i bar_filled="" bar_empty=""
    for ((i=0; i<filled; i++)); do bar_filled+="█"; done
    for ((i=0; i<empty; i++)); do bar_empty+="░"; done
    printf '%b%s%b%s%b ' "\e[${color}m" "$bar_filled" "\e[90m" "$bar_empty" "\e[0m"
  fi

  # Percentage + window (always)
  printf '%b%s%b %s' "\e[${color}m" "${pct}%" "\e[0m" "$window"

  if [ -n "$resets_at" ] && [ "$resets_at" -gt 0 ] 2>/dev/null; then
    # → remaining (detail ≥ 3)
    if [ "$detail" -ge 3 ]; then
      local remaining=$((resets_at - now))
      if [ "$remaining" -gt 0 ]; then
        printf ' %b%s%b %s' "\e[90m" "→" "\e[0m" "$(format_remaining $remaining)"
      fi
    fi
    # (reset_date) (detail ≥ 4)
    if [ "$detail" -ge 4 ]; then
      local reset_fmt
      reset_fmt=$(date -r "$resets_at" "+%m/%d %H:%M" 2>/dev/null \
               || date -d "@$resets_at" "+%m/%d %H:%M" 2>/dev/null)
      [ -n "$reset_fmt" ] && printf ' %b(%s)%b' "\e[90m" "$reset_fmt" "\e[0m"
    fi
  fi
}

# 출력 순서: Link Icons → Rate Limits (별도 줄)

# Jira: yellow — ⚡ (SSH에서는 클릭 불가한 외부 URL이므로 숨김)
if [ -n "$JIRA_URL" ] && [ -n "$JIRA_LABEL" ] && ! $IS_SSH; then
  print_icon "33" "$JIRA_URL" "\xe2\x9a\xa1" "$JIRA_LABEL"
fi

# Slack: magenta — 💬 (SSH에서 숨김)
if [ -n "$SLACK_URL" ] && [ -n "$SLACK_LABEL" ] && ! $IS_SSH; then
  print_icon "35" "$SLACK_URL" "\xf0\x9f\x92\xac" "$SLACK_LABEL"
fi

# Figma: red — 🎨 (SSH에서 숨김)
if [ -n "$FIGMA_URL" ] && [ -n "$FIGMA_LABEL" ] && ! $IS_SSH; then
  print_icon "31" "$FIGMA_URL" "\xf0\x9f\x8e\xa8" "$FIGMA_LABEL"
fi

# Plan: cyan — 📝 (SSH에서는 링크 없이 텍스트만 표시)
# stale state file은 [ -f "$PLAN_FILE" ]에 의해 아이콘 미표시,
# 새 plan 생성 시 자연 덮어쓰기로 갱신됨
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  PLAN_URL="file://${PLAN_FILE}"; $IS_SSH && PLAN_URL=""
  print_icon "36" "$PLAN_URL" "\xf0\x9f\x93\x9d" "Plan"
fi

# Memo: green — 📓 (SSH에서는 링크 없이 텍스트만 표시)
if [ -n "$MEMO_PATH" ] && [ -f "$MEMO_PATH" ]; then
  MEMO_URL="file://${MEMO_PATH}"; $IS_SSH && MEMO_URL=""
  print_icon "32" "$MEMO_URL" "\xf0\x9f\x93\x93" "${MEMO_LABEL:-Memo}"
fi

# Memory: blue — 🧠 (SSH에서는 링크 없이 텍스트만 표시)
# statusline에서 직접 감지 (Plan과 동일한 방식, 상태 파일 불필요)
if [ -n "$MEMORY_LINK" ]; then
  MEMORY_URL="$MEMORY_LINK"; $IS_SSH && MEMORY_URL=""
  print_icon "34" "$MEMORY_URL" "\xf0\x9f\xa7\xa0" "$MEMORY_LABEL"
fi

# 아이콘이 하나라도 있으면 최종 개행
if $HAS_OUTPUT; then printf '\n'; fi

# Rate Limits: 터미널 폭에 따라 progressive disclosure
# detail 4: ██░░░░░░░░ 1% 5h → 3h49m (03/20 16:00) | █████████░ 97% 7d → 8h49m (03/20 21:00)
# detail 3: ██░░░░░░░░ 1% 5h → 3h49m | █████████░ 97% 7d → 8h49m
# detail 2: ██░░░░░░░░ 1% 5h | █████████░ 97% 7d
# detail 1: 1% 5h | 97% 7d
if [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; then
  # tput cols는 서브프로세스에서 항상 80 고정 → stty size </dev/tty로 실제 폭 조회
  COLS=$(stty size </dev/tty 2>/dev/null | awk '{print $2}')
  [ "${COLS:-0}" -gt 0 ] 2>/dev/null || COLS=80

  # === 유효 폭(EFF_COLS) 계산 ===
  # Claude Code statusbar는 좌측(statusline 출력)과 우측(토큰 수, 버전 등)을 한 줄에 배치.
  # COLS >= 80: 좌우 콘텐츠가 한 줄에 공존 → 우측 ~40자 감안하여 유효폭 축소.
  # COLS < 80: 줄바꿈이 발생하여 각 항목이 별도 행 → rate limits가 전체 폭 사용 가능.
  #   근거: ~50 cols 터미널(iPhone Termius)에서 아이콘/rate/토큰/버전이 각각 별도 행 확인.
  if [ "$COLS" -lt 80 ]; then
    EFF_COLS=$COLS
  else
    EFF_COLS=$((COLS - 40))
  fi

  # 콘텐츠 너비 기반 임계값:
  #   detail 4 = bar(11) + "100% 5h → 99d23h (12/31 23:59)"(~30) × 2 + sep(3) ≈ 최대 85자 → 임계값 88
  #   detail 3 = bar(11) + "100% 5h → 99d23h"(~16) × 2 + sep(3) ≈ 최대 55자 → 임계값 58
  #   detail 2 = bar(11) + "100% 5h"(7) × 2 + sep(3) = 최대 39자 → 임계값 40
  if   [ "$EFF_COLS" -ge 88 ]; then RATE_DETAIL=4
  elif [ "$EFF_COLS" -ge 58 ]; then RATE_DETAIL=3
  elif [ "$EFF_COLS" -ge 40 ]; then RATE_DETAIL=2
  else RATE_DETAIL=1
  fi

  NOW=$(date +%s)
  if [ -n "$RATE_5H" ]; then
    render_rate_window "$RATE_5H" "5h" "$RATE_5H_RESET" "$NOW" "$RATE_DETAIL"
  fi
  if [ -n "$RATE_5H" ] && [ -n "$RATE_7D" ]; then
    printf ' %b%s%b ' "\e[90m" "|" "\e[0m"
  fi
  if [ -n "$RATE_7D" ]; then
    render_rate_window "$RATE_7D" "7d" "$RATE_7D_RESET" "$NOW" "$RATE_DETAIL"
  fi
  printf '\n'
fi
