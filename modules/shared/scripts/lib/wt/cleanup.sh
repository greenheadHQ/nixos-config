# shellcheck shell=bash
# ── 서브커맨드: cleanup ──────────────────────────────────────────────────────

# 현재 worktree는 자기 자신을 지우면 셸의 cwd가 사라지므로 정리 대상에서 제외된다.
# 그 사실과 재실행 방법을 알리는 안내를 한곳에 둔다 — auto 경로와 이름 지정 경로가
# 같은 문구·같은 quoting을 써야 안내가 갈라지지 않는다.
_wt_warn_cleanup_from_root() {
  local git_root="$1" name="$2" message="$3"
  local _safe_root _safe_name
  printf -v _safe_root '%q' "$git_root"
  printf -v _safe_name '%q' "$name"
  _warn "$message"
  _warn "  저장소 루트에서 실행하세요: cd ${_safe_root} && wt cleanup ${_safe_name}"
}

# MERGED 판정의 근거가 아직 유효한지 확인하고, 무효면 경고까지 낸다.
# 두 삭제 경로(auto·이름 지정)가 같은 안전 정책과 같은 문구를 쓰도록 한곳에 둔다.
_wt_merged_head_still_valid() {
  local wt_path="$1" head_file="$2" name="$3"
  _wt_head_unchanged "$wt_path" "$head_file" && return 0
  # 실패 원인은 HEAD 변경뿐 아니라 근거 기록 부재·읽기 실패도 포함한다 (fail-closed).
  # 어느 쪽이든 "지워도 되는지 다시 확인해야 한다"는 결론은 같으므로 한 문장으로 알린다.
  _warn "스킵: $name (MERGED 근거를 재확인하지 못했습니다 — HEAD 변경 또는 근거 기록 유실. 다시 실행하세요)"
  return 1
}

