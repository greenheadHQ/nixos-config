# shellcheck shell=bash
_wt_last_file_path() {
  local git_root="$1"
  echo "$git_root/$WT_LAST_FILE"
}

_wt_record_last_path() {
  local git_root="$1"
  local current_dir
  local last_file
  current_dir=$(pwd -P)
  last_file=$(_wt_last_file_path "$git_root")
  mkdir -p "$(dirname "$last_file")"
  echo "$current_dir" > "$last_file"
}

_wt_read_last_path() {
  local git_root="$1"
  local last_file
  last_file=$(_wt_last_file_path "$git_root")
  [[ -f "$last_file" ]] || return 1
  cat "$last_file"
}

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
