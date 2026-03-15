#!/usr/bin/env bash
# wt: Git worktree 관리 도구 (fzf TUI, tmux 통합)
# 사용법: wt [--stay] [--claude] [--tmux] <branch> | wt cd [--tmux] [-|name] | wt ls | wt cleanup [--auto]

# === Change Intent Record ===
# v1 (2025년 초~): 커스텀 wt/wt-cleanup 셸 함수 838줄 (zsh, fzf 기반)
#    .wt/ 경로, tmux 윈도우 통합, .wt-parent 부모 브랜치 추적
# v2 (PR #176, CLOSED): claude-wrapper.sh Killed: 9 수정 시도, wrapper 복잡성 한계 확인
# v3 (PR #180): Claude Code v2.x 내장 --worktree --tmux로 완전 대체, -1441줄 삭제
#    판단 근거: 내장 기능이 동일 역할을 수행하므로 코드 제거가 합리적
# v4 (PR #205): 내장 --worktree의 치명적 한계 확인 후 커스텀 구현 복구+고도화
#    한계 1: 항상 default branch 기준 분기 (Git Flow 환경에서 치명적, GitHub Issue #28958)
#    한계 2: Ctrl+C/Z 시 main worktree cwd로 복귀 (worktree 컨텍스트 유실)
#    한계 3: worktree 정리 도구 부재 (stale worktree 누적)
#    TUI 백엔드: gum (choose/filter/confirm/spin/style/table 6종 서브커맨드 활용)
# v5 (이번 변경): TUI 백엔드를 gum → fzf로 전환
#    전환 이유 1: gum의 wide character truncation 버그 — 한글 커밋 메시지가 바이트 경계에서
#               잘려서 인코딩이 깨짐 (CJK 2-column width 미고려)
#    전환 이유 2: fzf의 --preview 지원 — 선택 전 worktree 상태(커밋 로그, dirty) 미리보기 가능
#    전환 이유 3: 사용자가 fzf에 더 익숙하고, 프로젝트 전체가 이미 fzf 기반 (cheat, tmux, nfu)
#    trade-off: gum의 대화형 컴포넌트(choose/filter/confirm)를 잃지만,
#              fzf의 preview + 정확한 유니코드 처리가 실용적으로 더 우수.
#    보존: gum table/style은 표시 전용(wide char 무관)이므로 wt ls에서 유지.
# v6 (이번 변경): --tmux 플래그 추가 — tmux 밖에서 독립 tmux 세션 생성+attach
#    동기: claude --worktree --tmux와 유사한 경험을 wt에서도 제공
#    세션 이름: wt-<repo>-<dir_name> (repo별 네임스페이스 — 멀티 repo 충돌 방지)
#    핵심 제약: 래퍼의 subshell $() 안에서 exec tmux 불가 → --tmux 감지 시 우회
#    tmux 안에서 --tmux: 기존 윈도우 모드로 fallback (의도적 정책 — 세션 전환보다 윈도우가 워크플로우에 적합)

set -euo pipefail

# ── 상수 ─────────────────────────────────────────────────────────────────────

WORKTREE_DIR=".claude/worktrees"
WT_LAST_FILE=".claude/worktrees/.wt-last"

# ── 유틸리티 ─────────────────────────────────────────────────────────────────

_has_fzf() { command -v fzf &>/dev/null; }
_has_gum() { command -v gum &>/dev/null; }

# worktree 내부에서도 항상 main repo root를 정확히 찾음
_get_repo_root() {
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  # common_dir: main repo → ".git" (상대), worktree → "/repo/.git" (절대)
  # 어느 경우든 dirname이 repo root를 반환
  (cd "$(dirname "$common_dir")" && pwd)
}

# 브랜치명을 디렉토리명으로 변환 (슬래시 → 언더스코어)
_sanitize_name() {
  echo "${1//\//_}"
}

# 커밋 타임스탬프 → 상대 시간 (2d, 1w 등)
_relative_age() {
  local timestamp="$1"
  local now
  now=$(date +%s)
  local diff=$(( now - timestamp ))

  if (( diff < 3600 )); then
    echo "$((diff / 60))m"
  elif (( diff < 86400 )); then
    echo "$((diff / 3600))h"
  elif (( diff < 604800 )); then
    echo "$((diff / 86400))d"
  elif (( diff < 2592000 )); then
    echo "$((diff / 604800))w"
  else
    echo "$((diff / 2592000))mo"
  fi
}

_die() {
  echo "error: $*" >&2
  exit 1
}

# CIR: echo → printf ANSI 선택 — echo "$*"는 간결하지만 스타일링 불가.
#   gum style은 표시 전용에는 적합하나 매 호출마다 프로세스 fork 부담.
#   printf + 인라인 ANSI가 fork 없이 즉시 출력되어 가장 효율적.
_info() {
  printf '\033[38;5;179m› \033[38;5;245m%s\033[0m\n' "$*" >&2
}

# y/N 확인 프롬프트 (gum confirm 대체)
_confirm() {
  local msg="$1"
  printf "%s (y/N): " "$msg" >&2
  local yn
  read -r yn
  [[ "$yn" =~ ^[yY] ]]
}

