# shellcheck shell=bash
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
      tmux select-window -t "$existing_window" || return 1
      _info "기존 tmux 윈도우로 전환: $window_name"
    fi
    echo "$existing_window"
    return 2
  fi

  # 새 윈도우 생성
  local new_window
  if [[ "$stay" == "true" ]]; then
    new_window=$(tmux new-window -d -n "$window_name" -c "$wt_path" -P -F '#{window_id}') || return 1
    _info "tmux 윈도우 생성 (background): $window_name"
  else
    new_window=$(tmux new-window -n "$window_name" -c "$wt_path" -P -F '#{window_id}') || return 1
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
