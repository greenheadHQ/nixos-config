#!/usr/bin/env bash
# darwin-rebuild preview-only script
# 빌드 후 변경사항만 미리보기 (switch 없이)
#
# 사용법 (공용 usage의 요약 — 전체는 nrp --help):
#   nrp           # 일반 미리보기
#   nrp --offline # 오프라인 미리보기
#   nrp --help    # 사용법 출력

set -euo pipefail

# shellcheck disable=SC2034  # REBUILD_CMD는 source된 rebuild-common.sh에서 사용
REBUILD_CMD="darwin-rebuild"
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
    preview_changes "preview only" "Changes (preview only, not applied):"
    cleanup_build_artifacts
    echo ""
    log_info "💡 Run 'nrs' to apply these changes."
}

main
