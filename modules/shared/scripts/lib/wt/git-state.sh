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

# ── worktree 등록 정보(porcelain) ────────────────────────────────────────────

# 한 worktree 등록 블록의 속성 줄만 stdout으로 낸다 (HEAD/branch/detached/locked/prunable).
# `git worktree list --porcelain`은 "worktree <path>"로 시작하는 블록의 나열이라, 경로가
# 정확히 일치하는 블록만 잘라내면 잠금 같은 등록 메타데이터를 그대로 읽을 수 있다.
# 조회 자체가 실패하면 1을 반환한다 — "속성이 없다"와 "확인하지 못했다"를 호출자가
# 구분해야 잠금 같은 보호 신호를 없는 것으로 오해하지 않는다.
_wt_registration_block() {
  local git_root="$1" wt_path="$2"
  local list
  list=$(git -C "$git_root" worktree list --porcelain 2>/dev/null) || return 1
  printf '%s\n' "$list" | awk -v target="worktree $wt_path" '
    $0 == target { found = 1; next }
    /^worktree / { found = 0 }
    found && NF { print }
  '
}

# 이 worktree가 git에 잠겨(locked) 있는가.
# stdout: locked | unlocked | unknown (tmux·등록 상태 probe와 같은 삼상태 계약)
_wt_lock_state() {
  local block
  block=$(_wt_registration_block "$1" "$2") || { printf 'unknown\n'; return 0; }
  if printf '%s\n' "$block" | grep -qE '^locked([[:space:]]|$)'; then
    printf 'locked\n'
  else
    printf 'unlocked\n'
  fi
}

# 잠금 여부 boolean 뷰. 확인하지 못한 상태(unknown)는 잠김으로 보지 않는다 —
# 파괴적 경로의 fail-closed 판단은 삼상태를 직접 보는 호출자가 소유한다.
_wt_is_locked() {
  [[ "$(_wt_lock_state "$1" "$2")" == "locked" ]]
}

# 파괴적 경로가 쓰는 잠금 조회 — 경로 표기 차이에 강하다.
# 등록 조회는 경로 문자열 일치라, 심링크가 낀 경로(macOS /var→/private/var)로 불리면
# 등록 블록을 못 찾아 잠금이 "없음"으로 보인다. 가드가 조용히 무력해지는 경로이므로
# unlocked로 보일 때 물리 경로로 한 번 더 확인한다.
# stdout: "<state> <probe_path>" — state는 locked|unlocked|unknown, probe_path는 그 판정을
# 낸 경로(안내에 실을 unlock 대상). 경로가 마지막 필드라 공백이 있어도 `read -r a b`로 나뉜다.
_wt_effective_lock_state() {
  local git_root="$1" wt_path="$2"
  local state probe_path="$wt_path" physical
  state=$(_wt_lock_state "$git_root" "$wt_path")
  if [[ "$state" == "unlocked" ]]; then
    physical="$(cd "$wt_path" && pwd -P)" || physical="$wt_path"
    if [[ "$physical" != "$wt_path" ]]; then
      state=$(_wt_lock_state "$git_root" "$physical")
      probe_path="$physical"
    fi
  fi
  printf '%s %s\n' "$state" "$probe_path"
}

# 잠금 사유 (없거나 확인 실패면 빈 문자열). 잠근 주체를 찾는 단서라 안내에 함께 싣는다.
_wt_lock_reason() {
  local block reason
  block=$(_wt_registration_block "$1" "$2") || return 0
  reason=$(printf '%s\n' "$block" | awk '/^locked[[:space:]]/ { sub(/^locked[[:space:]]+/, ""); print; exit }') || reason=""
  printf '%s' "$reason"
}

