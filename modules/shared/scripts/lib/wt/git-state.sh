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

# worktree gitdir 유효성 — 손상(stale/orphaned)이면 0(true).
# .git 파일이 존재하지 않는 gitdir을 가리키면(예: 사용자명 마이그레이션 잔재) 모든
# `git -C "$wt"`가 fatal(exit 128)을 낸다. _collect_worktrees는 .git 파일 존재만
# 검사하므로 이런 손상 worktree까지 수집하는데, 무가드 git 호출이 set -e/pipefail로
# 폭사하기 전에(예: _wt_last_commit_msg) 이 헬퍼로 걸러낸다 (#883).
_wt_is_broken() {
  ! git -C "$1" rev-parse --git-dir >/dev/null 2>&1
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

# worktree에 unpushed 커밋이 있는지 체크 (raw git 상태)
# upstream을 못 찾으면 보수적으로 true다 — 한 번도 push하지 않은 브랜치를 놓치지
# 않기 위함이다. 이 보수성이 squash merge 후 false positive를 만드는 문제는
# _wt_has_unpushed_risk가 PR 상태로 보정한다 (아래 주석 참조).
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

# 정리(cleanup) 안전성 관점의 unpushed 판정 — "지우면 잃을 커밋이 있는가".
#
# squash merge를 하면 GitHub이 원격 브랜치를 삭제하고, remote-tracking ref까지
# 정리되면 로컬 브랜치의 upstream이 사라진다. 그러면 위 _wt_has_unpushed가 보수적
# true를 내어, 이미 main에 반영된 worktree가 "push하지 않은 커밋 있음"으로 오판된다.
# 이 false positive는 정리를 막아 worktree가 계속 쌓이게 한다.
#
# git만으로는 이 상태를 신뢰성 있게 판정할 수 없다 (실측):
#   - `git cherry`는 patch-id 비교라, 여러 커밋이 하나로 합쳐지는 squash에서는
#     모든 커밋을 미반영(+)으로 판정한다.
#   - 트리 직접 비교는 머지 직후에만 맞고, main이 이후 앞서가면 차이로 나온다.
#
# 반면 PR이 MERGED라는 사실은 _wt_pr_status의 branch name reuse guard가
# "머지된 PR의 headRefOid == 로컬 HEAD"까지 확인한 결과다. 즉 로컬에만 있는
# 커밋이 없음이 이미 보장되므로, 잃을 것이 없어 경고 대상에서 제외한다.
# MERGED가 아니면 기존 보수적 판정을 그대로 유지한다.
_wt_has_unpushed_risk() {
  local wt="$1"
  local pr_status="${2:-NONE}"
  [[ "$pr_status" == "MERGED" ]] && return 1
  _wt_has_unpushed "$wt"
}

# MERGED 판정의 근거가 된 HEAD가 아직 그대로인지 확인한다 (TOCTOU 가드).
#
# PR 상태는 cleanup 시작 시 한 번 조회해 캐시한다. 그 사이에 worktree에 새 커밋이
# 생기면 "MERGED = 잃을 커밋 없음"이라는 전제가 깨지는데, 캐시된 문자열만으로는
# 알 수 없다. 대화형 선택처럼 조회와 삭제 사이가 길어질수록 창이 커진다.
# 기록이 없거나 현재 HEAD를 못 읽으면 fail-closed로 false를 반환한다 —
# 확인할 수 없으면 삭제하지 않는 쪽이 안전하다.
_wt_head_unchanged() {
  local wt="$1"
  local recorded_file="$2"
  [[ -f "$recorded_file" ]] || return 1

  local recorded current
  recorded=$(cat "$recorded_file" 2>/dev/null) || return 1
  [[ -n "$recorded" ]] || return 1
  current=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  [[ "$recorded" == "$current" ]]
}

# PR 상태 조회 (gh CLI)
# 인자: branch, git_root, [wt_path], [verified_oid_out]
# wt_path가 주어지면 branch name reuse 감지: MERGED PR의 headRefOid와
# 현재 브랜치 HEAD를 비교하여, 다르면 NONE 반환 (동명의 다른 브랜치)
#
# verified_oid_out이 주어지면 MERGED 판정의 근거가 된 OID를 그 경로에 기록한다.
# 반드시 "비교에 사용한 그 값"이어야 한다 — 판정 후 HEAD를 다시 읽으면 두 읽기
# 사이에 생긴 커밋이 근거로 둔갑해, 삭제 직전 재검증이 그 커밋을 통과시킨다.
_wt_pr_status() {
  local branch="$1"
  local git_root="$2"
  local wt_path="${3:-}"
  local verified_oid_out="${4:-}"

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
    # 비교를 통과한 바로 그 OID를 근거로 남긴다 (여기서 HEAD를 다시 읽지 않는다).
    [[ -n "$verified_oid_out" ]] && printf '%s\n' "$pr_head_oid" > "$verified_oid_out"
  fi

  case "$pr_state" in
    MERGED) echo "MERGED" ;;
    OPEN)   echo "OPEN" ;;
    CLOSED) echo "CLOSED" ;;
    *)      echo "NONE" ;;
  esac
}

# 마지막 커밋 메시지 (한 줄)
# 자매 함수 _wt_branch(|| true)·_wt_last_commit_ts(|| echo "0")와 일관되게 git 실패를
# 흡수한다. git을 먼저 변수로 받아(|| msg="") 파이프라인 밖으로 빼므로, 손상/detached
# worktree에서 git이 fatal(128)을 내도 pipefail이 그 128을 채택해 set -e로 폭사하는
# 경로가 사라진다 (#883: bare assignment + pipefail + stale worktree 폭사).
_wt_last_commit_msg() {
  local msg
  msg=$(git -C "$1" log -1 --format='%s' 2>/dev/null) || msg=""
  printf '%s' "$msg" | cut -c1-60
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
      # MERGED 판정의 근거가 된 OID를 _wt_pr_status가 직접 기록한다 — 판정 후 HEAD를
      # 다시 읽으면 그 사이에 생긴 커밋이 근거로 둔갑해 삭제 직전 재검증을 통과한다.
      local pr_status
      pr_status=$(_wt_pr_status "$branch" "$git_root" "$wt" "$tmp_dir/$name.head")
      echo "$pr_status" > "$tmp_dir/$name.pr"
    ) &
    pids+=($!)
  done

  if (( ${#pids[@]} > 0 )); then
    _info "PR 상태 조회 중..."
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  fi
}
