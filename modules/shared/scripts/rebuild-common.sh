# shellcheck shell=bash
# rebuild 스크립트 공통 함수 라이브러리 (source 전용, 직접 실행 불가)
# 사용법: REBUILD_CMD="darwin-rebuild" 설정 후 source
#
# 필수 변수:
#   REBUILD_CMD - "darwin-rebuild" 또는 "nixos-rebuild"
#
# 제공 함수:
#   parse_args, log_info, log_warn, log_error,
#   preflight_source_build_check, preview_changes, cleanup_build_artifacts
#
# 출력 변수:
#   NO_CHANGES - preview_changes() 실행 후 true/false (store 경로 비교)
#   FORCE_FLAG - --force 전달 시 true
#   CORES_FLAG - --cores N 전달 시 "--cores N"

# fail-fast: REBUILD_CMD 미설정 시 즉시 실패
if [[ -z "${REBUILD_CMD:-}" ]]; then
    echo "ERROR: REBUILD_CMD must be set before sourcing rebuild-common.sh" >&2
    exit 1
fi

FLAKE_PATH="@flakePath@"
# shellcheck disable=SC2034  # NO_CHANGES는 source한 nrs.sh에서 사용
NO_CHANGES=false

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
