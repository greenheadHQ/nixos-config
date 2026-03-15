# shellcheck shell=bash
# rebuild 스크립트 공통 함수 라이브러리 (source 전용, 직접 실행 불가)
# 사용법: REBUILD_CMD="darwin-rebuild" 설정 후 source
#
# 필수 변수:
#   REBUILD_CMD - "darwin-rebuild" 또는 "nixos-rebuild"
#
# 제공 함수:
#   parse_args, log_info, log_warn, log_error,
#   preflight_source_build_check, preflight_cask_conflict_check,
#   worktree_symlink_guard, preview_changes, cleanup_build_artifacts
#
# 출력 변수:
#   NO_CHANGES - preview_changes() 실행 후 true/false (store 경로 비교)
#   MAIN_FLAKE_PATH - detect_worktree 전 경로 보존 (worktree 여부 판별용)
#   FORCE_FLAG - --force 전달 시 true
#   CORES_FLAG - --cores N 전달 시 "--cores N"
#   UNINSTALLED_CASKS - preflight_cask_conflict_check에서 제거한 cask 목록 (복구용)

# fail-fast: REBUILD_CMD 미설정 시 즉시 실패
if [[ -z "${REBUILD_CMD:-}" ]]; then
    echo "ERROR: REBUILD_CMD must be set before sourcing rebuild-common.sh" >&2
    exit 1
fi

FLAKE_PATH="@flakePath@"
MAIN_FLAKE_PATH="$FLAKE_PATH"   # detect_worktree 전 경로 보존 (worktree 여부 판별용)
# shellcheck disable=SC2034  # NO_CHANGES는 source한 nrs.sh에서 사용
NO_CHANGES=false
# shellcheck disable=SC2034  # UNINSTALLED_CASKS는 nrs.sh의 run_darwin_rebuild에서 참조
UNINSTALLED_CASKS=""

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

#───────────────────────────────────────────────────────────────────────────────
# Worktree 감지: 현재 디렉토리가 FLAKE_PATH 저장소의 worktree이면 FLAKE_PATH 전환
# source 시점에 실행 (main()의 cd "$FLAKE_PATH"보다 먼저)
# 심링크 타깃(nixosConfigPath)은 항상 메인 레포 — 여기서는 flake 빌드 경로만 전환
#───────────────────────────────────────────────────────────────────────────────
detect_worktree() {
    local git_toplevel
    git_toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ "$git_toplevel" == "$FLAKE_PATH" ]] && return 0

    # worktree의 git-common-dir이 메인 레포의 .git을 가리키는지 검증
    local git_common_dir
    git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 0
    local abs_common_dir
    abs_common_dir=$(cd "$git_common_dir" 2>/dev/null && pwd) || return 0
    [[ "$abs_common_dir" != "${FLAKE_PATH}/.git" ]] && return 0

    log_warn "⚠️  Worktree detected: $git_toplevel"
    FLAKE_PATH="$git_toplevel"
}

detect_worktree

