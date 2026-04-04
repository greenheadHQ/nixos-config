# shellcheck shell=bash
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
  _wt_cleanup_tmp=$(mktemp -d)
  trap 'jobs -p | xargs -r kill 2>/dev/null || true; rm -rf "${_wt_cleanup_tmp:-}"' EXIT

  _fetch_pr_statuses "$git_root" "$_wt_cleanup_tmp" "${worktrees[@]}"

  local current_wt=""
  local current_dir
  current_dir=$(pwd -P)
  for wt in "${worktrees[@]}"; do
    if [[ "$current_dir" == "$wt" || "$current_dir" == "$wt/"* ]]; then
      current_wt="$wt"
      break
    fi
  done

  local items=()
  local item_paths=()
  local item_branches=()
  local item_pr=()
  local item_dirty=()
  local item_unpushed=()
  local merged_indices=()

  local idx=0
  for wt in "${worktrees[@]}"; do
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

      if [[ "${item_dirty[$i]}" == "true" ]]; then
        _info "스킵: $name (dirty 있음)"
        continue
      fi

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

  local selected_names=()

  if _has_fzf; then
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

    while IFS=$'\t' read -r label path; do
      [[ -n "$path" ]] && selected_names+=("$(basename "$path")")
    done <<< "$chosen"
  else
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
