# shellcheck shell=bash
# ── 서브커맨드: create ───────────────────────────────────────────────────────

cmd_create() {
  local branch_name=""
  local if_exists=""

  # 옵션 파싱
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --yes|-y) export WT_ASSUME_YES=1 ;;  # ui.sh _confirm이 소비 (cross-file)
      --if-exists=*) if_exists="${1#--if-exists=}" ;;
      -h|--help) show_help; return 0 ;;
      -*)       _die "알 수 없는 옵션: $1" ;;
      *)
        [[ -n "$branch_name" ]] && _die "브랜치명이 이미 지정됨: $branch_name (추가: $1)"
        branch_name="$1"
        ;;
    esac
    shift
  done

  case "$if_exists" in
    ""|reuse|recreate|fail) ;;
    *) _die "--if-exists 값은 reuse|recreate|fail 중 하나여야 합니다 (받음: $if_exists)" ;;
  esac

  [[ -z "$branch_name" ]] && _die "브랜치명을 지정하세요. 사용법: wt [--yes] [--if-exists=reuse|recreate|fail] <branch>"

  local git_root
  git_root=$(_get_repo_root) || _die "Git 저장소가 아닙니다"

  # 현재 브랜치 (분기 출처 표시용)
  local parent_branch
  parent_branch=$(git branch --show-current 2>/dev/null)
  if [[ -z "$parent_branch" ]]; then
    parent_branch=$(git rev-parse --short HEAD 2>/dev/null) || parent_branch="unknown"
  fi

  # 디렉토리명 결정
  local dir_name
  dir_name=$(_sanitize_name "$branch_name")
  # shellcheck disable=SC2153  # WORKTREE_DIR is set by wt.sh before sourcing helpers.
  local worktree_dir="$git_root/$WORKTREE_DIR/$dir_name"

  # 슬래시 포함 브랜치: 디렉토리명 매핑 안내 (슬래시→언더스코어 변환 인지용)
  if [[ "$dir_name" != "$branch_name" ]]; then
    _info "디렉토리명: $dir_name (← $branch_name)"
  fi

  # 기존 디렉토리 처리
  if [[ -d "$worktree_dir" ]]; then
    if [[ -f "$worktree_dir/.git" ]]; then
      _handle_existing_worktree "$worktree_dir" "$branch_name" "$git_root" "$parent_branch" "$if_exists"
      return $?
    fi
    _die "유효하지 않은 기존 디렉토리가 있습니다: $worktree_dir"
  fi

  # 기존 브랜치 존재 확인
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    _handle_existing_branch "$worktree_dir" "$branch_name" "$git_root" "$parent_branch" "$if_exists"
    return $?
  fi

  # 새 worktree 생성 (현재 HEAD 기준)
  _wt_require_state_helpers
  mkdir -p "$(dirname "$worktree_dir")"
  git worktree add -b "$branch_name" "$worktree_dir" >&2 || _die "worktree 생성 실패"

  _bootstrap_worktree "$worktree_dir" "$git_root"

  _info "worktree 생성: $branch_name (from $parent_branch)"

  _wt_record_last_path "$git_root"
  _wt_emit_worktree_path "$worktree_dir"
}