cmd_cleanup() {
  local auto=false
  local names_filter=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto)    auto=true ;;
      --yes|-y)  export WT_ASSUME_YES=1 ;;  # ui.sh _confirm이 소비 (cross-file)
      -h|--help) show_help; return 0 ;;
      -*)        _die "알 수 없는 옵션: $1" ;;
      *)         names_filter+=("$1") ;;
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
  local item_loss_risk=()
  local merged_indices=()
  local broken_count=0

  local idx=0
  for wt in "${worktrees[@]}"; do
    [[ "$wt" == "$current_wt" ]] && continue

    # 손상(stale) worktree 가드 (#883): gitdir이 무효하면(예: 사용자명 마이그레이션
    # 잔재로 .git이 죽은 gitdir을 가리킴) 아래 _wt_last_commit_msg 등 무가드 git 호출이
    # set -e/pipefail로 폭사한다. 정리 후보에서 제외하고 경고만 남긴다 (사용자 정책:
    # 경고 + 정리 제외 — 자동 삭제 시 미커밋 작업물 손실 위험이라 보수적으로 건너뜀).
    if _wt_is_broken "$wt"; then
      # 경로에 작은따옴표/공백이 있어도 사용자가 그대로 복붙할 수 있도록 %q로 인용.
      local _safe_wt
      printf -v _safe_wt '%q' "$wt"
      _warn "손상된 worktree 건너뜀: $(basename "$wt") (gitdir 무효 — 수동 정리: rm -rf ${_safe_wt} 후 git worktree prune)"
      broken_count=$((broken_count + 1))
      continue
    fi

    local name branch ts age pr_status dirty_flag loss_risk_flag last_msg
    name=$(basename "$wt")
    branch=$(_wt_branch "$wt")
    ts=$(_wt_last_commit_ts "$wt")
    age=$(_relative_age "$ts")

    pr_status="NONE"
    [[ -f "$_wt_cleanup_tmp/$name.pr" ]] && pr_status=$(cat "$_wt_cleanup_tmp/$name.pr")

    dirty_flag=false
    _wt_is_dirty "$wt" && dirty_flag=true

    loss_risk_flag=false
    _wt_has_unpushed_risk "$wt" "$pr_status" && loss_risk_flag=true

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
    local loss_risk_mark=""
    [[ "$loss_risk_flag" == "true" ]] && loss_risk_mark=" ↑unpushed"

    local label="$st_icon $name [$age $pr_status${dirty_mark}${loss_risk_mark}] — $last_msg"

    items+=("$label")
    item_paths+=("$wt")
    item_branches+=("$branch")
    item_pr+=("$pr_status")
    item_dirty+=("$dirty_flag")
    item_loss_risk+=("$loss_risk_flag")

    [[ "$pr_status" == "MERGED" ]] && merged_indices+=("$idx")

    idx=$((idx + 1))
  done

  # 현재 위치한 worktree는 위 루프에서 제외된다 — 자기 자신을 지우면 셸의 cwd가
  # 사라지기 때문이다. 문제는 그 제외를 침묵하면 "정리했는데 왜 그대로냐"로 보인다는
  # 점이다 (#1186: finish-pr을 worktree 안에서 돌리면 --auto가 아무 말 없이 끝났다).
  # 제외 사실과 해결 방법을 알리고, 실제 정리 대상(MERGED)이면 경고 수준으로 올린다.
  #
  # 이름을 지정한 호출에서는 이 안내를 생략한다 — 지정한 이름이 현재 worktree면
  # 아래 미매칭 분기가 같은 안내를 하므로, 여기서도 알리면 같은 재실행 명령이 두 번
  # 출력된다. 안내 책임을 호출 형태별로 한쪽에만 둔다.
  if [[ -n "$current_wt" ]] && (( ${#names_filter[@]} == 0 )); then
    local cur_name cur_pr
    cur_name=$(basename "$current_wt")
    cur_pr="NONE"
    [[ -f "$_wt_cleanup_tmp/$cur_name.pr" ]] && cur_pr=$(cat "$_wt_cleanup_tmp/$cur_name.pr")
    if [[ "$cur_pr" == "MERGED" ]]; then
      _wt_warn_cleanup_from_root "$git_root" "$cur_name" \
        "현재 worktree라 여기서는 삭제할 수 없어 제외했습니다: $cur_name (PR MERGED)"
    else
      _info "현재 worktree 제외: $cur_name (PR $cur_pr)"
    fi
  fi

  if [[ "$auto" == "true" ]]; then
    if (( ${#merged_indices[@]} == 0 )); then
      # 손상 카운트를 late-auto(아래)·name-filter 요약과 일관되게 노출 (#883 broken-only 경로).
      if (( broken_count > 0 )); then
        _info "자동 정리 대상 (MERGED)이 없습니다 (손상 ${broken_count}개 건너뜀)"
      else
        _info "자동 정리 대상 (MERGED)이 없습니다"
      fi
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

      # item_loss_risk는 PR MERGED로 보정된 값이라 이 분기에서는 항상 false다.
      # --auto는 사용자 확인 없이 지우므로 raw git 상태를 한 번 더 본다: upstream이
      # 살아 있는데 그보다 앞선 커밋이 있으면 머지 후 추가 작업일 수 있다.
      # (reuse guard와 중복 방어 — 자동 삭제 경로만 이 보수성을 유지한다.)
      if git -C "$wt_path" rev-parse --abbrev-ref "@{upstream}" &>/dev/null \
        && _wt_has_unpushed "$wt_path"; then
        _info "스킵: $name (merge 후 추가 커밋 있음)"
        continue
      fi

      # PR 조회와 삭제 사이에 새 커밋이 생겼으면 MERGED 판정이 stale하다 (git-state.sh).
      _wt_merged_head_still_valid "$wt_path" "$_wt_cleanup_tmp/$name.head" "$name" || continue

      # 검증한 OID를 넘겨 브랜치 삭제를 CAS로 만든다 — 이 확인과 실제 삭제 사이에도
      # 창이 남으므로, 그 안에서 커밋이 생기면 ref가 지워지지 않아야 한다.
      # 근거를 읽지 못하면 중단한다 — 빈 값을 넘기면 CAS가 아니라 강제 삭제로 떨어져
      # 안전 근거를 잃은 상태에서 오히려 보호가 풀린다.
      local verified_oid
      verified_oid=$(cat "$_wt_cleanup_tmp/$name.head" 2>/dev/null || true)
      if [[ -z "$verified_oid" ]]; then
        _warn "스킵: $name (삭제 근거 OID를 읽지 못했습니다 — 다시 실행하세요)"
        continue
      fi
      _remove_worktree "$wt_path" "$branch" "$git_root" "$verified_oid" || _info "경고: $name 삭제 실패"
    done

    git worktree prune 2>/dev/null || true
    if (( broken_count > 0 )); then
      _info "자동 정리 완료 (손상 ${broken_count}개 건너뜀)"
    else
      _info "자동 정리 완료"
    fi
    return 0
  fi

  local selected_names=()

  if (( ${#names_filter[@]} > 0 )); then
    # 위치 인자로 정리 대상 지정 (대화형/비대화형 공통)
    selected_names=("${names_filter[@]}")
  elif ! _wt_interactive; then
    _info "정리 가능한 worktree:"
    local _it
    for _it in "${items[@]}"; do _info "  $_it"; done
    _die "비대화형: 정리할 이름을 인자로 지정하거나 --auto를 사용하세요 (예: wt cleanup <name>...)"
  elif _has_fzf; then
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
    if (( found_idx < 0 )); then
      # items에 없음: 존재하지 않거나, 손상되어 제외됐거나(위 경고), 현재 worktree.
      # 과거엔 silent continue라 "정리 완료: 0개"만 떠 진단이 어려웠다 (#883).
      # 세 원인을 한 문장에 뭉뚱그리면 사용자가 어느 쪽인지 모른 채 막힌다 (#1186).
      # 현재 worktree는 원인이 특정되고 해결책도 명확하므로 분리해 안내한다.
      if [[ -n "$current_wt" && "$sel_name" == "$(basename "$current_wt")" ]]; then
        _wt_warn_cleanup_from_root "$git_root" "$sel_name" \
          "현재 위치한 worktree라 여기서는 삭제할 수 없습니다: $sel_name"
      else
        _warn "정리 대상 아님: $sel_name (존재하지 않거나, 손상되어 제외됨)"
      fi
      continue
    fi

    local wt_path="${item_paths[$found_idx]}"
    local branch="${item_branches[$found_idx]}"
    local name
    name=$(basename "$wt_path")

    if [[ "${item_dirty[$found_idx]}" == "true" ]] || [[ "${item_loss_risk[$found_idx]}" == "true" ]]; then
      local warn_msg="$name:"
      [[ "${item_dirty[$found_idx]}" == "true" ]] && warn_msg+=" uncommitted 변경사항"
      [[ "${item_loss_risk[$found_idx]}" == "true" ]] && warn_msg+=" push하지 않은 커밋"

      _info "$warn_msg"
      _confirm "정말 삭제하시겠습니까?" || { _info "스킵: $name"; continue; }
    fi

    # MERGED는 확인 프롬프트를 건너뛰므로, 그 판정의 근거가 아직 유효한지 삭제 직전에
    # 다시 본다 — 조회 이후 새 커밋이 생겼다면 사용자 확인 없이 지워선 안 된다.
    if [[ "${item_pr[$found_idx]}" == "MERGED" ]]; then
      _wt_merged_head_still_valid "$wt_path" "$_wt_cleanup_tmp/$name.head" "$name" || continue
    fi

    # MERGED로 확인을 건너뛴 항목은 검증 OID를 넘겨 브랜치 삭제를 CAS로 만든다.
    # 근거를 읽지 못하면 중단한다 — 빈 값은 CAS가 아니라 강제 삭제 경로이므로,
    # 확인을 생략한 채 보호까지 풀린 상태가 된다.
    # 그 외(사용자가 확인한 dirty/미push)는 기존대로 강제 삭제한다 — 잃을 것을 알고
    # 승인한 경로다.
    local verified_oid=""
    if [[ "${item_pr[$found_idx]}" == "MERGED" ]]; then
      verified_oid=$(cat "$_wt_cleanup_tmp/$name.head" 2>/dev/null || true)
      if [[ -z "$verified_oid" ]]; then
        _warn "스킵: $name (삭제 근거 OID를 읽지 못했습니다 — 다시 실행하세요)"
        continue
      fi
    fi
    if _remove_worktree "$wt_path" "$branch" "$git_root" "$verified_oid"; then
      removed=$((removed + 1))
    fi
  done

  git worktree prune 2>/dev/null || true
  if (( broken_count > 0 )); then
    _info "정리 완료: ${removed}개 삭제 (손상 ${broken_count}개 건너뜀)"
  else
    _info "정리 완료: ${removed}개 삭제"
  fi
}
