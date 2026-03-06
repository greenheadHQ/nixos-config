#!/usr/bin/env bash
# nixos-rebuild wrapper script
#
# 사용법:
#   nrs.sh                       # 일반 rebuild
#   nrs.sh --offline             # 오프라인 rebuild (빠름)
#   nrs.sh --force               # 소스 빌드 경고 무시
#   nrs.sh --force --cores 2    # 코어 제한으로 진행

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
        return 0
    fi
    run_nixos_rebuild
    cleanup_build_artifacts

    echo ""
    log_info "✅ Done! (${SECONDS}s)"
}

main
