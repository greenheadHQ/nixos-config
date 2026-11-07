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
    local link listing count=0
    # EXIT trap에서도 호출되므로 정리 실패는 경고하고 원래 종료·락 해제를 보존한다.
    if listing=$(mktemp); then
        :
    else
        log_warn "Cannot prepare build artifact cleanup; existing links are preserved"
        return 0
    fi
    # 검색이 완전히 성공한 뒤에만 삭제한다. 부분 출력 뒤 실패한 목록은 사용하지 않는다.
    if find "$FLAKE_PATH" -maxdepth 1 -name 'result*' -type l -print0 > "$listing" 2>/dev/null; then
        :
    else
        rm -f -- "$listing" || log_warn "Cannot remove build artifact cleanup listing"
        log_warn "Cannot enumerate build artifacts; existing links are preserved"
        return 0
    fi
    # NUL을 셸 변수에 담거나 경로를 다시 토큰화하지 않는다.
    while IFS= read -r -d '' link; do
        [[ -L "$link" ]] || continue
        if [[ "$count" -eq 0 ]]; then
            log_info "🧹 Cleaning up build artifacts..."
        fi
        if rm -f -- "$link"; then
            :
        else
            rm -f -- "$listing" || log_warn "Cannot remove build artifact cleanup listing"
            log_warn "Build artifact cleanup failed"
            return 0
        fi
        ((++count))
    done < "$listing"
    rm -f -- "$listing" || log_warn "Cannot remove build artifact cleanup listing"

    if [[ "$count" -gt 0 ]]; then
        log_info "  ✓ Removed $count result symlink(s)"
    fi
}
