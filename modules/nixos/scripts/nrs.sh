#!/usr/bin/env bash
# nixos-rebuild wrapper script
#
# 사용법:
#   nrs.sh           # 일반 rebuild
#   nrs.sh --offline # 오프라인 rebuild (빠름)
#   nrs.sh --update  # nixos-config-secret flake input 업데이트 후 rebuild
#
# 안전 기능:
#   - SSH 키 로드 확인
#   - GitHub SSH 접근 테스트
#   - nixos-config-secret 프라이빗 레포 접근 테스트
#   - sudo 환경에서 SSH_AUTH_SOCK 전달
#   - nixos-config-secret 로컬 변경 감지 및 경고

set -euo pipefail

FLAKE_PATH="$HOME/IdeaProjects/nixos-config"
SECRET_PATH="$HOME/IdeaProjects/nixos-config-secret"
SECRET_REPO="git@github.com:shren207/nixos-config-secret.git"
OFFLINE_FLAG=""
UPDATE_FLAG=""

# 인수 파싱
for arg in "$@"; do
    case "$arg" in
        --offline)
            OFFLINE_FLAG="--offline"
            ;;
        --update)
            UPDATE_FLAG="true"
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
#───────────────────────────────────────────────────────────────────────────────
ensure_ssh_key_loaded() {
    if ! ssh-add -l 2>/dev/null | grep -q "id_ed25519"; then
        log_info "🔑 Loading SSH key..."
        ssh-add ~/.ssh/id_ed25519
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# nixos-config-secret 로컬 변경 감지
#───────────────────────────────────────────────────────────────────────────────
check_secret_repo_sync() {
    if [[ ! -d "$SECRET_PATH" ]]; then
        return 0
    fi

    local has_warning=false

    # 1. uncommitted 변경 확인
    if [[ -n "$(git -C "$SECRET_PATH" status --porcelain 2>/dev/null)" ]]; then
        log_warn "⚠️  nixos-config-secret에 커밋되지 않은 변경이 있습니다"
        log_warn "   경로: $SECRET_PATH"
        has_warning=true
    fi

    # 2. unpushed commits 확인
    local unpushed
    unpushed=$(git -C "$SECRET_PATH" log origin/main..HEAD --oneline 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$unpushed" -gt 0 ]]; then
        log_warn "⚠️  nixos-config-secret에 push되지 않은 커밋이 ${unpushed}개 있습니다"
        has_warning=true
    fi

    # 3. flake.lock과 remote main 비교 (--offline이 아닐 때만)
    if [[ -z "$OFFLINE_FLAG" ]]; then
        # flake.lock에서 현재 잠긴 rev 추출
        local locked_rev
        locked_rev=$(nix flake metadata "$FLAKE_PATH" --json 2>/dev/null | \
            jq -r '.locks.nodes["nixos-config-secret"].locked.rev // empty' 2>/dev/null || echo "")

        if [[ -n "$locked_rev" ]]; then
            # remote main의 최신 rev 가져오기
            local remote_rev
            remote_rev=$(git -C "$SECRET_PATH" ls-remote origin main 2>/dev/null | cut -f1 || echo "")

            if [[ -n "$remote_rev" && "$locked_rev" != "$remote_rev" ]]; then
                log_warn "⚠️  nixos-config-secret이 업데이트되었지만 flake.lock에 반영되지 않았습니다"
                log_warn "   locked: ${locked_rev:0:7}"
                log_warn "   remote: ${remote_rev:0:7}"
                log_warn "   💡 'nrs --update' 또는 'nix flake update nixos-config-secret' 실행 필요"
                has_warning=true
            fi
        fi
    fi

    if [[ "$has_warning" == "true" ]]; then
        echo ""
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# flake input 업데이트 (--update 옵션)
#───────────────────────────────────────────────────────────────────────────────
update_flake_inputs() {
    if [[ "$UPDATE_FLAG" != "true" ]]; then
        return 0
    fi

    log_info "🔄 Updating nixos-config-secret flake input..."
    nix flake update nixos-config-secret --flake "$FLAKE_PATH"
    log_info "  ✓ flake.lock updated"
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# GitHub SSH 접근 테스트
#───────────────────────────────────────────────────────────────────────────────
test_github_access() {
    log_info "🔐 Testing GitHub SSH access..."

    # 일반 사용자 환경에서 GitHub 접근 테스트
    # ssh -T는 인증 성공해도 exit code 1 반환 (shell access 미제공)
    # pipefail 때문에 별도 변수에 저장 후 grep
    local ssh_output
    ssh_output=$(ssh -T git@github.com 2>&1 || true)
    if ! echo "$ssh_output" | grep -q "successfully authenticated"; then
        log_error "❌ GitHub SSH authentication failed!"
        log_error "   Run: ssh-add ~/.ssh/id_ed25519"
        exit 1
    fi
    log_info "  ✓ GitHub SSH access OK"
}

#───────────────────────────────────────────────────────────────────────────────
# nixos-config-secret 프라이빗 레포 접근 테스트
#───────────────────────────────────────────────────────────────────────────────
test_secret_repo_access() {
    log_info "🔒 Testing nixos-config-secret access..."

    # git ls-remote로 프라이빗 레포 접근 테스트 (실제 clone 없이)
    if ! git ls-remote "$SECRET_REPO" HEAD &>/dev/null; then
        log_error "❌ Cannot access nixos-config-secret repository!"
        log_error "   Check your SSH key permissions for the private repo."
        exit 1
    fi
    log_info "  ✓ nixos-config-secret access OK"
}

#───────────────────────────────────────────────────────────────────────────────
# sudo 환경에서 SSH 접근 테스트
#───────────────────────────────────────────────────────────────────────────────
test_sudo_ssh_access() {
    log_info "🔑 Testing SSH access under sudo..."

    # sudo 환경에서 SSH_AUTH_SOCK이 전달되는지 확인
    # ssh -T는 인증 성공해도 exit code 1 반환 (shell access 미제공)
    local ssh_output
    ssh_output=$(sudo SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh -T git@github.com 2>&1 || true)
    if ! echo "$ssh_output" | grep -q "successfully authenticated"; then
        log_error "❌ GitHub SSH authentication failed under sudo!"
        log_error "   SSH_AUTH_SOCK is not properly forwarded."
        exit 1
    fi
    log_info "  ✓ sudo SSH access OK"
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
    if ! sudo SSH_AUTH_SOCK="$SSH_AUTH_SOCK" nixos-rebuild build --flake "$FLAKE_PATH" $OFFLINE_FLAG; then
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

    # shellcheck disable=SC2086
    sudo SSH_AUTH_SOCK="$SSH_AUTH_SOCK" nixos-rebuild switch --flake "$FLAKE_PATH" $OFFLINE_FLAG
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

    # 1. SSH 인증 검증 (--offline이 아닐 때만)
    if [[ -z "$OFFLINE_FLAG" ]]; then
        ensure_ssh_key_loaded
        check_secret_repo_sync
        update_flake_inputs
        test_github_access
        test_secret_repo_access
        test_sudo_ssh_access
        echo ""
    fi

    # 2. 빌드 및 적용
    preview_changes
    run_nixos_rebuild
    cleanup_build_artifacts

    echo ""
    log_info "✅ Done!"
}

main
