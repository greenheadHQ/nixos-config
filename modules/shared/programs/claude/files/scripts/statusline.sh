#!/usr/bin/env bash
# Claude Code custom statusline
#   plan 파일, status icons, cwd/branch, Cache TTL, rate limits 출력
#   stdin으로 JSON 세션 데이터를 받아 statusbar 내용을 stdout으로 출력
#
# 라인 구조 (3-way 분기):
#   L1: /set-icons (Jira/Slack/Figma/Memo) — 조건부, 미설정 시 라인 생략
#   L2:
#     - 비-git cwd: cwd 단독
#     - git main repo: cwd + branch
#     - git worktree: cwd 단독
#   L3 (worktree만): branch
#   L_M: Plan/Memory/Cache TTL + hit%
#   L_N: Rate Limits (5h/7d) — SSH 분기는 vertical glyph + bracket으로 압축

input=$(cat)

# 공유 helper. SESSION_STATE_DIR / is_safe_session_id 등 SSOT를 hook과 공유.
# pinning-guard.sh와 동일 패턴: 설치된 $HOME/.claude/lib 우선, repo fallback.
SESSION_STATE_LIB="${SESSION_STATE_LIB:-$HOME/.claude/lib/session-state.sh}"
if [ ! -f "$SESSION_STATE_LIB" ]; then
  STATUSLINE_DIR="$(cd "$(dirname "$0")" && pwd)"
  SESSION_STATE_LIB="$STATUSLINE_DIR/../lib/session-state.sh"
fi
# shellcheck source=../lib/session-state.sh disable=SC1091
[ -f "$SESSION_STATE_LIB" ] && . "$SESSION_STATE_LIB"

# ============================================================
# Helper: 입력 검증 + sanitize
# ============================================================

# URL 인자에 C0/DEL control 문자 포함 시 빈 문자열 반환 (universal sanitize)
sanitize_osc8_url() {
  local url=$1
  [ -z "$url" ] && return
  if printf '%s' "$url" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return
  fi
  printf '%s' "$url"
}

# path segment 내부 공백/control/예약 문자만 percent-encode (`/` separator 유지)
# byte-aware encoder: UTF-8 multi-byte 문자도 RFC 3986 octet 기준으로 인코딩
# `jq @uri`는 byte 단위 percent-encoding이고 ASCII unreserved를 그대로 둔다.
# `/`는 @uri가 `%2F`로 인코딩하므로 path separator 보존을 위해 다시 복원한다.
percent_encode_segment() {
  local input=$1
  [ -z "$input" ] && return
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$input" | jq -sRr '@uri | gsub("%2F"; "/")'
  else
    # fallback (jq 미가용 시): char-level encoder. ASCII만 안전, 비ASCII는 깨질 수 있음
    local i char hex
    local output=""
    local len=${#input}
    for (( i=0; i<len; i++ )); do
      char="${input:$i:1}"
      case "$char" in
        [a-zA-Z0-9._~/-]) output+="$char" ;;
        *) printf -v hex '%%%02X' "'$char"; output+="$hex" ;;
      esac
    done
    printf '%s' "$output"
  fi
}

# 디렉토리를 canonical absolute path로 변환. 미존재 시 빈 문자열
canonicalize_dir() {
  local dir=$1
  [ -z "$dir" ] && return
  (cd "$dir" 2>/dev/null && pwd -P) 2>/dev/null
}

