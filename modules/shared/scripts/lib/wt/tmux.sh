# shellcheck shell=bash
# tmux UI 부수효과(윈도우 생성/전환) 허용 여부 — 단일 정책 경계.
# 비대화형(LLM/스크립트) 호출은 사용자 tmux 화면을 임의로 바꾸지 않고
# "경로를 stdout으로 출력" 계약을 지켜야 한다 (CLAUDE.md Worktree 섹션).
# cd/create/reuse 등 tmux 윈도우 전환·생성이 가능한 모든 경로는 이 함수로
# 게이트한다 — 호출자별 가드 복제로 정책 누락이 생기는 것을 막는다.
_wt_tmux_ui_allowed() {
  [[ -n "${TMUX:-}" ]] && _wt_interactive
}

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
      "claude --dangerously-skip-permissions" Enter
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

  local err rc=0
  err=$(tmux list-sessions 2>&1 >/dev/null) || rc=$?
  if (( rc != 0 )); then
    # 서버 부재와 조회 불능을 errno 문구로 가른다. tmux는 소켓이 없으면
    # "error connecting to <socket> (No such file or directory)"를, 서버가 죽어 있으면
    # "no server running" 또는 "(Connection refused)"를 낸다 — 모두 부재다.
    # 반면 "(Permission denied)"처럼 접근 자체가 막힌 경우는 활성 세션이 있어도 알 수
    # 없으므로 unknown으로 두어 무확인 삭제를 막는다.
    # (실측: 이 저장소 개발 환경에서 서버 미실행 시 "No such file or directory"가 나온다.
    #  "error connecting"만 보고 부재로 단정하면 권한 오류가, unknown으로 단정하면
    #  정상적인 서버 부재가 잘못 처리된다.)
    if [[ "$err" == *"no server running"* \
       || "$err" == *"No such file or directory"* \
       || "$err" == *"Connection refused"* ]]; then
      printf 'absent\n'
    else
      printf 'unknown\n'
    fi
    return 0
  fi

  if tmux has-session -t "=$session_name" 2>/dev/null; then
    printf 'present\n'
  else
    printf 'absent\n'
  fi
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