# 등록에 기록된 브랜치명. 디렉토리가 사라진 worktree는 `git -C`가 통째로 실패해
# _wt_branch가 항상 detached를 내므로, 그런 항목의 정체를 표시하려면 등록을 봐야 한다.
_wt_registered_branch() {
  local block ref
  block=$(_wt_registration_block "$1" "$2") || { printf 'detached\n'; return 0; }
  ref=$(printf '%s\n' "$block" | awk '/^branch refs\/heads\// { sub(/^branch refs\/heads\//, ""); print; exit }') || ref=""
  printf '%s\n' "${ref:-detached}"
}

# 손상 worktree 복구 안내 (stdout 한 줄). 상황마다 실제로 듣는 명령이 다르다:
#   디렉토리 없음            → 등록만 남았으니 `git worktree prune`
#   디렉토리 있음+gitdir 무효 → 경로를 지운 뒤 prune (사용자명 마이그레이션 잔재 등, #883)
# 잠금은 두 경우 모두에 앞선다 — `git worktree prune`은 잠긴 등록을 건너뛰므로(실측),
# 잠긴 채로 "rm -rf 후 prune"을 안내하면 사용자는 디렉토리만 잃고 유령 등록은 그대로
# 남는다. 이 PR이 없애려는 상태를 안내문이 만들어내지 않도록 unlock을 선행 단계로 붙인다.
# 한 문장으로 뭉뚱그리면 사용자가 듣지 않는 명령을 실행하고 상태는 그대로 남는다.
_wt_broken_hint() {
  local git_root="$1" wt_path="$2"
  local safe_path
  printf -v safe_path '%q' "$wt_path"
  # 잠금 조회는 git 호출이라 분기마다 반복하지 않고 한 번만 한다.
  local locked=false
  _wt_is_locked "$git_root" "$wt_path" && locked=true
  if [[ -d "$wt_path" ]]; then
    if [[ "$locked" == "true" ]]; then
      printf 'gitdir 무효(잠김) — 수동 정리: git worktree unlock %s 후 rm -rf %s, git worktree prune' \
        "$safe_path" "$safe_path"
    else
      printf 'gitdir 무효 — 수동 정리: rm -rf %s 후 git worktree prune' "$safe_path"
    fi
  elif [[ "$locked" == "true" ]]; then
    printf '디렉토리 없음(잠김) — 수동 정리: git worktree unlock %s 후 git worktree prune' "$safe_path"
  else
    printf '디렉토리 없음 — 수동 정리: git worktree prune'
  fi
}

# worktree 목록 수집 — git 등록을 1차 근거로, 미등록 잔재 디렉토리를 합집합으로.
#
# 디렉토리 스캔(mindepth/maxdepth 1)만 보던 과거 구현은 두 부류를 통째로 놓쳤다:
#   (a) 등록만 남고 디렉토리가 사라진 worktree — 잠겨 있어 prune이 지우지 못한 것 포함.
#       사용자에게는 `git worktree list`에 보이는데 `wt ls`에는 없는 유령이 된다.
#   (b) depth 2 이상 경로(.claude/worktrees/feat/x) — 브랜치명을 sanitize하지 않고 만든
#       worktree가 여기 해당하며, wt의 모든 서브커맨드 시야 밖이었다.
# 반대로 등록만 보면 git이 모르는 잔재 디렉토리가 안 보이므로, 두 출처를 합쳐야 한다.
#
# porcelain 경로는 git이 canonical(물리) 경로로 기록한다. _get_repo_root도 `pwd -P`라
# 보통 접두사가 그대로 맞지만, 심링크가 낀 배치를 대비해 물리 경로 접두사도 함께 본다.
#
# 합집합의 중복 제거는 문자열 비교라, 두 출처가 같은 worktree를 다른 표기(논리/물리)로
# 내면 같은 항목이 두 줄이 된다 (`.claude`가 심링크인 배치에서 실측). find 결과를 물리
# 경로로 정규화해 담아 두 출처의 표기를 하나로 맞춘다.
_wt_base_physical() {
  local wt_base="$1"
  if [[ -d "$wt_base" ]]; then
    (cd "$wt_base" && pwd -P) 2>/dev/null || printf '%s\n' "$wt_base"
  else
    printf '%s\n' "$wt_base"
  fi
}

