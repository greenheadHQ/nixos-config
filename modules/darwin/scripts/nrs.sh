#!/usr/bin/env bash
# darwin-rebuild wrapper script
# 문제 예방: setupLaunchAgents 멈춤, Hammerspoon HOME 오염
#
# 사용법:
#   nrs           # 일반 rebuild
#   nrs --offline # 오프라인 rebuild (빠름)
#   nrs --force   # NO_CHANGES 스킵 우회 (activation scripts 강제 재실행)

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="darwin-rebuild"
# shellcheck source=/dev/null  # 런타임에 ~/.local/lib/rebuild-common.sh 로딩
source "$HOME/.local/lib/rebuild-common.sh"
parse_args "$@"

# repo-local 최신 entrypoint가 이전 deployed helper tree와 조합돼도 동작하도록 유지.
install_rebuild_common_compat_shims() {
    declare -F rebuild_is_main_flake >/dev/null || rebuild_is_main_flake() {
        [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]]
    }
    declare -F prepare_worktree_symlinks_for_rebuild >/dev/null || prepare_worktree_symlinks_for_rebuild() {
        log_info "🔗 Removing worktree symlinks before rebuild..."
        _remove_worktree_symlinks "$FLAKE_PATH/" "worktree" || true
        "$HOME/.local/bin/nrs-relink" restore || log_warn "⚠️  nrs-relink restore failed (non-fatal)"
    }
    declare -F release_nrs_lock_after_no_changes >/dev/null || release_nrs_lock_after_no_changes() {
        if [[ "${NRS_LOCK_ACQUIRED:-false}" == true && "${NRS_LOCK_REENTRY:-false}" != true ]]; then
            release_nrs_lock
        fi
    }
    declare -F mark_nrs_lock_switch_success >/dev/null || mark_nrs_lock_switch_success() {
        # shellcheck disable=SC2034  # Older deployed helpers still read this global in failure cleanup.
        NRS_LOCK_SWITCH_SUCCESS=true
    }
    local codex_legacy_hooks_helper
    local -a codex_legacy_hooks_candidates=()
    if [[ -n "${REBUILD_COMMON_LIB_DIR:-}" ]]; then
        codex_legacy_hooks_candidates+=("$REBUILD_COMMON_LIB_DIR/codex-legacy-hooks.sh")
    fi
    codex_legacy_hooks_candidates+=("$FLAKE_PATH/modules/shared/scripts/lib/rebuild/codex-legacy-hooks.sh")

    for codex_legacy_hooks_helper in "${codex_legacy_hooks_candidates[@]}"; do
        [[ -n "$codex_legacy_hooks_helper" && -f "$codex_legacy_hooks_helper" ]] || continue
        # shellcheck source=/dev/null
        source "$codex_legacy_hooks_helper"
        declare -F codex_clear_retired_hook_artifacts >/dev/null && break
    done
    declare -F codex_clear_retired_hook_artifacts >/dev/null && _clear_retired_codex_hook_artifacts() {
        codex_clear_retired_hook_artifacts "$FLAKE_PATH" "$HOME"
    }
    # 구버전 rebuild-common.sh 는 codex helper 가 없어 이 함수도 없다. 그 조합에서는
    # NO_CHANGES 경로가 "command not found"로 죽지 않도록 no-op shim 을 둔다. 사용자가
    # 한 번 nrs --force 로 새 HM generation 을 활성화하면 shim 이 실 helper 로 교체된다.
    declare -F repair_codex_config_drift_no_changes >/dev/null || repair_codex_config_drift_no_changes() {
        return 0
    }
}

install_rebuild_common_compat_shims

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
        if [[ -n "${UNINSTALLED_CASKS:-}" ]]; then
            echo ""
            log_warn "⚠️  The following cask(s) were uninstalled before rebuild:"
            # shellcheck disable=SC2086  # 의도적 word splitting — 공백 구분 cask 목록
            for cask in $UNINSTALLED_CASKS; do
                echo "    brew install --cask $cask"
            done
            echo "  Run the above to restore if needed."
        fi
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
    trap 'cleanup_build_artifacts; release_rebuild_lock_on_failure; release_nrs_lock_on_failure' EXIT

    _clear_retired_codex_hook_artifacts
    echo ""
    acquire_nrs_lock
    preview_changes "preview" "Changes to be applied:"
    if [[ "$NO_CHANGES" == true && "$FORCE_FLAG" != true ]]; then
        echo ""
        log_info "✅ No changes to apply. Skipping rebuild."
        log_info "  (Use 'nrs --force' to force full rebuild including activation scripts)"
        maybe_relink_or_restore
        repair_codex_config_drift_no_changes
        release_nrs_lock_after_no_changes
        return 0
    fi
    worktree_symlink_guard

    # Critical section: cask conflict resolve + cleanup + restore + switch를 serialize
    # DA Fix #3: cleanup이 lock 밖에 있으면 다른 프로세스의 switch와 겹칠 수 있음
    # CodeRabbit: preflight_cask_conflict_check의 brew uninstall도 lock 안에서 실행
    acquire_rebuild_lock
    preflight_cask_conflict_check
    cleanup_launchd_agents
    # Pre-rebuild restore:
    # HM activation의 checkLinkTargets가 non-HMF 심링크(worktree 타깃)를
    # "would be clobbered"로 거부하므로, rebuild 전에 먼저 복원한다.
    # - main: maybe_relink_or_restore() → stale worktree symlink 제거 + nix store 복원
    # - worktree: worktree 심링크 직접 제거 + nrs-relink restore로 기존 entry 복원
    #   (activation 성공 후 maybe_relink_or_restore()가 다시 worktree로 relink)
    if rebuild_is_main_flake; then
        maybe_relink_or_restore
    else
        prepare_worktree_symlinks_for_rebuild
    fi
    run_darwin_rebuild
    mark_nrs_lock_switch_success
    maybe_relink_or_restore
    release_rebuild_lock
    restart_hammerspoon
    cleanup_build_artifacts
    echo ""
    log_info "✅ Done! (${SECONDS}s)"
}

main