# 기존 worktree 경로의 실제 checkout이 요청 브랜치인지 대조한다 (#1375).
# 경로는 브랜치명의 `/`를 `_`로 바꿔 정하므로 서로 다른 브랜치(feat/a, feat_a)가 같은 경로로
# 매핑되고, worktree 안에서 브랜치를 직접 전환해도 경로는 그대로다. 경로가 있다는 사실만으로
# 진행하면 재사용은 다른 브랜치의 경로를 성공으로 돌려주고, 재생성은 worktree의 현재 HEAD로
# 손실을 판정한 뒤 요청 브랜치를 지워 그 브랜치에만 있던 커밋을 경고 없이 잃는다.
# 일치를 확인했을 때만 0이다. 손상·다른 브랜치·detached·조회 실패는 요청 브랜치와 확인된
# 상태를 알리고 1을 반환한다 — 확인하지 못한 것은 일치한 것이 아니다 (fail-closed).
# 읽기만 하므로 거부해도 worktree·브랜치·등록·마지막 경로 기록은 그대로다.
_wt_verify_requested_checkout() {
  local worktree_dir="$1" branch_name="$2" git_root="$3"
  local dir_name head_ref state rc=0 detached_hint=""
  local hint="재사용·재생성은 이 경로에 요청 브랜치가 checkout돼 있을 때만 합니다 (브랜치명의 '/'는 '_'로 바뀌어 다른 브랜치와 경로가 겹칠 수 있음)"
  dir_name=$(basename "$worktree_dir")

  if _wt_is_broken "$worktree_dir"; then
    state="손상된 worktree"
    hint=$(_wt_broken_hint "$git_root" "$worktree_dir")
  else
    # symbolic-ref --quiet: 브랜치면 0, detached면 1, 그 밖의 조회 오류는 128.
    head_ref=$(git -C "$worktree_dir" symbolic-ref --quiet HEAD 2>/dev/null) || rc=$?
    if (( rc == 0 )); then
      [[ "$head_ref" == "refs/heads/$branch_name" ]] && return 0
      state="브랜치 '${head_ref#refs/heads/}' checkout"
    elif (( rc == 1 )); then
      state="detached HEAD"
      # 자기 브랜치에서 rebase·bisect 중이어도 HEAD는 detached다 — 겹침 설명만으로는 이유를 모른다.
      detached_hint="rebase·bisect가 진행 중일 수 있습니다 — 이동만 필요하면: wt cd $(printf '%q' "$dir_name")"
    else
      state="checkout 조회 실패"
    fi
  fi

  _warn "기존 worktree 사용 불가: $dir_name (요청 브랜치 '$branch_name', 확인된 상태: $state)"
  _warn "  $hint"
  if [[ -n "$detached_hint" ]]; then
    _warn "  $detached_hint"
  fi
  return 1
}

# 기존 worktree 처리
_handle_existing_worktree() {
  local worktree_dir="$1" branch_name="$2" git_root="$3" parent_branch="$4" if_exists="${5:-}"
  local dir_name
  dir_name=$(basename "$worktree_dir")

  # 부작용 없이 끝나는 두 거부(fail, 비대화형 미지정)는 기존 계약 그대로 먼저 낸다.
  if [[ "$if_exists" == "fail" ]]; then
    _die "worktree '$branch_name'이(가) 이미 존재합니다 (--if-exists=fail)"
  elif [[ -z "$if_exists" ]] && ! _wt_interactive; then
    _die "worktree '$branch_name'이(가) 이미 존재합니다 — 비대화형에서는 --if-exists=reuse|recreate|fail로 명시하세요"
  fi

  # 재사용·재생성·대화형 선택이 공유하는 진입점. 요청 브랜치와 다른 checkout이면 선택지를
  # 묻지도 않는다 — 어느 쪽을 골라도 요청과 다른 worktree를 다루게 된다.
  _wt_verify_requested_checkout "$worktree_dir" "$branch_name" "$git_root" || return 1

  local choice
  case "$if_exists" in
    reuse)    choice="기존 열기" ;;
    recreate) choice="재생성" ;;
    *)        choice=$(_choose "worktree '$branch_name'이(가) 이미 존재합니다" "기존 열기" "재생성" "취소") || return 1 ;;
  esac

  case "$choice" in
    "기존 열기")
      _wt_record_last_path "$git_root"
      _wt_emit_worktree_path "$worktree_dir"
      ;;
    "재생성")
      _wt_require_state_helpers

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

      # 잠금 가드 (bootstrap.sh의 제거 경로와 같은 계약). git lock은 "다른 주체가 이
      # worktree를 붙잡고 있다"는 신호를 tmux pane과 독립적으로 낸다. 재생성은 제거를
      # 포함하므로 여기서도 잠금을 먼저 본다 — 뚫고 지우면 잠근 주체가 쓰던 디렉토리를
      # 파괴하고, 등록만 남은 유령이 되어 이후 prune은 잠긴 등록을 건너뛰고 add는
      # "missing but locked worktree"로 실패한다(실측). 확인하지 못한 상태(unknown)도
      # 되돌릴 수 없는 작업이라 진행하지 않는다(fail-closed).
      local _recreate_lock_state _recreate_lock_path
      read -r _recreate_lock_state _recreate_lock_path \
        <<< "$(_wt_effective_lock_state "$git_root" "$worktree_dir")"
      case "$_recreate_lock_state" in
        unlocked) ;;
        locked)
          _wt_warn_locked "재생성 불가: $dir_name" "$git_root" "$_recreate_lock_path"
          return 1
          ;;
        *)
          _warn "재생성 불가: $dir_name (잠금 상태를 확인하지 못했습니다)"
          return 1
          ;;
      esac

      _wt_tmux_close "$worktree_dir" || true
      # tmux 세션 정리 (연결된 클라이언트 있으면 재생성 중단)
      local _recreate_session
      _recreate_session=$(_wt_session_name "$dir_name")
      _wt_tmux_session_close "$_recreate_session" || {
        _info "재생성 불가: tmux 세션을 정리하지 못했습니다 (연결된 클라이언트 또는 상태 확인 실패)"
        _info "세션을 종료한 뒤 다시 시도하세요"
        return 1
      }
      local canonical_worktree_dir
      canonical_worktree_dir="$(cd "$worktree_dir" && pwd -P)" || canonical_worktree_dir="$worktree_dir"
      _wt_remove_claude_local_plugins_for_worktree "$worktree_dir" "$canonical_worktree_dir" \
        || _die "Claude local plugin manifest cleanup 실패 — 재생성 중단"
      # Codex trust는 해제하지 않는다 — 바로 아래 _bootstrap_worktree가 같은 경로를
      # 다시 trust하므로 지웠다 쓰는 왕복만 늘어난다. 등록이 남아 stale이 되는 경로는
      # 재생성이 아니라 제거(cleanup)이고, 그쪽은 bootstrap.sh가 해제한다.
      # `rm -rf` fallback은 두지 않는다 — git이 `--force`로도 거부하는 대상을 디렉토리만
      # 지워 흉내내면 등록은 남고 실체만 사라진 유령 worktree가 된다 (bootstrap.sh의
      # 제거 경로와 같은 이유). 실패 안내도 그 경로와 같은 등록 상태 분류를 쓴다.
      local _recreate_remove_err _recreate_remove_rc=0
      _recreate_remove_err=$(git -C "$git_root" worktree remove --force "$worktree_dir" 2>&1 >/dev/null) \
        || _recreate_remove_rc=$?
      if (( _recreate_remove_rc != 0 )); then
        _wt_warn_remove_failure "$dir_name" "$branch_name" "$git_root" "$worktree_dir" \
          "$canonical_worktree_dir" "$_recreate_remove_err"
        _die "worktree 재생성 실패: 기존 worktree를 제거하지 못했습니다"
      fi
      git worktree prune 2>/dev/null || true
      git branch -D "$branch_name" >&2 2>/dev/null || true

      git worktree add -b "$branch_name" "$worktree_dir" >&2 || _die "worktree 재생성 실패"
      _bootstrap_worktree "$worktree_dir" "$git_root"
      _info "worktree 재생성: $branch_name (from $parent_branch)"
      _wt_record_last_path "$git_root"
      _wt_emit_worktree_path "$worktree_dir"
      ;;
    *)
      _info "취소됨"
      return 1
      ;;
  esac
}