# 단일 선택 (fzf 사용, fallback: 번호 선택)
_choose() {
  local header="${1:-선택}"
  shift
  local options=("$@")

  if _has_fzf; then
    printf '%s\n' "${options[@]}" | fzf --no-multi --height ~$((${#options[@]} + 4)) \
      --prompt "선택> " --header "$header"
  else
    echo "$header:" >&2
    local i=1
    for opt in "${options[@]}"; do
      echo "  $i) $opt" >&2
      ((i++))
    done
    printf "번호 [1-${#options[@]}]: " >&2
    local choice_num
    read -r choice_num
    if [[ "$choice_num" =~ ^[0-9]+$ ]] && (( choice_num >= 1 && choice_num <= ${#options[@]} )); then
      echo "${options[$((choice_num - 1))]}"
    else
      return 1
    fi
  fi
}

# ── tmux 헬퍼 ────────────────────────────────────────────────────────────────

# worktree 디렉토리에 해당하는 tmux 윈도우 찾기
# tmux 안/밖 모두 동작 — 서버 실행 여부만 확인
_wt_find_tmux_window() {
  local wt_path="$1"
  tmux list-sessions &>/dev/null || return 1

  # list-panes -a: 모든 세션의 모든 pane 검색 (분할 pane의 비활성 pane도 포함)
  # list-windows는 활성 pane 경로만 반환하므로 비활성 pane의 worktree를 놓칠 수 있음
  local window_id
  window_id=$(tmux list-panes -a -F '#{window_id} #{pane_current_path}' 2>/dev/null \
    | while read -r wid wpath; do
        if [[ "$wpath" == "$wt_path" || "$wpath" == "$wt_path/"* ]]; then
          echo "$wid"
          break
        fi
      done)

  [[ -n "$window_id" ]] && echo "$window_id" && return 0
  return 1
}

# tmux 윈도우 생성/전환
_wt_tmux_open() {
  local wt_path="$1"
  local window_name="$2"
  local stay="${3:-false}"

  [[ -z "${TMUX:-}" ]] && return 1

  # 이미 존재하는 윈도우 확인
  # return 2 = 기존 윈도우 재사용 (caller가 --claude send-keys 스킵 판단에 사용)
  local existing_window
  if existing_window=$(_wt_find_tmux_window "$wt_path"); then
    if [[ "$stay" == "true" ]]; then
      _info "기존 tmux 윈도우 유지 (background): $window_name"
    else
      tmux select-window -t "$existing_window"
      _info "기존 tmux 윈도우로 전환: $window_name"
    fi
    echo "$existing_window"
    return 2
  fi

  # 새 윈도우 생성
  local new_window
  if [[ "$stay" == "true" ]]; then
    new_window=$(tmux new-window -d -n "$window_name" -c "$wt_path" -P -F '#{window_id}')
    _info "tmux 윈도우 생성 (background): $window_name"
  else
    new_window=$(tmux new-window -n "$window_name" -c "$wt_path" -P -F '#{window_id}')
    _info "tmux 윈도우 생성: $window_name"
  fi

  echo "$new_window"
}

# tmux 윈도우에 셸 이외의 포그라운드 프로세스가 있는지 확인 (전체 pane 검사)
# 있으면 return 0 (true), 없으면 return 1 (false)
_wt_has_active_process() {
  local wt_path="$1"
  tmux list-sessions &>/dev/null || return 1

  local window_id
  window_id=$(_wt_find_tmux_window "$wt_path") || return 1

  # 모든 pane 검사 (분할 pane의 비활성 pane도 포함)
  local pane_cmd
  while IFS= read -r pane_cmd; do
    case "$pane_cmd" in
      zsh|bash|fish) ;;  # 셸 — 안전
      *)
        _info "스킵: $(basename "$wt_path") — 실행 중인 프로세스: $pane_cmd"
        return 0
        ;;
    esac
  done < <(tmux list-panes -t "$window_id" -F '#{pane_current_command}' 2>/dev/null)

  return 1
}

# ── tmux 세션 헬퍼 (--tmux 플래그용) ──────────────────────────────────────

# 세션 이름 생성: wt-<repo>-<dir> (repo별 네임스페이스로 충돌 방지)
# === Change Intent Record ===
# v1 (45aa39e): wt-<dir> — repo 구분 없이 dir_name만 사용.
#    멀티 repo에서 동명 브랜치 시 잘못된 세션 attach/kill (DA 피드백으로 발견)
# v2 (이번 변경, f862deb): wt-<repo>-<dir> — basename 네임스페이스 추가
#    거부한 대안 1: 이중 하이픈 구분자 (wt-repo--dir) — 하이픈 조합 충돌은 해결하나
#                  같은 basename의 다른 경로 repo 충돌은 미해결 (부분 수정)
#    거부한 대안 2: 경로 해시 접두사 (wt-a1b2c3-repo-dir) — 모든 충돌 해결하나
#                  세션 이름의 의미 없는 해시가 가독성을 해침
#    trade-off: 같은 basename repo 충돌은 미해결이지만,
#              ~/Workspace 내 프로젝트명이 고유하므로 실질적 충돌 없음.
#              가독성(tmux ls에서 한눈에 파악)이 완전한 유일성보다 가치 있음.
_wt_session_name() {
  local dir_name="$1"
  local repo_name
  repo_name=$(basename "$(_get_repo_root)" 2>/dev/null) || repo_name="default"
  # tmux target 구분자(. :)를 언더스코어로 치환
  repo_name="${repo_name//[.:]/_}"
  echo "wt-${repo_name}-${dir_name}"
}

# 세션 존재 확인 (= prefix: exact match — tmux default prefix matching 방지)
_wt_tmux_session_exists() {
  tmux has-session -t "=$1" 2>/dev/null
}

# 세션 생성/attach
_wt_tmux_session_open() {
  local wt_path="$1" session_name="$2" stay="$3" run_claude="$4"

  # 기존 세션 확인
  if _wt_tmux_session_exists "$session_name"; then
    if [[ "$stay" == "true" ]]; then
      _info "기존 tmux 세션 유지: $session_name"
      return 0
    fi
    _info "기존 tmux 세션으로 전환: $session_name"
    exec tmux attach-session -t "=$session_name"
  fi

  # 새 세션 생성
  if [[ "$run_claude" == "true" ]]; then
    tmux new-session -d -s "$session_name" -c "$wt_path"
    tmux send-keys -t "=$session_name" \
      "claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json" Enter
    if [[ "$stay" == "true" ]]; then
      _info "tmux 세션 생성 (detached): $session_name"
      _info "접속: tmux attach -t $session_name"
      return 0
    fi
    exec tmux attach-session -t "=$session_name"
  fi

  if [[ "$stay" == "true" ]]; then
    tmux new-session -d -s "$session_name" -c "$wt_path"
    _info "tmux 세션 생성 (detached): $session_name"
    _info "접속: tmux attach -t $session_name"
    return 0
  fi

  exec tmux new-session -s "$session_name" -c "$wt_path"
}

# 세션 정리 (cleanup용, = prefix: exact match)
# 연결된 클라이언트가 있으면 세션을 죽이지 않음 (활성 사용 보호)
_wt_tmux_session_close() {
  local session_name="$1"
  if tmux list-clients -t "=$session_name" 2>/dev/null | grep -q .; then
    _info "스킵: tmux 세션 '$session_name'에 연결된 클라이언트가 있습니다"
    return 1
  fi
  tmux kill-session -t "=$session_name" 2>/dev/null || true
}

# tmux 윈도우 안전하게 닫기
# tmux 안/밖 모두 동작 — 서버 실행 중이면 윈도우 정리 가능
_wt_tmux_close() {
  local wt_path="$1"
  tmux list-sessions &>/dev/null || return 0

  local window_id
  window_id=$(_wt_find_tmux_window "$wt_path") || return 0

  # 현재 윈도우는 닫지 않음 (tmux 세션 안에서만 해당)
  if [[ -n "${TMUX:-}" ]]; then
    local current_window
    current_window=$(tmux display-message -p '#{window_id}')
    if [[ "$window_id" == "$current_window" ]]; then
      _info "현재 윈도우는 닫을 수 없습니다: $(basename "$wt_path")"
      return 1
    fi
  fi

  # 마지막 윈도우 체크 (해당 세션 종료 방지)
  local session_windows
  session_windows=$(tmux display-message -t "$window_id" -p '#{session_windows}' 2>/dev/null) || true
  if (( ${session_windows:-0} <= 1 )); then
    _info "마지막 윈도우는 닫을 수 없습니다"
    return 1
  fi

  tmux kill-window -t "$window_id" 2>/dev/null || true
}

# ── 워크트리 정보 수집 ───────────────────────────────────────────────────────

# worktree 목록 수집
_collect_worktrees() {
  local git_root="$1"
  local wt_base="$git_root/$WORKTREE_DIR"

  [[ -d "$wt_base" ]] || return 0

  while IFS= read -r -d '' dir; do
    # .git 파일이 있는 디렉토리만 (유효한 worktree)
    [[ -f "$dir/.git" ]] && echo "$dir"
  done < <(find "$wt_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
}

# worktree의 브랜치명
_wt_branch() {
  local b
  b=$(git -C "$1" branch --show-current 2>/dev/null) || true
  echo "${b:-detached}"
}

# worktree의 마지막 커밋 타임스탬프
_wt_last_commit_ts() {
  git -C "$1" log -1 --format='%ct' 2>/dev/null || echo "0"
}

# worktree dirty 상태 체크
_wt_is_dirty() {
  local status
  status=$(git -C "$1" status --porcelain 2>/dev/null)
  [[ -n "$status" ]]
}

# worktree에 unpushed 커밋이 있는지 체크
_wt_has_unpushed() {
  local branch
  branch=$(_wt_branch "$1")
  [[ "$branch" == "detached" ]] && return 1

  local upstream
  upstream=$(git -C "$1" rev-parse --abbrev-ref "@{upstream}" 2>/dev/null) || return 0
  local ahead
  ahead=$(git -C "$1" rev-list --count "$upstream..HEAD" 2>/dev/null) || return 1
  (( ahead > 0 ))
}

# PR 상태 조회 (gh CLI)
# 인자: branch, git_root, [wt_path]
# wt_path가 주어지면 branch name reuse 감지: MERGED PR의 headRefOid와
# 현재 브랜치 HEAD를 비교하여, 다르면 NONE 반환 (동명의 다른 브랜치)
_wt_pr_status() {
  local branch="$1"
  local git_root="$2"
  local wt_path="${3:-}"

  if ! command -v gh &>/dev/null; then
    echo "NONE"
    return
  fi

  local remote_url
  remote_url=$(git -C "$git_root" remote get-url origin 2>/dev/null) || { echo "NONE"; return; }

  local pr_data
  pr_data=$(gh pr list --head "$branch" --state all --json state,headRefOid \
    --jq '.[0] | "\(.state) \(.headRefOid // "")"' \
    --repo "$remote_url" 2>/dev/null) || true

  local pr_state="${pr_data%% *}"
  local pr_head_oid="${pr_data#* }"

  # Branch name reuse guard: MERGED PR의 headRefOid가 현재 브랜치 HEAD와 다르면
  # 동일 이름의 새 브랜치이므로 NONE 처리 (stale PR로 auto-cleanup 방지)
  if [[ "$pr_state" == "MERGED" ]] && [[ -n "$wt_path" ]] && [[ -n "$pr_head_oid" ]]; then
    local branch_head
    branch_head=$(git -C "$wt_path" rev-parse HEAD 2>/dev/null) || true
    if [[ -n "$branch_head" && "$pr_head_oid" != "$branch_head" ]]; then
      echo "NONE"
      return
    fi
  fi

  case "$pr_state" in
    MERGED) echo "MERGED" ;;
    OPEN)   echo "OPEN" ;;
    CLOSED) echo "CLOSED" ;;
    *)      echo "NONE" ;;
  esac
}

# 마지막 커밋 메시지 (한 줄)
_wt_last_commit_msg() {
  git -C "$1" log -1 --format='%s' 2>/dev/null | cut -c1-60
}

# ── PR 상태 병렬 조회 ────────────────────────────────────────────────────────

# 모든 worktree의 PR 상태를 병렬로 조회하고 tmp_dir/*.pr에 저장
_fetch_pr_statuses() {
  local git_root="$1"
  local tmp_dir="$2"
  shift 2
  local worktrees=("$@")

  local pids=()
  for wt in "${worktrees[@]}"; do
    local branch name
    branch=$(_wt_branch "$wt")
    name=$(basename "$wt")
    (
      local pr_status
      pr_status=$(_wt_pr_status "$branch" "$git_root" "$wt")
      echo "$pr_status" > "$tmp_dir/$name.pr"
    ) &
    pids+=($!)
  done

  if (( ${#pids[@]} > 0 )); then
    _info "PR 상태 조회 중..."
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  fi
}

# ── Bootstrap ────────────────────────────────────────────────────────────────

_bootstrap_worktree() {
  local wt_path="$1"
  local git_root="$2"

  # 중첩 회귀 가드
  if [[ -d "$wt_path/.claude/.claude" ]] || [[ -d "$wt_path/.codex/.codex" ]]; then
    _die "중첩 .claude/.claude 또는 .codex/.codex 감지 — bootstrap 중단"
  fi

  # .claude/settings.local.json 복사 (파일 단위)
  local src_settings="$git_root/.claude/settings.local.json"
  local dst_claude_dir="$wt_path/.claude"
  if [[ -f "$src_settings" ]]; then
    mkdir -p "$dst_claude_dir"
    cp "$src_settings" "$dst_claude_dir/settings.local.json"
  fi

  # .codex/ 디렉토리 복사 (기존 제거 후 복사 — 중첩 방지)
  local src_codex="$git_root/.codex"
  if [[ -d "$src_codex" ]]; then
    rm -rf "$wt_path/.codex"
    cp -r "$src_codex" "$wt_path/.codex"
  fi

  # .claude/plans/ 제거 (worktree에서는 불필요)
  rm -rf "$wt_path/.claude/plans"
}

# ── worktree 열기 (tmux 또는 stdout) ─────────────────────────────────────────

_open_worktree() {
  local wt_path="$1" window_name="$2" stay="$3" run_claude="$4" use_tmux_session="${5:-false}"

  # --tmux: tmux 밖에서만 세션 모드 활성화 (tmux 안이면 윈도우 모드로 fallback — 의도적 정책)
  if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
    local session_name
    session_name=$(_wt_session_name "$window_name")
    _wt_tmux_session_open "$wt_path" "$session_name" "$stay" "$run_claude"
    return
  fi

  if [[ -n "${TMUX:-}" ]]; then
    local window_id open_rc=0
    window_id=$(_wt_tmux_open "$wt_path" "$window_name" "$stay") || open_rc=$?

    # tmux 연결 실패 (stale TMUX 환경변수 등) → fallback: 경로 stdout 출력
    if (( open_rc == 1 )); then
      _info "경고: tmux 윈도우 생성 실패 — 경로로 fallback합니다"
      [[ "$run_claude" == "true" ]] && _info "경고: --claude는 tmux 윈도우가 필요합니다"
      echo "$wt_path"
      return
    fi

    # --claude: 새 윈도우에서만 claude 실행 (open_rc == 0)
    # 기존 윈도우(open_rc == 2)에는 send-keys 하지 않음 — 실행 중인 프로세스에 주입 방지
    # send-keys로 큐잉 — 셸 초기화 완료 후 버퍼에서 읽어 실행 (레이스 안전)
    if [[ "$run_claude" == "true" ]] && [[ -n "${window_id:-}" ]]; then
      if (( open_rc == 0 )); then
        tmux send-keys -t "$window_id" \
          "claude --dangerously-skip-permissions --mcp-config ~/.claude/mcp.json" Enter
      else
        _info "기존 윈도우 — --claude 스킵 (실행 중인 프로세스 보호)"
      fi
    fi
  else
    # tmux 밖: 경로 stdout 출력 (래퍼가 cd)
    [[ "$run_claude" == "true" ]] && _info "경고: --claude는 tmux 세션 안에서만 동작합니다"
    if [[ "$stay" == "true" ]]; then
      # --stay: 현재 디렉토리 유지, 경로만 안내
      _info "worktree 경로: $wt_path"
    else
      echo "$wt_path"
    fi
  fi
}

# ── worktree 제거 (tmux 윈도우 포함) ─────────────────────────────────────────

_remove_worktree() {
  local wt_path="$1" branch="$2" git_root="$3"
  local name
  name=$(basename "$wt_path")

  # cwd 가드: 현재 셸이 삭제 대상 worktree 안에 있으면 중단
  local current_dir
  current_dir=$(pwd -P)
  if [[ "$current_dir" == "$wt_path" || "$current_dir" == "$wt_path/"* ]]; then
    _info "스킵: $name — 현재 작업 디렉토리가 이 worktree 안에 있습니다"
    return 1
  fi

  # 활성 프로세스 가드: tmux 윈도우에 실행 중인 프로세스(nvim, claude 등)가 있으면 중단
  if _wt_has_active_process "$wt_path"; then
    return 1
  fi

  # tmux 윈도우 닫기 (실패해도 worktree는 삭제)
  _wt_tmux_close "$wt_path" || true

  # tmux 세션 정리 (wt- 접두사 세션, 연결된 클라이언트 있으면 삭제 중단)
  local session_name
  session_name=$(_wt_session_name "$name")
  _wt_tmux_session_close "$session_name" || {
    _info "스킵: $name — 연결된 tmux 세션이 있어 삭제하지 않습니다"
    return 1
  }

  # worktree 제거
  git -C "$git_root" worktree remove --force "$wt_path" 2>/dev/null || rm -rf "$wt_path"

  # 브랜치 삭제 (detached가 아닌 경우)
  if [[ "$branch" != "detached" ]]; then
    git -C "$git_root" branch -D "$branch" 2>/dev/null || true
  fi

  _info "삭제: $name ($branch)"

  # worktree 제거 후, 해당 worktree가 마지막 rebuild 소스였는지 확인
  if [[ -f /tmp/nrs-state ]]; then
    local nrs_wt
    nrs_wt=$(jq -r '.worktree' /tmp/nrs-state 2>/dev/null || echo "")
    if [[ "$nrs_wt" == "$wt_path" ]]; then
      _info "⚠️  삭제된 worktree가 마지막 rebuild 소스였습니다."
      _info "   심링크가 dangling 상태일 수 있습니다."
      _info "   main repo에서 rebuild를 실행하거나 'nrs-restore'를 실행하세요."
    fi
  fi
}

# ── 서브커맨드: create ───────────────────────────────────────────────────────

cmd_create() {
  local stay=false
  local run_claude=false
  local use_tmux_session=false
  local branch_name=""

  # 옵션 파싱
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stay)   stay=true ;;
      --claude) run_claude=true ;;
      --tmux)   use_tmux_session=true ;;
      -h|--help) show_help; return 0 ;;
      -*)       _die "알 수 없는 옵션: $1" ;;
      *)
        [[ -n "$branch_name" ]] && _die "브랜치명이 이미 지정됨: $branch_name (추가: $1)"
        branch_name="$1"
        ;;
    esac
    shift
  done

  [[ -z "$branch_name" ]] && _die "브랜치명을 지정하세요. 사용법: wt [--stay] [--claude] <branch>"

  local git_root
  git_root=$(_get_repo_root) || _die "Git 저장소가 아닙니다"

  # 현재 브랜치 기록 (.wt-parent용)
  local parent_branch
  parent_branch=$(git branch --show-current 2>/dev/null)
  if [[ -z "$parent_branch" ]]; then
    parent_branch=$(git rev-parse --short HEAD 2>/dev/null) || parent_branch="unknown"
  fi

  # 디렉토리명 결정
  local dir_name
  dir_name=$(_sanitize_name "$branch_name")
  local worktree_dir="$git_root/$WORKTREE_DIR/$dir_name"

  # 슬래시 포함 브랜치: 디렉토리명 매핑 안내 (슬래시→언더스코어 변환 인지용)
  if [[ "$dir_name" != "$branch_name" ]]; then
    _info "디렉토리명: $dir_name (← $branch_name)"
  fi

  # 기존 디렉토리 처리
  if [[ -d "$worktree_dir" ]]; then
    if [[ -f "$worktree_dir/.git" ]]; then
      _handle_existing_worktree "$worktree_dir" "$branch_name" "$git_root" "$parent_branch" "$stay" "$run_claude" "$use_tmux_session"
      return $?
    fi
    # 디렉토리는 있지만 유효한 worktree가 아님 → 정리 후 새로 생성
    rm -rf "$worktree_dir"
  fi

  # 기존 브랜치 존재 확인
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    _handle_existing_branch "$worktree_dir" "$branch_name" "$git_root" "$parent_branch" "$stay" "$run_claude" "$use_tmux_session"
    return $?
  fi

  # 새 worktree 생성 (현재 HEAD 기준)
  mkdir -p "$(dirname "$worktree_dir")"
  git worktree add -b "$branch_name" "$worktree_dir" >&2 || _die "worktree 생성 실패"

  echo "$parent_branch" > "$worktree_dir/.wt-parent"
  _bootstrap_worktree "$worktree_dir" "$git_root"

  _info "worktree 생성: $branch_name (from $parent_branch)"

  _open_worktree "$worktree_dir" "$dir_name" "$stay" "$run_claude" "$use_tmux_session"
}

