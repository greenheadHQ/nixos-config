# shellcheck shell=bash
# ── 서브커맨드: cd / ls ─────────────────────────────────────────────────────

# wt ls --json: worktree 상태를 JSON 배열로 출력 (LLM/스크립트 파싱용; stdout)
# 필드: name, branch, path, pr, committedAt(epoch), age, dirty, unpushed, current
_wt_ls_json() {
  local tmp="$1" current_wt="$2"
  shift 2
  local worktrees=("$@")
  command -v jq &>/dev/null || _die "--json은 jq가 필요합니다"

  local objs=()
  local wt
  for wt in "${worktrees[@]}"; do
    local name branch ts age pr_status dirty unpushed is_current
    name=$(basename "$wt")
    branch=$(_wt_branch "$wt")
    ts=$(_wt_last_commit_ts "$wt")
    age=$(_relative_age "$ts")
    pr_status="NONE"
    [[ -f "$tmp/$name.pr" ]] && pr_status=$(cat "$tmp/$name.pr")
    dirty=false; _wt_is_dirty "$wt" && dirty=true
    unpushed=false; _wt_has_unpushed "$wt" && unpushed=true
    is_current=false; [[ "$wt" == "$current_wt" ]] && is_current=true
    objs+=("$(jq -n \
      --arg name "$name" --arg branch "$branch" --arg path "$wt" \
      --arg pr "$pr_status" --arg age "$age" --argjson ts "${ts:-0}" \
      --argjson dirty "$dirty" --argjson unpushed "$unpushed" \
      --argjson current "$is_current" \
      '{name:$name, branch:$branch, path:$path, pr:$pr, committedAt:$ts, age:$age, dirty:$dirty, unpushed:$unpushed, current:$current}')")
  done
  printf '%s\n' "${objs[@]}" | jq -s 'sort_by(-.committedAt)'
}

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
    local last_path
    last_path=$(_wt_read_last_path "$git_root") || _die "이전 worktree 기록이 없습니다"
    if [[ ! -d "$last_path" ]]; then
      _info "이전 worktree가 삭제됨: $(basename "$last_path") → main repo로 이동"
      last_path="$git_root"
    fi
    # 현재 위치 저장 후 이동
    _wt_record_last_path "$git_root"

    # --tmux: 세션 모드 (tmux 밖 + 대화형에서만; 비대화형은 exec tmux 불가)
    if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
      if _wt_interactive; then
        local session_name
        session_name=$(_wt_session_name "$(basename "$last_path")")
        _wt_tmux_session_open "$last_path" "$session_name" "false" "false"
        return 0
      fi
      _warn "비대화형: --tmux 무시 (경로만 출력)"
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
    # 인자 없이 호출 = 대화형 선택. 비대화형은 이름을 인자로 요구(안전 실패).
    if ! _wt_interactive; then
      _info "사용 가능한 worktree:"
      local _wt
      for _wt in "${worktrees[@]}"; do _info "  $(basename "$_wt")"; done
      _die "비대화형: worktree 이름을 인자로 지정하세요 (예: wt cd <name>)"
    fi

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
  _wt_record_last_path "$git_root"

  # --tmux: 세션 attach/생성 (tmux 밖 + 대화형에서만; 비대화형은 exec tmux 불가)
  if [[ "$use_tmux_session" == "true" ]] && [[ -z "${TMUX:-}" ]]; then
    if _wt_interactive; then
      local session_name
      session_name=$(_wt_session_name "$(basename "$target_path")")
      _wt_tmux_session_open "$target_path" "$session_name" "false" "false"
      return 0
    fi
    _warn "비대화형: --tmux 무시 (경로만 출력)"
  fi

  # tmux 안이면 윈도우 전환 시도 (대화형 한정 — 정책은 _wt_tmux_ui_allowed가 소유).
  # 비대화형 호출(LLM/스크립트)은 "경로를 stdout으로 출력" 계약을 지켜야 하고,
  # 사용자 tmux 화면을 임의로 전환하는 부수효과도 내면 안 된다. 전환 성공 시 경로
  # 출력 없이 return 0이라 `cd "$(wt cd <name>)"`가 빈 문자열을 받는다
  # (zsh의 `cd ""`는 no-op 성공).
  if _wt_tmux_ui_allowed; then
    local window_id
    if window_id=$(_wt_find_tmux_window "$target_path"); then
      tmux select-window -t "$window_id"
      return 0
    fi
  fi

  # stdout으로 경로 출력 (래퍼 함수가 cd)
  echo "$target_path"
}

cmd_ls() {
  local as_json=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --json)    as_json=true ;;
      -h|--help) show_help; return 0 ;;
      *)         _die "알 수 없는 옵션: $1" ;;
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

  # --json: 구조화 출력 (LLM/스크립트 파싱용; stdout, 로그는 stderr)
  if [[ "$as_json" == "true" ]]; then
    _wt_ls_json "$_wt_ls_tmp" "$current_wt" "${worktrees[@]}"
    return 0
  fi

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

    local pr_display
    case "$pr_status" in
      MERGED) pr_display="✅ MERGED" ;;
      OPEN)   pr_display="🔵 OPEN" ;;
      CLOSED) pr_display="🔴 CLOSED" ;;
      *)      pr_display="⚪ NONE" ;;
    esac

    local display_name="$name"
    [[ -n "$current_mark" ]] && display_name="$name (*)"

    entries+=("$ts|$display_name|$branch|$age|$pr_display|$dirty_mark")
  done

  IFS=$'\n' read -r -d '' -a sorted < <(printf '%s\n' "${entries[@]}" | sort -t'|' -k1 -rn && printf '\0') || true

  _info "Worktrees (${#sorted[@]})"
  printf "  %-30s %-25s %-5s %-12s %s\n" "NAME" "BRANCH" "AGE" "PR" "DIRTY" >&2
  printf "  " >&2; printf '%.0s─' {1..78} >&2; echo >&2
  for entry in "${sorted[@]}"; do
    IFS='|' read -r _ name branch age pr dirty <<< "$entry"
    (( ${#branch} > 25 )) && branch="${branch:0:22}..."
    printf "  %-30s %-25s %-5s %-12s %s\n" "$name" "$branch" "$age" "$pr" "$dirty" >&2
  done
}
