# shellcheck shell=bash
# wt의 tmux 관여는 "정리"뿐이다. 윈도우/세션을 만들거나 전환하는 presentation은
# 제거했고(경로 출력 계약으로 통일), 여기 남은 것은 worktree를 지우기 전에 필요한
# 판정과 뒷정리다: 대상 worktree의 pane 찾기, 그 pane에 살아 있는 프로세스 판정,
# 그리고 예전 presentation이 남긴 `wt-*` 윈도우·세션 닫기.

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

# 정리 대상 세션 이름 재구성: wt-<repo>-<dir>. 이 이름의 세션을 만들던 코드는 사라졌고,
# 남은 용도는 그때 만들어진 세션을 worktree 제거 전에 찾아 닫는 것뿐이다. 그래서 규칙을
# 바꿀 수 없다 — 바꾸면 이미 떠 있는 세션을 못 찾고 orphan으로 남긴다.
# repo basename을 네임스페이스로 두는 이유도 그때와 같다: 멀티 repo에서 동명 브랜치의
# 세션을 잘못 죽이지 않기 위해서다.
_wt_session_name() {
  local dir_name="$1"
  local repo_name
  repo_name=$(basename "$(_get_repo_root)" 2>/dev/null) || repo_name="default"
  # tmux target 구분자(. :)를 언더스코어로 치환
  repo_name="${repo_name//[.:]/_}"
  echo "wt-${repo_name}-${dir_name}"
}

# 세션 상태를 삼상태로 조회한다 (stdout: absent | present | unknown).
#
# tmux는 "세션 없음"과 "상태를 못 읽음"을 모두 exit 1로 알리므로, 그 구분을 여기 한곳에
# 둔다. 삭제 안전성을 판단하는 호출자들이 각자 stderr를 해석하면 같은 삼상태 모델이
# 여러 모듈로 흩어지고, 의미를 바꿀 때 함께 고쳐야 한다.
#   absent  — tmux가 없거나 서버가 안 떠 있거나 그 이름의 세션이 없다
#   present — 세션이 있다
#   unknown — 서버는 있는데 조회가 실패했다 (소켓·권한 등). 판단 불가.
_wt_tmux_session_state() {
  local session_name="$1"
  command -v tmux >/dev/null 2>&1 || { printf 'absent\n'; return 0; }

  # has-session 하나로 충분하다 — 서버가 없으면 그 사실도 이 호출이 알려준다(실측).
  # exit 1만으로는 "없음"과 "못 읽음"을 구분할 수 없으므로 stderr를 분류한다.
  local err rc=0
  err=$(tmux has-session -t "=$session_name" 2>&1) || rc=$?
  if (( rc == 0 )); then
    printf 'present\n'
  elif _wt_tmux_err_means_absent "$err"; then
    printf 'absent\n'
  else
    printf 'unknown\n'
  fi
}

# tmux 오류 메시지가 "부재"를 뜻하는지 판정한다. 이 환경 실측 기준:
#   서버 미실행 — "error connecting to <socket> (No such file or directory)"
#                 (서버가 죽는 방식에 따라 "no server running"이나 "(Connection refused)"도 나온다)
#   세션 없음   — "can't find session: <name>"
# 그 밖의 실패(예: "(Permission denied)")는 활성 세션이 있어도 알 수 없다는 뜻이므로
# 부재로 보지 않는다 — 그래야 호출자가 unknown으로 fail-closed할 수 있다.
_wt_tmux_err_means_absent() {
  local err="$1"
  [[ "$err" == *"no server running"* \
     || "$err" == *"No such file or directory"* \
     || "$err" == *"Connection refused"* \
     || "$err" == *"can't find session"* \
     || "$err" == *"session not found"* ]]
}

# 세션 종료를 막아야 하는지 판정한다 (부수효과 없음). 사실 조회가 아니라 정책 판정이라
# 이름도 그렇게 붙였다 — 반환값을 "클라이언트가 존재한다"로 읽으면 안 된다.
# 연결된 클라이언트가 있으면 막고(활성 사용 보호), 상태나 클라이언트 목록을 읽지 못하면
# "없음"이 아니라 "알 수 없음"이므로 역시 막는다(fail-closed).
_wt_tmux_session_close_should_block() {
  local session_name="$1"
  case "$(_wt_tmux_session_state "$session_name")" in
    absent)  return 1 ;;
    unknown) return 0 ;;
  esac

  local clients
  clients=$(tmux list-clients -t "=$session_name" 2>/dev/null) || return 0
  [[ -n "$clients" ]]
}

_wt_tmux_session_close() {
  local session_name="$1"
  if _wt_tmux_session_close_should_block "$session_name"; then
    _info "스킵: tmux 세션 '$session_name' — 연결된 클라이언트가 있거나 상태를 확인하지 못했습니다"
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
