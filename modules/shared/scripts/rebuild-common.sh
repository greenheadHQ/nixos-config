# shellcheck shell=bash
# rebuild 스크립트 공통 함수 라이브러리 (source 전용, 직접 실행 불가)
# 사용법: REBUILD_CMD="darwin-rebuild" 설정 후 source
#
# 필수 변수:
#   REBUILD_CMD - "darwin-rebuild" 또는 "nixos-rebuild"
#
# 제공 함수:
#   parse_args, log_info, log_warn, log_error,
#   preview_changes, cleanup_build_artifacts

# fail-fast: REBUILD_CMD 미설정 시 즉시 실패
if [[ -z "${REBUILD_CMD:-}" ]]; then
    echo "ERROR: REBUILD_CMD must be set before sourcing rebuild-common.sh" >&2
    exit 1
fi

FLAKE_PATH="@flakePath@"

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

#───────────────────────────────────────────────────────────────────────────────
# 인수 파싱 (OFFLINE_FLAG 설정)
#───────────────────────────────────────────────────────────────────────────────
parse_args() {
    OFFLINE_FLAG=""
    for arg in "$@"; do
        case "$arg" in
            --offline)
                OFFLINE_FLAG="--offline"
                ;;
            *)
                log_error "Unknown argument: $arg"
                exit 1
                ;;
        esac
    done
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 및 변경사항 미리보기
# 인수: $1 = 빌드 라벨 ("preview" 또는 "preview only"), $2 = diff 헤더 메시지
# offline 접두사는 OFFLINE_FLAG에 따라 자동 추가
#───────────────────────────────────────────────────────────────────────────────
preview_changes() {
    local label="${1:-preview}"
    local diff_msg="${2:-Changes:}"

    local offline_tag=""
    [[ -n "$OFFLINE_FLAG" ]] && offline_tag="offline, "

    log_info "🔨 Building (${offline_tag}${label})..."

    # shellcheck disable=SC2086
    if ! sudo "$REBUILD_CMD" build --flake "$FLAKE_PATH" $OFFLINE_FLAG; then
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
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 아티팩트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_build_artifacts() {
    log_info "🧹 Cleaning up build artifacts..."

    local links
    links=$(find "$FLAKE_PATH" -maxdepth 1 -name 'result*' -type l 2>/dev/null)
    local count
    count=$(echo "$links" | grep -c . 2>/dev/null || echo 0)

    if [[ "$count" -gt 0 ]]; then
        # result는 sudo rebuild로 생성되어 root 소유. 삭제할 때도 root 권한 필요
        echo "$links" | xargs sudo rm -f
        log_info "  ✓ Removed $count result symlink(s)"
    fi
}
