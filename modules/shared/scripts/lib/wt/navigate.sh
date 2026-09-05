# shellcheck shell=bash
# ── 서브커맨드: cd / ls ─────────────────────────────────────────────────────

# wt ls --json: worktree 상태를 JSON 배열로 출력 (LLM/스크립트 파싱용; stdout)
# 필드: name, branch, path, pr, committedAt(epoch), age, dirty, unpushed, current,
#       locked, broken
_wt_ls_json() {
  local git_root="$1" tmp="$2" current_wt="$3"
  shift 3
  local worktrees=("$@")
  command -v jq &>/dev/null || _die "--json은 jq가 필요합니다"

  local objs=()
  local wt
  for wt in "${worktrees[@]}"; do
    local name cache_key branch ts age pr_status dirty loss_risk is_current locked broken
    # 이름은 WORKTREE_DIR 상대 경로다 — depth 2 이상 항목이 depth 1 항목과 같은 name으로
    # 보이면 소비자가 두 worktree를 구분하지 못한다. 캐시 파일명은 이스케이프한 값을 쓴다.
    name=$(_wt_display_name "$git_root" "$wt")
    cache_key=$(_wt_pr_cache_key "$name")
    locked=false; _wt_is_locked "$git_root" "$wt" && locked=true
    # broken은 "등록은 있는데 git -C가 통하지 않는다"는 뜻이다 (디렉토리 소실, gitdir 무효).
    # 이 항목의 branch/committedAt/dirty는 worktree에서 읽을 수 없으므로, 소비자가 빈 값을
    # 실제 상태로 오해하지 않도록 플래그를 함께 낸다.
    broken=false; _wt_is_broken "$wt" && broken=true
    if [[ "$broken" == "true" ]]; then
      branch=$(_wt_registered_branch "$git_root" "$wt")
      ts=0
      age="-"
      pr_status="NONE"
      dirty=false
      loss_risk=false
    else
      branch=$(_wt_branch "$wt")
      ts=$(_wt_last_commit_ts "$wt")
      age=$(_relative_age "$ts")
      pr_status="NONE"
      [[ -f "$tmp/$cache_key.pr" ]] && pr_status=$(cat "$tmp/$cache_key.pr")
      dirty=false; _wt_is_dirty "$wt" && dirty=true
      # JSON 키 unpushed는 "정리하면 잃을 커밋이 있는가"를 뜻한다 — squash merge 후 upstream이
      # 사라진 MERGED worktree를 미push로 오판하지 않도록 PR 상태로 보정한다 (git-state.sh).
      # 내부 변수는 그 의미대로 loss_risk로 두고, 기존 JSON 키는 아래 경계에서 매핑한다.
      #
      # 단 PR 상태는 조회 시점 스냅샷이라, 그 뒤 커밋이 생기면 MERGED 근거가 stale해진다.
      # 출력 직전에 근거 OID와 현재 HEAD를 대조해, 어긋나면 raw 판정으로 되돌린다 —
      # 그러지 않으면 잃을 커밋이 있는데도 unpushed:false를 보고하게 된다.
      loss_risk=false; _wt_has_unpushed_risk "$wt" "$pr_status" "$tmp/$cache_key.head" && loss_risk=true
    fi
    is_current=false; [[ "$wt" == "$current_wt" ]] && is_current=true
    objs+=("$(jq -n \
      --arg name "$name" --arg branch "$branch" --arg path "$wt" \
      --arg pr "$pr_status" --arg age "$age" --argjson ts "${ts:-0}" \
      --argjson dirty "$dirty" --argjson unpushed "$loss_risk" \
      --argjson current "$is_current" \
      --argjson locked "$locked" --argjson broken "$broken" \
      '{name:$name, branch:$branch, path:$path, pr:$pr, committedAt:$ts, age:$age, dirty:$dirty, unpushed:$unpushed, current:$current, locked:$locked, broken:$broken}')")
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
        # 세션 이름의 재료는 basename이 아니라 wt_base 상대 표시 이름이다 (아래 동일 이유).
        local session_name
        session_name=$(_wt_session_name "$(_wt_display_name "$git_root" "$last_path")")
        _wt_tmux_session_open "$last_path" "$session_name" "false" "false"
        return 0
      fi
      _warn "비대화형: --tmux 무시 (경로만 출력)"
    fi

    echo "$last_path"
    return 0
  fi

  if [[ -n "$search" ]]; then
    # 매칭은 디렉토리명(= wt_base 상대 표시 이름) + 브랜치명 + sanitized 검색어를 모두 본다.
    #
    # 다만 substring 첫 매치로 끊으면 안 된다. 수집 결과는 경로 정렬이라 `feat/x`가 `x`보다
    # 먼저 오고, 두 이름 모두 검색어 `x`에 substring으로 맞는다 — `wt cd x`가 사용자가 지목한
    # `x` 대신 `feat/x`를 내놓는다. 그래서 우선순위를 둔다:
    #   1) 표시 이름 정확 일치 (사용자가 `wt ls`에서 본 그 이름) → 2) 브랜치명 정확 일치
    #   3) 정확 일치가 없으면 substring 후보를 모두 모아 유일할 때만 선택
    # 후보가 여럿이면 아무거나 고르지 않고 후보를 보인 뒤 실패한다 (fail-closed). 잘못 고른
    # 경로는 그대로 `cd`되고, 이어지는 파괴적 명령이 다른 worktree에 적용될 수 있다.
    local sanitized_search
    sanitized_search=$(_sanitize_name "$search")
    # 손상 항목이 검색어에 맞았다는 사실은 기억해 둔다 — 매칭이 하나도 없는 것과 원인이
    # 다르고, 사용자가 들어야 할 명령(prune/unlock)도 다르다.
    local broken_match=""
    local exact_name_path="" exact_branch_path=""
    local candidates=() candidate_names=()
    for wt in "${worktrees[@]}"; do
      local name branch
      name=$(_wt_display_name "$git_root" "$wt")
      branch=$(_wt_branch "$wt")
      if [[ "$name" == *"$search"* ]] || [[ "$name" == *"$sanitized_search"* ]] \
        || [[ "$branch" == *"$search"* ]]; then
        # 등록만 남고 디렉토리가 없는(또는 gitdir이 무효한) 항목은 cd할 대상이 아니다.
        # 경로를 그대로 출력하면 `cd "$(wt cd <name>)"`가 이유 없이 실패하고, 같은 항목을
        # ⚠️ BROKEN으로 표시하는 `wt ls`와 진단이 갈라진다.
        if _wt_is_broken "$wt"; then
          [[ -z "$broken_match" ]] && broken_match="$name ($(_wt_broken_hint "$git_root" "$wt"))"
          continue
        fi
        if [[ -z "$exact_name_path" ]] \
          && { [[ "$name" == "$search" ]] || [[ "$name" == "$sanitized_search" ]]; }; then
          exact_name_path="$wt"
        elif [[ -z "$exact_branch_path" ]] && [[ "$branch" == "$search" ]]; then
          exact_branch_path="$wt"
        fi
        candidates+=("$wt")
        candidate_names+=("$name")
      fi
    done
    if [[ -n "$exact_name_path" ]]; then
      target_path="$exact_name_path"
    elif [[ -n "$exact_branch_path" ]]; then
      target_path="$exact_branch_path"
    elif (( ${#candidates[@]} == 1 )); then
      target_path="${candidates[0]}"
    elif (( ${#candidates[@]} > 1 )); then
      _info "여러 worktree가 매치됩니다 — 정확한 이름을 지정하세요:"
      local _cand
      for _cand in "${candidate_names[@]}"; do _info "  $_cand"; done
      _die "모호한 검색어: $search"
    fi
    if [[ -z "$target_path" ]]; then
      [[ -n "$broken_match" ]] && _die "손상된 worktree라 이동할 수 없습니다: $broken_match"
      _die "매치하는 worktree 없음: $search"
    fi
  else
    # 인자 없이 호출 = 대화형 선택. 비대화형은 이름을 인자로 요구(안전 실패).
    if ! _wt_interactive; then
      _info "사용 가능한 worktree:"
      local _wt
      for _wt in "${worktrees[@]}"; do _info "  $(basename "$_wt")"; done
      _die "비대화형: worktree 이름을 인자로 지정하세요 (예: wt cd <name>)"
    fi

    # 인터랙티브 선택 (fzf + preview)
    # 선택 후 "$wt_base/$selected"로 경로를 되짚으므로 목록도 wt_base 상대 경로여야 한다.
    # basename만 보여주면 depth 2 이상 항목을 골랐을 때 존재하지 않는 경로가 나온다.
    #
    # 손상 항목(등록만 남음)은 애초에 고를 수 없어야 한다. 목록에 넣으면 이름으로 지정하는
    # 경로가 받는 거부 가드를 건너뛰고 존재하지 않는 경로를 그대로 출력하게 된다 — 같은
    # worktree를 두고 대화형과 비대화형의 진단이 갈린다. 제외 사실과 복구 명령은 알린다.
    local names=()
    local broken_names=()
    for wt in "${worktrees[@]}"; do
      if _wt_is_broken "$wt"; then
        broken_names+=("$(_wt_display_name "$git_root" "$wt") ($(_wt_broken_hint "$git_root" "$wt"))")
        continue
      fi
      names+=("$(_wt_display_name "$git_root" "$wt")")
    done
    local _broken
    for _broken in ${broken_names[@]+"${broken_names[@]}"}; do
      _warn "손상된 worktree라 선택 목록에서 제외: $_broken"
    done
    (( ${#names[@]} == 0 )) && _die "이동할 수 있는 worktree가 없습니다 (수집된 항목이 모두 손상)"

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
      # 세션 이름도 wt_base 상대 표시 이름으로 짓는다. basename으로 접으면 `feat/zz`와
      # 최상위 `zz`가 같은 세션 이름이 되고, _wt_tmux_session_open은 기존 세션을 경로 대조
      # 없이 재사용하므로 `wt cd feat/zz --tmux`가 `zz`의 세션에 붙는다. tmux 세션 이름은
      # `/`를 허용한다 (실측: `has-session -t '=wt-repo-feat/zz'` 정확 매치 성립).
      local session_name
      session_name=$(_wt_session_name "$(_wt_display_name "$git_root" "$target_path")")
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
    _wt_ls_json "$git_root" "$_wt_ls_tmp" "$current_wt" "${worktrees[@]}"
    return 0
  fi

  # 데이터 수집 + 정렬 (age 기준, 최신 우선)
  local entries=()
  # 손상 항목은 표에 한 줄로 보이기만 해서는 무엇을 해야 할지 모른다. 표 아래에
  # 상황별 복구 명령을 따로 낸다 (cleanup과 같은 헬퍼를 써서 문구가 갈라지지 않게).
  local broken_notes=()
  for wt in "${worktrees[@]}"; do
    local name cache_key branch ts age pr_status dirty_mark current_mark pr_display
    name=$(_wt_display_name "$git_root" "$wt")
    cache_key=$(_wt_pr_cache_key "$name")

    current_mark=""
    [[ "$wt" == "$current_wt" ]] && current_mark="*"

    if _wt_is_broken "$wt"; then
      # 등록은 있는데 git -C가 통하지 않는 항목(디렉토리 소실·gitdir 무효). worktree에서
      # 읽어야 하는 값은 전부 무의미하므로 등록 정보만 쓰고 상태를 BROKEN으로 표시한다.
      branch=$(_wt_registered_branch "$git_root" "$wt")
      ts=0
      age="-"
      dirty_mark=""
      pr_display="⚠️ BROKEN"
      broken_notes+=("$name ($(_wt_broken_hint "$git_root" "$wt"))")
    else
      branch=$(_wt_branch "$wt")
      ts=$(_wt_last_commit_ts "$wt")
      age=$(_relative_age "$ts")

      pr_status="NONE"
      [[ -f "$_wt_ls_tmp/$cache_key.pr" ]] && pr_status=$(cat "$_wt_ls_tmp/$cache_key.pr")

      dirty_mark=""
      _wt_is_dirty "$wt" && dirty_mark="●"

      case "$pr_status" in
        MERGED) pr_display="✅ MERGED" ;;
        OPEN)   pr_display="🔵 OPEN" ;;
        CLOSED) pr_display="🔴 CLOSED" ;;
        *)      pr_display="⚪ NONE" ;;
      esac
    fi

    # 잠금은 "정리에서 제외된다"는 뜻이라 목록에서 바로 보여야 한다 (cleanup은 후보에서 뺀다).
    local display_name="$name"
    _wt_is_locked "$git_root" "$wt" && display_name="$display_name 🔒"
    [[ -n "$current_mark" ]] && display_name="$display_name (*)"

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

  local note
  for note in ${broken_notes[@]+"${broken_notes[@]}"}; do
    _warn "손상된 worktree: $note"
  done
}
