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
    trap cleanup_build_artifacts EXIT

    echo ""
    preflight_source_build_check
    preview_changes "preview" "Changes to be applied:"
    if [[ "$NO_CHANGES" == true && "$FORCE_FLAG" != true ]]; then
        echo ""
        log_info "✅ No changes to apply. Skipping rebuild."
        maybe_relink_or_restore
        return 0
    fi
    worktree_symlink_guard
    # Pre-rebuild restore (darwin과 같은 이유):
    # HM activation의 checkLinkTargets가 non-HMF 심링크(worktree 타깃)를
    # "would be clobbered"로 거부하므로, main에서는 rebuild 전에 먼저 복원
    # Safety: HM gcroot가 유효할 때만 실행 — gcroot 파손 시 Phase 1(rm)만 되고
    # Phase 2(restore) 실패하여 심링크 유실 방지
    if [[ "$FLAKE_PATH" == "$MAIN_FLAKE_PATH" ]] \
       && [[ -e "$HOME/.local/state/home-manager/gcroots/current-home" ]]; then
        maybe_relink_or_restore
    fi
    run_nixos_rebuild
    maybe_relink_or_restore
    cleanup_build_artifacts

    echo ""
    log_info "✅ Done! (${SECONDS}s)"
}

main