# 기존 브랜치 처리 (worktree 없음)
_handle_existing_branch() {
  local worktree_dir="$1" branch_name="$2" git_root="$3" parent_branch="$4" if_exists="${5:-}"
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
  if [[ -n "$if_exists" ]]; then
    case "$if_exists" in
      reuse)    choice="기존 브랜치 사용" ;;
      recreate) choice="새로 생성" ;;
      fail)     _die "브랜치 '$branch_name'이(가) 이미 존재합니다 (--if-exists=fail)" ;;
    esac
  elif ! _wt_interactive; then
    _die "브랜치 '$branch_name'이(가) 이미 존재합니다 — 비대화형에서는 --if-exists=reuse|recreate|fail로 명시하세요"
  else
    choice=$(_choose "브랜치 '$branch_name'이(가) 이미 존재합니다 (worktree 없음)" "기존 브랜치 사용" "새로 생성" "취소") || return 1
  fi

  case "$choice" in
    "기존 브랜치 사용")
      _wt_require_state_helpers
      mkdir -p "$(dirname "$worktree_dir")"
      git worktree add "$worktree_dir" "$branch_name" >&2 || _die "worktree 생성 실패"
      _bootstrap_worktree "$worktree_dir" "$git_root"
      _info "worktree 생성 (기존 브랜치): $branch_name"
      _wt_record_last_path "$git_root"
      _wt_emit_worktree_path "$worktree_dir"
      ;;
    "새로 생성")
      _wt_require_state_helpers

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
      _bootstrap_worktree "$worktree_dir" "$git_root"
      _info "worktree 생성 (브랜치 재생성): $branch_name (from $parent_branch)"
      _wt_record_last_path "$git_root"
      _wt_emit_worktree_path "$worktree_dir"
      ;;
    *)
      _info "취소됨"
      return 1
      ;;
  esac
}
