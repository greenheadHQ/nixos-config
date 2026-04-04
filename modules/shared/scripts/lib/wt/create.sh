# shellcheck shell=bash
# ── 서브커맨드: create ───────────────────────────────────────────────────────

_record_wt_last_path() {
  local git_root="$1"
  local current_dir
  current_dir=$(pwd -P)
  mkdir -p "$(dirname "$git_root/$WT_LAST_FILE")"
  echo "$current_dir" > "$git_root/$WT_LAST_FILE"
}

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

  [[ -z "$branch_name" ]] && _die "브랜치명을 지정하세요. 사용법: wt [--stay] [--claude] [--tmux] <branch>"

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
  # shellcheck disable=SC2153  # WORKTREE_DIR is set by wt.sh before sourcing helpers.
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
    _die "유효하지 않은 기존 디렉토리가 있습니다: $worktree_dir"
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

  _record_wt_last_path "$git_root"
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
      _record_wt_last_path "$git_root"
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
      _record_wt_last_path "$git_root"
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
      _record_wt_last_path "$git_root"
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
      _record_wt_last_path "$git_root"
      _open_worktree "$worktree_dir" "$dir_name" "$stay" "$run_claude" "$use_tmux_session"
      ;;
    *)
      _info "취소됨"
      return 1
      ;;
  esac
}
