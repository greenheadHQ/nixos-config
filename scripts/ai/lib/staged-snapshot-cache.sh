#!/usr/bin/env bash
# scripts/ai/lib/staged-snapshot-cache.sh
#
# 공유 staged-snapshot 캐시 provider.
#
# 문제: pre-commit(lefthook, parallel:true)의 여러 command가 각자 `git checkout-index --all`로
#   staged 트리(~752파일)를 임시 디렉토리에 복제해 디스크 I/O 경합을 일으켰다.
# 해법: `git write-tree` 해시를 키로 staged 트리를 1회만 materialize 하고, 동일 index 내용을
#   보는 모든 command가 그 결과를 공유한다.
#
# 메커니즘 (flock 부재 — macOS/devShell 실측):
#   - mkdir atomic lock + `.ready` 완료 마커로 첫 호출만 build, 나머지는 대기 후 공유.
#   - build 는 builds/ 임시 경로에서 완성한 뒤 trees/<hash> 로 rename(`mv`; dest 부재 시 atomic
#     publish). 반쯤 채워진 트리가 노출되지 않는다.
#   - 공유 worktree 는 chmod a-w(read-only). consumer 가 실수로 쓰면 즉시 드러난다.
#   - lock holder 가 죽거나 과도하게 느리면 대기자가 타임아웃 후 lock 을 제거하고 직접
#     빌드한다(정교한 PID 판정 없음 — 최악은 중복 checkout 1회로, 정확성은 유지된다).
#   - 캐시 정리는 OS 임시디렉토리 정책(macOS /var/folders, /tmp 청소 등)에 위임한다. 같은 staged
#     내용은 같은 hash 로 재사용되고, 다른 hash 누적은 OS tmp 청소로 회수된다.
#
# 사용:
#   . "$REPO_ROOT/scripts/ai/lib/staged-snapshot-cache.sh"
#   staged_snapshot_cache_provide "$REPO_ROOT"               # 기본: repo 의 현재 index 로
#   staged_snapshot_cache_provide "$REPO_ROOT" "$src_index"  # explicit: 주어진 index(의 복사본)로
#   trap 'staged_snapshot_cache_release' EXIT                # 정리는 호출자(trap) 책임
#
# 계약:
#   - 성공 시 $STAGED_SNAPSHOT_CACHE_WORKTREE 가 read-only 공유 트리를 가리킨다. 절대 쓰지 않는다.
#   - 2번째 인자(caller-owned src index)를 주면, provide 가 그것을 즉시 private copy 로 떠서
#     write-tree 키와 checkout-index materialize 의 단일 소스로 쓴다 — 인자 파일 자체가 아니라 그
#     복사본이 소스다(호출자가 같은 src 로 만든 자기 index 작업과 동일 staged tree 를 보게 하려는 용도).
#     생략하면 repo 현재 index(`git rev-parse --git-path index`, GIT_INDEX_FILE 반영)를 복사한다.
#   - 그 private copy(_SSC_PINNED_INDEX)와 umask 는 provide wrapper 가 정리/복구한다.

# lock 대기 타임아웃(초). 초과 시 holder 가 죽었거나 과부하로 보고 lock 을 제거한 뒤 직접 빌드한다.
_SSC_LOCK_TIMEOUT_SECONDS="${STAGED_SNAPSHOT_CACHE_LOCK_TIMEOUT_SECONDS:-120}"
# polling 간격(초)
_SSC_POLL_INTERVAL="0.1"
# 오래된 캐시 GC TTL(초). provide 진입 시 현재 hash 를 제외하고 이보다 오래된(mtime) trees/builds
# 를 제거한다. gitleaks 가 막은 staged secret 사본의 잔존과 tree-hash 별 디스크 누적을 OS tmp
# 청소에만 의존하지 않고 정리하기 위함이다(기존 per-run 의 즉시 정리 동작에 근접).
STAGED_SNAPSHOT_CACHE_TTL_SECONDS="${STAGED_SNAPSHOT_CACHE_TTL_SECONDS:-3600}" # 1h

# release/wrapper 가 참조하는 상태
_SSC_HELD_LOCK=""
# 이번 호출이 보유한 lock 의 owner 토큰. timeout takeover 후 successor 가 같은 경로에 만든 lock 을
# 원 builder 가 훼손하지 않도록, unlock 시 lockdir/owner 와 대조한다.
_SSC_LOCK_TOKEN=""
_SSC_BUILD_DIR=""
# write-tree 키 계산과 checkout-index materialize 가 공유하는 pinned index. wrapper 가 정리한다.
_SSC_PINNED_INDEX=""

# 결과 (provide 가 설정)
STAGED_SNAPSHOT_CACHE_WORKTREE=""