# 기존 worktree 처리
_handle_existing_worktree() {
  local worktree_dir="$1" branch_name="$2" git_root="$3" parent_branch="$4" stay="$5" run_claude="$6" use_tmux_session="${7:-false}"
  local dir_name
  dir_name=$(basename "$worktree_dir")

  local choice
  choice=$(_choose "worktree '$branch_name'이(가) 이미 존재합니다" "기존 열기" "재생성" "취소") || return 1

  case "$choice" in
    "기존 열기")
      _open_worktree "$worktree_dir" "$dir_name" "$stay" "$run_claude" "$use_tmux_session"
      ;;
    "재생성")
      # unpushed/dirty 경고
      local warnings=()
      _wt_is_dirty "$worktree_dir" && warnings+=("uncommitted 변경사항이 있습니다")
      _wt_has_unpushed "$worktree_dir" && warnings+=("push하지 않은 커밋이 있습니다")

      if (( ${#warnings[@]} > 0 )); then
        echo "경고:" >&2
        for w in "${warnings[@]}"; do
          echo "  - $w" >&2
        done
        _confirm "정말 재생성하시겠습니까? (모든 변경사항 삭제)" || { _info "취소됨"; return 1; }
      fi

      # cwd 가드: 현재 셸이 대상 worktree 안에 있으면 재생성 불가
      local current_dir
      current_dir=$(pwd -P)
      if [[ "$current_dir" == "$worktree_dir" || "$current_dir" == "$worktree_dir/"* ]]; then
        _info "재생성 불가: 현재 작업 디렉토리가 이 worktree 안에 있습니다"
        _info "다른 디렉토리에서 다시 시도하세요"
        return 1
      fi

      # 활성 프로세스 가드: tmux 윈도우에 실행 중인 프로세스가 있으면 재생성 불가
      if _wt_has_active_process "$worktree_dir"; then
        _info "다른 프로세스를 종료한 뒤 다시 시도하세요"
        return 1
      fi

      _wt_tmux_close "$worktree_dir" || true
      # tmux 세션 정리 (연결된 클라이언트 있으면 재생성 중단)
      local _recreate_session
      _recreate_session=$(_wt_session_name "$dir_name")
      _wt_tmux_session_close "$_recreate_session" || {
        _info "재생성 불가: tmux 세션에 연결된 클라이언트가 있습니다"
        _info "세션을 종료한 뒤 다시 시도하세요"
        return 1
      }
      git worktree remove --force "$worktree_dir" 2>/dev/null || rm -rf "$worktree_dir"
      git worktree prune 2>/dev/null || true
      git branch -D "$branch_name" >&2 2>/dev/null || true

      git worktree add -b "$branch_name" "$worktree_dir" >&2 || _die "worktree 재생성 실패"
      echo "$parent_branch" > "$worktree_dir/.wt-parent"
      _bootstrap_worktree "$worktree_dir" "$git_root"
      _info "worktree 재생성: $branch_name (from $parent_branch)"
      _open_worktree "$worktree_dir" "$dir_name" "$stay" "$run_claude" "$use_tmux_session"
      ;;
    *)
      _info "취소됨"
      return 1
      ;;
  esac
}

# 기존 브랜치 처리 (worktree 없음)
_handle_existing_branch() {
  local worktree_dir="$1" branch_name="$2" git_root="$3" parent_branch="$4" stay="$5" run_claude="$6" use_tmux_session="${7:-false}"
  local dir_name
  dir_name=$(basename "$worktree_dir")

  # 브랜치가 다른 worktree에 이미 checkout되어 있는지 확인
  # (checkout된 브랜치는 worktree add/branch -D 모두 실패)
  local branch_ref="refs/heads/$branch_name"
  local checked_out_at
  checked_out_at=$(git worktree list --porcelain 2>/dev/null | awk -v ref="$branch_ref" '
    /^worktree / { wt = substr($0, 10) }
    /^branch / && substr($0, 8) == ref { print wt; exit }
  ')
  if [[ -n "$checked_out_at" ]]; then
    _info "브랜치 '$branch_name'이(가) 이미 checkout되어 있습니다: $checked_out_at"
    _info "다른 브랜치로 전환 후 다시 시도하세요"
    return 1
  fi

  local choice
  choice=$(_choose "브랜치 '$branch_name'이(가) 이미 존재합니다 (worktree 없음)" "기존 브랜치 사용" "새로 생성" "취소") || return 1

  case "$choice" in
    "기존 브랜치 사용")
      mkdir -p "$(dirname "$worktree_dir")"
      git worktree add "$worktree_dir" "$branch_name" >&2 || _die "worktree 생성 실패"
      echo "$parent_branch" > "$worktree_dir/.wt-parent"
      _bootstrap_worktree "$worktree_dir" "$git_root"
      _info "worktree 생성 (기존 브랜치): $branch_name"
      _open_worktree "$worktree_dir" "$dir_name" "$stay" "$run_claude" "$use_tmux_session"
      ;;
    "새로 생성")
      # 커밋 유실 경고: 현재 HEAD에서 도달 불가능한 커밋이 있으면 확인
      local ahead_count
      ahead_count=$(git rev-list --count "HEAD..$branch_name" 2>/dev/null) || true
      if (( ${ahead_count:-0} > 0 )); then
        _info "경고: '$branch_name'에 현재 HEAD에 없는 커밋 ${ahead_count}개가 있습니다"
        _confirm "브랜치를 삭제하고 새로 생성하시겠습니까?" || { _info "취소됨"; return 1; }
      fi
      git branch -D "$branch_name" >&2 2>/dev/null || true
      mkdir -p "$(dirname "$worktree_dir")"
      git worktree add -b "$branch_name" "$worktree_dir" >&2 || _die "worktree 생성 실패"
      echo "$parent_branch" > "$worktree_dir/.wt-parent"
      _bootstrap_worktree "$worktree_dir" "$git_root"
      _info "worktree 생성 (브랜치 재생성): $branch_name (from $parent_branch)"
      _open_worktree "$worktree_dir" "$dir_name" "$stay" "$run_claude" "$use_tmux_session"
      ;;
    *)
      _info "취소됨"
      return 1
      ;;
  esac
}