_collect_worktrees() {
  local git_root="$1"
  local wt_base="$git_root/$WORKTREE_DIR"
  local wt_base_physical
  wt_base_physical=$(_wt_base_physical "$wt_base")

  local results=()
  local line path
  while IFS= read -r line; do
    [[ "$line" == "worktree "* ]] || continue
    path="${line#worktree }"
    [[ "$path" == "$wt_base"/* || "$path" == "$wt_base_physical"/* ]] || continue
    results+=("$path")
  done < <(git -C "$git_root" worktree list --porcelain 2>/dev/null || true)

  if [[ -d "$wt_base" ]]; then
    local dir physical_dir
    while IFS= read -r -d '' dir; do
      # .git 파일이 있는 디렉토리만 (git이 모르는 잔재도 여기서 잡힌다)
      [[ -f "$dir/.git" ]] || continue
      physical_dir="$(cd "$dir" && pwd -P)" || physical_dir="$dir"
      results+=("$physical_dir")
    done < <(find "$wt_base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi

  (( ${#results[@]} > 0 )) || return 0
  printf '%s\n' "${results[@]}" | LC_ALL=C sort -u
}

# 목록에서 이 worktree를 가리키는 표시·선택 이름 — WORKTREE_DIR 기준 상대 경로다.
# basename을 이름으로 쓰면 depth 2 이상 경로(.claude/worktrees/feat/x)가 depth 1 항목
# (.claude/worktrees/x)과 같은 이름이 되어, 이름으로 대상을 고르는 파괴적 명령이 사용자가
# 지목하지 않은 쪽을 지울 수 있다 (정렬상 먼저 오는 항목이 선택됨 — 실측).
_wt_display_name() {
  local git_root="$1" wt_path="$2"
  local wt_base="$git_root/$WORKTREE_DIR"
  local wt_base_physical
  wt_base_physical=$(_wt_base_physical "$wt_base")
  case "$wt_path" in
    "$wt_base"/*)          printf '%s\n' "${wt_path#"$wt_base"/}" ;;
    "$wt_base_physical"/*) printf '%s\n' "${wt_path#"$wt_base_physical"/}" ;;
    *)                     basename "$wt_path" ;;
  esac
}

# PR 상태 캐시 파일 이름. 표시 이름은 `/`를 포함할 수 있어 그대로 파일명에 쓰면 없는
# 하위 디렉토리 경로가 되고, basename으로 접으면 두 worktree가 같은 캐시 파일에 병렬로
# 써서 PR 표시가 뒤섞인다. 되돌릴 수 있는 이스케이프로 이름 하나에 파일 하나를 보장한다.
_wt_pr_cache_key() {
  printf '%s\n' "${1//\//%2F}"
}

# worktree gitdir 유효성 — 손상(stale/orphaned)이면 0(true).
# .git 파일이 존재하지 않는 gitdir을 가리키거나(예: 사용자명 마이그레이션 잔재) 디렉토리
# 자체가 사라졌으면 모든 `git -C "$wt"`가 fatal(exit 128)을 낸다. _collect_worktrees는
# 등록과 잔재 디렉토리를 모두 수집하므로 이런 항목이 그대로 들어오는데, 무가드 git 호출이
# set -e/pipefail로 폭사하기 전에(예: _wt_last_commit_msg) 이 헬퍼로 걸러낸다 (#883).
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
# 인자: wt, pr_status, head_file (셋 다 필수)
#
# 근거 파일을 반드시 받아 유효성 보정까지 이 함수가 수행한다. 선택 인자로 두면
# "근거 없이 문자열만 보고 판정"하는 우회 경로가 남고, 그것을 쓴 소비자는 검증되지
# 않았거나 낡은 MERGED를 "손실 없음"으로 오판한다 — 파괴적 정리의 입력이라 그 여지를
# 남기지 않는다. 정말 비검증 판정이 필요해지면 의미가 드러나는 별도 helper를 만든다.
_wt_has_unpushed_risk() {
  local wt="$1"
  local pr_status="${2:-NONE}"
  local head_file="$3"

  local effective
  effective=$(_wt_effective_pr_status "$wt" "$pr_status" "$head_file")

  [[ "$effective" == "MERGED" ]] && return 1
  _wt_has_unpushed "$wt"
}

# MERGED 판정의 근거가 된 HEAD가 아직 그대로인지 확인한다 (TOCTOU 가드).
#
# PR 상태는 cleanup 시작 시 한 번 조회해 캐시한다. 그 사이에 worktree에 새 커밋이
# 생기면 "MERGED = 잃을 커밋 없음"이라는 전제가 깨지는데, 캐시된 문자열만으로는
# 알 수 없다. 대화형 선택처럼 조회와 삭제 사이가 길어질수록 창이 커진다.
# 기록이 없거나 현재 HEAD를 못 읽으면 fail-closed로 false를 반환한다 —
# 확인할 수 없으면 삭제하지 않는 쪽이 안전하다.
# 캐시된 PR 상태를 근거 유효성까지 반영한 값으로 보정한다.
#
# `MERGED`는 "조회 시점 headRefOid == 로컬 HEAD"를 전제로 한 판정이다. 그 근거가
# 없거나(검증하지 못한 MERGED) 이후 HEAD가 바뀌었으면 더는 MERGED로 취급하면 안 된다.
# 소비자마다 이 보정을 다시 구현하면 한 곳이 빠지고, 그 소비자만 낡은 근거를 믿게 된다.
_wt_effective_pr_status() {
  local wt="$1" pr_status="$2" head_file="$3"
  if [[ "$pr_status" == "MERGED" ]] && ! _wt_head_unchanged "$wt" "$head_file"; then
    printf 'NONE\n'
    return 0
  fi
  printf '%s\n' "$pr_status"
}

_wt_head_unchanged() {
  local wt="$1"
  local recorded_file="$2"
  [[ -f "$recorded_file" ]] || return 1

  # 기록 형식: "<oid> <branch>". OID만으로는 부족하다 — 같은 커밋을 가리키는 다른
  # 브랜치로 전환되면 OID 비교는 통과하고, 그 상태로 삭제하면 조회한 적 없는 브랜치의
  # ref를 지운다. 근거를 브랜치 정체성까지 묶어야 "그때 그 브랜치"임이 보장된다.
  # 형식이 어긋난 기록은 통과시키지 않는다 — 파괴적 경계에서 "검증하지 못한 근거"는
  # 근거가 없는 것과 같게 다뤄야 한다. 관대한 해석은 브랜치 검사를 건너뛰는 우회로가 된다.
  local recorded recorded_oid recorded_branch current_oid current_branch
  recorded=$(cat "$recorded_file" 2>/dev/null) || return 1
  [[ "$recorded" == *" "* ]] || return 1
  recorded_oid="${recorded%% *}"
  recorded_branch="${recorded#* }"
  [[ -n "$recorded_oid" && -n "$recorded_branch" ]] || return 1

  current_oid=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || return 1
  [[ "$recorded_oid" == "$current_oid" ]] || return 1

  current_branch=$(_wt_branch "$wt")
  [[ "$recorded_branch" == "$current_branch" ]] || return 1
  return 0
}

# PR 상태 조회 (gh CLI)
# 인자: branch, git_root, [wt_path]
# wt_path가 주어지면 branch name reuse 감지: MERGED PR의 headRefOid와
# 현재 브랜치 HEAD를 비교하여, 다르면 NONE 반환 (동명의 다른 브랜치)
#
# stdout: "<STATE>". MERGED만 두 가지 형태를 가진다 —
#   "MERGED <verified_oid>": wt_path가 주어지고 PR headRefOid와 HEAD 비교에 성공한 경우.
#   "MERGED": 비교를 하지 못한 경우(wt_path 없음, PR headRefOid 없음, HEAD 읽기 실패).
# 근거 OID는 반드시 "비교에 사용한 그 값"이다 — 판정 후 HEAD를 다시 읽으면 두 읽기
# 사이에 생긴 커밋이 근거로 둔갑해, 삭제 직전 재검증이 그 커밋을 통과시킨다.
# 저장은 호출자(_fetch_pr_statuses)가 전담한다 — 조회 함수는 캐시 경로를 모른다.
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
    if [[ -n "$branch_head" ]]; then
      # 비교를 통과한 바로 그 OID를 근거로 반환한다 (여기서 HEAD를 다시 읽지 않는다).
      echo "MERGED $pr_head_oid"
      return
    fi
    # HEAD를 읽지 못해 비교를 하지 못했다. 상태는 MERGED로 두되 근거는 붙이지 않는다 —
    # 검증하지 않은 값을 "verified" 자리에 넣으면 그 계약을 믿는 소비자가 생긴다.
    # 근거가 없으면 무확인 삭제 경로가 fail-closed로 멈춘다.
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

# 모든 worktree의 PR 상태를 병렬로 조회해 tmp_dir에 캐시한다.
# 생성 파일: <key>.pr (상태 문자열), 그리고 MERGED인 경우에만 <key>.head
# (판정 근거 OID — 삭제 직전 재검증과 JSON 출력 보정이 이 값에 의존한다).
# <key>는 표시 이름(WORKTREE_DIR 상대 경로)을 _wt_pr_cache_key로 이스케이프한 값이다 —
# 소비자(cleanup/ls)도 같은 헬퍼로 만들어야 캐시가 어긋나지 않는다.
# 캐시를 정리하거나 호출부를 옮길 때 두 파일을 함께 다뤄야 한다.
_fetch_pr_statuses() {
  local git_root="$1"
  local tmp_dir="$2"
  shift 2
  local worktrees=("$@")

  local pids=()
  for wt in "${worktrees[@]}"; do
    # 손상 항목(디렉토리 소실·gitdir 무효)은 브랜치를 읽을 수 없어 _wt_branch가 detached를
    # 낸다 — 그 이름으로 조회해봐야 결과가 없고, 등록만 남은 worktree 수만큼 무의미한 gh
    # 네트워크 호출만 늘어난다. 캐시 파일을 안 만들면 소비자는 기본값 NONE으로 읽는다.
    _wt_is_broken "$wt" && continue
    local branch name
    branch=$(_wt_branch "$wt")
    name=$(_wt_pr_cache_key "$(_wt_display_name "$git_root" "$wt")")
    (
      # _wt_pr_status는 MERGED이면서 HEAD 비교에 성공한 경우에만 "MERGED <verified_oid>"를
      # 반환한다 (비교하지 못했으면 근거 없는 bare "MERGED"). 상태와 근거 OID를 분리해
      # 저장하는 책임은 여기(캐시 소유자)에 둔다.
      local raw pr_status verified_oid
      raw=$(_wt_pr_status "$branch" "$git_root" "$wt")
      pr_status="${raw%% *}"
      verified_oid=""
      [[ "$raw" == "$pr_status "* ]] && verified_oid="${raw#"$pr_status" }"
      echo "$pr_status" > "$tmp_dir/$name.pr"
      # 근거는 "<oid> <branch>"로 남긴다 — OID만 남기면 같은 커밋의 다른 브랜치로
      # 전환된 경우를 구분하지 못한다 (_wt_head_unchanged 참조).
      [[ -n "$verified_oid" ]] && printf '%s %s\n' "$verified_oid" "$branch" > "$tmp_dir/$name.head"
    ) &
    pids+=($!)
  done

  if (( ${#pids[@]} > 0 )); then
    _info "PR 상태 조회 중..."
    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  fi
}
