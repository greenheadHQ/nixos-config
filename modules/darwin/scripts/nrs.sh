#!/usr/bin/env bash
# darwin-rebuild wrapper script
# 문제 예방: setupLaunchAgents 멈춤, Hammerspoon HOME 오염
#
# 사용법:
#   nrs.sh           # 일반 rebuild
#   nrs.sh --offline # 오프라인 rebuild (빠름)
#   nrs.sh --update  # nixos-config-secret flake input 업데이트 후 rebuild
#
# 소스 참조 방식:
#   - nrs, nrs-offline 모두 flake.lock에 잠긴 remote Git URL에서 소스를 참조함
#   - 로컬 경로(path:...)가 아닌 SSH URL(git+ssh://...)을 사용하므로 로컬 파일 직접 참조 없음
#   - --offline 플래그는 "다운로드를 건너뛰고 Nix store 캐시만 사용"하는 것이지,
#     로컬 경로로 전환하는 것이 아님
#   - 새 input 버전을 반영하려면 먼저 `nix flake update <input>`으로 flake.lock 업데이트 필요

set -euo pipefail

FLAKE_PATH="$HOME/IdeaProjects/nixos-config"
SECRET_PATH="$HOME/IdeaProjects/nixos-config-secret"
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
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}$1${NC}"; }
log_warn() { echo -e "${YELLOW}$1${NC}"; }
log_error() { echo -e "${RED}$1${NC}"; }

#───────────────────────────────────────────────────────────────────────────────
# 0단계: SSH 키 로드 확인
#───────────────────────────────────────────────────────────────────────────────
ensure_ssh_key_loaded() {
    if ! ssh-add -l 2>/dev/null | grep -q "id_ed25519"; then
        log_info "🔑 Loading SSH key..."
        ssh-add ~/.ssh/id_ed25519
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# 0.5단계: nixos-config-secret 로컬 변경 감지
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
# 0.7단계: flake input 업데이트 (--update 옵션)
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
# 5단계: Hammerspoon 재시작
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
# 6단계: 빌드 아티팩트 정리
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
    ensure_ssh_key_loaded
    check_secret_repo_sync
    update_flake_inputs
    cleanup_launchd_agents
    preview_changes
    run_darwin_rebuild
    restart_hammerspoon
    cleanup_build_artifacts
    echo ""
    log_info "✅ Done!"
}

main
