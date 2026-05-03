#!/usr/bin/env bash
# nixos-rebuild wrapper script
#
# 사용법:
#   nrs                       # 일반 rebuild
#   nrs --offline             # 오프라인 rebuild (빠름)
#   nrs --force               # 소스 빌드 경고 무시
#   nrs --force --cores 2    # 코어 제한으로 진행

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="nixos-rebuild"
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
    sudo "$REBUILD_CMD" switch --flake "$FLAKE_PATH" $OFFLINE_FLAG $CORES_FLAG || rc=$?

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
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    cd "$FLAKE_PATH" || exit 1
    trap 'cleanup_build_artifacts; release_rebuild_lock_on_failure' EXIT

    _clear_retired_codex_hook_artifacts
    echo ""
    preflight_source_build_check
    preview_changes "preview" "Changes to be applied:"
    if [[ "$NO_CHANGES" == true && "$FORCE_FLAG" != true ]]; then
        echo ""
        log_info "✅ No changes to apply. Skipping rebuild."
        maybe_relink_or_restore
        repair_codex_config_drift_no_changes
        return 0
    fi
    worktree_symlink_guard
    acquire_rebuild_lock
    # Pre-rebuild restore:
    # HM activation의 checkLinkTargets가 non-HMF 심링크(worktree 타깃)를
    # "would be clobbered"로 거부하므로, rebuild 전에 먼저 복원한다.
    # Safety: HM gcroot가 유효할 때만 실행 — gcroot 파손 시 Phase 1(rm)만 되고
    # Phase 2(restore) 실패하여 심링크 유실 방지
    if rebuild_is_main_flake \
       && [[ -e "$HOME/.local/state/home-manager/gcroots/current-home" ]]; then
        maybe_relink_or_restore
    elif ! rebuild_is_main_flake; then
        prepare_worktree_symlinks_for_rebuild
    fi
    run_nixos_rebuild
    maybe_relink_or_restore
    release_rebuild_lock
    cleanup_build_artifacts

    echo ""
    log_info "✅ Done! (${SECONDS}s)"
}

main
