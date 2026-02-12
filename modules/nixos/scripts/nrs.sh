#!/usr/bin/env bash
# nixos-rebuild wrapper script
#
# 사용법:
#   nrs.sh           # 일반 rebuild
#   nrs.sh --offline # 오프라인 rebuild (빠름)

set -euo pipefail

FLAKE_PATH="$HOME/IdeaProjects/nixos-config"
OFFLINE_FLAG=""

# 인수 파싱
for arg in "$@"; do
    case "$arg" in
        --offline)
            OFFLINE_FLAG="--offline"
            ;;
    esac
done

# 색상 정의
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

#───────────────────────────────────────────────────────────────────────────────
# SSH 키 로드 확인
# NOTE: 현재 main()에서 호출하지 않지만 git 작업 시 수동 호출용으로 유지
#───────────────────────────────────────────────────────────────────────────────
ensure_ssh_key_loaded() {
    if ! ssh-add -l 2>/dev/null | grep -q "id_ed25519"; then
        log_info "🔑 Loading SSH key..."
        ssh-add ~/.ssh/id_ed25519
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 및 미리보기
#───────────────────────────────────────────────────────────────────────────────
preview_changes() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Building (offline, preview)..."
    else
        log_info "🔨 Building (preview)..."
    fi

    # shellcheck disable=SC2086
    if ! sudo nixos-rebuild build --flake "$FLAKE_PATH" $OFFLINE_FLAG; then
        log_error "❌ Build failed!"
        exit 1
    fi

    echo ""
    log_info "📋 Changes to be applied:"
    # nvd diff 출력 안내:
    # - <none> 버전: home-manager 관리 파일(files, hm_*)은 버전 접미사가 없어 정상적으로 <none> 표시
    # - nvd diff는 동일 결과 시 non-zero 반환 가능
    if ! nvd diff /run/current-system ./result; then
        log_warn "⚠️  nvd diff returned non-zero (possibly identical results)"
    fi
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# nixos-rebuild switch 실행
#───────────────────────────────────────────────────────────────────────────────
run_nixos_rebuild() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Applying changes (offline)..."
    else
        log_info "🔨 Applying changes..."
    fi

    local rc=0
    # shellcheck disable=SC2086
    sudo nixos-rebuild switch --flake "$FLAKE_PATH" $OFFLINE_FLAG || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        return 0
    elif [[ "$rc" -eq 4 ]]; then
        log_warn "⚠️  switch-to-configuration exited with status 4 (transient unit failures, e.g. health check start period)"
        log_warn "   Services are likely healthy. Verify: sudo podman ps"
    else
        log_error "❌ nixos-rebuild switch failed (exit code: $rc)"
        exit "$rc"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 아티팩트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_build_artifacts() {
    log_info "🧹 Cleaning up build artifacts..."

    local count
    count=$(find "$FLAKE_PATH" -maxdepth 1 -name 'result*' -type l 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count" -gt 0 ]]; then
        sudo rm -f "$FLAKE_PATH"/result*
        log_info "  ✓ Removed $count result symlink(s)"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    cd "$FLAKE_PATH" || exit 1

    echo ""

    # 빌드 및 적용
    preview_changes
    run_nixos_rebuild
    cleanup_build_artifacts

    echo ""
    log_info "✅ Done!"
}

main