#───────────────────────────────────────────────────────────────────────────────
# mkOutOfStoreSymlink 엔트리 추출 (awk 단일 파서, 매치 없어도 항상 exit 0)
# 사용: extract_oos_entries "main:path/to.nix"  (git show)
#       extract_oos_entries "/abs/path/to.nix"   (파일시스템)
# DA Fix #1: grep|grep 파이프라인은 매치 없을 때 exit 1 → set -euo pipefail 하에서 nrs abort.
#            awk 단일 파서로 전환하여 항상 exit 0 보장.
# DA Fix R2-2: .mkOutOfStoreSymlink 패턴으로 문자열 리터럴 내 오탐 방지 + trailing comment strip.
#───────────────────────────────────────────────────────────────────────────────
extract_oos_entries() {
    local source="$1"
    local content

    if [[ "$source" == *:* ]]; then
        content=$(git -C "$FLAKE_PATH" show "$source" 2>/dev/null) || return 0
    else
        [[ -f "$source" ]] || return 0
        content=$(cat "$source") || return 0
    fi

    printf '%s\n' "$content" | awk '
        /^[[:space:]]*#/ { next }
        /\.mkOutOfStoreSymlink[[:space:]]/ {
            sub(/;[[:space:]]*#.*$/, "")
            sub(/.*\.mkOutOfStoreSymlink[[:space:]]*/, "")
            sub(/;[[:space:]]*$/, "")
            if ($0 != "") print
        }
    ' | sort -u
}

#───────────────────────────────────────────────────────────────────────────────
# Worktree symlink guard: worktree nrs 실행 시 main과의 mkOutOfStoreSymlink
# 엔트리 불일치를 사전 감지하고 차단
# - main에 추가된 엔트리가 worktree에 없으면 Home Manager가 해당 symlink을 삭제
# - --force로 우회 가능
#───────────────────────────────────────────────────────────────────────────────
worktree_symlink_guard() {
    [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]] && return 0

    log_info "🔍 Checking mkOutOfStoreSymlink consistency with main..."

    local merge_base
    merge_base=$(git -C "$FLAKE_PATH" merge-base HEAD main 2>/dev/null) || {
        log_warn "⚠️  symlink guard: cannot find merge-base with main. Skipping."
        return 0
    }

    local changed_nix_files
    changed_nix_files=$(git -C "$FLAKE_PATH" diff --name-only "$merge_base" main -- '*.nix' 2>/dev/null) || {
        log_warn "⚠️  symlink guard: git diff failed. Skipping."
        return 0
    }
    [[ -z "$changed_nix_files" ]] && { log_info "  ✓ No mkOutOfStoreSymlink drift."; return 0; }

    # DA R1 Fix: 플랫폼별 경로 필터 — darwin nrs가 nixos-only 파일에 차단되지 않도록
    local platform_filter
    case "$REBUILD_CMD" in
        darwin-rebuild)  platform_filter='^(modules/darwin/|modules/shared/|libraries/)' ;;
        nixos-rebuild)   platform_filter='^(modules/nixos/|modules/shared/|libraries/)' ;;
        *)               platform_filter='.' ;;
    esac
    changed_nix_files=$(printf '%s\n' "$changed_nix_files" | grep -E "$platform_filter" || true)
    [[ -z "$changed_nix_files" ]] && { log_info "  ✓ No mkOutOfStoreSymlink drift."; return 0; }

    local all_missing="" missing_count=0

    while IFS= read -r nix_file; do
        [[ -z "$nix_file" ]] && continue
        local main_entries base_entries
        main_entries=$(extract_oos_entries "main:$nix_file")
        [[ -z "$main_entries" ]] && continue

        # 3-way 비교: merge-base 대비 main에서 진짜 새로 추가된 엔트리만 플래그
        # (DA R4 Fix: worktree가 의도적으로 제거한 엔트리를 오탐하지 않도록)
        base_entries=$(extract_oos_entries "$merge_base:$nix_file")
        local new_on_main
        if [[ -z "$base_entries" ]]; then
            new_on_main="$main_entries"
        elif ! new_on_main=$(comm -23 <(printf '%s\n' "$main_entries") <(printf '%s\n' "$base_entries")); then
            new_on_main="$main_entries"
        fi
        [[ -z "$new_on_main" ]] && continue

        # Known limitation: main에서 .nix 파일이 rename된 경우, 새 경로가 worktree에
        # 없어 false positive 발생 가능. .nix 모듈 rename은 극히 드물고 --force로 우회 가능.
        local wt_entries
        if [[ ! -f "$FLAKE_PATH/$nix_file" ]]; then
            wt_entries=""
        else
            wt_entries=$(extract_oos_entries "$FLAKE_PATH/$nix_file")
        fi

        # 빈 wt_entries 특수 처리: printf '%s\n' ""는 빈 줄 1개를 comm에 전달하여
        # 실제 엔트리와 빈 문자열 간 오비교 발생. comm 실패 시 fail-closed (안전 우선).
        local only_in_main
        if [[ -z "$wt_entries" ]]; then
            only_in_main="$new_on_main"
        elif ! only_in_main=$(comm -23 <(printf '%s\n' "$new_on_main") <(printf '%s\n' "$wt_entries")); then
            only_in_main="$new_on_main"
        fi

        if [[ -n "$only_in_main" ]]; then
            while IFS= read -r entry; do
                [[ -z "$entry" ]] && continue
                all_missing+="    $nix_file → $entry"$'\n'
                ((++missing_count))
            done <<< "$only_in_main"
        fi
    done <<< "$changed_nix_files"

    if [[ $missing_count -eq 0 ]]; then
        log_info "  ✓ No mkOutOfStoreSymlink drift."
        return 0
    fi

    if [[ "$FORCE_FLAG" == true ]]; then
        log_warn "⚠️  $missing_count mkOutOfStoreSymlink entry(s) missing vs main (--force, proceeding):"
        echo -n "$all_missing"
        echo ""
        return 0
    fi

    log_error "❌ Worktree would remove $missing_count mkOutOfStoreSymlink entry(s) from main:"
    echo -n "$all_missing"
    echo ""
    echo "  These entries were added to main after this worktree branched."
    echo "  Home Manager will silently remove these symlinks during switch."
    echo ""
    echo "  Fix:  git merge main    # incorporate main's changes"
    echo "        git rebase main   # or rebase onto main"
    echo "  Skip: nrs --force       # override (symlinks WILL be removed)"
    exit 1
}

