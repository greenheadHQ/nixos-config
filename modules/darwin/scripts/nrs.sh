#!/usr/bin/env bash
# darwin-rebuild wrapper script
# 문제 예방: setupLaunchAgents 멈춤, Hammerspoon HOME 오염
#
# 사용법:
#   nrs.sh           # 일반 rebuild
#   nrs.sh --offline # 오프라인 rebuild (빠름)
#   nrs.sh --force   # NO_CHANGES 스킵 우회 (activation scripts 강제 재실행)

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="darwin-rebuild"
# shellcheck source=/dev/null  # 런타임에 ~/.local/lib/rebuild-common.sh 로딩
source "$HOME/.local/lib/rebuild-common.sh"
parse_args "$@"

#───────────────────────────────────────────────────────────────────────────────
# launchd 에이전트 정리
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
    if [[ $failed -gt 0 ]]; then
        log_warn "  ⚠️  $failed agent(s) failed to bootout"
    fi

    # launchd 내부 상태 정리 대기
    sleep 1
}

#───────────────────────────────────────────────────────────────────────────────
# darwin-rebuild switch 실행
#───────────────────────────────────────────────────────────────────────────────
run_darwin_rebuild() {
    if [[ -n "$OFFLINE_FLAG" ]]; then
        log_info "🔨 Applying changes (offline)..."
    else
        log_info "🔨 Applying changes..."
    fi

    local rc=0
    # shellcheck disable=SC2086
    sudo "$REBUILD_CMD" switch --flake "$FLAKE_PATH" $OFFLINE_FLAG || rc=$?

    if [[ "$rc" -ne 0 ]]; then
        log_error "❌ darwin-rebuild switch failed (exit code: $rc)"
        exit "$rc"
    fi
}

#───────────────────────────────────────────────────────────────────────────────
# Hammerspoon 재시작
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
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    # darwin-rebuild build가 pwd에 ./result를 생성하므로 디렉토리 이동 필수
    cd "$FLAKE_PATH" || exit 1

    echo ""
    preview_changes "preview" "Changes to be applied:"
    if [[ "$NO_CHANGES" == true && "$FORCE_FLAG" != true ]]; then
        cleanup_build_artifacts
        echo ""
        log_info "✅ No changes to apply. Skipping rebuild."
        log_info "  (Use 'nrs --force' to force full rebuild including activation scripts)"
        return 0
    fi
    cleanup_launchd_agents
    run_darwin_rebuild
    restart_hammerspoon
    cleanup_build_artifacts
    echo ""
    log_info "✅ Done!"
}

main