# transcript_path validation (D-10: 진입 직후, file I/O 전체 신뢰 경계)
#   (a) 절대경로 (b) symlink 거부 (c) .jsonl 확장자
#   (d) dirname canonical 변환 + $HOME/.claude/projects/ canonical 경계 포함 prefix
#   (e) file canonical (realpath) 도 같은 root 하위
# 통과 시 canonical transcript dir 반환, 미통과 시 빈 문자열
validate_transcript_path() {
  local transcript=$1
  [ -z "$transcript" ] && return
  case "$transcript" in /*) ;; *) return ;; esac
  [ -L "$transcript" ] && return
  case "$transcript" in *.jsonl) ;; *) return ;; esac
  local dir canonical_dir canonical_root canonical_file
  dir=$(dirname "$transcript")
  canonical_dir=$(canonicalize_dir "$dir")
  [ -z "$canonical_dir" ] && return
  canonical_root=$(canonicalize_dir "$HOME/.claude/projects")
  [ -z "$canonical_root" ] && return
  case "$canonical_dir" in
    "$canonical_root"|"$canonical_root"/*) ;;
    *) return ;;
  esac
  # file 자체 realpath
  if command -v realpath >/dev/null 2>&1; then
    canonical_file=$(realpath "$transcript" 2>/dev/null)
  else
    canonical_file="$canonical_dir/$(basename "$transcript")"
  fi
  [ -z "$canonical_file" ] && return
  case "$canonical_file" in
    "$canonical_root"/*) ;;
    *) return ;;
  esac
  printf '%s' "$canonical_dir"
}

# session_id 패턴 검증 — lib/session-state.sh의 is_safe_session_id를 그대로 위임.
# lib source 실패 시(개발 환경 부재) 동일 정책의 inline fallback 사용.
# 정책 SSOT는 lib의 is_safe_session_id이며, 본 wrapper는 statusline 호출 표면만
# 유지하기 위한 thin alias이다.
validate_session_id() {
  if command -v is_safe_session_id >/dev/null 2>&1; then
    is_safe_session_id "$1"
    return $?
  fi
  # lib 미로드 fallback — 정책은 is_safe_session_id와 동일하게 유지한다.
  case "${1:-}" in
    "") return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *..*) return 1 ;;
  esac
  return 0
}

# cwd validation (D-2 보강: control 문자 거부 우선, 그 다음 절대경로 + canonical 디렉토리)
# control 문자 검사를 절대경로 검사보다 먼저 — 상대경로 형태 cwd에 control 문자가 있으면
# 검증 실패 fallback에서 raw display로 escape 주입되는 것을 방지
# 통과 시 canonical cwd 반환, 미통과 시 빈 문자열
canonicalize_cwd_check() {
  local cwd=$1
  [ -z "$cwd" ] && return
  if printf '%s' "$cwd" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return
  fi
  case "$cwd" in /*) ;; *) return ;; esac
  canonicalize_dir "$cwd"
}

# Display sanitize: control 문자가 라벨로 직접 흘러가지 않도록 거부
# 미통과 시 빈 문자열 반환 (호출부는 빈 문자열을 표시 skip으로 처리)
sanitize_display_text() {
  local t=$1
  [ -z "$t" ] && return
  if printf '%s' "$t" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    return
  fi
  printf '%s' "$t"
}

# $HOME 접두사를 `~`로 치환
tilde_shorten() {
  local p=$1
  if [ -n "$HOME" ] && [ "${p#"$HOME"}" != "$p" ]; then
    printf '~%s' "${p#"$HOME"}"
  else
    printf '%s' "$p"
  fi
}

# ============================================================
# Section 1-2 (통합): stdin JSON 필드 단일 jq 호출로 추출
#   audit Performance-1: 매초 fork 비용 절감 (4회 → 1회)
#   추출 후 transcript canonical validation 및 session_id resolution 수행
# ============================================================

if command -v jq >/dev/null 2>&1; then
  eval "$(printf '%s' "$input" | jq -r '
    @sh "TRANSCRIPT=\(.transcript_path // "")",
    @sh "STDIN_SESSION_ID=\(.session_id // "")",
    @sh "CWD=\(.cwd // "")",
    @sh "WS_WORKTREE=\(.workspace.git_worktree // "")",
    @sh "WORKTREE_BRANCH=\(.worktree.branch // "")",
    @sh "STDIN_COLS=\(.terminal.columns // "")"
  ' 2>/dev/null)" 2>/dev/null || true
fi

if [ -z "${TRANSCRIPT:-}" ]; then
  exit 0
fi

# transcript canonical validation (D-10)
CANONICAL_TRANSCRIPT_DIR=$(validate_transcript_path "$TRANSCRIPT")
TRANSCRIPT_VALID=false
if [ -n "$CANONICAL_TRANSCRIPT_DIR" ]; then
  TRANSCRIPT_VALID=true
fi

# session_id resolution (D-8): stdin.session_id // basename(transcript .jsonl) + 패턴 검증
SESSION_ID="${STDIN_SESSION_ID:-}"
if [ -z "$SESSION_ID" ]; then
  SESSION_ID=$(basename "$TRANSCRIPT" .jsonl)
fi
if ! validate_session_id "$SESSION_ID"; then
  SESSION_ID=""
fi

# ============================================================
# Section 3: HEAVY cache setup (D-15: CACHED_CWD invalidate)
# ============================================================

NOW=$(date +%s)
HEAVY_CACHE_DIR="${XDG_RUNTIME_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/claude-statusline}"
mkdir -p "$HEAVY_CACHE_DIR"

# Sidecar identity guard (D-8 + audit Edge Cases-1/2):
#   SESSION_ID 비어있거나 TRANSCRIPT_VALID=false면 sidecar I/O 전체 비활성
#   HEAVY_STATE, ICONS_FILE, LAST_STOP_FILE 모두 같은 guard로 묶음
SIDECAR_IO_ENABLED=false
HEAVY_STATE=""
if [ -n "$SESSION_ID" ] && $TRANSCRIPT_VALID; then
  SIDECAR_IO_ENABLED=true
  HEAVY_STATE="${HEAVY_CACHE_DIR}/heavy-${SESSION_ID}"
fi
HEAVY_INTERVAL=10
DO_HEAVY=true

# cwd 정규화 (위 jq 통합 추출에서 받음. 빈 문자열이면 $PWD fallback)
CWD=${CWD:-$PWD}

# Cached CWD 비교 → cwd 변경 시 timestamp 무관 DO_HEAVY=true
if $SIDECAR_IO_ENABLED && [ -f "$HEAVY_STATE" ]; then
  last_heavy=$(head -1 "$HEAVY_STATE" 2>/dev/null || echo 0)
  CACHED_CWD=""
  if [ -f "${HEAVY_STATE}.vars" ]; then
    eval "$(grep '^CACHED_CWD=' "${HEAVY_STATE}.vars" 2>/dev/null)" 2>/dev/null || true
  fi
  if [ "$CACHED_CWD" = "$CWD" ] && [ "$((NOW - last_heavy))" -lt "$HEAVY_INTERVAL" ]; then
    DO_HEAVY=false
  fi
fi

# ============================================================
# Section 4: SSH 감지
#   SSH 세션에서는 OSC 8 hyperlink 클릭 불가 → URL 비활성, 텍스트만
# ============================================================
IS_SSH=false
[ -n "$SSH_CONNECTION" ] && IS_SSH=true

CACHE_GUIDE_URL="https://github.com/greenheadHQ/nixos-config/blob/main/modules/shared/programs/claude/files/docs/cache-guide.md"
$IS_SSH && CACHE_GUIDE_URL=""

# 256-color 고정 그레이
MUTED="38;5;242"

# ============================================================
# Section 5: HEAVY 연산 (Plan/Memory/Cache TTL/Worktree/Branch)
# ============================================================
PLAN_FILE=""
MEMORY_LINK=""
MEMORY_LABEL=""
CACHE_TTL=300
IS_WORKTREE=false
GIT_BRANCH=""

if $DO_HEAVY; then

# -- Plan 파일 감지 (transcript valid 시에만)
#
# === Change Intent Record ===
# v1 (초기): 세션별 state file (.statusline-plan-<session_id>)로 격리.
#    resume/compact 시 동일 session_id로 fallback 정상 작동.
# v2: /clear 시 Claude Code가 새 transcript(= 새 session_id)를 생성하여
#    이전 session_id의 state file을 찾지 못하는 문제 발견.
#    프로젝트 단위 fallback (.statusline-plan-current) 추가.
# v3: 프로젝트 단위 fallback 사용 시 plan 파일 복사본 생성 (편집 충돌 방지).
#    복사본 이름: <원본>-<session_id 8자>.md.
# v4: TRANSCRIPT_VALID 조건 추가. canonical transcript dir에 state 파일 조립.
#    raw `dirname "$TRANSCRIPT"` 대신 canonical 경로 사용으로 path traversal 차단.
# v5 (이번): 프로젝트 단위 fallback(v2)과 복사본 생성(v3)을 제거.
#    [근거] 프로젝트 fallback은 영구·무차별적이어서, plan을 세운 적 없는
#    무관한 세션에도 "프로젝트의 마지막 plan"을 상속시켜 false positive를
#    유발했다 (하나의 plan이 장기간 다수의 새 세션에 전염되고, 세션마다
#    복사본을 양산해 plans 디렉토리를 오염시켰다).
#    이제 우선순위는 (1) transcript 직접 감지 (2) 세션별 state 뿐이다.
#    세션별 state는 유효한 SESSION_ID가 있고(SIDECAR_IO_ENABLED) transcript에서
#    plan을 감지했을 때만 기록되므로 (아래 첫 분기), 같은 session_id의
#    resume/compact 복원에만 쓰이고 교차 세션 누출이 없다. SESSION_ID 검증
#    실패(빈 값) 시 다른 sidecar I/O와 동일하게 state를 만들지 않는다 —
#    `.statusline-plan-${SESSION_ID:-unknown}`의 unknown fallback을 그대로 두면
#    같은 transcript dir의 모든 invalid identity가 `.statusline-plan-unknown`을
#    공유해 false positive가 축소 재발하므로, SIDECAR_IO_ENABLED 가드로 막는다.
#    trade-off: /clear로 session_id가 바뀐 직후 세션은 plan 아이콘이 사라진다.
#    의도적 컨텍스트 리셋이라 '잘못된 plan 표시'보다 안전한 실패 모드이며,
#    plan을 다시 보려면 사용자가 직접 열거나 plan mode를 재진입한다.
PLAN_STATE_FILE=""
if $SIDECAR_IO_ENABLED; then
  # SIDECAR_IO_ENABLED = 유효 SESSION_ID + TRANSCRIPT_VALID (Section 3). unknown fallback 불필요.
  PLAN_STATE_FILE="$CANONICAL_TRANSCRIPT_DIR/.statusline-plan-${SESSION_ID}"
fi

if $TRANSCRIPT_VALID && [ -f "$TRANSCRIPT" ]; then
  # agent_progress 이벤트 제외, agent plan 파일명 제외
  PLAN_FILE=$(grep -v '"type":"agent_progress"' "$TRANSCRIPT" 2>/dev/null \
    | grep -oE '"(filePath|file_path|planFilePath)":"[^"]*\.claude/plans/[^"]*\.md"' \
    | grep -v 'plans/[^"]*-agent-' \
    | tail -1 | sed 's/^"[^"]*":"//;s/"$//')
fi

# 우선순위: (1) transcript 직접 감지 → 세션별 state 기록  (2) 미감지 → 세션별 state 복원
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ] && [ -n "$PLAN_STATE_FILE" ]; then
  printf '%s' "$PLAN_FILE" > "$PLAN_STATE_FILE" 2>/dev/null
elif [ -z "$PLAN_FILE" ] && [ -n "$PLAN_STATE_FILE" ] && [ -f "$PLAN_STATE_FILE" ]; then
  PLAN_FILE=$(cat "$PLAN_STATE_FILE" 2>/dev/null)
fi

# -- Memory 감지 (canonical transcript dir 기반)
#
# === Change Intent Record ===
# v1 (PR #264): dirname(transcript_path)/memory/로 경로 유도.
#    main repo에서는 정상 동작하나 worktree 세션에서 아이콘 미표시 버그 발견.
#    원인: Claude Code는 findCanonicalGitRoot(.git → gitdir → commondir)로
#    worktree에서도 main repo의 memory를 사용하지만, transcript_path는
#    worktree별 프로젝트 디렉토리(~/.claude/projects/<worktree-encoded>/)에
#    저장되어 memory 경로와 불일치.
# v2: cwd + git rev-parse --git-common-dir로 canonical root를 해석.
#    transcript 경로에 memory/가 없으면 cwd에서 git common dir를 찾아
#    main repo 경로를 유도하고 ~/.claude/projects/<main-repo-encoded>/memory/를 구성.
#    trade-off: worktree 세션에서 git rev-parse 1~2회 추가 실행되지만,
#              main repo와 동일한 memory를 정확히 표시.
# v3 (orphan 감지): MEMORY.md에 등록되지 않은 파일은 Claude가 접근 불가
#    (getMemoryFiles는 MEMORY.md만 읽고 디렉토리를 스캔하지 않음).
#    orphan 존재 시 ⚠ 표시. 평소엔 깔끔하고 orphan 존재 시에만 시각적 신호.
# v4 (이번): canonical transcript dir 기반으로 변경. URL은 universal sanitize 적용.
if $TRANSCRIPT_VALID; then
  PROJECT_MEMORY_DIR="$CANONICAL_TRANSCRIPT_DIR/memory"
  GLOBAL_MEMORY_DIR="$HOME/.claude/memory"
  MEMORY_COUNT=0
  MEMORY_INDEX=""

  # worktree 보정: canonical transcript dir에 memory/가 없으면 cwd → canonical git root
  if [ ! -d "$PROJECT_MEMORY_DIR" ] && [ -n "$CWD" ] && [ -d "$CWD" ]; then
    GIT_COMMON=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null) || true
    if [ -n "$GIT_COMMON" ]; then
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

  if [ -d "$PROJECT_MEMORY_DIR" ]; then
    MEMORY_INDEX="$PROJECT_MEMORY_DIR/MEMORY.md"
    MEMORY_COUNT=$(find "$PROJECT_MEMORY_DIR" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
  fi

  if [ -d "$GLOBAL_MEMORY_DIR" ]; then
    GLOBAL_COUNT=$(find "$GLOBAL_MEMORY_DIR" -maxdepth 1 -name "*.md" ! -name "MEMORY.md" -type f 2>/dev/null | wc -l | tr -d ' ')
    MEMORY_COUNT=$((MEMORY_COUNT + GLOBAL_COUNT))
    [ -z "$MEMORY_INDEX" ] && MEMORY_INDEX="$GLOBAL_MEMORY_DIR/MEMORY.md"
  fi

  if [ "$MEMORY_COUNT" -gt 0 ] && [ -n "$MEMORY_INDEX" ] && [ -f "$MEMORY_INDEX" ]; then
    REFERENCED=$(grep -cE '^[[:space:]]*-[[:space:]]*\[.*\.md\]' "$MEMORY_INDEX" 2>/dev/null) || REFERENCED=0
    MEMORY_WARN=""
    [ "$MEMORY_COUNT" -gt "$REFERENCED" ] && MEMORY_WARN=$'\xe2\x9a\xa0'
    MEMORY_LINK="file://$(dirname "$MEMORY_INDEX")"
    MEMORY_LABEL="Memory (${MEMORY_COUNT}${MEMORY_WARN})"
  fi
fi

# -- Cache TTL detection
#
# === Change Intent Record ===
# v1 (PR #444): CACHE_TTL=300 하드코딩 (5분 전용).
# v2: Max 구독자 1시간 TTL 대응. transcript에서 assistant usage의
#   cache_creation.ephemeral_1h_input_tokens를 jq로 파싱하여 감지.
#   grep 대신 jq: user 메시지에 포함된 필드명 텍스트 오탐 방지 (DA Regression-F2).
#   sticky: 이전 heavy에서 감지한 CACHE_TTL을 vars에서 복원.
#     pure cache hit(cache_creation 없음)에서는 이전 값을 유지한다.
#     실측: 매 턴 새 메시지 추가로 cache_creation > 0 (최솟값 ~120 tokens),
#     ephemeral 상세도 항상 존재하므로 pure hit에 의한 stale은 발생하지 않음.
#   다운그레이드 감지: 마지막 cache_creation이 5m이면 300으로 복귀.
# v3 (이번): SIDECAR_IO_ENABLED 가드 추가. canonical transcript dir 기반.
# 우선순위: CLAUDE_CACHE_TTL env > transcript 감지 > vars 캐시 > 기본값 300
if [ -f "${HEAVY_STATE}.vars" ]; then
  eval "$(grep '^CACHE_TTL=' "${HEAVY_STATE}.vars" 2>/dev/null)" 2>/dev/null || true
fi
if $TRANSCRIPT_VALID && [ -f "$TRANSCRIPT" ]; then
  _detected=$(jq -r '
    select(.message.usage.cache_creation)
    | if .message.usage.cache_creation.ephemeral_1h_input_tokens > 0 then "3600"
      elif .message.usage.cache_creation.ephemeral_5m_input_tokens > 0 then "300"
      else empty end
  ' "$TRANSCRIPT" 2>/dev/null | tail -1)
  [ -n "$_detected" ] && CACHE_TTL="$_detected"
fi

# -- Worktree detection (D-14)
#    Primary: stdin.workspace.git_worktree (위 jq 통합에서 추출)
#    Fallback: git rev-parse --path-format=absolute --git-dir/--git-common-dir
#    워크트리일 때 메인 repo 경로(MAIN_REPO_DIR)도 함께 추출 — D-4 display용
MAIN_REPO_DIR=""
if [ -d "$CWD" ]; then
  GIT_DIR_ABS=$(git -C "$CWD" rev-parse --path-format=absolute --git-dir 2>/dev/null) || true
  GIT_COMMON_ABS=$(git -C "$CWD" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || true
fi

if [ -n "${WS_WORKTREE:-}" ]; then
  IS_WORKTREE=true
elif [ -n "${GIT_DIR_ABS:-}" ] && [ -n "${GIT_COMMON_ABS:-}" ] && [ "$GIT_DIR_ABS" != "$GIT_COMMON_ABS" ]; then
  IS_WORKTREE=true
fi

# 워크트리면 메인 repo 경로 = git_common_dir의 부모 (= .git의 부모 = repo root)
if $IS_WORKTREE && [ -n "${GIT_COMMON_ABS:-}" ]; then
  MAIN_REPO_DIR=$(dirname "$GIT_COMMON_ABS")
fi

# -- Branch 추출 (D-14: worktree.branch || git branch --show-current)
GIT_BRANCH="${WORKTREE_BRANCH:-}"
if [ -z "$GIT_BRANCH" ] && [ -d "$CWD" ]; then
  GIT_BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null) || true
fi

# -- Heavy 결과 저장 (D-15: CACHED_CWD 포함). SIDECAR_IO_ENABLED 가드
if $SIDECAR_IO_ENABLED; then
  printf 'PLAN_FILE=%q\nMEMORY_LINK=%q\nMEMORY_LABEL=%q\nCACHE_TTL=%q\nIS_WORKTREE=%q\nGIT_BRANCH=%q\nMAIN_REPO_DIR=%q\nCACHED_CWD=%q\n' \
    "$PLAN_FILE" "$MEMORY_LINK" "$MEMORY_LABEL" "$CACHE_TTL" "$IS_WORKTREE" "$GIT_BRANCH" "$MAIN_REPO_DIR" "$CWD" \
    > "${HEAVY_STATE}.vars"
  echo "$NOW" > "$HEAVY_STATE"
fi

else
  # Light run: 캐시된 변수 복원. SIDECAR_IO_ENABLED 시에만
  if $SIDECAR_IO_ENABLED && [ -f "${HEAVY_STATE}.vars" ]; then
    # shellcheck source=/dev/null
    source "${HEAVY_STATE}.vars" 2>/dev/null || true
  fi
  # bash bool 변수 복원 (eval 결과 string이라 '$IS_WORKTREE' 평가가 문자열일 수 있음)
  [ "$IS_WORKTREE" = "true" ] && IS_WORKTREE=true || IS_WORKTREE=false
fi

# CLAUDE_CACHE_TTL override
if [ -n "${CLAUDE_CACHE_TTL:-}" ] && [ "$CLAUDE_CACHE_TTL" -gt 0 ] 2>/dev/null; then
  CACHE_TTL=$CLAUDE_CACHE_TTL
fi

# ============================================================
# Section 6: Status icons 읽기 (Jira/Slack/Figma/Memo)
#   SESSION_ID 검증 통과 시에만 sidecar I/O
# ============================================================
ICONS_FILE=""
# SESSION_STATE_DIR은 lib/session-state.sh의 SSOT. lib 미로드 시 hook과 동일 경로
# 하드코딩으로 fallback (sidecar 파일은 동일 위치).
$SIDECAR_IO_ENABLED && ICONS_FILE="${SESSION_STATE_DIR:-$HOME/.claude/status-icons}/$SESSION_ID.json"

JIRA_URL="" JIRA_LABEL=""
SLACK_URL="" SLACK_LABEL=""
FIGMA_URL="" FIGMA_LABEL=""
MEMO_PATH="" MEMO_LABEL=""

if [ -n "$ICONS_FILE" ] && [ -f "$ICONS_FILE" ] && command -v jq >/dev/null 2>&1; then
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

# ============================================================
# Section 7: Rate Limits + cache hit %
# ============================================================
RATE_5H="" RATE_5H_RESET=""
RATE_7D="" RATE_7D_RESET=""
CACHE_READ=0
CACHE_CREATE=0

if command -v jq >/dev/null 2>&1; then
  eval "$(printf '%s' "$input" | jq -r '
    @sh "RATE_5H=\(.rate_limits.five_hour.used_percentage // "")",
    @sh "RATE_5H_RESET=\(.rate_limits.five_hour.resets_at // "")",
    @sh "RATE_7D=\(.rate_limits.seven_day.used_percentage // "")",
    @sh "RATE_7D_RESET=\(.rate_limits.seven_day.resets_at // "")",
    @sh "CACHE_READ=\(.context_window.current_usage.cache_read_input_tokens // 0)",
    @sh "CACHE_CREATE=\(.context_window.current_usage.cache_creation_input_tokens // 0)"
  ' 2>/dev/null)" 2>/dev/null || true
fi

CACHE_HIT_PCT=""
_cache_total=$((${CACHE_READ:-0} + ${CACHE_CREATE:-0}))
if [ "$_cache_total" -gt 0 ] 2>/dev/null; then
  CACHE_HIT_PCT=$((${CACHE_READ:-0} * 100 / _cache_total))
fi

# ============================================================
# Section 8: 폭/임계값 + display values (D-5: 정적 threshold)
# ============================================================
#
# === Change Intent Record ===
# v1 (초기): `stty size </dev/tty` → terminfo 80 fallback. controlling tty가
#    있는 환경에서는 정상 동작.
# v5: Claude Code v2.1.139부터 hook/statusline 자식에서 controlling tty가
#    제거되어 stty가 항상 실패. RATE_DETAIL이 항상 가장 좁은 fallback으로 떨어지는
#    회귀 발생. 폭 측정을 raw cols resolver `resolve_raw_terminal_cols`로 위임하여
#    5단계 chain으로 회복한다:
#      (1) CLAUDE_STATUSLINE_COLUMNS env (사용자 명시 override, 항상 우선)
#      (2) stdin .terminal.columns (forward-compat for upstream columns 요청 이슈)
#      (3) $COLUMNS env (interactive parent shell이 export 한 경우)
#      (4) stty size </dev/tty (pre-2.1.139 compatibility branch — v2.1.139+에서
#          항상 실패하지만 1회 fork 비용 미미. 사용자 명시 결정으로 유지.)
#      (5) 정적 기본값 140 cols (EFF_COLS=100 → detail=4 보장)
#    함수는 raw cols만 반환한다. EFF_COLS 보정 (`COLS - 40`)은 호출자 책임이며
#    아래 산식 그대로 유지한다.
#    상세 결정 근거는 .claude/plans/statusline-width-fallback.md 참조.
resolve_raw_terminal_cols() {
  # raw cols default → EFF_COLS=COLS-40=100 → detail=4 임계값(EFF_COLS>=88) 통과.
  #   기본값을 조정할 때 docs/임계값 매트릭스와 bats assertion 메시지도 함께
  #   갱신한다.
  local DEFAULT_RAW_COLS=140
  local v
  # decimal-only 가드: `0140` 같은 leading-zero 입력은 호출부의 `$((COLS - 40))`
  # 에서 bash 가 octal로 해석한다. canonical decimal (1-9 leading) 1-4자리 (1..9999)
  # 만 통과시킨다. 4자리 상한: 10000 이상 5자리+ 입력으로 bash 정수 연산이
  # 오염되는 것을 차단한다 (정상 터미널 폭 80-300 범위 충분히 포함).
  _is_decimal() {
    [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]]
  }

  # (1) CLAUDE_STATUSLINE_COLUMNS env — 명시 override, 항상 우선
  v=${CLAUDE_STATUSLINE_COLUMNS:-}
  if _is_decimal "$v"; then
    printf '%s' "$v"
    return
  fi

  # (2) stdin .terminal.columns (Section 1-2의 jq 추출 결과)
  v=${STDIN_COLS:-}
  if _is_decimal "$v"; then
    printf '%s' "$v"
    return
  fi

  # (3) $COLUMNS env (interactive parent shell이 export 한 경우)
  v=${COLUMNS:-}
  if _is_decimal "$v"; then
    printf '%s' "$v"
    return
  fi

  # (4) stty size </dev/tty (pre-2.1.139 compatibility branch, dead in v2.1.139+)
  # /dev/tty 가 stat-level 에서는 readable 이지만 controlling tty 부재 시 open이
  # ENXIO로 실패하면서 shell 이 직접 stderr를 낸다. command group 의 stderr 까지
  # 리다이렉트해서 noise 를 막는다.
  v=$({ stty size </dev/tty | awk '{print $2}'; } 2>/dev/null)
  if _is_decimal "$v"; then
    printf '%s' "$v"
    return
  fi

  # (5) 정적 기본값
  printf '%s' "$DEFAULT_RAW_COLS"
}

COLS=$(resolve_raw_terminal_cols)
if [ "$COLS" -lt 80 ]; then
  EFF_COLS=$COLS
else
  EFF_COLS=$((COLS - 40))
fi

# cwd canonical 검증 + display + URL
# D-4 update: 워크트리일 때 display는 `<메인 repo ~ 단축>:<worktree 폴더명>` 형식
#   (사용자 요청 — 풀 경로는 너무 길어 잘림). URL은 항상 canonical 풀 path (VSCode 정확 dispatch)
CWD_CANONICAL=$(canonicalize_cwd_check "$CWD")
if [ -n "$CWD_CANONICAL" ]; then
  if $IS_WORKTREE && [ -n "${MAIN_REPO_DIR:-}" ]; then
    MAIN_REPO_SHORT=$(tilde_shorten "$MAIN_REPO_DIR")
    WORKTREE_NAME=$(basename "$CWD_CANONICAL")
    CWD_DISPLAY="${MAIN_REPO_SHORT}:${WORKTREE_NAME}"
  else
    CWD_DISPLAY=$(tilde_shorten "$CWD_CANONICAL")
  fi
  CWD_URL=""
  if ! $IS_SSH; then
    CWD_URL_PATH=$(percent_encode_segment "$CWD_CANONICAL")
    # ?windowId=_blank — vscode:// URL handler는 window.openFoldersInNewWindow 설정을
    # 따르지 않고 기본적으로 마지막 활성 창을 덮어쓴다. query param이 공식 해결책으로
    # 항상 새 창을 강제한다 (microsoft/vscode#141548, 머지 commit bcc2da6).
    CWD_URL="vscode://file${CWD_URL_PATH}/?windowId=_blank"
  fi
else
  # 검증 실패: 텍스트만 표시. control 문자가 들어와 fallback으로 escape 주입되는 것 방지
  CWD_DISPLAY=$(sanitize_display_text "$(tilde_shorten "$CWD")")
  CWD_URL=""
fi

# ============================================================
# Section 9: Render helpers (D-11: 라인별 상태 격리)
# ============================================================

LINE_HAS_OUTPUT=false

begin_line() {
  LINE_HAS_OUTPUT=false
}

end_line() {
  $LINE_HAS_OUTPUT && printf '\n'
}

# print_icon: 아이콘 + 라벨 + 선택적 OSC 8 hyperlink 출력
#   D-9: URL 인자는 universal sanitize 후 %s로 출력 (escape 문자 분리)
#   $1=ansi_color $2=url $3=emoji_bytes $4=label
print_icon() {
  local color=$1
  local url=$2
  local emoji=$3
  local label=$4
  url=$(sanitize_osc8_url "$url")
  $LINE_HAS_OUTPUT && printf '  '
  if [ -n "$url" ]; then
    # OSC 8 hyperlink: escape sequence는 %b, URL은 %s, label은 %s
    printf '%b' "\e[4;${color}m\e]8;;"
    printf '%s' "$url"
    printf '%b' "\a${emoji} "
    printf '%s' "$label"
    printf '%b' "\e]8;;\a\e[0m"
  else
    printf '%b' "\e[${color}m${emoji} "
    printf '%s' "$label"
    printf '%b' "\e[0m"
  fi
  LINE_HAS_OUTPUT=true
}

# 캐시 히트율 suffix (render_cache_ttl 내부 호출)
_render_cache_hit() {
  [ -z "$CACHE_HIT_PCT" ] && return
  local sym color
  if [ "$CACHE_HIT_PCT" -ge 80 ] 2>/dev/null; then
    sym=$'\xe2\x9c\x93'; color="32"
  elif [ "$CACHE_HIT_PCT" -ge 50 ] 2>/dev/null; then
    sym=$'\xe2\x96\xb3'; color="33"
  else
    sym=$'\xe2\x9c\x97'; color="31"
  fi
  printf ' %b' "\e[${color}m${sym}"
  printf '%s%%' "$CACHE_HIT_PCT"
  printf '%b' "\e[0m"
}

# Cache TTL 렌더 + hit% suffix
render_cache_ttl() {
  local remaining=$1
  if [ "$remaining" -le 0 ]; then
    print_icon "$MUTED" "$CACHE_GUIDE_URL" "\xf0\x9f\x92\xa4" "expired"
    _render_cache_hit
    return
  fi
  local minutes=$((remaining / 60))
  local seconds=$((remaining % 60))
  local cache_label
  cache_label=$(printf '%d:%02d' "$minutes" "$seconds")
  local green_th=$((CACHE_TTL * 40 / 100))
  local yellow_th=$((CACHE_TTL * 20 / 100))
  local cache_color
  if [ "$remaining" -ge "$green_th" ]; then cache_color="32"
  elif [ "$remaining" -ge "$yellow_th" ]; then cache_color="33"
  else cache_color="31"
  fi
  print_icon "$cache_color" "$CACHE_GUIDE_URL" "\xe2\x8f\xb1\xef\xb8\x8f" "$cache_label"
  _render_cache_hit
}

rate_color() {
  if [ "${1:-0}" -ge 80 ] 2>/dev/null; then echo "31"
  elif [ "${1:-0}" -ge 50 ] 2>/dev/null; then echo "33"
  else echo "32"
  fi
}

format_remaining() {
  local secs=${1:-0}
  if [ "$secs" -le 0 ] 2>/dev/null; then echo "0m"; return; fi
  local d=$((secs / 86400)) h=$(((secs % 86400) / 3600)) m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%dd%dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh%02dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
}

# SSH gauge core glyphs: 9단계 vertical block (U+2581-2588).
# idx 0 = empty (출력은 literal " "로 치환), 1..8 = ▁..█.
SSH_BAR_GLYPHS=("" "▁" "▂" "▃" "▄" "▅" "▆" "▇" "█")

# 비-SSH: 10칸 horizontal bar (filled █ + empty ░). pct>0인데 filled=0이면
# 시각적으로 0%와 구별되도록 floor 보정해 minimum 1칸을 채운다.
_render_rate_bar_horizontal() {
  local pct=$1 color=$2
  local filled=$((pct / 10)) empty
  [ "$pct" -gt 0 ] 2>/dev/null && [ "$filled" -eq 0 ] && filled=1
  empty=$((10 - filled))
  local i bar_filled="" bar_empty=""
  for ((i=0; i<filled; i++)); do bar_filled+="█"; done
  for ((i=0; i<empty; i++)); do bar_empty+="░"; done
  printf '%b%s%b%s%b ' "\e[${color}m" "$bar_filled" "\e[${MUTED}m" "$bar_empty" "\e[0m"
}

# SSH: 좁은 폭(default 140 → EFF_COLS=100)에서 5h/7d 두 윈도우가 한 줄에 들어가도록
# 3 cell로 압축한 vertical 게이지. ▏▕ thinnest vertical bracket — SSH gauge container.
# 산식: idx = (pct==0)?0 : ((pct-1)*8/100 + 1). naive pct*8/100는 pct=1~12에서
# idx=0으로 떨어져 0%와 시각 구별이 불가능해진다. boundary 보정으로 1% 이상은
# 항상 idx>=1을 보장하고 idx<=8로 cap한다.
_render_rate_bar_ssh_vertical() {
  local pct=$1 color=$2
  local idx
  if [ "$pct" -eq 0 ] 2>/dev/null; then
    idx=0
  else
    idx=$(((pct - 1) * 8 / 100 + 1))
    [ "$idx" -gt 8 ] 2>/dev/null && idx=8
  fi
  local core
  if [ "$idx" -eq 0 ]; then
    core=" "
  else
    core="${SSH_BAR_GLYPHS[$idx]}"
  fi
  printf '%b▏%b%s%b▕%b ' "\e[${MUTED}m" "\e[${color}m" "$core" "\e[${MUTED}m" "\e[0m"
}

render_rate_window() {
  local pct=${1:-0} window=$2 resets_at=$3 now=$4 detail=${5:-4}
  pct=${pct%%.*}
  pct=${pct:-0}
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local color
  color=$(rate_color "$pct")

  if [ "$detail" -ge 2 ]; then
    if $IS_SSH; then
      _render_rate_bar_ssh_vertical "$pct" "$color"
    else
      _render_rate_bar_horizontal "$pct" "$color"
    fi
  fi

  printf '%b%s%b %s' "\e[${color}m" "${pct}%" "\e[0m" "$window"

  if [ -n "$resets_at" ] && [ "$resets_at" -gt 0 ] 2>/dev/null; then
    if [ "$detail" -ge 3 ]; then
      local remaining=$((resets_at - now))
      if [ "$remaining" -gt 0 ]; then
        printf ' %b%s%b %s' "\e[${MUTED}m" "→" "\e[0m" "$(format_remaining "$remaining")"
      fi
    fi
    if [ "$detail" -ge 4 ]; then
      local reset_fmt
      reset_fmt=$(date -r "$resets_at" "+%m/%d %H:%M" 2>/dev/null \
               || date -d "@$resets_at" "+%m/%d %H:%M" 2>/dev/null)
      [ -n "$reset_fmt" ] && printf ' %b(%s)%b' "\e[${MUTED}m" "$reset_fmt" "\e[0m"
    fi
  fi
}

# ============================================================
# Output: 라인별 출력 (D-13: begin_line/end_line 헬퍼만, context_lines 추상화 없음)
# ============================================================

# L1: /set-icons (Jira → Slack → Figma → Memo) — 조건부 라인
begin_line
if [ -n "$JIRA_URL" ] && [ -n "$JIRA_LABEL" ] && ! $IS_SSH; then
  print_icon "33" "$JIRA_URL" "\xe2\x9a\xa1" "$JIRA_LABEL"
fi
if [ -n "$SLACK_URL" ] && [ -n "$SLACK_LABEL" ] && ! $IS_SSH; then
  print_icon "35" "$SLACK_URL" "\xf0\x9f\x92\xac" "$SLACK_LABEL"
fi
if [ -n "$FIGMA_URL" ] && [ -n "$FIGMA_LABEL" ] && ! $IS_SSH; then
  print_icon "31" "$FIGMA_URL" "\xf0\x9f\x8e\xa8" "$FIGMA_LABEL"
fi
if [ -n "$MEMO_PATH" ] && [ -f "$MEMO_PATH" ]; then
  MEMO_URL="file://${MEMO_PATH}"; $IS_SSH && MEMO_URL=""
  print_icon "32" "$MEMO_URL" "\xf0\x9f\x93\x93" "${MEMO_LABEL:-Memo}"
fi
end_line

# L2: cwd + (워크트리가 아니면 같은 라인에 branch)
begin_line
if [ -n "$CWD_DISPLAY" ]; then
  # cwd 아이콘: 📁 (folder)
  print_icon "36" "$CWD_URL" "\xf0\x9f\x93\x81" "$CWD_DISPLAY"
fi
if ! $IS_WORKTREE; then
  if [ -n "$GIT_BRANCH" ]; then
    # branch 아이콘: 🌿 (no link)
    print_icon "32" "" "\xf0\x9f\x8c\xbf" "$GIT_BRANCH"
  fi
fi
end_line

# L3 (worktree만): branch
# basename(CWD_CANONICAL) == GIT_BRANCH면 L2가 이미 동일 토큰을 담고 있어 L3 라인째 생략.
#   L2 표시: $IS_WORKTREE && MAIN_REPO_DIR 분기는 "<repo>:<폴더명>", else는 풀 경로 끝에 폴더명.
#   어느 쪽이든 폴더명 토큰이 L2에 포함되므로 L3은 정보 손실 없이 생략 가능.
# CWD_CANONICAL 부재 시 basename 결과가 ""라 GIT_BRANCH와 일치 불가 → 가드 자연스럽게 비활성.
if $IS_WORKTREE; then
  begin_line
  WORKTREE_BASENAME=""
  [ -n "$CWD_CANONICAL" ] && WORKTREE_BASENAME=$(basename "$CWD_CANONICAL")
  if [ -n "$GIT_BRANCH" ] && [ "$WORKTREE_BASENAME" != "$GIT_BRANCH" ]; then
    print_icon "32" "" "\xf0\x9f\x8c\xbf" "$GIT_BRANCH"
  fi
  end_line
fi

# L_M: Plan/Memory/Cache TTL + hit%
begin_line
if [ -n "$PLAN_FILE" ] && [ -f "$PLAN_FILE" ]; then
  PLAN_URL="file://${PLAN_FILE}"; $IS_SSH && PLAN_URL=""
  print_icon "36" "$PLAN_URL" "\xf0\x9f\x93\x9d" "Plan"
fi
if [ -n "$MEMORY_LINK" ]; then
  MEMORY_URL="$MEMORY_LINK"; $IS_SSH && MEMORY_URL=""
  print_icon "34" "$MEMORY_URL" "\xf0\x9f\xa7\xa0" "$MEMORY_LABEL"
fi

# Cache TTL (기존 로직 유지, SESSION_ID 검증 통과 시에만)
CACHE_TTL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claude-hooks"
LAST_STOP_FILE=""
$SIDECAR_IO_ENABLED && LAST_STOP_FILE="${CACHE_TTL_DIR}/last-stop-${SESSION_ID}"
if [ -n "$LAST_STOP_FILE" ] && [ -f "$LAST_STOP_FILE" ]; then
  last_stop=$(cat "$LAST_STOP_FILE" 2>/dev/null)
  if [ -n "$last_stop" ] 2>/dev/null; then
    if [ "$last_stop" = "0" ]; then
      file_mtime=$(stat -c %Y "$LAST_STOP_FILE" 2>/dev/null \
                || /usr/bin/stat -f %m "$LAST_STOP_FILE" 2>/dev/null || echo 0)
      elapsed=$((NOW - file_mtime))
      remaining=$((CACHE_TTL - elapsed))
      render_cache_ttl "$remaining"
    elif [ "$last_stop" -gt 0 ] 2>/dev/null; then
      elapsed=$((NOW - last_stop))
      remaining=$((CACHE_TTL - elapsed))
      render_cache_ttl "$remaining"
    fi
  fi
fi
end_line

# L_N: Rate Limits (5h/7d) — 폭에 따라 progressive disclosure
if [ -n "$RATE_5H" ] || [ -n "$RATE_7D" ]; then
  if   [ "$EFF_COLS" -ge 88 ]; then RATE_DETAIL=4
  elif [ "$EFF_COLS" -ge 58 ]; then RATE_DETAIL=3
  elif [ "$EFF_COLS" -ge 40 ]; then RATE_DETAIL=2
  else RATE_DETAIL=1
  fi

  if [ -n "$RATE_5H" ]; then
    render_rate_window "$RATE_5H" "5h" "$RATE_5H_RESET" "$NOW" "$RATE_DETAIL"
  fi
  if [ -n "$RATE_5H" ] && [ -n "$RATE_7D" ]; then
    printf ' %b%s%b ' "\e[${MUTED}m" "|" "\e[0m"
  fi
  if [ -n "$RATE_7D" ]; then
    render_rate_window "$RATE_7D" "7d" "$RATE_7D_RESET" "$NOW" "$RATE_DETAIL"
  fi
  printf '\n'
fi
