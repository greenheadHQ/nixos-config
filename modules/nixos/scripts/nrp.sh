#!/usr/bin/env bash
# nixos-rebuild preview script (build only, no switch)
#
# 사용법 (공용 usage의 요약 — 전체는 nrp --help):
#   nrp                       # 미리보기 (소스 빌드는 경고만, 항상 진행)
#   nrp --offline             # 오프라인 미리보기 (빠름)
#   nrp --cores 2             # 코어 제한으로 진행
#   nrp --help                # 사용법 출력

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="nixos-rebuild"
# shellcheck disable=SC2034  # REBUILD_MODE는 source된 rebuild-common.sh의 usage 분기에서 사용
REBUILD_MODE="preview"
# shellcheck source=/dev/null  # 런타임에 ~/.local/lib/rebuild-common.sh 로딩
source "$HOME/.local/lib/rebuild-common.sh"
parse_args "$@"

#───────────────────────────────────────────────────────────────────────────────
# 메인
#───────────────────────────────────────────────────────────────────────────────
main() {
    cd "$FLAKE_PATH" || exit 1
    trap cleanup_build_artifacts EXIT
    preflight_source_build_check --warn-only
    preview_changes "preview only" "Changes (preview only, not applied):"
    cleanup_build_artifacts
    echo ""
    log_info "✅ Preview complete (no changes applied)"
}

main