_ssc_die() {
  echo "staged-snapshot-cache: $*" >&2
  return 1
}

# read-only(chmod a-w) 트리도 지울 수 있도록 u+w 복구 후 rm
_ssc_rm_tree() {
  [ -n "$1" ] || return 0
  chmod -R u+w "$1" 2>/dev/null || true
  rm -rf "$1" 2>/dev/null || true
}

# 자기 token 이 기록된 lock 만 해제한다. timeout takeover(rm -rf)로 successor 가 같은 경로에 새
# lock 을 만든 경우, 원 builder 가 그 successor lock 을 rmdir 해 직렬화가 붕괴되는 것을 막는다.
_ssc_unlock() {
  [ -n "${_SSC_HELD_LOCK:-}" ] || return 0
  if [ -f "$_SSC_HELD_LOCK/owner" ] \
    && [ "$(cat "$_SSC_HELD_LOCK/owner" 2>/dev/null)" = "${_SSC_LOCK_TOKEN:-}" ]; then
    rm -f "$_SSC_HELD_LOCK/owner" 2>/dev/null
    rmdir "$_SSC_HELD_LOCK" 2>/dev/null || true
  fi
  _SSC_HELD_LOCK=""
}

# 경로 16자 해시 (per-worktree 캐시 격리 키)
_ssc_hash16() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-16
  else
    shasum -a 256 | cut -c1-16
  fi
}

# 소유 uid (GNU stat -c vs BSD /usr/bin/stat -f)
_ssc_owner_uid() {
  local ou
  if ou="$(stat -c %u "$1" 2>/dev/null)" && [ -n "$ou" ]; then
    printf '%s' "$ou"
  else
    /usr/bin/stat -f %u "$1" 2>/dev/null
  fi
}

# 파일/디렉토리 mtime epoch (GNU stat -c vs BSD /usr/bin/stat -f)
_ssc_mtime() {
  local mt
  if mt="$(stat -c %Y "$1" 2>/dev/null)" && [ -n "$mt" ]; then
    printf '%s' "$mt"
  else
    /usr/bin/stat -f %m "$1" 2>/dev/null
  fi
}

