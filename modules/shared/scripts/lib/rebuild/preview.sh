# shellcheck shell=bash
#───────────────────────────────────────────────────────────────────────────────
# 빌드 및 변경사항 미리보기
# 인수: $1 = 빌드 라벨 ("preview" 또는 "preview only"), $2 = diff 헤더 메시지
# 부수효과: NO_CHANGES를 true/false로 설정 (store 경로 비교)
# offline 접두사는 OFFLINE_FLAG에 따라 자동 추가
#───────────────────────────────────────────────────────────────────────────────
preview_changes() {
    local label="${1:-preview}"
    local diff_msg="${2:-Changes:}"

    local offline_tag=""
    [[ -n "$OFFLINE_FLAG" ]] && offline_tag="offline, "

    log_info "🔨 Building (${offline_tag}${label})..."

    # shellcheck disable=SC2086
    if ! "$REBUILD_CMD" build --flake "$FLAKE_PATH" $OFFLINE_FLAG $CORES_FLAG; then
        log_error "❌ Build failed!"
        exit 1
    fi

    echo ""
    log_info "📋 $diff_msg"
    # nvd diff 출력 안내:
    # - <none> 버전: home-manager 관리 파일(files, hm_*)은 버전 접미사가 없어 정상적으로 <none> 표시
    # - nvd diff는 동일 결과 시 non-zero 반환 가능
    if ! nvd diff /run/current-system ./result; then
        log_warn "⚠️  nvd diff returned non-zero (possibly identical results)"
    fi

    # shellcheck disable=SC2034  # NO_CHANGES는 source한 nrs.sh에서 사용
    NO_CHANGES=false
    if [[ -L ./result ]] && [[ "$(readlink ./result)" == "$(readlink /run/current-system)" ]]; then
        # shellcheck disable=SC2034  # NO_CHANGES는 source한 nrs.sh에서 사용
        NO_CHANGES=true
    fi
    echo ""
}

#───────────────────────────────────────────────────────────────────────────────
# 빌드 아티팩트 정리
#───────────────────────────────────────────────────────────────────────────────
cleanup_build_artifacts() {
    local links
    links=$(find "$FLAKE_PATH" -maxdepth 1 -name 'result*' -type l 2>/dev/null)
    local count
    count=$(echo "$links" | grep -c . 2>/dev/null || true)

    if [[ "$count" -gt 0 ]]; then
        log_info "🧹 Cleaning up build artifacts..."
        # result는 일반 사용자 build로 생성되어 사용자 소유
        echo "$links" | xargs rm -f
        log_info "  ✓ Removed $count result symlink(s)"
    fi
}
