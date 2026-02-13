#!/usr/bin/env bash
# darwin-rebuild wrapper script
# 문제 예방: setupLaunchAgents 멈춤, Hammerspoon HOME 오염
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
NC='\033[0m' # No Color

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
# 0단계: 외부 패키지 버전 갱신 (fetchurl 기반)
#───────────────────────────────────────────────────────────────────────────────
update_external_packages() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_warn "⏭️  Skipping package updates (offline mode)"
        return
    fi

    log_info "📦 Checking for external package updates..."

    if "$FLAKE_PATH/scripts/update-codex-cli.sh"; then
        :
    else
        log_warn "  ⚠️  Codex CLI update check failed (continuing anyway)"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 1단계: launchd 에이전트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_launchd_agents() {
    log_info "🧹 Cleaning up launchd agents..."

    local uid cleaned=0 failed=0 exit_code
    uid=$(id -u)

    # 동적으로 com.green.* 에이전트 찾아서 정리
    # 주의: ((++var)) 사용 필수. ((var++))는 var=0일 때 exit code 1 반환 → set -e로 스크립트 종료됨
    while IFS= read -r agent; do
        [[ -z "$agent" ]] && continue

        if launchctl bootout "gui/${uid}/${agent}" 2>/dev/null; then
            ((++cleaned))
        else
            # 에이전트가 이미 없는 경우는 무시, 다른 에러는 기록
            exit_code=$?
            if [[ $exit_code -ne 3 ]]; then  # 3 = No such process (정상)
                log_warn "  ⚠️  Failed to bootout: $agent (exit: $exit_code)"
                ((++failed))
            fi
        fi
    done < <(launchctl list 2>/dev/null | awk '/com\.green\./ {print $3}')

    # plist 파일 삭제
    local plist_count
    plist_count=$(find ~/Library/LaunchAgents -name 'com.green.*.plist' 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$plist_count" -gt 0 ]]; then
        rm -f ~/Library/LaunchAgents/com.green.*.plist
        log_info "  ✓ Removed $plist_count plist file(s)"
    fi

    if [[ $cleaned -gt 0 ]]; then
        log_info "  ✓ Cleaned up $cleaned agent(s)"
    fi

    # launchd 내부 상태 정리 대기
    sleep 1
}

#───────────────────────────────────────────────────────────────────────────────
# 2단계: 빌드 및 변경사항 미리보기
#───────────────────────────────────────────────────────────────────────────────
preview_changes() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Building (offline, preview)..."
    else
        log_info "🔨 Building (preview)..."
    fi

    # shellcheck disable=SC2086
    if ! sudo darwin-rebuild build --flake "$FLAKE_PATH" $OFFLINE_FLAG; then
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
# 3단계: darwin-rebuild switch 실행
#───────────────────────────────────────────────────────────────────────────────
run_darwin_rebuild() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Applying changes (offline)..."
    else
        log_info "🔨 Applying changes..."
    fi

    # shellcheck disable=SC2086
    sudo darwin-rebuild switch --flake "$FLAKE_PATH" $OFFLINE_FLAG
}

#───────────────────────────────────────────────────────────────────────────────
# 4단계: Hammerspoon 재시작
#───────────────────────────────────────────────────────────────────────────────
restart_hammerspoon() {
    log_info "🔄 Restarting Hammerspoon..."

    # Hammerspoon이 실행 중인 경우에만 재시작
    if pgrep -x "Hammerspoon" > /dev/null; then
        killall Hammerspoon 2>/dev/null || true
        sleep 1
    fi

    open -a Hammerspoon
    log_info "  ✓ Hammerspoon restarted"
}

#───────────────────────────────────────────────────────────────────────────────
# 5단계: 빌드 아티팩트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_build_artifacts() {
    log_info "🧹 Cleaning up build artifacts..."

    local count
    count=$(find "$FLAKE_PATH" -maxdepth 1 -name 'result*' -type l 2>/dev/null | wc -l | tr -d ' ')

    if [[ "$count" -gt 0 ]]; then
        # result는 sudo darwin-rebuild로 생성되어 root 소유. 그렇기 때문에 삭제할 때도 root 권한이 필요함
        sudo rm -f "$FLAKE_PATH"/result*
        log_info "  ✓ Removed $count result symlink(s)"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    # darwin-rebuild build가 pwd에 ./result를 생성하므로 디렉토리 이동 필수
    cd "$FLAKE_PATH" || exit 1

    echo ""
    update_external_packages
    cleanup_launchd_agents
    preview_changes
    run_darwin_rebuild
    restart_hammerspoon
    cleanup_build_artifacts
    echo ""
    log_info "✅ Done!"
}

main