# best-effort GC: 현재 hash 를 제외하고, mtime 이 TTL 보다 오래된 trees/builds 항목을 제거한다.
# lease 추적 없이 mtime 만 보므로(단일 사용자 전제) 막 빌드됐거나 방금 쓰인 캐시(mtime 최신)는
# 건드리지 않는다. secret 사본 잔존과 디스크 누적을 OS tmp 청소에만 의존하지 않고 줄인다.
_ssc_gc() {
  local trees_dir="$1" builds_dir="$2" keep_hash="$3"
  local now entry mt base
  now="$(date +%s)"
  for entry in "$trees_dir"/* "$builds_dir"/*; do
    [ -d "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = "$keep_hash" ] && continue
    mt="$(_ssc_mtime "$entry")" || continue
    [ -n "$mt" ] || continue
    if [ $(( now - mt )) -ge "$STAGED_SNAPSHOT_CACHE_TTL_SECONDS" ]; then
      _ssc_rm_tree "$entry"
    fi
  done
  return 0
}

# 심링크 거부 + mkdir -p + 소유권 검증 (predictable /tmp path 방어)
_ssc_safe_mkdir() {
  local dir="$1" owner
  if [ -L "$dir" ]; then
    _ssc_die "refusing symlinked cache path: $dir"
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || { _ssc_die "mkdir failed: $dir"; return 1; }
  owner="$(_ssc_owner_uid "$dir")"
  if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
    _ssc_die "cache path not owned by uid $(id -u): $dir (owner uid $owner)"
    return 1
  fi
  return 0
}

# 캐시가 준비될 때까지 빌드(획득)하거나 대기한다. 성공 시 0.
_ssc_acquire() {
  local repo_root="$1" cache_dir="$2" lockdir="$3" build_dir="$4" src_index="$5"
  local start
  while true; do
    if [ -f "$cache_dir/.ready" ] && [ -d "$cache_dir/worktree" ]; then
      return 0
    fi
    _SSC_LOCK_TOKEN="${BASHPID:-$$}.$RANDOM.$(date +%s)"
    if mkdir "$lockdir" 2>/dev/null && printf '%s\n' "$_SSC_LOCK_TOKEN" > "$lockdir/owner" 2>/dev/null; then
      # 빌더. lockdir/owner 에 이번 호출 token 을 적어, 해제 시 자기 lock 만 제거한다(아래 timeout
      # takeover 가 만든 successor lock 을 원 builder 가 rmdir 하지 않게 함 → 직렬화 붕괴 방지).
      _SSC_HELD_LOCK="$lockdir"
      _SSC_BUILD_DIR="$build_dir"
      if ! mkdir -p "$build_dir/worktree" 2>/dev/null; then
        _ssc_rm_tree "$build_dir"; _SSC_BUILD_DIR=""
        _ssc_unlock
        _ssc_die "build dir mkdir failed: $build_dir"
        return 1
      fi
      if ! GIT_INDEX_FILE="$src_index" git -C "$repo_root" checkout-index --all --prefix="$build_dir/worktree/" 2>/dev/null; then
        _ssc_rm_tree "$build_dir"; _SSC_BUILD_DIR=""
        _ssc_unlock
        _ssc_die "git checkout-index failed"
        return 1
      fi
      # 테스트 가시성: 실제 checkout-index(=캐시 빌드) 횟수 기록. env 미설정 시 무동작.
      if [ -n "${STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG:-}" ]; then
        printf '%s\n' "$build_dir" >> "$STAGED_SNAPSHOT_CACHE_DEBUG_BUILD_LOG" 2>/dev/null || true
      fi
      chmod -R a-w "$build_dir/worktree" 2>/dev/null || true
      # .ready 는 build_dir 안에 만들어 publish(mv) 로 cache_dir 과 함께 원자 게시한다. 생성에
      # 실패하면 build 를 폐기해 .ready 없는 cache_dir 이 publish 를 영구 막는 일이 없게 한다.
      if ! : > "$build_dir/.ready" 2>/dev/null; then
        _ssc_rm_tree "$build_dir"; _SSC_BUILD_DIR=""
        _ssc_unlock
        _ssc_die "ready marker write failed"
        return 1
      fi
      # atomic publish: lock 직렬화로 cache_dir 은 보통 부재이며, dest 가 없을 때 `mv <dir>
      # <nonexistent>` 는 rename(2) 한 번으로 원자적이다(BSD mv 라 -T 미지원). 단 타임아웃 탈취로
      # 중복 빌더가 생겨 경쟁자가 검사~mv 사이에 먼저 publish 하면, BSD mv 는 build_dir 를
      # cache_dir/<basename> 안으로 넣는다(rename 아님). 그 loser 잔여를 감지해 정리하고, 어느
      # 경로든 완성된 cache_dir 트리(winner)를 공유한다.
      local _bd_name; _bd_name="$(basename "$build_dir")"
      if [ ! -e "$cache_dir" ] && mv "$build_dir" "$cache_dir" 2>/dev/null && [ ! -e "$cache_dir/$_bd_name" ]; then
        _SSC_BUILD_DIR=""
      else
        _ssc_rm_tree "$cache_dir/$_bd_name"
        _ssc_rm_tree "$build_dir"
        _SSC_BUILD_DIR=""
      fi
      _ssc_unlock
      if [ -f "$cache_dir/.ready" ] && [ -d "$cache_dir/worktree" ]; then
        return 0
      fi
      _ssc_die "staged snapshot publish failed (cache_dir=$cache_dir)"
      return 1
    fi
    # 대기자: 다른 호출이 빌드 중. .ready 를 polling 하고, 타임아웃 초과 시 lock 을 제거해
    # 직접 빌드 경로로 넘어간다(holder 사망/과부하 추정 — 최악은 중복 checkout 1회).
    start="$SECONDS"
    while [ ! -f "$cache_dir/.ready" ]; do
      sleep "$_SSC_POLL_INTERVAL"
      if [ -f "$cache_dir/.ready" ] && [ -d "$cache_dir/worktree" ]; then
        return 0
      fi
      if [ ! -d "$lockdir" ]; then
        break
      fi
      if [ $(( SECONDS - start )) -ge "$_SSC_LOCK_TIMEOUT_SECONDS" ]; then
        rm -rf "$lockdir" 2>/dev/null || true
        break
      fi
    done
  done
}

# 메인 진입점 (wrapper). umask 와 pinned index 의 수명을 관리하고 본체는 _ssc_provide_impl 에 둔다.
# - umask 077 을 캐시 생성 구간에만 적용하고, 같은 프로세스에서 이어 실행되는 consumer 에
#   누수시키지 않도록 호출 전 umask 로 복구한다.
# - pinned index(write-tree 키 + checkout-index 공통 소스)를 모든 종료 경로에서 정리한다.
staged_snapshot_cache_provide() {
  local _saved_umask _rc
  _saved_umask="$(umask)"
  umask 077
  _ssc_provide_impl "$@"
  _rc=$?
  umask "$_saved_umask"
  if [ -n "${_SSC_PINNED_INDEX:-}" ]; then
    rm -f "$_SSC_PINNED_INDEX" "$_SSC_PINNED_INDEX.lock" 2>/dev/null
    _SSC_PINNED_INDEX=""
  fi
  return "$_rc"
}

# 본체. 성공 시 $STAGED_SNAPSHOT_CACHE_WORKTREE 를 설정한다. umask/pinned 정리는 wrapper 책임.
_ssc_provide_impl() {
  local repo_root="$1"
  [ -n "$repo_root" ] || { _ssc_die "repo_root argument required"; return 1; }

  # 1. 캐시 키 = git write-tree 해시. 같은 pinned index 를 write-tree(키)와 이후 checkout-index
  #    (materialize)에 모두 써서 캐시 키와 worktree 내용이 동일 staged tree 를 가리키게 한다
  #    (index.lock 경쟁/부작용도 격리). 2번째 인자가 있으면 그 index 기준, 없으면 repo 현재 index.
  local src_index tree_hash
  src_index="${2:-}"
  if [ -z "$src_index" ]; then
    src_index="$(git -C "$repo_root" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  fi
  [ -f "$src_index" ] || { _ssc_die "index not found: $src_index"; return 1; }
  _SSC_PINNED_INDEX="$(mktemp "${TMPDIR:-/tmp}/ssc-index.XXXXXX")" || { _ssc_die "mktemp failed"; return 1; }
  cp "$src_index" "$_SSC_PINNED_INDEX" 2>/dev/null || { _ssc_die "index copy failed"; return 1; }
  if ! tree_hash="$(GIT_INDEX_FILE="$_SSC_PINNED_INDEX" git -C "$repo_root" write-tree 2>/dev/null)"; then
    _ssc_die "git write-tree failed — resolve merge conflicts before commit"
    return 1
  fi
  [ -n "$tree_hash" ] || { _ssc_die "empty tree hash"; return 1; }

  # 2. 캐시 base (per-repo_id 격리 + umask 077 + 소유권 검증). 정리는 OS tmp 정책에 위임.
  local base repo_id cache_root trees_dir builds_dir locks_dir
  base="${TMPDIR:-/tmp}"
  base="${base%/}/staged-snapshot-cache"
  repo_id="$(printf '%s' "$repo_root" | _ssc_hash16)"
  cache_root="$base/$repo_id"
  trees_dir="$cache_root/trees"
  builds_dir="$cache_root/builds"
  locks_dir="$cache_root/locks"
  _ssc_safe_mkdir "$base" || return 1
  _ssc_safe_mkdir "$cache_root" || return 1
  _ssc_safe_mkdir "$trees_dir" || return 1
  _ssc_safe_mkdir "$builds_dir" || return 1
  _ssc_safe_mkdir "$locks_dir" || return 1

  # 오래된 캐시 정리 (secret 사본 잔존·디스크 누적 방지). 현재 tree_hash 는 보존한다.
  _ssc_gc "$trees_dir" "$builds_dir" "$tree_hash" || true

  # 3. 획득/빌드
  local nonce
  nonce="$$.$(date +%s).${RANDOM}${RANDOM}"
  _ssc_acquire "$repo_root" "$trees_dir/$tree_hash" "$locks_dir/$tree_hash" \
    "$builds_dir/$tree_hash.$nonce" "$_SSC_PINNED_INDEX" || return 1
  [ -d "$trees_dir/$tree_hash/worktree" ] || { _ssc_die "cache worktree missing"; return 1; }
  # cache hit/build 후 mtime 을 갱신(touch)해, 사용 중인 캐시가 다른 호출의 GC(mtime TTL) 대상이
  # 되지 않게 한다. lease 추적의 경량 대체다(touch~GC 사이의 극단적 동시 race 는 알려진 한계).
  touch "$trees_dir/$tree_hash" 2>/dev/null || true
  # shellcheck disable=SC2034  # source 한 호출자가 읽는 출력 변수
  STAGED_SNAPSHOT_CACHE_WORKTREE="$trees_dir/$tree_hash/worktree"
  return 0
}

# 호출자 trap 에서 호출. 빌드 중이던 lock/build 잔여와 pinned index 를 정리한다.
staged_snapshot_cache_release() {
  if [ -n "${_SSC_BUILD_DIR:-}" ]; then
    _ssc_rm_tree "$_SSC_BUILD_DIR"
    _SSC_BUILD_DIR=""
  fi
  _ssc_unlock
  if [ -n "${_SSC_PINNED_INDEX:-}" ]; then
    rm -f "$_SSC_PINNED_INDEX" "$_SSC_PINNED_INDEX.lock" 2>/dev/null
    _SSC_PINNED_INDEX=""
  fi
}