#───────────────────────────────────────────────────────────────────────────────
# NRS Lock: worktree 간 동시 rebuild 방지를 위한 협조적 잠금
# Lock 파일: /tmp/nrs-state (JSON: worktree, branch, timestamp, pid)
# 타임아웃: 30분 자동 만료
#───────────────────────────────────────────────────────────────────────────────
NRS_LOCK_FILE="/tmp/nrs-state"
# 주의: 이 값은 rebuild-common.sh, nrs-lock.sh, nrs-lock-guard.sh 3곳에서 동일하게 유지해야 함
NRS_LOCK_TIMEOUT_MINUTES=30
NRS_LOCK_ACQUIRED=false    # 이 프로세스가 lock을 획득했는가? (EXIT trap 보호용)
NRS_LOCK_REENTRY=false     # 기존 lock에 대한 재진입인가?

is_stale_lock() {
    # Returns 0 (true) if stale, 1 (false) if active
    # Stale 조건 (OR): worktree 경로 미존재 OR (타임아웃 초과 AND PID 미생존)
    # DA Fix: PID가 살아있으면 타임아웃 초과해도 stale 아님 (장시간 빌드 보호)
    local lock_worktree lock_ts lock_pid now
    lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
    lock_ts=$(jq -r '.timestamp' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
    now=$(date +%s)

    if [[ -n "$lock_worktree" && ! -d "$lock_worktree" ]]; then
        return 0
    fi

    local expiry=$(( lock_ts + NRS_LOCK_TIMEOUT_MINUTES * 60 ))
    if (( now > expiry )); then
        # PID가 살아있으면 stale 아님 (장시간 빌드 보호)
        if [[ "$lock_pid" != "0" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            return 1
        fi
        return 0
    fi

    return 1
}

acquire_nrs_lock() {
    local now
    now=$(date +%s)

    # Main worktree: lock 취득하지 않음, 기존 lock 존재 시 경고만 표시
    if [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]]; then
        if [[ -f "$NRS_LOCK_FILE" ]]; then
            local lock_worktree lock_branch
            lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
            lock_branch=$(jq -r '.branch' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
            if is_stale_lock; then
                log_warn "⚠️  Stale lock detected. Removing."
                log_warn "    Branch: $lock_branch, Worktree: $lock_worktree"
                rm -f "$NRS_LOCK_FILE"
            else
                log_warn "⚠️  Worktree lock active (branch: $lock_branch). Proceeding from main."
            fi
        fi
        return 0
    fi

    if [[ -f "$NRS_LOCK_FILE" ]]; then
        local lock_ts lock_worktree lock_branch
        lock_ts=$(jq -r '.timestamp' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
        lock_worktree=$(jq -r '.worktree' "$NRS_LOCK_FILE" 2>/dev/null || echo "")
        lock_branch=$(jq -r '.branch' "$NRS_LOCK_FILE" 2>/dev/null || echo "")

        if is_stale_lock; then
            local stale_reason=""
            if [[ -n "$lock_worktree" && ! -d "$lock_worktree" ]]; then
                stale_reason="worktree deleted"
            else
                stale_reason="timeout ($(( (now - lock_ts) / 60 ))m, limit: ${NRS_LOCK_TIMEOUT_MINUTES}m)"
            fi
            log_warn "⚠️  Stale lock detected ($stale_reason). Removing."
            log_warn "    Branch: $lock_branch, Worktree: $lock_worktree"
            rm -f "$NRS_LOCK_FILE"
        elif [[ "$lock_worktree" == "$FLAKE_PATH" ]]; then
            # 같은 worktree — re-entry
            # 기존 lock의 PID가 아직 살아있으면 동시 실행 → 차단
            local lock_pid
            lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
            if [[ "$lock_pid" != "0" ]] && kill -0 "$lock_pid" 2>/dev/null; then
                if [[ "$lock_pid" != "$$" ]]; then
                    log_error "❌ Another nrs process (PID $lock_pid) is running in this worktree."
                    echo "  Wait for it to finish or run 'nrs-unlock' to force release."
                    exit 1
                fi
            fi
            NRS_LOCK_REENTRY=true
            NRS_LOCK_ACQUIRED=true
            local branch
            branch=$(git -C "$FLAKE_PATH" branch --show-current 2>/dev/null || echo "unknown")
            local json
            json=$(jq -n \
                --arg w "$FLAKE_PATH" \
                --arg b "$branch" \
                --argjson t "$now" \
                --argjson p "$$" \
                '{worktree: $w, branch: $b, timestamp: $t, pid: $p}')
            # tmpfile + mv로 원자적 교체 (truncate 중 partial read 방지)
            local tmpfile
            tmpfile=$(mktemp "${NRS_LOCK_FILE}.XXXXXX")
            echo "$json" > "$tmpfile"
            mv -f "$tmpfile" "$NRS_LOCK_FILE"
            log_info "🔒 Lock re-entry: $branch ($FLAKE_PATH)"
            return 0
        else
            # 다른 worktree — 충돌
            local elapsed=$(( (now - lock_ts) / 60 ))
            log_error "❌ Another worktree holds the nrs lock:"
            echo "  Branch:   $lock_branch"
            echo "  Worktree: $lock_worktree"
            echo "  Locked:   ${elapsed}m ago"
            echo ""
            echo "  Run 'nrs-unlock' to release the lock."
            exit 1
        fi
    fi

    # Lock 생성: tmpfile에 쓰고 ln으로 원자적 생성 (partial-read 방지)
    # ln은 대상이 이미 존재하면 실패 → noclobber와 동일한 경쟁 방지
    local branch
    branch=$(git -C "$FLAKE_PATH" branch --show-current 2>/dev/null || echo "unknown")
    local json
    json=$(jq -n \
        --arg w "$FLAKE_PATH" \
        --arg b "$branch" \
        --argjson t "$now" \
        --argjson p "$$" \
        '{worktree: $w, branch: $b, timestamp: $t, pid: $p}')

    local tmpfile
    tmpfile=$(mktemp "${NRS_LOCK_FILE}.XXXXXX")
    echo "$json" > "$tmpfile"
    if ! ln "$tmpfile" "$NRS_LOCK_FILE" 2>/dev/null; then
        rm -f "$tmpfile"
        log_error "❌ Race condition: another process acquired the lock."
        exit 1
    fi
    rm -f "$tmpfile"

    NRS_LOCK_ACQUIRED=true
    log_info "🔒 Lock acquired: $branch ($FLAKE_PATH)"
}

release_nrs_lock() {
    rm -f "$NRS_LOCK_FILE"
    NRS_LOCK_ACQUIRED=false
    log_info "🔓 Lock released"
}

release_nrs_lock_on_failure() {
    # 4가지 조건 모두 충족 시에만 lock 삭제:
    #   1. 이 프로세스가 lock을 획득한 경우
    #   2. switch가 성공하지 않은 경우
    #   3. re-entry가 아닌 경우 (기존 lock 보호)
    #   4. 현재 lock 파일의 PID가 자기 것인 경우 (owner-blind rm 방지)
    if [[ "$NRS_LOCK_ACQUIRED" == true && "${NRS_LOCK_SWITCH_SUCCESS:-}" != true && "$NRS_LOCK_REENTRY" != true ]]; then
        local lock_pid
        lock_pid=$(jq -r '.pid' "$NRS_LOCK_FILE" 2>/dev/null || echo "0")
        if [[ "$lock_pid" == "$$" ]]; then
            rm -f "$NRS_LOCK_FILE"
            log_warn "🔓 Lock released (build failed)"
        fi
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 인수 파싱 (OFFLINE_FLAG, FORCE_FLAG, CORES_FLAG 설정)
#───────────────────────────────────────────────────────────────────────────────
parse_args() {
    OFFLINE_FLAG=""
    FORCE_FLAG=false
    CORES_FLAG=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) OFFLINE_FLAG="--offline" ;;
            --force)   FORCE_FLAG=true ;;
            --cores)
                [[ -z "${2:-}" || "$2" =~ ^-- ]] && { log_error "--cores requires a number"; exit 1; }
                [[ ! "$2" =~ ^[0-9]+$ ]] && { log_error "--cores: positive integer required"; exit 1; }
                (( 10#$2 < 1 )) && { log_error "--cores: positive integer required"; exit 1; }
                CORES_FLAG="--cores $2"; shift ;;
            *) log_error "Unknown argument: $1"; exit 1 ;;
        esac
        shift
    done
}

#───────────────────────────────────────────────────────────────────────────────
# Pre-flight 소스 빌드 체크 (NixOS 전용, nrs.sh/nrp.sh에서 호출)
# nix build --dry-run으로 소스 빌드 대상을 사전 감지하고,
# non-trivial 패키지가 있으면 --force 없이는 abort
# 인수: --warn-only → abort 대신 경고만 출력 (nrp에서 사용)
#───────────────────────────────────────────────────────────────────────────────
preflight_source_build_check() {
    local warn_only=false
    [[ "${1:-}" == "--warn-only" ]] && warn_only=true

    # offline 모드에서는 dry-run 결과가 부정확하므로 스킵
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔍 Pre-flight skipped (offline mode)."
        return 0
    fi

    log_info "🔍 Checking for source builds..."

    local dry_run_output
    if ! dry_run_output=$(nix build \
        "${FLAKE_PATH}#nixosConfigurations.$(hostname).config.system.build.toplevel" \
        --dry-run 2>&1); then
        log_warn "⚠️  Pre-flight dry-run failed. Proceeding with build."
        return 0  # fallthrough — pre-flight 실패가 빌드를 차단하면 안 됨
    fi

    # .drv 라인 추출 — dry-run 출력에서 .drv로 끝나는 경로는
    # "will be built" 섹션에만 존재 (fetched 경로는 빌드 출력이므로 .drv 아님)
    # 참고: nix CLI 출력 형식은 unstable이나, .drv 확장자는 Nix 설계상 불변
    local build_drvs
    build_drvs=$(echo "$dry_run_output" | grep '\.drv$' || true)
    [[ -z "$build_drvs" ]] && { log_info "  ✓ All packages cached."; return 0; }

    # known-heavy: 소스 빌드 시 장시간 소요되는 패키지 (Rust 컴파일 등)
    # 각 항목은 패키지명 접두사. 매칭: ^<name>-[0-9]+\.[0-9]+ (semver 시작 필수)
    # 예: "anki" → anki-25.09.2, anki-25.09.2-vendor 매칭 (anki-addon-* 등은 제외)
    # 추가 방법: 배열에 패키지명만 추가 (예: "firefox")
    #
    # === Change Intent Record ===
    # v1 (b9cd235): known-heavy blocklist 구상 → 관리 부담 우려로 known-trivial allowlist 채택
    # v2 (f09a575): activation-script 등 false positive 발생, trivial 패턴 추가로 대응
    # v3 (이번 변경): allowlist 방식이 두더지 잡기(끝없는 패턴 추가)임을 확인,
    #    원래 구상대로 known-heavy blocklist로 회귀. 미등록 패키지는 무시(수동 관리).
    #    trade-off: 새 무거운 패키지 추가 시 수동 등록 필요하나,
    #              false positive를 크게 줄여 사용자 경험이 압도적으로 나음.
    local heavy_packages=(
        mise    # Rust 패키지 → flake update 후 캐시 미스 시 장시간 빌드
    )

    # 빈 배열 guard — heavy_packages가 비면 체크 자체를 비활성화
    if ((${#heavy_packages[@]} == 0)); then
        log_warn "⚠️  heavy_packages is empty; preflight detection disabled."
        return 0
    fi

    # 패키지명 추출 (해시 제거, .drv 제거)
    local pkg_names
    pkg_names=$(printf '%s\n' "$build_drvs" | sed 's|.*/[a-z0-9]\{32\}-||; s|\.drv$||' | sort -u)

    # heavy_packages 매칭 regex 생성: ^anki-[0-9]+\.[0-9]+|^mise-[0-9]+\.[0-9]+
    # semver 시작(X.Y)을 요구하여 anki-addon-*, mise-plugin-* 등 비패키지 제외
    local heavy_regex
    heavy_regex=$(printf '|^%s-[0-9]+\\.[0-9]+' "${heavy_packages[@]}")
    heavy_regex="${heavy_regex:1}"

    local matched_heavy=""
    local grep_rc=0
    matched_heavy=$(printf '%s\n' "$pkg_names" | grep -E -- "$heavy_regex") || grep_rc=$?
    case $grep_rc in
        0) ;;  # matches found
        1) ;;  # no matches (정상)
        *) log_error "  ✗ Invalid heavy regex: $heavy_regex"; return 1 ;;
    esac

    [[ -z "$matched_heavy" ]] && { log_info "  ✓ No known-heavy source builds."; return 0; }

    # 보고할 패키지명은 매칭된 heavy 패키지만
    pkg_names="$matched_heavy"

    # --force 또는 warn-only: 경고만 출력하고 진행
    if [[ "$FORCE_FLAG" == true || "$warn_only" == true ]]; then
        local reason=""
        [[ "$FORCE_FLAG" == true ]] && reason=" (--force로 진행)"
        log_warn "⚠️  소스 빌드 감지${reason}:"
        while IFS= read -r pkg; do echo "  - $pkg"; done <<< "$pkg_names"
        echo ""
        return 0
    fi

    # abort — 호출 스크립트명을 $0에서 추출
    local cmd_name
    cmd_name=$(basename "$0" .sh)

    log_warn "⚠️  다음 패키지가 소스에서 빌드됩니다 (Nix 캐시 없음):"
    while IFS= read -r pkg; do echo "  - $pkg"; done <<< "$pkg_names"
    echo ""
    echo "MiniPC에서 소스 빌드는 과열 및 장시간 소요될 수 있습니다."
    echo "  ${cmd_name} --force            # 경고 무시하고 진행"
    echo "  ${cmd_name} --force --cores 2  # 코어 제한으로 진행 (과열 방지)"
    echo ""
    echo "또는 Hydra 캐시가 준비될 때까지 대기하세요."
    exit 1
}

#───────────────────────────────────────────────────────────────────────────────
# Homebrew cask 충돌 사전 감지 (darwin 전용, nrs.sh에서 호출)
# preview_changes 이후 호출 — ./result/activate에서 새 Brewfile을 파싱하여
# 선언된 cask과 설치된 cask 간 conflicts_with 충돌을 감지.
# 충돌 발견 시 사용자 확인 후 이전 cask 제거, --force 시 프롬프트 없이 자동 해소.
# 감지/파싱 실패 시 fallthrough (빌드를 차단하지 않음)
#───────────────────────────────────────────────────────────────────────────────
preflight_cask_conflict_check() {
    command -v brew &>/dev/null || return 0
    command -v jq &>/dev/null || return 0

    # ./result/activate에서 Brewfile 경로 추출
    [[ -f ./result/activate ]] || return 0
    local brewfile_path
    brewfile_path=$(sed -n "s/.*brew bundle --file='\([^']*\)'.*/\1/p" ./result/activate) || return 0
    if [[ -z "$brewfile_path" || ! -f "$brewfile_path" ]]; then
        log_warn "⚠️  Cask conflict check: Brewfile path extraction failed. Skipping."
        return 0
    fi

    # Brewfile에서 선언된 cask 목록 파싱
    local declared_casks
    declared_casks=$(sed -n 's/^cask "\([^"]*\)".*/\1/p' "$brewfile_path") || return 0
    [[ -n "$declared_casks" ]] || return 0

    # 설치된 cask 목록 조회
    local installed_casks
    installed_casks=$(brew list --cask 2>/dev/null) || {
        log_warn "⚠️  Cask conflict check: brew list failed. Skipping."
        return 0
    }

    # 새로 설치할 cask 식별 (선언됨 - 설치됨)
    local new_casks=()
    while IFS= read -r cask; do
        [[ -z "$cask" ]] && continue
        if ! echo "$installed_casks" | grep -qx "$cask"; then
            new_casks+=("$cask")
        fi
    done <<< "$declared_casks"
    [[ ${#new_casks[@]} -gt 0 ]] || return 0

    # 각 새 cask의 conflicts_with 메타데이터 개별 조회
    # 배치 호출(brew info --cask A B)은 미지 cask 포함 시 전체 실패하므로 개별 호출
    log_info "🔍 Checking cask conflicts (${#new_casks[@]} new cask(s))..."
    local conflicts=()
    for new_cask in "${new_casks[@]}"; do
        local cask_json
        cask_json=$(brew info --json=v2 --cask "$new_cask" 2>/dev/null) || continue
        local conflict_casks
        conflict_casks=$(echo "$cask_json" | \
            jq -r '.casks[0].conflicts_with.cask // empty | .[]' \
            2>/dev/null) || continue
        while IFS= read -r conflict_cask; do
            [[ -z "$conflict_cask" ]] && continue
            if echo "$installed_casks" | grep -qx "$conflict_cask"; then
                conflicts+=("${conflict_cask}:${new_cask}")
            fi
        done <<< "$conflict_casks"
    done
    [[ ${#conflicts[@]} -gt 0 ]] || return 0

    # 충돌 발견 — 사용자에게 안내
    log_warn "🍺 Homebrew cask conflict detected:"
    for conflict in "${conflicts[@]}"; do
        local old_cask="${conflict%%:*}"
        local new_cask="${conflict##*:}"
        echo "  $old_cask (installed) conflicts with $new_cask (declared)"
    done
    echo ""

    # 동일 old_cask이 여러 new_cask과 충돌할 수 있으므로 중복 제거
    local uniq_old_casks=()
    local seen_casks=""
    for conflict in "${conflicts[@]}"; do
        local c="${conflict%%:*}"
        if ! echo "$seen_casks" | grep -qx "$c"; then
            uniq_old_casks+=("$c")
            seen_casks+="$c"$'\n'
        fi
    done

    # 충돌 해소 — uninstall
    local do_uninstall=false
    if [[ "$FORCE_FLAG" == true ]]; then
        do_uninstall=true
    else
        read -p "  Uninstall conflicting cask(s) to resolve? [y/N]: " -r
        [[ $REPLY =~ ^[Yy]$ ]] && do_uninstall=true
    fi

    if [[ "$do_uninstall" == true ]]; then
        for old_cask in "${uniq_old_casks[@]}"; do
            log_info "  Uninstalling $old_cask..."
            if ! brew uninstall --cask "$old_cask"; then
                log_error "❌ Failed to uninstall $old_cask"
                echo "  Resolve manually: brew uninstall --cask $old_cask"
                return 1
            fi
            log_info "  ✓ Uninstalled $old_cask"
            UNINSTALLED_CASKS+="$old_cask "
        done
        echo ""
    else
        log_error "❌ Cask conflict not resolved. Aborting."
        echo "  Resolve manually:"
        for old_cask in "${uniq_old_casks[@]}"; do
            echo "    brew uninstall --cask $old_cask"
        done
        exit 1
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 및 변경사항 미리보기
# 인수: $1 = 빌드 라벨 ("preview" 또는 "preview only"), $2 = diff 헤더 메시지
# 부수효과: NO_CHANGES를 true/false로 설정 (store 경로 비교)
# offline 접두사는 OFFLINE_FLAG에 따라 자동 추가
#───────────────────────────────────────────────────────────────────────────────
preview_changes() {
    local label="${1:-preview}"
    local diff_msg="${2:-Changes:}"

    local offline_tag=""
    [[ -n "$OFFLINE_FLAG" ]] && offline_tag="offline, "

    log_info "🔨 Building (${offline_tag}${label})..."

    # shellcheck disable=SC2086
    if ! "$REBUILD_CMD" build --flake "$FLAKE_PATH" $OFFLINE_FLAG $CORES_FLAG; then
        log_error "❌ Build failed!"
        exit 1
    fi

    echo ""
    log_info "📋 $diff_msg"
    # nvd diff 출력 안내:
    # - <none> 버전: home-manager 관리 파일(files, hm_*)은 버전 접미사가 없어 정상적으로 <none> 표시
    # - nvd diff는 동일 결과 시 non-zero 반환 가능
    if ! nvd diff /run/current-system ./result; then
        log_warn "⚠️  nvd diff returned non-zero (possibly identical results)"
    fi

    if [[ -L ./result ]] && [[ "$(readlink ./result)" == "$(readlink /run/current-system)" ]]; then
        # shellcheck disable=SC2034  # NO_CHANGES는 source한 nrs.sh에서 사용
        NO_CHANGES=true
    fi
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 아티팩트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_build_artifacts() {
    local links
    links=$(find "$FLAKE_PATH" -maxdepth 1 -name 'result*' -type l 2>/dev/null)
    local count
    count=$(echo "$links" | grep -c . 2>/dev/null || true)

    if [[ "$count" -gt 0 ]]; then
        log_info "🧹 Cleaning up build artifacts..."
        # result는 일반 사용자 build로 생성되어 사용자 소유
        echo "$links" | xargs rm -f
        log_info "  ✓ Removed $count result symlink(s)"
    fi
}
