#!/usr/bin/env bash
# nixos-rebuild preview script (build only, no switch)
#
# 사용법:
#   nrp.sh           # 미리보기
#   nrp.sh --offline # 오프라인 미리보기 (빠름)

set -euo pipefail

FLAKE_PATH="$HOME/IdeaProjects/nixos-config"
OFFLINE_FLAG=""

if [[ "${1:-}" == "--offline" ]]; then
    OFFLINE_FLAG="--offline"
fi

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

main() {
    cd "$FLAKE_PATH" || exit 1

    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Building (offline, preview only)..."
    else
        log_info "🔨 Building (preview only)..."
    fi

    # shellcheck disable=SC2086
    if ! sudo nixos-rebuild build --flake "$FLAKE_PATH" $OFFLINE_FLAG; then
        log_error "❌ Build failed!"
        exit 1
    fi

    echo ""
    log_info "📋 Changes (preview only, not applied):"
    # nvd diff 출력 안내:
    # - <none> 버전: home-manager 관리 파일(files, hm_*)은 버전 접미사가 없어 정상적으로 <none> 표시
    # - nvd diff는 동일 결과 시 non-zero 반환 가능
    if ! nvd diff /run/current-system ./result; then
        log_warn "⚠️  nvd diff returned non-zero (possibly identical results)"
    fi

    # 정리
    sudo rm -f "$FLAKE_PATH"/result*

    echo ""
    log_info "✅ Preview complete (no changes applied)"
}

main
