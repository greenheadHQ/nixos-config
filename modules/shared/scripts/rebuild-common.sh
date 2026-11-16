# shellcheck shell=bash
# rebuild 스크립트 공통 함수 라이브러리 (source 전용, 직접 실행 불가)
# 사용법: REBUILD_CMD="darwin-rebuild" 설정 후 source
# caller-facing contract의 authoritative source:
#   modules/shared/scripts/README.md
#
# 필수 변수:
#   REBUILD_CMD - "darwin-rebuild" 또는 "nixos-rebuild"
# 선택 변수:
#   REBUILD_MODE - "switch"(기본) 또는 "preview" — usage 표기와 --force 노출 결정.
#                  환경 상속 오염 방지를 위해 모든 진입점이 명시 선언한다.
#
# caller-facing 제공 함수:
#   parse_args, log_info, log_warn, log_error,
#   worktree_symlink_guard, acquire_nrs_lock, release_nrs_lock,
#   release_nrs_lock_after_no_changes, release_nrs_lock_on_failure,
#   mark_nrs_lock_switch_success, acquire_rebuild_lock, release_rebuild_lock,
#   release_rebuild_lock_on_failure, preflight_source_build_check,
#   preflight_cask_conflict_check, rebuild_is_main_flake,
#   prepare_worktree_symlinks_for_rebuild, maybe_relink_or_restore,
#   preview_changes, cleanup_build_artifacts,
#   codex_managed_artifacts_missing, codex_log_managed_artifacts_missing,
#   repair_codex_config_drift_no_changes
#
# caller-facing 출력 변수:
#   FLAKE_PATH - detect_worktree 후 실제 build/switch 대상 flake 경로
#   OFFLINE_FLAG - --offline 전달 시 "--offline"
#   NO_CHANGES - preview_changes() 실행 후 true/false (store 경로 비교)
#   FORCE_FLAG - --force 전달 시 true
#   CORES_FLAG - --cores N 전달 시 "--cores N"
#   UNINSTALLED_CASKS - preflight_cask_conflict_check에서 제거한 cask 목록 (복구용)
#
# internal helper state:
#   MAIN_FLAKE_PATH, NRS_LOCK_ACQUIRED, NRS_LOCK_REENTRY, NRS_LOCK_SWITCH_SUCCESS,
#   CODEX_MANAGED_HOOK_ARTIFACTS, CODEX_MANAGED_LIB_ARTIFACTS,
#   CODEX_MISSING_MANAGED_ARTIFACTS

# fail-fast: REBUILD_CMD 미설정 시 즉시 실패
if [[ -z "${REBUILD_CMD:-}" ]]; then
    echo "ERROR: REBUILD_CMD must be set before sourcing rebuild-common.sh" >&2
    exit 1
fi

FLAKE_PATH="@flakePath@"
# shellcheck disable=SC2034  # Internal helper modules consume this global.
MAIN_FLAKE_PATH="$FLAKE_PATH"   # detect_worktree 전 경로 보존 (worktree 여부 판별용)
# shellcheck disable=SC2034  # NO_CHANGES는 source한 nrs.sh에서 사용
NO_CHANGES=false
# shellcheck disable=SC2034  # UNINSTALLED_CASKS는 nrs.sh의 run_darwin_rebuild에서 참조
UNINSTALLED_CASKS=""

# 색상 정의
# shellcheck disable=SC2034  # Helper modules consume these globals.
GREEN='\033[0;32m'
# shellcheck disable=SC2034  # Helper modules consume these globals.
YELLOW='\033[0;33m'
# shellcheck disable=SC2034  # Helper modules consume these globals.
RED='\033[0;31m'
# shellcheck disable=SC2034  # Helper modules consume these globals.
NC='\033[0m' # No Color

REBUILD_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REBUILD_COMMON_LIB_DIR=""
REBUILD_DEPLOYED_LIB_DIR="$REBUILD_COMMON_DIR/rebuild"
REBUILD_REPO_LIB_DIR=""
REBUILD_HELPERS=(
    common
    worktree
    locks
    preflight
    relink
    preview
    codex
)

case "$REBUILD_COMMON_DIR" in
    */modules/shared/scripts) REBUILD_REPO_LIB_DIR="$REBUILD_COMMON_DIR/lib/rebuild" ;;
esac

_rebuild_has_helper_set() {
    local dir="$1"
    local helper
    for helper in "${REBUILD_HELPERS[@]}"; do
        [[ -f "$dir/$helper.sh" ]] || return 1
    done
    return 0
}

if _rebuild_has_helper_set "$REBUILD_DEPLOYED_LIB_DIR"; then
    REBUILD_COMMON_LIB_DIR="$REBUILD_DEPLOYED_LIB_DIR"
elif [[ -n "$REBUILD_REPO_LIB_DIR" ]] && _rebuild_has_helper_set "$REBUILD_REPO_LIB_DIR"; then
    REBUILD_COMMON_LIB_DIR="$REBUILD_REPO_LIB_DIR"
fi

[[ -n "$REBUILD_COMMON_LIB_DIR" ]] || {
    echo "ERROR: rebuild helper directory not found" >&2
    echo "  expected location: $REBUILD_DEPLOYED_LIB_DIR" >&2
    [[ -n "$REBUILD_REPO_LIB_DIR" ]] && echo "  also tried (repo): $REBUILD_REPO_LIB_DIR" >&2
    echo "  required helpers (manifest): ${REBUILD_HELPERS[*]}" >&2
    # 이 실패는 진입점의 parse_args보다 먼저 발생하므로 --force로 우회할 수 없다.
    # repo fallback은 이 loader 자체를 repo layout에서 source할 때만 적용된다.
    # repo-local nrs.sh도 먼저 배포된 loader를 source하므로 그것만 실행해선 복구되지 않는다.
    echo "  nrs cannot parse --force until the required helpers are available." >&2
    echo "  Inspect the missing deployment entries and restore them from a matching Home Manager generation." >&2
    echo "  Verify the complete helper set before rerunning nrs; see modules/shared/scripts/README.md." >&2
    exit 1
}

# Load order is intentional and driven by the ordered helper manifest above.
for helper in "${REBUILD_HELPERS[@]}"; do
    # shellcheck source=/dev/null
    source "$REBUILD_COMMON_LIB_DIR/$helper.sh"
done

detect_worktree
