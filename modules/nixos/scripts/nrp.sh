#!/usr/bin/env bash
# nixos-rebuild preview script (build only, no switch)
#
# 사용법:
#   nrp.sh           # 미리보기
#   nrp.sh --offline # 오프라인 미리보기 (빠름)

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="nixos-rebuild"
# shellcheck source=/dev/null  # 런타임에 ~/.local/lib/rebuild-common.sh 로딩
source "$HOME/.local/lib/rebuild-common.sh"
parse_args "$@"

#───────────────────────────────────────────────────────────────────────────────
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    cd "$FLAKE_PATH" || exit 1
    preview_changes "preview only" "Changes (preview only, not applied):"
    cleanup_build_artifacts
    echo ""
    log_info "✅ Preview complete (no changes applied)"
}

main