# ── 서브커맨드: cd ───────────────────────────────────────────────────────────

cmd_cd() {
  local git_root
  git_root=$(_get_repo_root) || _die "Git 저장소가 아닙니다"

  local wt_base="$git_root/$WORKTREE_DIR"
  [[ -d "$wt_base" ]] || _die "worktree가 없습니다: $wt_base"

  # worktree 목록 수집
  local worktrees=()
  while IFS= read -r wt; do
    [[ -n "$wt" ]] && worktrees+=("$wt")
  done < <(_collect_worktrees "$git_root")

  (( ${#worktrees[@]} == 0 )) && _die "활성 worktree가 없습니다"

  local target_path=""
  local use_tmux_session=false
  local search=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tmux) use_tmux_session=true ;;
      -)      search="-" ;;
      -*)     _die "알 수 없는 옵션: $1" ;;
      *)
        [[ -n "$search" ]] && _die "검색어가 이미 지정됨: $search (추가: $1)"
        search="$1"
        ;;
    esac
    shift
  done

  # wt cd - : 이전 worktree로 이동 (cd -, git checkout - 와 동일 패턴)
  if [[ "$search" == "-" ]]; then
    local last_file="$git_root/$WT_LAST_FILE"
    [[ -f "$last_file" ]] || _die "이전 worktree 기록이 없습니다"
    local last_path
    last_path=$(cat "$last_file")
    if [[ ! -d "$last_path" ]]; then
      _info "이전 worktree가 삭제됨: $(basename "$last_path") → main repo로 이동"
      last_path="$git_root"
    fi
    # 현재 위치 저장 후 이동
    local current_dir
    current_dir=$(pwd -P)
    echo "$current_dir" > "$last_file"

    # --tmux: 세션 모드 (tmux 밖에서만)
    if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
      local session_name
      session_name=$(_wt_session_name "$(basename "$last_path")")
      _wt_tmux_session_open "$last_path" "$session_name" "false" "false"
      return 0
    fi

    echo "$last_path"
    return 0
  fi

  if [[ -n "$search" ]]; then
    # substring 매치: 디렉토리명 + 브랜치명 + sanitized 검색어 모두 시도
    local sanitized_search
    sanitized_search=$(_sanitize_name "$search")
    for wt in "${worktrees[@]}"; do
      local name branch
      name=$(basename "$wt")
      branch=$(_wt_branch "$wt")
      if [[ "$name" == *"$search"* ]] || [[ "$name" == *"$sanitized_search"* ]] \
        || [[ "$branch" == *"$search"* ]]; then
        target_path="$wt"
        break
      fi
    done
    [[ -z "$target_path" ]] && _die "매치하는 worktree 없음: $search"
  else
    # 인터랙티브 선택 (fzf + preview)
    local names=()
    for wt in "${worktrees[@]}"; do
      names+=("$(basename "$wt")")
    done

    local selected
    if _has_fzf; then
      selected=$(printf '%s\n' "${names[@]}" | fzf --no-multi \
        --header "worktree 선택" --prompt "cd> " \
        --preview "git -C '$wt_base/{}' log --oneline -5 2>/dev/null; echo '---'; git -C '$wt_base/{}' status --short 2>/dev/null" \
        --preview-window right,75% --preview-label "worktree 상태") || return 1
    else
      echo "worktree 선택:" >&2
      local i=1
      for n in "${names[@]}"; do
        echo "  $i) $n" >&2
        ((i++))
      done
      printf "번호: " >&2
      local choice_num
      read -r choice_num
      if ! [[ "$choice_num" =~ ^[0-9]+$ ]] || (( choice_num < 1 || choice_num > ${#names[@]} )); then
        _die "잘못된 선택"
      fi
      selected="${names[$((choice_num - 1))]}"
    fi

    target_path="$wt_base/$selected"
  fi

  # 이전 worktree 경로 저장 (wt cd - 용)
  local current_dir
  current_dir=$(pwd -P)
  echo "$current_dir" > "$git_root/$WT_LAST_FILE"

  # --tmux: 세션 attach/생성 (tmux 밖에서만)
  if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
    local session_name
    session_name=$(_wt_session_name "$(basename "$target_path")")
    _wt_tmux_session_open "$target_path" "$session_name" "false" "false"
    return 0
  fi

  # tmux 안이면 윈도우 전환 시도
  if [[ -n "${TMUX:-}" ]]; then
    local window_id
    if window_id=$(_wt_find_tmux_window "$target_path"); then
      tmux select-window -t "$window_id"
      return 0
    fi
  fi

  # stdout으로 경로 출력 (래퍼 함수가 cd)
  echo "$target_path"
}

# ── 서브커맨드: ls ───────────────────────────────────────────────────────────

cmd_ls() {
  local git_root
  git_root=$(_get_repo_root) || _die "Git 저장소가 아닙니다"

  # worktree 수집
  local worktrees=()
  while IFS= read -r wt; do
    [[ -n "$wt" ]] && worktrees+=("$wt")
  done < <(_collect_worktrees "$git_root")

  if (( ${#worktrees[@]} == 0 )); then
    _info "활성 worktree가 없습니다"
    return 0
  fi

  # 현재 worktree 경로 (있으면)
  local current_wt=""
  local current_dir
  current_dir=$(pwd -P)
  for wt in "${worktrees[@]}"; do
    if [[ "$current_dir" == "$wt" || "$current_dir" == "$wt/"* ]]; then
      current_wt="$wt"
      break
    fi
  done

  # 임시 디렉토리 (PR 상태 병렬 조회)
  # global 변수: EXIT trap은 함수 종료 후 실행되므로 local은 set -u에서 unbound
  _wt_ls_tmp=$(mktemp -d)
  trap 'jobs -p | xargs -r kill 2>/dev/null || true; rm -rf "${_wt_ls_tmp:-}"' EXIT

  # PR 상태 병렬 조회
  _fetch_pr_statuses "$git_root" "$_wt_ls_tmp" "${worktrees[@]}"

  # 데이터 수집 + 정렬 (age 기준, 최신 우선)
  local entries=()
  for wt in "${worktrees[@]}"; do
    local name branch ts age pr_status dirty_mark current_mark
    name=$(basename "$wt")
    branch=$(_wt_branch "$wt")
    ts=$(_wt_last_commit_ts "$wt")
    age=$(_relative_age "$ts")

    pr_status="NONE"
    [[ -f "$_wt_ls_tmp/$name.pr" ]] && pr_status=$(cat "$_wt_ls_tmp/$name.pr")

    dirty_mark=""
    _wt_is_dirty "$wt" && dirty_mark="●"

    current_mark=""
    [[ "$wt" == "$current_wt" ]] && current_mark="*"

    # PR 상태 표시 (이모지 + 텍스트 통합)
    local pr_display
    case "$pr_status" in
      MERGED) pr_display="✅ MERGED" ;;
      OPEN)   pr_display="🔵 OPEN" ;;
      CLOSED) pr_display="🔴 CLOSED" ;;
      *)      pr_display="⚪ NONE" ;;
    esac

    # 현재 worktree 표시: name (*) 접미사
    local display_name="$name"
    [[ -n "$current_mark" ]] && display_name="$name (*)"

    # timestamp|name|branch|age|pr_display|dirty 형식으로 저장
    entries+=("$ts|$display_name|$branch|$age|$pr_display|$dirty_mark")
  done

  # age 기준 정렬 (최신 우선 = timestamp 내림차순)
  IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn && printf '\0') || true

  # 출력
  if _has_gum; then
    local header="NAME,BRANCH,AGE,PR,DIRTY"
    local rows=""
    for entry in "${sorted[@]}"; do
      IFS='|' read -r _ name branch age pr dirty <<< "$entry"
      (( ${#branch} > 25 )) && branch="${branch:0:22}..."
      rows+="$name,$branch,$age,$pr,$dirty"$'\n'
    done
    gum style --bold --border double --padding "0 1" "Worktrees (${#sorted[@]})" >&2
    echo "${header}"$'\n'"${rows%$'\n'}" | gum table --print >&2
  else
    _info "Worktrees (${#sorted[@]})"
    printf "  %-30s %-25s %-5s %-12s %s\n" "NAME" "BRANCH" "AGE" "PR" "DIRTY" >&2
    printf "  " >&2; printf '%.0s─' {1..78} >&2; echo >&2
    for entry in "${sorted[@]}"; do
      IFS='|' read -r _ name branch age pr dirty <<< "$entry"
      (( ${#branch} > 25 )) && branch="${branch:0:22}..."
      printf "  %-30s %-25s %-5s %-12s %s\n" "$name" "$branch" "$age" "$pr" "$dirty" >&2
    done
  fi
}

# ── 서브커맨드: cleanup ──────────────────────────────────────────────────────

cmd_cleanup() {
  local auto=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) auto=true ;;
      -h|--help) show_help; return 0 ;;
      *) _die "알 수 없는 옵션: $1" ;;
    esac
    shift
  done

  local git_root
  git_root=$(_get_repo_root) || _die "Git 저장소가 아닙니다"

  # worktree 수집
  local worktrees=()
  while IFS= read -r wt; do
    [[ -n "$wt" ]] && worktrees+=("$wt")
  done < <(_collect_worktrees "$git_root")

  if (( ${#worktrees[@]} == 0 )); then
    _info "정리할 worktree가 없습니다"
    return 0
  fi

  # 임시 디렉토리 (PR 상태 병렬 조회)
  # global 변수: EXIT trap은 함수 종료 후 실행되므로 local은 set -u에서 unbound
  _wt_cleanup_tmp=$(mktemp -d)
  trap 'jobs -p | xargs -r kill 2>/dev/null || true; rm -rf "${_wt_cleanup_tmp:-}"' EXIT

  # PR 상태 병렬 조회
  _fetch_pr_statuses "$git_root" "$_wt_cleanup_tmp" "${worktrees[@]}"

  # 현재 worktree 감지 (cleanup 목록에서 제외)
  local current_wt=""
  local current_dir
  current_dir=$(pwd -P)
  for wt in "${worktrees[@]}"; do
    if [[ "$current_dir" == "$wt" || "$current_dir" == "$wt/"* ]]; then
      current_wt="$wt"
      break
    fi
  done

  # 데이터 수집
  local items=()        # fzf 라벨
  local item_paths=()   # worktree 경로
  local item_branches=() # 브랜치명
  local item_pr=()      # PR 상태
  local item_dirty=()   # dirty 여부
  local item_unpushed=() # unpushed 여부
  local merged_indices=() # MERGED 항목 인덱스

  local idx=0
  for wt in "${worktrees[@]}"; do
    # 현재 worktree는 cleanup 대상에서 제외
    [[ "$wt" == "$current_wt" ]] && continue

    local name branch ts age pr_status dirty_flag unpushed_flag last_msg
    name=$(basename "$wt")
    branch=$(_wt_branch "$wt")
    ts=$(_wt_last_commit_ts "$wt")
    age=$(_relative_age "$ts")

    pr_status="NONE"
    [[ -f "$_wt_cleanup_tmp/$name.pr" ]] && pr_status=$(cat "$_wt_cleanup_tmp/$name.pr")

    dirty_flag=false
    _wt_is_dirty "$wt" && dirty_flag=true

    unpushed_flag=false
    _wt_has_unpushed "$wt" && unpushed_flag=true

    last_msg=$(_wt_last_commit_msg "$wt")

    # 상태 아이콘
    local st_icon
    case "$pr_status" in
      MERGED) st_icon="✅" ;;
      OPEN)   st_icon="🔵" ;;
      CLOSED) st_icon="🔴" ;;
      *)      st_icon="⚪" ;;
    esac

    local dirty_mark=""
    [[ "$dirty_flag" == "true" ]] && dirty_mark=" ●dirty"
    local unpushed_mark=""
    [[ "$unpushed_flag" == "true" ]] && unpushed_mark=" ↑unpushed"

    # 라벨: "ICON NAME [age PR dirty unpushed] — msg\tPATH"
    # fzf --with-nth 1로 라벨만 표시, --delimiter '\t'로 PATH 분리
    local label="$st_icon $name [$age $pr_status${dirty_mark}${unpushed_mark}] — $last_msg"

    items+=("$label")
    item_paths+=("$wt")
    item_branches+=("$branch")
    item_pr+=("$pr_status")
    item_dirty+=("$dirty_flag")
    item_unpushed+=("$unpushed_flag")

    [[ "$pr_status" == "MERGED" ]] && merged_indices+=("$idx")

    idx=$((idx + 1))
  done

  if [[ "$auto" == "true" ]]; then
    # --auto: MERGED 상태 자동 정리
    if (( ${#merged_indices[@]} == 0 )); then
      _info "자동 정리 대상 (MERGED)이 없습니다"
      return 0
    fi

    _info "자동 정리 대상: ${#merged_indices[@]}개 (MERGED)"
    for i in "${merged_indices[@]}"; do
      local wt_path="${item_paths[$i]}"
      local branch="${item_branches[$i]}"
      local name
      name=$(basename "$wt_path")

      # dirty → 스킵
      if [[ "${item_dirty[$i]}" == "true" ]]; then
        _info "스킵: $name (dirty 있음)"
        continue
      fi

      # unpushed 체크: upstream이 존재하는 경우에만 (merge 후 추가 커밋 보호)
      # upstream 삭제(GitHub auto-delete + git fetch -p) 시 false positive이므로 스킵
      if [[ "${item_unpushed[$i]}" == "true" ]]; then
        if git -C "$wt_path" rev-parse --abbrev-ref "@{upstream}" &>/dev/null; then
          _info "스킵: $name (merge 후 추가 커밋 있음)"
          continue
        fi
      fi

      _remove_worktree "$wt_path" "$branch" "$git_root" || _info "경고: $name 삭제 실패"
    done

    git worktree prune 2>/dev/null || true
    _info "자동 정리 완료"
    return 0
  fi

  # 인터랙티브 모드
  local selected_names=()

  if _has_fzf; then
    # fzf 멀티 선택 + preview
    # 라벨\t경로 형식으로 전달, --with-nth 1로 라벨만 표시
    local fzf_input=""
    for ((i=0; i<${#items[@]}; i++)); do
      fzf_input+="${items[$i]}"$'\t'"${item_paths[$i]}"$'\n'
    done

    local chosen
    chosen=$(printf '%s' "$fzf_input" | fzf --multi --delimiter $'\t' --with-nth 1 \
      --header "정리할 worktree 선택 (Tab 토글, Enter 확인)" \
      --prompt "cleanup> " \
      --preview 'git -C {2} log --oneline -5 2>/dev/null; echo "---"; git -C {2} status --short 2>/dev/null' \
      --preview-window right,75% --preview-label "worktree 상태") || { _info "취소됨"; return 0; }

    # 선택된 항목에서 worktree 이름 추출
    while IFS=$'\t' read -r label path; do
      [[ -n "$path" ]] && selected_names+=("$(basename "$path")")
    done <<< "$chosen"
  else
    # fallback: 번호 선택
    echo "정리할 worktree 선택 (쉼표로 구분, 빈 입력=취소):" >&2
    local i=1
    for label in "${items[@]}"; do
      echo "  $i) $label" >&2
      ((i++))
    done
    printf "번호: " >&2
    local nums_str
    read -r nums_str
    [[ -z "$nums_str" ]] && { _info "취소됨"; return 0; }

    IFS=',' read -ra nums <<< "$nums_str"
    for num in "${nums[@]}"; do
      num=$(echo "$num" | tr -d ' ')
      local idx=$((num - 1))
      if (( idx >= 0 && idx < ${#items[@]} )); then
        selected_names+=("$(basename "${item_paths[$idx]}")")
      fi
    done
  fi

  if (( ${#selected_names[@]} == 0 )); then
    _info "선택한 항목이 없습니다"
    return 0
  fi

  # 선택된 항목 처리
  local removed=0
  for sel_name in "${selected_names[@]}"; do
    local found_idx=-1
    for ((i=0; i<${#item_paths[@]}; i++)); do
      if [[ "$(basename "${item_paths[$i]}")" == "$sel_name" ]]; then
        found_idx=$i
        break
      fi
    done
    (( found_idx < 0 )) && continue

    local wt_path="${item_paths[$found_idx]}"
    local branch="${item_branches[$found_idx]}"
    local name
    name=$(basename "$wt_path")

    # dirty/unpushed → 개별 확인
    if [[ "${item_dirty[$found_idx]}" == "true" ]] || [[ "${item_unpushed[$found_idx]}" == "true" ]]; then
      local warn_msg="$name:"
      [[ "${item_dirty[$found_idx]}" == "true" ]] && warn_msg+=" uncommitted 변경사항"
      [[ "${item_unpushed[$found_idx]}" == "true" ]] && warn_msg+=" push하지 않은 커밋"

      _info "$warn_msg"
      _confirm "정말 삭제하시겠습니까?" || { _info "스킵: $name"; continue; }
    fi

    if _remove_worktree "$wt_path" "$branch" "$git_root"; then
      removed=$((removed + 1))
    fi
  done

  git worktree prune 2>/dev/null || true
  _info "정리 완료: ${removed}개 삭제"
}

# ── 도움말 ───────────────────────────────────────────────────────────────────

show_help() {
  cat << 'EOF'
사용법: wt [옵션] <command|branch>

Git worktree 관리 도구 (fzf TUI, tmux 통합)

서브커맨드:
  wt <branch>             현재 HEAD 기준 worktree 생성
  wt cd [name|-]          worktree로 이동 (fuzzy 검색, - = 이전)
  wt ls                   worktree 목록 (PR 상태, age, dirty)
  wt cleanup [--auto]     worktree 정리 (인터랙티브/자동)

옵션 (create):
  --stay                  tmux 윈도우를 백그라운드로 생성
  --claude                worktree 생성 후 Claude Code 자동 실행
  --tmux                  독립 tmux 세션 생성+attach (tmux 밖에서)

옵션 (cd):
  --tmux                  worktree를 tmux 세션으로 열기 (tmux 밖에서)

옵션 (cleanup):
  --auto                  MERGED 상태 worktree 자동 정리

예시:
  wt feature-login        feature-login 브랜치 + worktree 생성
  wt --claude fix-bug     worktree 생성 + claude 실행
  wt --tmux feature-x     worktree 생성 + tmux 세션 attach
  wt --tmux --claude pr   worktree + tmux 세션 + claude 실행
  wt --tmux --stay test   tmux 세션 detached 생성
  wt cd login             "login" 포함 worktree로 이동
  wt cd --tmux login      worktree를 tmux 세션으로 열기
  wt cd -                 이전 worktree로 이동
  wt ls                   전체 worktree 상태 확인
  wt cleanup              인터랙티브 정리
  wt cleanup --auto       MERGED 자동 정리
EOF
}

# ── 디스패치 ─────────────────────────────────────────────────────────────────

case "${1:-}" in
  cd)      shift; cmd_cd "$@" ;;
  ls)      shift; cmd_ls "$@" ;;
  cleanup) shift; cmd_cleanup "$@" ;;
  -h|--help) show_help ;;
  "")      show_help ;;
  *)       cmd_create "$@" ;;
esac
